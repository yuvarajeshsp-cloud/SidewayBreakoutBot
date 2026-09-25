# TradingView -> MT5 signal bridge

Sends entries from `pine/SidewayBreakoutBot_Indicator_Signal.pine` into MT5
automatically. Three pieces, all running on the **same Windows machine/VPS**
as your MT5 terminal:

1. **TradingView** — the Signal indicator's `alert()` calls carry JSON.
2. **This bridge** (`webhook_bridge.py`) — a tiny local web server that
   receives TradingView's webhook and drops each signal as its own file.
3. **The EA** (`mt5/SidewayBreakoutBotSignalEA.mq5`) — polls that folder and
   places/modifies/closes the real orders.

## 1. Install and run the bridge

On the Windows VPS (needs Python 3.9+):

```
cd bridge
pip install -r requirements.txt
set BRIDGE_SECRET=pick-your-own-private-value
python webhook_bridge.py
```

Leave it running (use Task Scheduler, NSSM, or just a background window — a
crashed/stopped bridge just means no new signals get queued; nothing about
your MT5 terminal or open trades depends on it staying up).

It defaults to writing signals into:
`%APPDATA%\MetaQuotes\Terminal\Common\Files\SidewayBreakoutBot\pending`

That's the **Common** Files folder shared by every MT5 terminal installed
under this Windows user account, not a specific terminal's own data folder —
you don't need to know the terminal's hashed folder name.

## 2. Install the EA in MT5

1. Copy `mt5/SidewayBreakoutBotSignalEA.mq5` into your MT5 data folder's
   `MQL5\Experts\` directory (File -> Open Data Folder in MT5, or MetaEditor's
   Navigator).
2. Open it in MetaEditor and compile (F7). It should build with 0 errors/0
   warnings.
3. In MT5, go to Tools -> Options -> Expert Advisors and make sure
   "Allow automated trading" is checked.
4. Drag the EA onto the chart for the symbol you're trading (must be the
   SAME symbol as your TradingView chart, e.g. both on EURUSD).
5. In the EA's Inputs tab, leave `EnableAutoTrading = false` at first — this
   runs it in **dry run**: it logs every signal it would act on (Experts tab)
   without placing a single real order. Watch a few signals go by, confirm
   the logged entry/SL/TP levels look right, then set `EnableAutoTrading =
   true` and re-attach the EA.
6. Set `FixedLotSize` to whatever size you want for EACH leg — a 3-TP signal
   opens 3 separate positions of this size (MT5 can't attach three take-profits
   to a single position), not one position split three ways.

## 3. Create the TradingView alert

1. Add `SidewayBreakoutBot_Indicator_Signal.pine` to your TradingView chart.
2. In its "MT5 Signal Bridge" input group, set **Shared Secret** to the exact
   same value as `BRIDGE_SECRET` above.
3. Create an alert on this indicator with condition **"Any alert() function
   call"**, and set its **Webhook URL** to
   `http://<vps-public-ip>:5000/webhook`.
   - The indicator also fires plain-text alerts for other events (breakout
     detected, TP hit notifications, etc.) — the bridge just ignores anything
     that isn't valid JSON, so you don't need a second, more specific alert.
4. Make sure port 5000 (or whatever `BRIDGE_PORT` you set) is open in the
   VPS's firewall/security group.

## What gets automated vs. what doesn't

- **Entry** (OPEN): one signal per enabled TP tier, opened as separate MT5
  positions sharing a `group_id`, each with the strategy's real SL and that
  tier's TP.
- **TP1 hit -> breakeven** (MODIFY_SL): moves the SL on the *other* still-open
  legs to the entry price, same as the indicator's own simulation.
- **Stagnation close** (CLOSE): closes every remaining leg in the group if the
  indicator's stagnation timeout fires (this has no price trigger of its own,
  so it can't be handled by MT5's native SL/TP).
- **TP2/TP3/SL hits**: need no message — each leg already carries its own
  real SL/TP on the broker and closes natively.
- Not wired up yet: the Funded Account Rules variant's session/news/holding
  restrictions have no MT5-side equivalent (Signal is based on Pro, which
  doesn't have them). If you want funded-rule enforcement on the MT5 side
  too, say so and it can be added.

## Notes / limitations

- The EA's leg-tracking (which ticket belongs to which `group_id`) is
  in-memory only — restarting the EA loses it. Already-open positions keep
  their real SL/TP regardless (they'll still close correctly), you just lose
  the breakeven-move/stagnation-close automation for trades opened *before*
  the restart.
- If you run multiple symbols, run one bridge (shared) and one EA instance
  per symbol's chart — each EA only claims files whose `"symbol"` matches its
  own chart, so they can safely share the same pending folder.
