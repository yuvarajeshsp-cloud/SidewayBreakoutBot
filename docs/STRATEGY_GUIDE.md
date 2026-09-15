# Sideway Breakout Bot — Strategy & Input Guide

Two Pine Script v6 files implement the same trading idea:

| File | Purpose |
|---|---|
| `pine/SidewayBreakoutBot_Indicator.pine` | Visuals + alerts only. No real positions — just plots the setups it would have taken. |
| `pine/SidewayBreakoutBot_Strategy.pine` | Same logic, but places real `strategy.entry()`/`strategy.exit()` orders so it can be backtested in TradingView's Strategy Tester. |

Both files share an identical setup/state-machine engine; the differences are noted where they matter below.

The sideways-range detection block is adapted from LuxAlgo's "Range Detector," licensed under CC BY-NC-SA 4.0 — the attribution comment at the top of both files must stay.

---

## 1. The trade idea, in plain English

1. **Find a sideways range.** Price consolidates tightly enough (all recent closes stay within an ATR band around a moving average) to be flagged as "ranging."
2. **Wait for a breakout.** A full-body candle (both open and close, not just a wick) clears the top or bottom of that range.
3. **Optional: confirm it's not a fakeout.** If enabled, the *next* candle must also clear the range before the breakout is trusted.
4. **Find a retracement target.** Scan back through the breakout leg for a Fair Value Gap (FVG). If none qualifies, fall back to the range's own high/low as the target zone.
5. **Wait for price to retrace into that zone**, then for a confirmation candle that closes back beyond the zone's midpoint in the breakout's original direction — that candle triggers entry.
6. **Manage the trade**: SL beyond the range's opposite boundary, up to 3 take-profit tiers, breakeven after TP1, an optional stagnation timeout, and an optional "flip" that re-watches the same range for the opposite breakout after a stop-loss.

Several of these setups can run concurrently (different ranges, watched independently) — the bot doesn't wait for one trade to finish before noticing the next range.

---

## 2. The state machine

Every setup is one independent lifecycle, tracked in an array so many can run side by side. Each one moves through:

| State | Meaning |
|---|---|
| **1** | Watching a locked range for a full-body breakout. |
| **4** | Breakout just happened; waiting one more candle to rule out a fakeout (only used if the fakeout filter is on). |
| **2** | Breakout confirmed; waiting for price to retrace into the target zone, then a confirmation candle. |
| **3** | In a trade — managing SL/TP/breakeven/stagnation. |

A setup is removed from tracking once it times out, invalidates, or its trade closes (win, loss, or stagnation cut).

### Step-by-step detail

**Range detection (LuxAlgo).** A short SMA ± an ATR band forms a box; if every close in the lookback window stays inside it, the range is "detected." A new setup is armed to watch that range for a breakout (subject to the concurrency cap below).

**Breakout (state 1 → 4 or 2).** `bullBreak`/`bearBreak` require **both** open and close of the current candle to clear the locked range boundary — a wick alone doesn't count. An optional minimum body-size filter (in ATR) can additionally reject small/indecisive breakout candles.

**Fakeout filter (state 4).** If on, the very next candle must *also* clear the range in the same direction. If it fails, the breakout is treated as a fakeout: direction resets and the setup goes back to state 1, still watching the same locked range (no need for a fresh consolidation).

**Retracement zone (state 4/1 → 2).** Scans backward through the breakout leg (up to `Zone Scan Lookback` bars) for the nearest classic 3-candle Fair Value Gap large enough to clear `Min FVG Size`. If none qualifies, the zone falls back to the range's own high/low.

**Zone "touch" (state 2).** The setup arms for confirmation as soon as price reaches the **near edge** of the zone — the FVG's own boundary closest to price when one was found, or the range's own boundary when using the fallback — not the zone's midpoint. This is sticky: once touched, it stays armed even if price pulls back out of the zone again.

**Confirmation → entry (state 2 → 3).** A candle that closes beyond the zone's **midpoint**, in the original breakout direction, triggers entry (this condition is unchanged regardless of the touch-arming above). Entry price = that candle's close. Skipped (setup just keeps waiting) if outside the configured session window.

**Invalidation (state 2).** If price's **wick** (high/low, not just the close) crosses back through the *far* side of the original range, the whole idea has failed and the setup is dropped — a deep intrabar spike counts even if the candle closes back inside the range.

