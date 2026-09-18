# SidewayBreakoutBot — MT5 Expert Advisor

`SidewayBreakoutBot_EA.mq5` is an MT5 port of the Pine `Strategy` file's full
feature set: range detection, breakout/fakeout/impulse entries, FVG
retracement zones, R-multiple SL/TP1/TP2/TP3 with partial closes and
breakeven, SL-flip re-watch, stagnation close, session filter, and concurrent
setups — plus an on-chart dashboard panel mirroring the Pine trade-summary
table, position-configurable to any corner (SL / Breakeven-after-TP1 /
Breakeven-after-TP2 / TP1 / TP2 / TP3 / Stagnant counts, total R, and real
gain/loss in $ and %, color-coded the same way as the Pine indicator's
table: red for SL, lime/green for TP hits).

## Install

1. Copy `SidewayBreakoutBot_EA.mq5` into your terminal's
   `MQL5/Experts/` folder (MetaEditor: File > Open Data Folder).
2. Compile in MetaEditor (F7).
3. Drag onto a chart, enable **Algo Trading**, and configure inputs.

## Environment differences from the Pine version (read before going live)

1. **Hedging account required for concurrent setups.** "Max Concurrent
   Setups" can open more than one same-direction position on this symbol at
   once. MT5 *netting* accounts collapse same-direction trades into a single
   net position and cannot represent this. On a netting account, set
   `InpMaxConcurrentSetups = 1` and `InpAllowStackedEntries = false`, or
   expect incorrect behavior. The EA logs a warning on init if the account
   isn't in hedging mode and stacking is enabled.

2. **Session times are in broker/server time.** Pine's `session()` type is
   IANA-timezone-aware; MQL5 has no timezone database. `InpSessionStart` /
   `InpSessionEnd` are compared directly against `TimeCurrent()` (server
   time) — convert your desired session window to your broker's server time
   yourself.

3. **Virtual SL/TP.** The EA manages its own SL/TP1/TP2/TP3 by watching
   price every tick and closing (partially or fully) itself — this is what
   lets TP1/TP2 be *partial* closes with a move to breakeven, matching the
   Pine strategy. A wide native stop-loss (2R beyond the real virtual stop)
   is still placed on every position as a catastrophic backstop in case the
   terminal/EA goes offline; it is not expected to be hit in normal
   operation.

4. **Bar-close gating.** Breakout detection, fakeout confirmation,
   retracement confirmation, and new-range arming all evaluate the *last
   closed* bar exactly once, at the moment a new bar begins — the MT5-native
   equivalent of the Pine side's `barstate.isconfirmed` gate (see that fix's
   commit for the reasoning). Wick-based checks (zone touch, invalidation,
   TP/SL fills) are evaluated every tick, matching how real stop/limit
   orders actually fill.

5. **Visuals are functional, not pixel-identical.** Range box, retracement
   zone box, and entry/SL/TP lines are drawn with plain MT5 chart objects —
   not a replica of the Pine version's multi-band fade-gradient boxes.

6. **Real P&L.** Unlike the Pine Indicator (which only simulates a position),
   this EA places real orders and reads real realized profit/loss from the
   trade history after every partial and full close — the dashboard's $ and
   % figures are actual account results, not an approximation from R
   multiples and a hypothetical balance.

7. **Lot sizing has no Pine equivalent to mirror** (backtests have unlimited
   capital). `InpRiskPercent` of account equity, divided by the stop
   distance's per-lot value (via the symbol's tick size/value), gives the
   base lot size; it's then bumped up if needed so every configured TP tier's
   partial-close slice is still at least one broker volume step (e.g. 3 TPs
   needs at least 3 × the symbol's minimum lot), and checked against free
   margin via `OrderCalcMargin()` before the order is sent. If the account
   can't afford even that minimum-viable size, the setup is skipped (logged)
   instead of retrying the same entry every bar. On a small enough account
   or a tight stop, the broker's own minimum lot (and that TP-split floor)
   can force a bigger size than `InpRiskPercent` alone would size — the EA
   still takes the trade, but logs a warning naming the actual $ risked vs.
   what was configured whenever this happens, so it's visible in the
   journal rather than a surprise the first time a stop is hit.

## Keeping this in sync with the Pine version

Going forward, changes made to the Pine Strategy/Indicator (the state
machine, entry/SL/TP rules, filters, etc.) should be mirrored here too. The
file is organized in the same section order as the Pine scripts (Range
Detector → Breakout → Impulse → Retracement Zone → state machine →
entry execution → position management → dashboard → visuals) to make that
easier.
