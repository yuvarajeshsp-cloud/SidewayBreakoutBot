"""
TradingView -> MT5 webhook bridge, console/headless mode.

For the Windows GUI version (a table of every signal received, no terminal
window needed), run bridge_app.py instead -- both share the exact same
webhook-handling logic in bridge_core.py.

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
alerts this indicator also fires just get logged and ignored).
"""

import logging
import os

from bridge_core import create_app, default_pending_dir

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("bridge")

# The secret must match the "Shared Secret" input on the Pine Signal indicator.
SECRET = os.environ.get("BRIDGE_SECRET", "changeme")
PENDING_DIR = os.environ.get("BRIDGE_PENDING_DIR", default_pending_dir())

app = create_app(get_secret=lambda: SECRET, get_pending_dir=lambda: PENDING_DIR)

if __name__ == "__main__":
    log.info("Pending dir: %s", PENDING_DIR)
    if SECRET == "changeme":
        log.warning("BRIDGE_SECRET is not set -- using the default 'changeme'. Set it to something private.")
    app.run(host="0.0.0.0", port=int(os.environ.get("BRIDGE_PORT", "5000")))