**Timeouts.** State 1 gives up after `Max Bars to Wait for Breakout` bars with no breakout. State 2 gives up after `Retracement Timeout` **real minutes** (wall-clock time, not bar count — so it means the same thing on any chart timeframe, but does keep ticking across weekend/holiday gaps).

**SL / TP / breakeven (state 3).**
- SL sits beyond the *opposite* boundary of the original range (the full range width is the initial risk) plus a small ATR buffer.
- Up to 3 TPs, each a configurable multiple of that risk ("R").
- SL moves to breakeven once TP1 is hit (if more than one TP is active).
- The trade closes on: SL hit, the *last active* TP tier hit, or the stagnation timeout.

**Stagnation cut.** If price never trades past the entry price in the trade's favor within `Close Stagnant Trade After` bars, the trade is cut early (no flip — this isn't treated as a loss the way an SL hit is).

**SL flip.** When a trade closes via SL (not stagnation, not a TP), and the flip budget isn't exhausted, a brand-new setup is spawned that re-watches the *same* frozen range boundaries for a breakout in the *opposite* direction, starting fresh from state 1.

**Max SL distance.** If the computed SL would be farther than `Max SL Distance` pips away, the entry is skipped entirely (the range's width won't change, so there's no point waiting for a re-confirmation).

**Session filter.** Range detection, breakout watching, and retracement waiting all run 24/7 regardless — this only gates the final entry moment. A confirmation outside the session window doesn't cancel the setup; it just doesn't enter yet, and can still enter later if price re-confirms inside the window.

**Concurrency.** If stacking is allowed, up to `Max Concurrent Setups` ranges can be watched/traded at once. A new range is only armed to watch *after* that bar's other setups have been processed (so a setup that times out or invalidates frees its slot before the arming check runs).

---

## 3. Input reference

Inputs are identical between the two files except where noted. Defaults shown are as shipped.

### Range Detector

| Input | Default | What it does |
|---|---|---|
| Minimum Range Length | 20 | Bars that must stay inside the ATR band before a range is recognized. |
| Range Width | 1.0 | Multiplies the ATR band — bigger tolerates more noise as still "sideways." |
| Range ATR Length | 500 | ATR length used only for sizing the range band (separate from the SL/filter ATR below). |
| Broken Upward / Broken Downward / Unbroken | colors | Range box/line colors for each state. |
| Max Bars to Wait for Breakout | 50 | Give up watching a locked range if no breakout happens within this many bars. |
| Allow Stacked Entries | true | Off = force exactly one setup at a time, overriding the count below. |
| Max Concurrent Setups | 3 (max 10) | Cap on setups (watching or in-trade) running at once when stacking is allowed. |
| Max SL Flips per Range | 1 | After an SL hit, how many times the same range may be re-watched for the opposite breakout (0 = never). |

### Breakout

| Input | Default | What it does |
|---|---|---|
| ATR Length (SL/Filters) | 14 | ATR used for the SL buffer and the body-size filter (not the range band above). |
| Require Min Body Size | false | Optional extra filter: reject small/indecisive breakout candles. |
| Min Body Size (x ATR) | 0.5 | How big (in ATR) a candle's body must be, when the filter above is on. |
| Require Confirmation Candle After Breakout | true | Require a 2nd candle to also clear the range before trusting the breakout (the fakeout filter). |

### Retracement Zone

| Input | Default | What it does |
|---|---|---|
| Zone Scan Lookback (bars) | 15 | How far back from the breakout to search for a Fair Value Gap. |
| Min FVG Size (x ATR) | 0.0 | Ignore FVGs smaller than this (in ATR) as noise. |
| Retracement Timeout (minutes) | 30 | Give up waiting for the retracement/entry after this many real minutes. |

### Risk Management

| Input | Default | What it does | File |
|---|---|---|---|
| Risk % per Trade | 1.0 | % of current equity risked on each new trade — drives position size. | Strategy only |
| SL Buffer (x ATR) | 0.1 | Extra cushion (in ATR) added beyond the opposite range boundary for the stop-loss. | Both |
| Close Stagnant Trade After (bars, 0=off) | 30 | Close a trade early if price never moves in its favor for this many bars. | Both |
| Max SL Distance (pips, 0=off) | 200 | Skip the entry entirely if the SL would be farther than this many pips away. | Both |
| Pip Size (price per pip) | 0.1 | How much price one "pip" is on this symbol — e.g. 0.1 for most indices, 0.0001 for most FX pairs, 0.01 for JPY pairs. Set this to match your instrument. | Both |

### Take Profit

| Input | Default | What it does | File |
|---|---|---|---|
| Number of Take Profits (1-3) | 3 | How many of TP1/TP2/TP3 are actually used. | Both |
| TP1 / TP2 / TP3 (R multiple) | 1.0 / 2.0 / 3.0 | Distance of each TP, as a multiple of the stop-loss distance ("R"). | Both |
| TP1 / TP2 / TP3 Close % | 33 / 33 / 34 | % of the position closed at each tier. The **last active tier always absorbs whatever % remains** (so the position fully closes no matter what these sum to) — e.g. with 2 TPs, TP2 ignores its own %. | Strategy only |
| Move SL to Breakeven after TP1 | true | Whether the stop actually moves to entry price once TP1 fills. | Strategy only |

(Indicator doesn't size real positions, so it always assumes breakeven-after-TP1 when more than one TP is active — see the state-3 walkthrough above.)

### Trading Session

| Input | Default | What it does |
|---|---|---|
| Restrict Entries to Session | true | Range detection/watching/waiting still run 24/7 — this only gates the final entry moment. |
| Session | 1000-2200 | 24-hour `HHMM-HHMM` window. Default is 10:00 AM–10:00 PM. |
| Session Timezone | Asia/Kolkata | IANA timezone the session above is interpreted in (default IST). |

### Visuals

| Input | Default | What it does |
|---|---|---|
| Show Retracement Zone | true | Draw the orange box marking the FVG/range retracement zone while waiting for entry. |
| Show Risk/Reward Zone (Indicator) / Show Entry/SL/TP Levels (Strategy) | true | Draw the fading red (risk) / green (reward) bands and SL/TP lines once a trade is open. |
| Show TP1/TP2/TP3/SL Hit Markers | true | Draw a small fixed dot + text label at the exact candle each level (TP1/TP2/TP3/SL) was actually hit — pinned there permanently, not dragged forward. |
| Minimum Position Width (bars) | 30 | Risk/reward visuals start this many bars wide instead of a 1-bar sliver, so a brand-new entry is immediately visible. |

There's also a small fixed constant `fadeBands = 6` near the top of each file (not a UI input) controlling how many stacked bands make up the risk/reward fade gradient — edit it directly in the script if you want a smoother or coarser fade.

---

## 4. Reading the chart

- **Range box** (blue/green/red per LuxAlgo's Range Detector) — the detected sideways range; color shows unbroken/broken-up/broken-down.
- **Orange box** — the pending retracement zone (FVG or range fallback) while a setup waits in state 2.
- **"L" / "S" triangle markers** — long/short entry signals.
- **Red band (fading)** — risk zone, entry → SL, solid nearest entry and fading toward SL.
- **Green band (fading)** — reward zone, entry → the last active TP tier, same fade style.
- **Right-edge price tags** — "Entry (…)", "SL (…)", "TP1/2/3 (…)" — live prices that slide forward with the trade; the SL tag/line tracks the breakeven move.
- **Small circular dot markers** — pinned at the exact candle each TP or SL was actually hit (permanent historical record, unlike the sliding tags above).
- **Gray X** — trade closed (Indicator only; drives the generic "Trade Closed" alert).

---

## 5. Alerts

Every distinct event has its own `alertcondition()`, so each can be selected individually when creating an alert in TradingView — **sound, popup, and desktop/mobile push are configured per-alert in TradingView's own "Create Alert" dialog (Notifications tab)**, not in the script.

| Alert | Fires on |
|---|---|
| Long Entry Signal / Short Entry Signal | A trade opens. |
| Trade Closed | Any close (SL, final TP, or — Strategy only — a stagnation close). |
| Stop Loss Hit | SL hit (fires regardless of whether a flip is also spawned). |
| TP1 / TP2 / TP3 Hit | Each tier being reached. |
| Stagnant Trade Closed | The stagnation timeout cut the trade early. |

A plain `alert()` also fires alongside most of these (state transitions like "breakout, awaiting confirmation," "fakeout," "watching the same range for an opposite breakout," etc. included), so a generic "Any alert() function call" TradingView alert will catch everything even without setting up each `alertcondition()` individually.

---

## 6. Known deliberate design choices (not bugs)

- **Retracement timeout uses real wall-clock minutes**, not bar count — so it keeps ticking across weekends/holidays even though no real trading happened. This is intentional so the timeout means the same thing on any chart timeframe.
- **Indicator has no real position sizing** — it always assumes the breakeven-after-TP1 rule applies (when >1 TP is active) since there's no real equity/quantity to reason about.
