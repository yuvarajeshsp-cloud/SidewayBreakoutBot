# Sideway Breakout Bot -- MT5 Signal Bridge (native Mac app)

A native macOS equivalent of `bridge/bridge_app.py` — same job (receive
TradingView's webhook, log every signal in a table, drop each one as a file
for the MT5 EA to pick up), but built with SwiftUI + Network.framework
instead of Python/Tkinter/Flask. No third-party dependencies at all, so
Xcode never needs to fetch anything from the internet to build it.

This also sidesteps the threading issue found in the Python GUI version
(Flask's dev server contending with Tkinter's event loop for the GIL) --
Swift has no GIL, and the HTTP listener's queue and SwiftUI's main queue are
kept properly separate via GCD.

## Opening it in Xcode

1. Open Xcode -> File -> Open... -> select the `mac` folder (or
   `mac/Package.swift` directly). Xcode recognizes it as a Swift Package and
   builds its own project model for it automatically -- there's no
   hand-written `.xcodeproj` to go stale or get corrupted.
2. In the scheme selector (top toolbar), pick the
   **SidewayBreakoutBotBridge** scheme running on **My Mac**.
3. Press **Run** (▶). A window opens with the Shared Secret / Port /
   Pending Folder fields, a status line, the live signal table, and a
   "Send Test Signal" button.

## Where it stores things

- **Config** (secret, port, pending folder): `~/Library/Application
  Support/SidewayBreakoutBotBridge/config.json`, remembered between runs.
- **Signal log**: `~/Library/Application Support/SidewayBreakoutBotBridge/signal_log.csv`
  — every signal ever received, opens directly in Excel/Numbers. Use the
  "Open Log File (CSV)" button to jump straight to it.

## Finding the MT5 pending folder on Mac

MetaQuotes doesn't ship a native Mac build of MT5 -- the Mac version runs
the real Windows terminal inside a bundled Wine environment. Its "Common
Files" folder (where the EA looks for signals) therefore lives inside that
Wine bottle, not a normal `~/Library` path you'd expect.

The app's default guess is:
```
~/Library/Application Support/MetaTrader 5/drive_c/users/<you>/AppData/Roaming/MetaQuotes/Terminal/Common/Files/SidewayBreakoutBot/pending
```

If your broker's MT5 build uses a different Wine wrapper (some do), find
the real path instead: in MT5, **File -> Open Data Folder**, then look for
a sibling **Common** folder next to the one that opens (usually one level
up). Paste that folder's `SidewayBreakoutBot\pending` path into the app's
"Pending folder" field and it's remembered from then on.

## Building a distributable app

**Product -> Archive** in Xcode produces a signed build you can export as a
plain executable (Organizer -> Distribute App -> Copy App). Because this is
a bare SwiftUI-over-SwiftPM executable rather than a full "macOS App"
Xcode target, the export is a raw binary rather than a polished `.app`
bundle with a custom icon -- perfectly fine to run directly, but if you
want a proper double-clickable `.app` with an icon and Dock presence for
sharing with others, say so and it can be restructured as a full Xcode App
target (adds an Info.plist / asset catalog, otherwise identical code).

## What gets automated vs. what doesn't

Same as the Python bridge -- see `bridge/README.md`'s "What gets automated"
section; the wire protocol (JSON action types, group_id scheme, EA
polling) is identical, so this app and `mt5/SidewayBreakoutBotSignalEA.mq5`
need no changes to work together.

## A note on testing

I don't have access to Xcode or macOS to compile this myself -- I've
reviewed it carefully by hand (balanced braces/parens, API signatures,
closure capture semantics) but the only real test is Xcode's own compiler.
If it doesn't build cleanly, please paste the exact error text (file, line,
message) and I'll fix it, the same way we iterated on the cTrader bot's
compile errors earlier.
