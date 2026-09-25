"""
TradingView -> MT5 webhook bridge for the Sideway Breakout Bot "Signal" indicator.

Receives the raw alert() message TradingView posts to this server's /webhook
endpoint, and (if it's valid JSON carrying the right secret) drops it as its
own file into the MT5 terminal's COMMON Files folder, where
mt5/SidewayBreakoutBotSignalEA.mq5 picks it up.

Run on the SAME machine/VPS as the MT5 terminal (per the "same machine"
architecture choice) so the EA can read the pending folder directly -- no
need to whitelist a URL in MT5's WebRequest options.

Usage:
    pip install -r requirements.txt
    set BRIDGE_SECRET=your-own-secret          (must match the Pine input)
    python webhook_bridge.py

Then in TradingView, create an alert on the Signal indicator with
"Webhook URL" set to http://<this-machine's-address>:5000/webhook
(condition: "Any alert() function call" on the indicator, so every
OPEN/MODIFY_SL/CLOSE JSON alert gets forwarded -- the other, plain-text
alerts this indicator also fires just get logged and ignored below).
"""

import json
import logging
import os
import tempfile
import time
import uuid

from flask import Flask, request, jsonify

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("bridge")

app = Flask(__name__)

# The secret must match the "Shared Secret" input on the Pine Signal indicator.
SECRET = os.environ.get("BRIDGE_SECRET", "changeme")

# Default: the current Windows user's MT5 Common Files folder. Override with
# BRIDGE_PENDING_DIR if the EA's PendingFolder input isn't the default
# "SidewayBreakoutBot\pending", or if MT5 is a different user account.
DEFAULT_PENDING_DIR = os.path.join(
    os.environ.get("APPDATA", ""), "MetaQuotes", "Terminal", "Common", "Files",
    "SidewayBreakoutBot", "pending",
)
PENDING_DIR = os.environ.get("BRIDGE_PENDING_DIR", DEFAULT_PENDING_DIR)

VALID_ACTIONS = {"OPEN", "MODIFY_SL", "CLOSE"}


def write_signal_file(payload: dict) -> str:
    """Write one JSON object as its own file, atomically (temp file + rename)
    so the EA never reads a half-written file mid-poll."""
    os.makedirs(PENDING_DIR, exist_ok=True)
    fname = f"{int(time.time() * 1000)}_{uuid.uuid4().hex[:8]}.json"
    final_path = os.path.join(PENDING_DIR, fname)
    fd, tmp_path = tempfile.mkstemp(dir=PENDING_DIR, prefix=".tmp_")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(payload, f)
        os.replace(tmp_path, final_path)
    except Exception:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
        raise
    return final_path


@app.route("/", methods=["GET"])
def health():
    return jsonify({"status": "ok", "pending_dir": PENDING_DIR})


@app.route("/webhook", methods=["POST"])
def webhook():
    raw = request.get_data(as_text=True)

    try:
        payload = json.loads(raw)
    except (ValueError, TypeError):
        # This indicator also fires plain-text alerts (breakout detected, TP hit
        # notifications, etc.) through the same "any alert() call" webhook -- those
        # aren't meant for MT5, so just log and ignore rather than error.
        log.info("Ignoring non-JSON alert: %r", raw[:200])
        return jsonify({"status": "ignored", "reason": "not JSON"}), 200

    if not isinstance(payload, dict):
        log.warning("Ignoring JSON alert that isn't an object: %r", raw[:200])
        return jsonify({"status": "ignored", "reason": "not an object"}), 200

    if payload.get("secret") != SECRET:
        log.warning("Rejected webhook call with wrong/missing secret")
        return jsonify({"status": "rejected", "reason": "bad secret"}), 401

    action = payload.get("action")
    if action not in VALID_ACTIONS:
        log.warning("Ignoring JSON alert with unknown action: %r", action)
        return jsonify({"status": "ignored", "reason": "unknown action"}), 200

    if not payload.get("group_id"):
        log.warning("Ignoring %s alert with no group_id", action)
        return jsonify({"status": "ignored", "reason": "missing group_id"}), 200

    path = write_signal_file(payload)
    log.info("Queued %s group_id=%s -> %s", action, payload.get("group_id"), path)
    return jsonify({"status": "queued"}), 200


if __name__ == "__main__":
    log.info("Pending dir: %s", PENDING_DIR)
    if SECRET == "changeme":
        log.warning("BRIDGE_SECRET is not set -- using the default 'changeme'. Set it to something private.")
    app.run(host="0.0.0.0", port=int(os.environ.get("BRIDGE_PORT", "5000")))
