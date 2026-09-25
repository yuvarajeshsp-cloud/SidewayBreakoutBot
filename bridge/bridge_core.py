"""
Shared webhook-receiving logic for the Sideway Breakout Bot MT5 bridge.

Used by both webhook_bridge.py (plain console/headless) and bridge_app.py
(Windows GUI with a live signal table) -- both just call create_app() with
different `on_event` callbacks, so the actual webhook handling only lives
here, once.
"""

import json
import logging
import os
import tempfile
import time
import uuid

from flask import Flask, request, jsonify

log = logging.getLogger("bridge")

VALID_ACTIONS = {"OPEN", "MODIFY_SL", "CLOSE"}


def default_pending_dir() -> str:
    """The current Windows user's MT5 Common Files pending folder. Override
    if the EA's PendingFolder input isn't the default
    "SidewayBreakoutBot\\pending", or if MT5 runs under a different user."""
    return os.path.join(
        os.environ.get("APPDATA", ""), "MetaQuotes", "Terminal", "Common", "Files",
        "SidewayBreakoutBot", "pending",
    )


def write_signal_file(pending_dir: str, payload: dict) -> str:
    """Write one JSON object as its own file, atomically (temp file + rename)
    so the EA never reads a half-written file mid-poll."""
    os.makedirs(pending_dir, exist_ok=True)
    fname = f"{int(time.time() * 1000)}_{uuid.uuid4().hex[:8]}.json"
    final_path = os.path.join(pending_dir, fname)
    fd, tmp_path = tempfile.mkstemp(dir=pending_dir, prefix=".tmp_")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(payload, f)
        os.replace(tmp_path, final_path)
    except Exception:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
        raise
    return final_path


def create_app(get_secret, get_pending_dir, on_event=None):
    """Build the Flask app.

    get_secret / get_pending_dir: zero-arg callables returning the CURRENT
    value -- callables (not plain values) so a GUI can let the user change
    the secret live, without restarting the server.

    on_event: optional callable(record: dict), called for every /webhook hit
    (accepted, rejected, or ignored) -- the GUI uses this to fill its table.
    record keys: time, action, group_id, leg, symbol, dir, entry, sl, tp,
    status, raw.
    """
    app = Flask(__name__)

    def emit(status, payload=None, raw=None):
        if on_event is None:
            return
        p = payload or {}
        on_event({
            "time": time.strftime("%Y-%m-%d %H:%M:%S"),
            "action": p.get("action", ""),
            "group_id": p.get("group_id", ""),
            "leg": p.get("leg", ""),
            "symbol": p.get("symbol", ""),
            "dir": p.get("dir", ""),
            "entry": p.get("entry", ""),
            "sl": p.get("sl", ""),
            "tp": p.get("tp", ""),
            "status": status,
            "raw": raw if raw is not None else json.dumps(p),
        })

    @app.route("/", methods=["GET"])
    def health():
        return jsonify({"status": "ok", "pending_dir": get_pending_dir()})

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
            emit("ignored (not JSON)", raw=raw)
            return jsonify({"status": "ignored", "reason": "not JSON"}), 200

        if not isinstance(payload, dict):
            log.warning("Ignoring JSON alert that isn't an object: %r", raw[:200])
            emit("ignored (not object)", raw=raw)
            return jsonify({"status": "ignored", "reason": "not an object"}), 200

        if payload.get("secret") != get_secret():
            log.warning("Rejected webhook call with wrong/missing secret")
            emit("rejected (bad secret)", payload, raw)
            return jsonify({"status": "rejected", "reason": "bad secret"}), 401

        action = payload.get("action")
        if action not in VALID_ACTIONS:
            log.warning("Ignoring JSON alert with unknown action: %r", action)
            emit("ignored (unknown action)", payload, raw)
            return jsonify({"status": "ignored", "reason": "unknown action"}), 200

        if not payload.get("group_id"):
            log.warning("Ignoring %s alert with no group_id", action)
            emit("ignored (no group_id)", payload, raw)
            return jsonify({"status": "ignored", "reason": "missing group_id"}), 200

        pending_dir = get_pending_dir()
        path = write_signal_file(pending_dir, payload)
        log.info("Queued %s group_id=%s -> %s", action, payload.get("group_id"), path)
        emit("queued", payload, raw)
        return jsonify({"status": "queued"}), 200

    return app
