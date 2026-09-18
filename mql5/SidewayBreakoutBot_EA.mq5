//+------------------------------------------------------------------+
//|                                        SidewayBreakoutBot_EA.mq5 |
//|  MT5 port of the SidewayBreakoutBot Pine Strategy/Indicator.     |
//|  Range detection -> breakout/fakeout/impulse -> FVG retracement  |
//|  zone -> entry with R-multiple SL/TP1/TP2/TP3, breakeven, SL     |
//|  flips, stagnation close, session filter, concurrent setups.     |
//|                                                                    |
//|  IMPORTANT ENVIRONMENT NOTES (read before running live):          |
//|  1) HEDGING ACCOUNT REQUIRED. "Max Concurrent Setups" can open    |
//|     more than one position in the SAME direction on this symbol   |
//|     at once. MT5 NETTING accounts collapse same-direction trades  |
//|     into a single net position and cannot represent this -- on a  |
//|     netting account, set InpMaxConcurrentSetups=1 and             |
//|     InpAllowStackedEntries=false, or expect incorrect behavior.   |
//|  2) SESSION TIMES ARE IN BROKER/SERVER TIME. Pine's session()     |
//|     type is IANA-timezone-aware; MQL5 has no timezone database.   |
//|     InpSessionStart/InpSessionEnd are read directly against       |
//|     TimeCurrent() (server time) -- convert your desired session   |
//|     window to server time yourself when setting these inputs.     |
//|  3) VIRTUAL SL/TP. This EA manages its own SL/TP1/TP2/TP3 by      |
//|     watching price every tick and closing (partially or fully)    |
//|     itself, rather than relying on the broker to fill a native    |
//|     take-profit order -- this is what lets TP1/TP2 be PARTIAL     |
//|     closes with a move to breakeven, matching the Pine strategy.  |
//|     A wide native stop-loss is still placed on every position as  |
//|     a catastrophic backstop (in case the terminal/EA goes         |
//|     offline) -- it sits well beyond the real (virtual) SL and is  |
//|     not expected to be hit in normal operation.                   |
//|  4) All bar-close-dependent decisions (breakout detection,        |
//|     fakeout confirmation, retracement confirmation, new-range     |
//|     arming) evaluate the LAST CLOSED bar (shift 1) exactly once,  |
//|     at the moment a new bar begins -- the MT5-native equivalent   |
//|     of the Pine side's barstate.isconfirmed gate. Wick-based      |
//|     checks (zone touch, invalidation, TP/SL fills) are evaluated  |
//|     every tick, matching how real stop/limit orders actually      |
//|     fill and how the Pine version deliberately reacts live.       |
//|  5) NO NATIVE ALPHA TRANSPARENCY. The risk/reward boxes (red for   |
//|     SL, green for TP -- TradingView Long/Short Position style)    |
//|     simulate "opacity" by blending the box color with the         |
//|     chart's actual background color, since MQL5 chart objects     |
//|     have no true alpha channel. This adapts automatically to      |
//|     light/dark themes but is an approximation, not a real blend.  |
//+------------------------------------------------------------------+
#property copyright "Sideway Breakout Bot"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

CTrade trade;

//====================================================================
// INPUTS
//====================================================================

input group "Range Detector"
input int    InpRangeLength         = 20;     // Minimum Range Length (bars)
input double InpRangeMult           = 1.0;    // Range Width (x ATR)
input int    InpRangeAtrLen         = 200;    // Range ATR Length
input int    InpMaxBarsWatch        = 50;     // Max Bars to Wait for Breakout
input bool   InpAllowStackedEntries = true;   // Allow Stacked Entries
input int    InpMaxConcurrentSetups = 3;      // Max Concurrent Setups (needs a HEDGING account, see header)
input int    InpMaxSlFlips          = 1;      // Max SL Flips per Range

input group "Breakout"
input int    InpAtrLength           = 20;     // ATR Length (SL/Filters)
input bool   InpUseBodyFilter       = true;   // Require Min Body Size
input double InpBodyATRMult         = 0.5;    // Min Body Size (x ATR)
input bool   InpUseFakeoutFilter    = true;   // Require Confirmation Candle After Breakout

input group "Impulse Breakout"
input bool   InpEnableImpulseEntry     = true;  // Enable Impulse Breakout Entry
input double InpImpulseThresholdPct    = 40.0;  // Impulse Threshold (% of range beyond boundary)

input group "Retracement Zone"
input int    InpZoneScanMaxBars     = 15;     // Zone Scan Lookback (bars)
input double InpFvgMinATRMult       = 0.0;    // Min FVG Size (x ATR)
input int    InpRetraceTimeoutMin   = 30;     // Retracement Timeout (minutes)

input group "Risk Management"
input double InpRiskPercent         = 1.0;    // Risk % per Trade (of account equity)
input double InpSlBufferATRMult     = 0.3;    // SL Buffer (x ATR)
input int    InpStagnationBars      = 30;     // Close Stagnant Trade After (bars, 0=off)
input double InpMaxSlPips           = 200;    // Max SL Distance (pips, 0=off)
input double InpPipSize             = 0.1;    // Pip Size (price per pip)

input group "Take Profit"
input int    InpNumTPs              = 3;      // Number of Take Profits (1-3)
input double InpTp1R                = 1.0;    // TP1 (R multiple)
input double InpTp2R                = 2.0;    // TP2 (R multiple)
input double InpTp3R                = 3.0;    // TP3 (R multiple)
input double InpTp1Qty              = 33.0;   // TP1 Close % of position
input double InpTp2Qty              = 33.0;   // TP2 Close %
input double InpTp3Qty              = 34.0;   // TP3 Close %
input bool   InpMoveToBEAfterTP1    = true;   // Move SL to Breakeven after TP1

input group "Trading Session (server/broker time -- see header note 2)"
input bool   InpUseSessionFilter    = true;      // Restrict Entries to Session
input string InpSessionStart        = "10:00";   // Session Start (HH:MM, server time)
input string InpSessionEnd          = "22:00";   // Session End (HH:MM, server time)

input group "Visuals"
input bool   InpShowRangeBox        = true;   // Show Range Box
input bool   InpShowZoneBox         = true;   // Show Retracement Zone Box
input bool   InpShowTradeLines      = true;   // Show Entry/SL/TP Lines
input bool   InpShowRRBoxes         = true;   // Show Risk/Reward Boxes (TradingView-style RR tool)
input double InpBoxTransparencyPct  = 80.0;   // RR Box Transparency % (0=solid, 100=invisible; simulated via background blend -- see header note 5)
input int    InpMinWidthBars        = 30;     // Minimum RR Box/Line Width (bars) -- how wide a brand-new entry starts before it grows
input bool   InpShowPriceTags       = true;   // Show Entry/SL/TP Price Tags (slide with the trade, like the Pine indicator)
input bool   InpShowHitMarkers      = true;   // Show TP1/TP2/TP3/SL Hit Dots (fixed at the exact candle each level was hit)
input bool   InpShowInfoMarker      = true;   // Show "i" Info Marker at Entry (hover for why the entry fired -- like the Pine indicator)

input group "Dashboard"
input bool   InpShowDashboard        = true;      // Show Trade Summary Dashboard (chart comment)
input string InpDashboardPeriod      = "All Time"; // Stats Period: Today / This Week / This Month / All Time

input group "Misc"
input ulong  InpMagic               = 20240601;  // Magic Number
input int    InpSlippagePoints      = 20;        // Max Slippage (points)

//====================================================================
// STRUCTS
//====================================================================

struct SSetup
{
   int      state;            // 1 watch, 4 fakeout-confirm, 5 impulse-entry, 2 retracement-wait, 3 in-trade
   double   lockedHigh;
   double   lockedLow;
   datetime lockTime;
   int      dir;               // 0 undetermined, 1 long, -1 short
   datetime breakoutTime;      // time of the CONFIRMED breakout -- reassigned in STATE 4 (drives the retracement timeout, matching Pine's s.breakoutTime)
   datetime breakoutBarTime;   // time of the ORIGINAL breakout candle -- set once in STATE 1, never touched again (matches Pine's s.breakoutBar; anchors the touchedZone backfill scan in STATE 4, which must NOT use the just-reassigned breakoutTime above)
   bool     isImpulse;
   double   impulsePct;
   double   preBreakoutLevel;
   double   zoneHigh;
   double   zoneLow;
   bool     touchedZone;
   double   slPrice;           // ORIGINAL (never mutated) 1R stop
   double   entryPrice;
   double   tp1Price;
   double   tp2Price;
   double   tp3Price;
   bool     tp1Filled;
   bool     tp2Filled;
   double   qtyAtEntry;
   double   qtyRemaining;
   ulong    posTicket;         // MT5 position id once open (state 3)
   int      flipsUsed;
   datetime entryTime;
   bool     leftEntry;         // true once price has ever moved in the trade's favor past entry
   double   cashPnLSoFar;      // real realized $ from partial closes so far (this setup)
   double   rWeightedSoFar;    // volume-weighted R realized so far (this setup)
   string   tag;               // unique object-name prefix for this setup's chart objects
};

struct STradeRecord
{
   datetime exitTime;
   int      dir;
   string   exitReason;   // "SL","Breakeven","TP1","TP2","TP3","Stagnant"
   double   rResult;       // final volume-weighted R for the whole trade
   double   cashResult;    // real realized $ for the whole trade
   bool     isImpulse;
   int      tpsReached;
};

//====================================================================
// GLOBALS
//====================================================================

SSetup       g_setups[];
STradeRecord g_history[];

double g_tradedHigh[];
double g_tradedLow[];
int    g_tradedDir[];

int      g_hAtrRange;   // ATR handle for the range band (InpRangeAtrLen)
int      g_hAtrMain;    // ATR handle for SL/filters (InpAtrLength)
datetime g_lastBarTime = 0;
int      g_setupCounter = 0;

// persistent range-detector state (mirrors Pine's var box/line)
bool     g_rangeActive   = false;
double   g_rangeTop      = 0.0;
double   g_rangeBottom   = 0.0;
datetime g_rangeLeftTime = 0;
datetime g_rangeRightTime= 0;
int      g_rangeState    = 0;    // 0 unbroken, 1 broke up, -1 broke down

// normalized TP % (last active tier absorbs the remainder, mirrors Pine)
double g_tp1Pct, g_tp2Pct, g_tp3Pct;
int    g_numTPs;

int g_sessStartMin = 600;   // minutes since midnight
int g_sessEndMin   = 1320;

//====================================================================
// INIT / DEINIT
//====================================================================

int OnInit()
{
   g_numTPs = (int)MathMax(1, MathMin(3, InpNumTPs));

   if(g_numTPs == 1)      { g_tp1Pct = 100.0; g_tp2Pct = 0.0;  g_tp3Pct = 0.0; }
   else if(g_numTPs == 2) { g_tp1Pct = InpTp1Qty; g_tp2Pct = 100.0 - InpTp1Qty; g_tp3Pct = 0.0; }
   else                   { g_tp1Pct = InpTp1Qty; g_tp2Pct = InpTp2Qty; g_tp3Pct = MathMax(0.0, 100.0 - InpTp1Qty - InpTp2Qty); }

   if(!ParseHHMM(InpSessionStart, g_sessStartMin))
   {
      Print("SidewayBreakoutBot: could not parse InpSessionStart '", InpSessionStart, "', defaulting to 10:00");
      g_sessStartMin = 600;
   }
   if(!ParseHHMM(InpSessionEnd, g_sessEndMin))
   {
      Print("SidewayBreakoutBot: could not parse InpSessionEnd '", InpSessionEnd, "', defaulting to 22:00");
      g_sessEndMin = 1320;
   }

   g_hAtrRange = iATR(_Symbol, _Period, InpRangeAtrLen);
   g_hAtrMain  = iATR(_Symbol, _Period, InpAtrLength);
   if(g_hAtrRange == INVALID_HANDLE || g_hAtrMain == INVALID_HANDLE)
   {
      Print("SidewayBreakoutBot: failed to create ATR handles");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   ENUM_ACCOUNT_MARGIN_MODE mm = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(mm != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING && (InpAllowStackedEntries || InpMaxConcurrentSetups > 1))
      Print("SidewayBreakoutBot WARNING: account is not in hedging mode -- concurrent same-direction ",
            "setups cannot be represented as separate positions. Set InpMaxConcurrentSetups=1 and ",
            "InpAllowStackedEntries=false, or switch to a hedging account.");

   ArrayResize(g_setups, 0);
   ArrayResize(g_history, 0);
   ArrayResize(g_tradedHigh, 0);
   ArrayResize(g_tradedLow, 0);
   ArrayResize(g_tradedDir, 0);

   g_lastBarTime = iTime(_Symbol, _Period, 0);

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(g_hAtrRange != INVALID_HANDLE) IndicatorRelease(g_hAtrRange);
   if(g_hAtrMain  != INVALID_HANDLE) IndicatorRelease(g_hAtrMain);
   Comment("");
}

//====================================================================
// SMALL HELPERS
//====================================================================

bool ParseHHMM(const string s, int &outMinutes)
{
   string parts[];
   int n = StringSplit(s, StringGetCharacter(":", 0), parts);
   if(n != 2) return(false);
   int h = (int)StringToInteger(parts[0]);
   int m = (int)StringToInteger(parts[1]);
   if(h < 0 || h > 23 || m < 0 || m > 59) return(false);
   outMinutes = h * 60 + m;
   return(true);
}

bool IsNewBar()
{
   datetime t = iTime(_Symbol, _Period, 0);
   if(t != g_lastBarTime)
   {
      g_lastBarTime = t;
      return(true);
   }
   return(false);
}

// Is the bar whose OPEN TIME is 'barTime' inside the configured session window?
// Server-time minute-of-day comparison; a window that crosses midnight (end < start)
// is treated as wrapping through midnight, same convention as most session tools.
bool IsInSession(datetime barTime)
{
   if(!InpUseSessionFilter) return(true);
   MqlDateTime dt;
   TimeToStruct(barTime, dt);
   int minutesOfDay = dt.hour * 60 + dt.min;
   if(g_sessStartMin <= g_sessEndMin)
      return(minutesOfDay >= g_sessStartMin && minutesOfDay < g_sessEndMin);
   else
      return(minutesOfDay >= g_sessStartMin || minutesOfDay < g_sessEndMin);
}

double NormalizeLots(double lots)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepLot <= 0) stepLot = minLot;
   double n = MathFloor(lots / stepLot) * stepLot;
   n = MathMax(minLot, MathMin(maxLot, n));
   return(NormalizeDouble(n, 8));
}

double NormalizePrice(double price)
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0) tickSize = _Point;
   return(NormalizeDouble(MathRound(price / tickSize) * tickSize, _Digits));
}

double GetAtrMain(int shift)
{
   double buf[];
   if(CopyBuffer(g_hAtrMain, 0, shift, 1, buf) != 1) return(0.0);
   return(buf[0]);
}

double GetAtrRange(int shift)
{
   double buf[];
   if(CopyBuffer(g_hAtrRange, 0, shift, 1, buf) != 1) return(0.0);
   return(buf[0]);
}

double GetSMA(int shift, int length)
{
   double sum = 0.0;
   for(int i = 0; i < length; i++)
      sum += iClose(_Symbol, _Period, shift + i);
   return(sum / length);
}

int BarsSince(datetime t)
{
   int shift = iBarShift(_Symbol, _Period, t, false);
   if(shift < 0) return(0);
   return(shift);
}

bool IsZoneAlreadyTraded(int dir, double hi, double lo)
{
   int n = ArraySize(g_tradedDir);
   for(int i = 0; i < n; i++)
      if(g_tradedDir[i] == dir && hi >= g_tradedLow[i] && lo <= g_tradedHigh[i])
         return(true);
   return(false);
}

void RecordTradedZone(int dir, double hi, double lo)
{
   int n = ArraySize(g_tradedDir);
   ArrayResize(g_tradedHigh, n + 1);
   ArrayResize(g_tradedLow,  n + 1);
   ArrayResize(g_tradedDir,  n + 1);
   g_tradedHigh[n] = hi;
   g_tradedLow[n]  = lo;
   g_tradedDir[n]  = dir;
}

void PushSetup(SSetup &s)
{
   int n = ArraySize(g_setups);
   ArrayResize(g_setups, n + 1);
   g_setups[n] = s;
}

void RemoveSetupAt(int idx)
{
   DeleteWatchObjects(g_setups[idx].tag);
   int n = ArraySize(g_setups);
   for(int i = idx; i < n - 1; i++)
      g_setups[i] = g_setups[i + 1];
   ArrayResize(g_setups, n - 1);
}

//====================================================================
// FVG / RETRACEMENT ZONE SCAN
// Mirrors Pine's f_findZone: scans back from 'baseShift' (the "current"
// bar in the Pine sense -- the bar the breakout/confirmation happened
// on) for a classic 3-candle Fair Value Gap. Falls back to the range's
// own boundaries if none is found.
//====================================================================

void FindFVGZone(int dir, datetime lockTime, double lockedHigh, double lockedLow,
                  int baseShift, double &outZoneHigh, double &outZoneLow)
{
   int lockShift  = BarsSince(lockTime);
   int scanLen    = (int)MathMin(lockShift - baseShift, InpZoneScanMaxBars);
   double atrVal  = GetAtrMain(baseShift);
   bool found = false;

   if(scanLen >= 3)
   {
      for(int i = 1; i <= scanLen - 2 && !found; i++)
      {
         int s0 = baseShift + i;
         int s2 = baseShift + i + 2;
         if(dir == 1)
         {
            double lowI  = iLow(_Symbol, _Period, s0);
            double highI2= iHigh(_Symbol, _Period, s2);
            if(lowI > highI2 && (lowI - highI2) >= InpFvgMinATRMult * atrVal)
            {
               outZoneLow  = highI2;
               outZoneHigh = lowI;
               found = true;
            }
         }
         else
         {
            double highI = iHigh(_Symbol, _Period, s0);
            double lowI2 = iLow(_Symbol, _Period, s2);
            if(highI < lowI2 && (lowI2 - highI) >= InpFvgMinATRMult * atrVal)
            {
               outZoneHigh = lowI2;
               outZoneLow  = highI;
               found = true;
            }
         }
      }
   }

   if(!found)
   {
      outZoneHigh = lockedHigh;
      outZoneLow  = lockedLow;
   }
}

//====================================================================
// RANGE DETECTOR (LuxAlgo-style: SMA +/- ATR band; a "range" is
// confirmed the instant every close in the lookback window is back
// inside the band). Evaluated once per new bar, on the just-closed
// bar (shift 1) -- see header note 4.
//====================================================================

bool ComputeFreshRange(double &outRMax, double &outRMin, datetime &outLockTime)
{
   int base = 1; // the just-closed bar
   double rAtr = GetAtrRange(base) * InpRangeMult;
   double ma   = GetSMA(base, InpRangeLength);

   int rCount = 0;
   for(int i = 0; i < InpRangeLength; i++)
      if(MathAbs(iClose(_Symbol, _Period, base + i) - ma) > rAtr) rCount++;

   int rCountPrev = 0;
   double maPrev  = GetSMA(base + 1, InpRangeLength);
   double rAtrPrev= GetAtrRange(base + 1) * InpRangeMult;
   for(int i = 0; i < InpRangeLength; i++)
      if(MathAbs(iClose(_Symbol, _Period, base + 1 + i) - maPrev) > rAtrPrev) rCountPrev++;

   bool rangeEvent = (rCount == 0 && rCountPrev != 0);
   if(!rangeEvent)
   {
      // keep stretching the currently-active box, purely visual
      if(g_rangeActive && rCount == 0)
      {
         g_rangeRightTime = iTime(_Symbol, _Period, base);
         UpdateRangeBox();
      }
      return(false);
   }

   double newTop = ma + rAtr;
   double newBot = ma - rAtr;
   datetime leftTime = iTime(_Symbol, _Period, base + InpRangeLength);

   bool overlapsExisting = g_rangeActive && (leftTime <= g_rangeRightTime);
   if(overlapsExisting)
   {
      g_rangeTop    = MathMax(newTop, g_rangeTop);
      g_rangeBottom = MathMin(newBot, g_rangeBottom);
      g_rangeRightTime = iTime(_Symbol, _Period, base);
      g_rangeState = 0;
      UpdateRangeBox();
      return(false); // re-extension, not a genuinely fresh range
   }

   g_rangeActive    = true;
   g_rangeTop       = newTop;
   g_rangeBottom    = newBot;
   g_rangeLeftTime  = leftTime;
   g_rangeRightTime = iTime(_Symbol, _Period, base);
   g_rangeState     = 0;
   UpdateRangeBox();

   outRMax = newTop;
   outRMin = newBot;
   outLockTime = iTime(_Symbol, _Period, base);
   return(true);
}

// Purely cosmetic, called every tick (unlike ComputeFreshRange, which only
// runs once per new bar for the actual detection/arming decision -- see
// header note 4). Matches Pine's own split exactly: LuxAlgo's box visually
// extends and recolors live, every tick, using the CURRENTLY FORMING bar's
// close (bx.set_right(n) in the "else if rCount == 0" branch, and the
// close > bx.get_top() / close < bx.get_bottom() recoloring block below it)
// -- only the NEW-RANGE DETECTION itself needed deferring to a confirmed
// bar, not this visual reactivity. rMax/rMin (g_rangeTop/g_rangeBottom) are
// never touched here, exactly like Pine: only the right edge and the color
// react live; the box's actual bounds only change on a real detection or
// re-extension event, both handled by ComputeFreshRange() above.
void UpdateRangeVisualLive()
{
   if(!InpShowRangeBox || !g_rangeActive) return;

   double rAtr0 = GetAtrRange(0) * InpRangeMult;
   double ma0   = GetSMA(0, InpRangeLength);
   int rCount0 = 0;
   for(int i = 0; i < InpRangeLength; i++)
      if(MathAbs(iClose(_Symbol, _Period, i) - ma0) > rAtr0) rCount0++;

   if(rCount0 == 0)
      g_rangeRightTime = iTime(_Symbol, _Period, 0);

   double liveClose = iClose(_Symbol, _Period, 0);
   if(liveClose > g_rangeTop)      g_rangeState = 1;
   else if(liveClose < g_rangeBottom) g_rangeState = -1;

   UpdateRangeBox();
}

//====================================================================
// STATE MACHINE -- NEW-BAR LOGIC (states 1, 4, 5-entry, 2-confirm,
// arm new setup). Uses the just-closed bar (shift 1) throughout,
// except STATE 5's entry which uses the JUST-OPENED bar's (shift 0)
// fixed open -- see header note 4 for why that one is safe live.
//====================================================================

void ProcessNewBar()
{
   int base = 1; // just-closed bar

   for(int idx = ArraySize(g_setups) - 1; idx >= 0; idx--)
   {
      SSetup s = g_setups[idx];
      bool removeThis = false;

      if(s.state == 1)
      {
         double o = iOpen(_Symbol, _Period, base);
         double c = iClose(_Symbol, _Period, base);
         double atrVal = GetAtrMain(base);
         double bodySize = MathAbs(c - o);
         bool passesBody = (!InpUseBodyFilter) || (bodySize >= InpBodyATRMult * atrVal);
         bool bullBreak = (MathMin(o, c) > s.lockedHigh) && passesBody;
         bool bearBreak = (MathMax(o, c) < s.lockedLow)  && passesBody;

         if(bullBreak || bearBreak)
         {
            s.dir = bullBreak ? 1 : -1;
            s.breakoutTime = iTime(_Symbol, _Period, base);
            s.breakoutBarTime = s.breakoutTime; // ORIGINAL breakout candle, never reassigned again

            double rangeHeight = s.lockedHigh - s.lockedLow;
            double breakoutDist = bullBreak ? (c - s.lockedHigh) : (s.lockedLow - c);
            bool isImpulse = InpEnableImpulseEntry && rangeHeight > 0 &&
                              breakoutDist >= (InpImpulseThresholdPct / 100.0) * rangeHeight;

            if(isImpulse)
            {
               s.isImpulse = true;
               s.impulsePct = breakoutDist / rangeHeight * 100.0;
               s.preBreakoutLevel = (s.dir == 1) ? iLow(_Symbol, _Period, base + 1) : iHigh(_Symbol, _Period, base + 1);
               s.state = 5;
            }
            else if(InpUseFakeoutFilter)
            {
               s.state = 4;
            }
            else
            {
               double zH, zL;
               FindFVGZone(s.dir, s.lockTime, s.lockedHigh, s.lockedLow, base, zH, zL);
               s.zoneHigh = zH; s.zoneLow = zL; s.touchedZone = false;
               s.state = 2;
               DrawZoneBox(s);
            }
         }
         // "-1": BarsSince() is relative to the NEW bar that just started (shift 0),
         // one bar ahead of Pine's bar_index (the just-closed bar this logic mirrors).
         else if((BarsSince(s.lockTime) - 1) > InpMaxBarsWatch)
         {
            removeThis = true;
         }
      }
      else if(s.state == 4)
      {
         double o = iOpen(_Symbol, _Period, base);
         double c = iClose(_Symbol, _Period, base);
         double atrVal = GetAtrMain(base);
         double bodySize = MathAbs(c - o);
         bool passesBody = (!InpUseBodyFilter) || (bodySize >= InpBodyATRMult * atrVal);
         bool confirmed = (s.dir == 1) ? (MathMin(o, c) > s.lockedHigh && passesBody)
                                        : (MathMax(o, c) < s.lockedLow  && passesBody);
         if(confirmed)
         {
            s.breakoutTime = iTime(_Symbol, _Period, base);
            double zH, zL;
            FindFVGZone(s.dir, s.lockTime, s.lockedHigh, s.lockedLow, base, zH, zL);
            s.zoneHigh = zH; s.zoneLow = zL;
            double zoneStart2 = (s.dir == 1) ? s.zoneHigh : s.zoneLow;
            // Anchored on breakoutBarTime (the ORIGINAL breakout candle), NOT the
            // breakoutTime just reassigned above (the confirmation candle) --
            // otherwise this window is far too short and backfills touchedZone
            // from almost nothing, exactly the bug the Pine version already hit
            // and fixed once before.
            // NOTE: no "+1" here -- Pine's own "+1" (bar_index - s.breakoutBar + 1)
            // exactly cancels the standing -1 offset between a raw BarsSince()
            // (relative to the NEW bar that just started, shift 0) and Pine's
            // bar_index (the just-closed confirmation bar, shift 1/base here).
            int scanLen2 = (int)MathMax(MathMin(BarsSince(s.breakoutBarTime), InpZoneScanMaxBars), 1);
            bool touchedSeed = false;
            for(int i = 0; i < scanLen2; i++)
            {
               if(s.dir == 1 && iLow(_Symbol, _Period, base + i) <= zoneStart2) touchedSeed = true;
               if(s.dir == -1 && iHigh(_Symbol, _Period, base + i) >= zoneStart2) touchedSeed = true;
            }
            s.touchedZone = touchedSeed;
            s.state = 2;
            DrawZoneBox(s);
         }
         else
         {
            s.dir = 0;
            s.state = 1;
         }
      }
      else if(s.state == 5)
      {
         // Entry timing/level handled by open-of-new-bar logic below; here we
         // only re-check the bar-count-independent timeout (wick-based
         // invalidation is handled every tick in ProcessPerTick()).
         double minutesSinceBreakout = (double)(iTime(_Symbol, _Period, 0) - s.breakoutTime) / 60.0;
         if(minutesSinceBreakout > InpRetraceTimeoutMin)
            removeThis = true;
      }
      else if(s.state == 2)
      {
         double o = iOpen(_Symbol, _Period, base);
         double c = iClose(_Symbol, _Period, base);
         double zoneStart = (s.dir == 1) ? s.zoneHigh : s.zoneLow;
         bool confirmBull = (c > o) && (c > zoneStart);
         bool confirmBear = (c < o) && (c < zoneStart);
         bool confirmation = s.touchedZone && ((s.dir == 1) ? confirmBull : confirmBear);
         double minutesSinceBreakout = (double)(iTime(_Symbol, _Period, base) - s.breakoutTime) / 60.0;
         bool invalidated = (s.dir == 1) ? (iLow(_Symbol, _Period, base) < s.lockedLow)
                                          : (iHigh(_Symbol, _Period, base) > s.lockedHigh);

         if(confirmation && IsInSession(iTime(_Symbol, _Period, base)))
         {
            double atrVal = GetAtrMain(base);
            double buffer = InpSlBufferATRMult * atrVal;
            double candidateEntry = c;
            double candidateSl = (s.dir == 1) ? (s.lockedLow - buffer) : (s.lockedHigh + buffer);
            double r = MathAbs(candidateEntry - candidateSl);

            bool slTooWide = InpMaxSlPips > 0 && r > InpMaxSlPips * InpPipSize;
            if(r <= 0 || slTooWide || IsZoneAlreadyTraded(s.dir, s.lockedHigh, s.lockedLow))
            {
               DeleteZoneBox(s);
               removeThis = true;
            }
            else
            {
               ExecuteEntry(s, candidateEntry, candidateSl, r, false);
            }
         }
         else if(invalidated || minutesSinceBreakout > InpRetraceTimeoutMin)
         {
            DeleteZoneBox(s);
            removeThis = true;
         }
      }

      g_setups[idx] = s;
      if(removeThis) RemoveSetupAt(idx);
   }

   // ---- STATE 5 entries: fire at the OPEN of the bar that just started ----
   for(int idx = ArraySize(g_setups) - 1; idx >= 0; idx--)
   {
      if(g_setups[idx].state != 5) continue;
      SSetup s = g_setups[idx];
      if(!IsInSession(iTime(_Symbol, _Period, 0))) continue;

      double entryOpen = iOpen(_Symbol, _Period, 0);
      double atrVal = GetAtrMain(1);
      double buffer = InpSlBufferATRMult * atrVal;
      double candidateSl = (s.dir == 1) ? (s.preBreakoutLevel - buffer) : (s.preBreakoutLevel + buffer);
      double r = MathAbs(entryOpen - candidateSl);
      bool slTooWide = InpMaxSlPips > 0 && r > InpMaxSlPips * InpPipSize;

      if(r <= 0 || slTooWide || IsZoneAlreadyTraded(s.dir, s.lockedHigh, s.lockedLow))
      {
         RemoveSetupAt(idx);
         continue;
      }
      ExecuteEntry(s, entryOpen, candidateSl, r, true);
      g_setups[idx] = s;
   }

   // ---- Arm a new setup on a genuinely fresh range ----
   double rMax, rMin; datetime lockT;
   if(ComputeFreshRange(rMax, rMin, lockT))
   {
      int active = ArraySize(g_setups);
      bool canArm = InpAllowStackedEntries ? (active < InpMaxConcurrentSetups) : (active == 0);
      if(canArm)
      {
         SSetup ns;
         ZeroMemory(ns);
         ns.state = 1;
         ns.lockedHigh = rMax;
         ns.lockedLow  = rMin;
         ns.lockTime   = lockT;
         ns.dir = 0;
         ns.flipsUsed = 0;
         g_setupCounter++;
         ns.tag = "SBB_" + IntegerToString(g_setupCounter);
         PushSetup(ns);
      }
   }
}

//====================================================================
// ENTRY EXECUTION
//====================================================================

void ExecuteEntry(SSetup &s, double entryPrice, double slPrice, double r, bool isImpulseEntry)
{
   double riskAmount = AccountInfoDouble(ACCOUNT_EQUITY) * (InpRiskPercent / 100.0);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0 || tickValue <= 0 || r <= 0) return;

   double lots = riskAmount / (r / tickSize * tickValue);
   lots = NormalizeLots(lots);
   if(lots <= 0) return;

   double tp1 = (s.dir == 1) ? entryPrice + r * InpTp1R : entryPrice - r * InpTp1R;
   double tp2 = (s.dir == 1) ? entryPrice + r * InpTp2R : entryPrice - r * InpTp2R;
   double tp3 = (s.dir == 1) ? entryPrice + r * InpTp3R : entryPrice - r * InpTp3R;
   double finalTp = (g_numTPs == 1) ? tp1 : (g_numTPs == 2) ? tp2 : tp3;

   // Catastrophic backstop: an extra 2R beyond the real (virtual) stop, so a
   // disconnected terminal still eventually gets stopped out by the broker.
   double backstopSl = (s.dir == 1) ? slPrice - r * 2.0 : slPrice + r * 2.0;

   bool ok;
   if(s.dir == 1)
      ok = trade.Buy(lots, _Symbol, 0.0, NormalizePrice(backstopSl), NormalizePrice(finalTp), s.tag);
   else
      ok = trade.Sell(lots, _Symbol, 0.0, NormalizePrice(backstopSl), NormalizePrice(finalTp), s.tag);

   if(!ok)
   {
      Print("SidewayBreakoutBot: entry failed for ", s.tag, " retcode=", trade.ResultRetcode());
      return;
   }

   ulong dealTicket = trade.ResultDeal();
   ulong posId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   double fillPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);

   // Re-base the risk distance and TP1/TP2/TP3 on the ACTUAL fill price.
   // slPrice is anchored to a fixed external level (range boundary or
   // pre-breakout wick), so it needs no adjustment for slippage -- but the
   // R multiples must be measured from where the trade actually entered,
   // not the pre-trade theoretical price, or a live fill that slips ends up
   // with TP targets Pine's frictionless simulation never has to correct for.
   double realR = MathAbs(fillPrice - slPrice);
   double tp1r = (s.dir == 1) ? fillPrice + realR * InpTp1R : fillPrice - realR * InpTp1R;
   double tp2r = (s.dir == 1) ? fillPrice + realR * InpTp2R : fillPrice - realR * InpTp2R;
   double tp3r = (s.dir == 1) ? fillPrice + realR * InpTp3R : fillPrice - realR * InpTp3R;
   double finalTpReal = (g_numTPs == 1) ? tp1r : (g_numTPs == 2) ? tp2r : tp3r;
   if(realR > 0 && MathAbs(NormalizePrice(finalTpReal) - NormalizePrice(finalTp)) > _Point / 2.0)
      trade.PositionModify(posId, NormalizePrice(backstopSl), NormalizePrice(finalTpReal));

   RecordTradedZone(s.dir, s.lockedHigh, s.lockedLow);

   s.posTicket   = posId;
   s.entryPrice  = fillPrice;
   s.slPrice     = slPrice;
   s.tp1Price    = tp1r;
   s.tp2Price    = tp2r;
   s.tp3Price    = tp3r;
   s.tp1Filled   = false;
   s.tp2Filled   = false;
   s.qtyAtEntry  = lots;
   s.qtyRemaining= lots;
   s.state       = 3;
   s.entryTime   = iTime(_Symbol, _Period, isImpulseEntry ? 0 : 1);
   s.leftEntry   = false;
   s.cashPnLSoFar   = 0.0;
   s.rWeightedSoFar = 0.0;

   DrawTradeVisuals(s);
   CreateInfoMarker(s, realR);
}

//====================================================================
// PER-TICK LOGIC (states 2/5 wick-reactive checks + state 3 management)
//====================================================================

void ProcessPerTick()
{
   UpdateRangeVisualLive();

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double curLow  = iLow(_Symbol, _Period, 0);
   double curHigh = iHigh(_Symbol, _Period, 0);

   for(int idx = ArraySize(g_setups) - 1; idx >= 0; idx--)
   {
      SSetup s = g_setups[idx];
      bool removeThis = false;

      if(s.state == 2)
      {
         double zoneStart = (s.dir == 1) ? s.zoneHigh : s.zoneLow;
         bool touchedNow = (s.dir == 1) ? (curLow <= zoneStart) : (curHigh >= zoneStart);
         if(touchedNow) s.touchedZone = true;

         bool invalidated = (s.dir == 1) ? (curLow < s.lockedLow) : (curHigh > s.lockedHigh);
         if(invalidated)
         {
            DeleteZoneBox(s);
            removeThis = true;
         }
         else if(InpShowZoneBox)
         {
            // Keep stretching the right edge while still waiting, matching
            // Pine's box.set_right(s.zoneBox, bar_index) in STATE 2.
            string zoneName = s.tag + "_zone";
            if(ObjectFind(0, zoneName) >= 0)
               ObjectMove(0, zoneName, 1, iTime(_Symbol, _Period, 0), s.zoneLow);
         }
      }
      else if(s.state == 5)
      {
         bool invalidated5 = (s.dir == 1) ? (curLow < s.lockedLow) : (curHigh > s.lockedHigh);
         if(invalidated5) removeThis = true;
      }
      else if(s.state == 3)
      {
         ManageOpenPosition(s, bid, ask);
         if(s.state != 3) removeThis = true; // fully closed inside ManageOpenPosition
      }

      g_setups[idx] = s;
      if(removeThis) RemoveSetupAt(idx);
   }

   if(InpShowTradeLines || InpShowRRBoxes) StretchOpenTradeVisuals();
   if(InpShowDashboard)  UpdateDashboard();
}

//====================================================================
// STATE 3 -- open-position management: TP1/TP2/TP3 partial closes,
// breakeven move, stagnation close, SL, and flip-on-SL spawning.
//====================================================================

void ManageOpenPosition(SSetup &s, double bid, double ask)
{
   if(!PositionSelectByTicket(s.posTicket))
   {
      // Closed by the backstop SL, manual intervention, etc. Record what we
      // can and stop tracking it -- we can't classify this precisely since
      // we didn't initiate the close ourselves.
      FinalizeTrade(s, "SL", 0);
      return;
   }

   double closePrice = (s.dir == 1) ? bid : ask; // price we'd exit AT
   double riskDistance = MathAbs(s.entryPrice - s.slPrice);
   if(riskDistance <= 0) riskDistance = 1e-10;

   if(!s.leftEntry)
   {
      bool moved = (s.dir == 1) ? (bid > s.entryPrice) : (ask < s.entryPrice);
      if(moved) s.leftEntry = true;
   }

   // ---- TP1 ----
   // Checked BEFORE stopNow/stopHit below (same reasoning as the Pine version):
   // a single wide tick range that reaches both TP1 and the pre-breakeven stop
   // must be judged against the just-updated (breakeven) stop, not the stale
   // pre-TP1 one -- so tp1Filled has to already reflect this tick's fill by the
   // time stopNow is computed. The virtual stop moving to breakeven needs no
   // separate action here: stopNow (below) already reads the just-updated
   // s.tp1Filled every tick, so there is nothing else to "move".
   if(!s.tp1Filled)
   {
      bool hit = (s.dir == 1) ? (bid >= s.tp1Price) : (ask <= s.tp1Price);
      if(hit)
      {
         s.tp1Filled = true;
         if(InpShowHitMarkers) CreateHitMarker(s.tag + "_hit_tp1", iTime(_Symbol, _Period, 0), s.tp1Price, "TP1", clrLimeGreen);
         double pct = (g_numTPs == 1) ? 100.0 : g_tp1Pct;
         PartialClose(s, pct, s.tp1Price, riskDistance);
         if(g_numTPs == 1) { FinalizeTrade(s, "TP1", 1); return; }
      }
   }

   // ---- TP2 ----
   if(g_numTPs >= 2 && s.tp1Filled && !s.tp2Filled)
   {
      bool hit = (s.dir == 1) ? (bid >= s.tp2Price) : (ask <= s.tp2Price);
      if(hit)
      {
         s.tp2Filled = true;
         if(InpShowHitMarkers) CreateHitMarker(s.tag + "_hit_tp2", iTime(_Symbol, _Period, 0), s.tp2Price, "TP2", clrLimeGreen);
         if(g_numTPs == 2) { PartialClose(s, 100.0, s.tp2Price, riskDistance); FinalizeTrade(s, "TP2", 2); return; }
         PartialClose(s, g_tp2Pct, s.tp2Price, riskDistance);
      }
   }

   // ---- TP3 (final tier when numTPs==3) ----
   if(g_numTPs == 3 && s.tp2Filled)
   {
      bool hit = (s.dir == 1) ? (bid >= s.tp3Price) : (ask <= s.tp3Price);
      if(hit)
      {
         if(InpShowHitMarkers) CreateHitMarker(s.tag + "_hit_tp3", iTime(_Symbol, _Period, 0), s.tp3Price, "TP3", clrLimeGreen);
         PartialClose(s, 100.0, s.tp3Price, riskDistance);
         FinalizeTrade(s, "TP3", 3);
         return;
      }
   }

   // ---- Stop / breakeven ----
   // Computed AFTER the TP checks above so a single wide tick range that
   // reaches both TP1 and the pre-breakeven stop is judged against the
   // just-updated (breakeven) stop, not the stale pre-TP1 one.
   double stopNow = (g_numTPs >= 2 && s.tp1Filled && InpMoveToBEAfterTP1) ? s.entryPrice : s.slPrice;
   bool stopHit = (s.dir == 1) ? (bid <= stopNow) : (ask >= stopNow);
   if(stopHit)
   {
      // Matches the Pine version: the dot always reads "SL" here, whether or
      // not the stop had already moved to breakeven -- Breakeven vs SL is a
      // dashboard/history distinction, not a different on-chart marker.
      if(InpShowHitMarkers) CreateHitMarker(s.tag + "_hit_sl", iTime(_Symbol, _Period, 0), stopNow, "SL", clrRed);
      PartialClose(s, 100.0, stopNow, riskDistance);
      int tpsReached = (s.tp1Filled ? 1 : 0) + (s.tp2Filled ? 1 : 0);
      FinalizeTrade(s, (stopNow == s.entryPrice) ? "Breakeven" : "SL", tpsReached);
      return;
   }

   // ---- Stagnation ----
   if(InpStagnationBars > 0 && !s.leftEntry)
   {
      // "-1": this runs every tick against the still-forming bar (shift 0), one
      // bar ahead of Pine's own bar-close-only evaluation of the same formula.
      int barsSinceEntry = BarsSince(s.entryTime) - 1;
      if(barsSinceEntry >= InpStagnationBars)
      {
         PartialClose(s, 100.0, closePrice, riskDistance);
         int tpsReached = (s.tp1Filled ? 1 : 0) + (s.tp2Filled ? 1 : 0);
         FinalizeTrade(s, "Stagnant", tpsReached);
         return;
      }
   }
}

void PartialClose(SSetup &s, double pctOfOriginal, double atPrice, double riskDistance)
{
   if(!PositionSelectByTicket(s.posTicket)) return; // already gone -- nothing to close
   double closeLots = NormalizeLots(s.qtyAtEntry * (pctOfOriginal / 100.0));
   double remaining = PositionGetDouble(POSITION_VOLUME);
   if(closeLots >= remaining) closeLots = remaining; // last slice: close everything left

   double fraction = (s.qtyAtEntry > 0) ? (closeLots / s.qtyAtEntry) : 0.0;
   double rThis = (atPrice - s.entryPrice) / riskDistance * s.dir;
   s.rWeightedSoFar += fraction * rThis;

   bool ok;
   if(closeLots >= remaining - 1e-9)
      ok = trade.PositionClose(s.posTicket, InpSlippagePoints);
   else
      ok = trade.PositionClosePartial(s.posTicket, closeLots, InpSlippagePoints);

   if(ok)
   {
      ulong dealTicket = trade.ResultDeal();
      double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                    + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                    + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      s.cashPnLSoFar += profit;
      s.qtyRemaining -= closeLots;
   }
}

void FinalizeTrade(SSetup &s, string exitReason, int tpsReached)
{
   STradeRecord rec;
   rec.exitTime   = TimeCurrent();
   rec.dir        = s.dir;
   rec.exitReason = exitReason;
   rec.rResult    = s.rWeightedSoFar;
   rec.cashResult = s.cashPnLSoFar;
   rec.isImpulse  = s.isImpulse;
   rec.tpsReached = tpsReached;
   int n = ArraySize(g_history);
   ArrayResize(g_history, n + 1);
   g_history[n] = rec;

   // Matches Pine: the flip re-arm fires on ANY stop-out -- the sticky
   // stopWasHit flag there doesn't distinguish the original SL from a
   // breakeven-adjusted stop, so both exit reasons re-watch the range.
   if((exitReason == "SL" || exitReason == "Breakeven") && s.flipsUsed < InpMaxSlFlips)
   {
      SSetup flip;
      ZeroMemory(flip);
      flip.state = 1;
      flip.lockedHigh = s.lockedHigh;
      flip.lockedLow  = s.lockedLow;
      flip.lockTime   = iTime(_Symbol, _Period, 0);
      flip.dir = 0;
      flip.flipsUsed = s.flipsUsed + 1;
      g_setupCounter++;
      flip.tag = "SBB_" + IntegerToString(g_setupCounter);
      PushSetup(flip);
   }

   s.state = 0; // signals ManageOpenPosition's caller to remove this setup
}

//====================================================================
// DASHBOARD (chart Comment -- see Pine's simplified trade-summary table)
//====================================================================

void UpdateDashboard()
{
   datetime cutoff = 0;
   if(InpDashboardPeriod == "Today")          cutoff = TimeCurrent() - 86400;
   else if(InpDashboardPeriod == "This Week") cutoff = TimeCurrent() - 604800;
   else if(InpDashboardPeriod == "This Month")cutoff = TimeCurrent() - 2592000;

   int total=0, slC=0, be1=0, be2=0, tp1=0, tp2=0, tp3=0, stag=0;
   double totalR = 0.0, totalCash = 0.0;

   int n = ArraySize(g_history);
   for(int i = 0; i < n; i++)
   {
      if(g_history[i].exitTime < cutoff) continue;
      total++;
      totalR    += g_history[i].rResult;
      totalCash += g_history[i].cashResult;
      string reason = g_history[i].exitReason;
      if(reason == "SL") slC++;
      else if(reason == "Breakeven") { if(g_history[i].tpsReached >= 2) be2++; else be1++; }
      else if(reason == "TP1") tp1++;
      else if(reason == "TP2") tp2++;
      else if(reason == "TP3") tp3++;
      else if(reason == "Stagnant") stag++;
   }

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double pct = (balance > 0) ? totalCash / balance * 100.0 : 0.0;

   string txt = "";
   txt += "Trade Summary (" + InpDashboardPeriod + ")\n";
   txt += "Total Trades: " + IntegerToString(total) + "\n";
   txt += "SL: " + IntegerToString(slC) + "\n";
   txt += "Breakeven (after TP1): " + IntegerToString(be1) + "\n";
   txt += "Breakeven (after TP2): " + IntegerToString(be2) + "\n";
   txt += "TP1: " + IntegerToString(tp1) + "\n";
   txt += "TP2: " + IntegerToString(tp2) + "\n";
   txt += "TP3: " + IntegerToString(tp3) + "\n";
   txt += "Stagnant: " + IntegerToString(stag) + "\n";
   txt += "Total R (Risk/Reward): " + DoubleToString(totalR, 2) + "R\n";
   txt += "Gain / Loss ($): " + DoubleToString(totalCash, 2) + "\n";
   txt += "Gain / Loss (%): " + DoubleToString(pct, 2) + "%";

   Comment(txt);
}

//====================================================================
// VISUALS (kept functional/simple -- range box, zone box, trade lines;
// not a pixel replica of the Pine fade-band gradients)
//====================================================================

void UpdateRangeBox()
{
   if(!InpShowRangeBox) return;
   string name = "SBB_range";
   color clr = (g_rangeState == 1) ? clrLimeGreen : (g_rangeState == -1) ? clrRed : clrDodgerBlue;
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, g_rangeLeftTime, g_rangeTop, g_rangeRightTime, g_rangeBottom);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
   }
   ObjectMove(0, name, 0, g_rangeLeftTime, g_rangeTop);
   ObjectMove(0, name, 1, g_rangeRightTime, g_rangeBottom);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

void DrawZoneBox(SSetup &s)
{
   if(!InpShowZoneBox) return;
   string name = s.tag + "_zone";
   // Anchored on breakoutTime (the confirmation/breakout candle -- correct in
   // both call sites, since it was just set to that bar's time right before
   // this runs), stretched immediately to the current bar so it starts
   // visibly wide rather than zero-width; ProcessPerTick()'s STATE 2 branch
   // then keeps extending the right edge every tick while this setup waits,
   // matching the Pine indicator's box.set_right(s.zoneBox, bar_index).
   datetime t1 = s.breakoutTime;
   datetime t2 = iTime(_Symbol, _Period, 0);
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, s.zoneHigh, t2, s.zoneLow);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrOrange);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
   }
   ObjectMove(0, name, 0, t1, s.zoneHigh);
   ObjectMove(0, name, 1, t2, s.zoneLow);
}

void DeleteZoneBox(SSetup &s)
{
   ObjectDelete(0, s.tag + "_zone");
}

// Simulates Pine's color.new(clr, transp): MQL5 objects have no real alpha
// channel, so we blend the target color toward the chart's own background
// color instead -- adapts to light/dark themes, and gives the same "faded"
// look a semi-transparent fill would. transparencyPct: 0 = solid color,
// 100 = fully background (invisible).
color BlendWithBackground(color clr, double transparencyPct)
{
   double opacity = 1.0 - MathMax(0.0, MathMin(100.0, transparencyPct)) / 100.0;
   int bg = (int)ChartGetInteger(0, CHART_COLOR_BACKGROUND);
   int fg = (int)clr;
   // MQL5 'color' is stored 0x00BBGGRR (Win32 COLORREF order).
   int r = (int)MathRound(((fg & 0xFF) * opacity) + ((bg & 0xFF) * (1.0 - opacity)));
   int g = (int)MathRound((((fg >> 8) & 0xFF) * opacity) + (((bg >> 8) & 0xFF) * (1.0 - opacity)));
   int b = (int)MathRound((((fg >> 16) & 0xFF) * opacity) + (((bg >> 16) & 0xFF) * (1.0 - opacity)));
   r = (int)MathMax(0, MathMin(255, r));
   g = (int)MathMax(0, MathMin(255, g));
   b = (int)MathMax(0, MathMin(255, b));
   return((color)(r | (g << 8) | (b << 16)));
}

void DrawTradeVisuals(SSetup &s)
{
   ObjectDelete(0, s.tag + "_zone");

   double lastTpPrice = (g_numTPs == 1) ? s.tp1Price : (g_numTPs == 2) ? s.tp2Price : s.tp3Price;
   datetime t1 = s.entryTime;
   datetime t2 = t1 + PeriodSeconds() * InpMinWidthBars;

   if(InpShowRRBoxes)
   {
      color riskClr   = BlendWithBackground(clrRed,       InpBoxTransparencyPct);
      color rewardClr = BlendWithBackground(clrLimeGreen, InpBoxTransparencyPct);
      CreateBox(s.tag + "_riskbox",   t1, s.entryPrice, t2, s.slPrice,  riskClr);
      CreateBox(s.tag + "_rewardbox", t1, s.entryPrice, t2, lastTpPrice, rewardClr);
   }

   if(InpShowPriceTags)
   {
      UpdatePriceTag(s.tag + "_entrytag", t2, s.entryPrice, "Entry", clrWhite);
      UpdatePriceTag(s.tag + "_sltag",    t2, s.slPrice,    "SL",    clrRed);
      UpdatePriceTag(s.tag + "_tp1tag",   t2, s.tp1Price,   "TP1",   clrLimeGreen);
      if(g_numTPs >= 2) UpdatePriceTag(s.tag + "_tp2tag", t2, s.tp2Price, "TP2", clrLimeGreen);
      if(g_numTPs == 3) UpdatePriceTag(s.tag + "_tp3tag", t2, s.tp3Price, "TP3", clrLimeGreen);
   }

   if(!InpShowTradeLines) return;
   CreateLine(s.tag + "_entry", t1, s.entryPrice, t2, s.entryPrice, clrWhite);
   CreateLine(s.tag + "_sl",    t1, s.slPrice,    t2, s.slPrice,    clrRed);
   CreateLine(s.tag + "_tp1",   t1, s.tp1Price,   t2, s.tp1Price,   clrLimeGreen);
   if(g_numTPs >= 2) CreateLine(s.tag + "_tp2", t1, s.tp2Price, t2, s.tp2Price, clrLimeGreen);
   if(g_numTPs == 3) CreateLine(s.tag + "_tp3", t1, s.tp3Price, t2, s.tp3Price, clrLimeGreen);
}

void CreateLine(string name, datetime t1, double p1, datetime t2, double p2, color clr)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
}

void CreateBox(string name, datetime t1, double p1, datetime t2, double p2, color clr)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
}

// A small dot+text marker pinned at the exact candle/price a level was hit --
// created once and never moved again, matching the Pine indicator's
// TP1/TP2/TP3/SL "hit" labels (label.style_circle there).
void CreateHitMarker(string name, datetime t, double price, string txt, color clr)
{
   if(ObjectFind(0, name) >= 0) return; // already marked, never redraw/move it
   string dotName = name + "_dot";
   ObjectCreate(0, dotName, OBJ_ARROW, 0, t, price);
   ObjectSetInteger(0, dotName, OBJPROP_ARROWCODE, 159); // Wingdings filled circle
   ObjectSetInteger(0, dotName, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, dotName, OBJPROP_WIDTH, 2);

   ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
   ObjectSetString(0, name, OBJPROP_TEXT, " " + txt);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT);
}

// A small "i" marker at the exact entry point, carrying a native MQL5
// tooltip (hover to expand) explaining why the entry fired -- the range and
// zone it used (or the impulse mode instead), every level computed, and the
// flip count if this is a re-watch after a prior SL on the same range.
// Matches the Pine indicator's entryInfoLbl. Created LAST (after
// DrawTradeVisuals) so it renders on top of the lines/boxes/tags, same
// z-order reasoning as the Pine version's fix for this exact marker.
void CreateInfoMarker(SSetup &s, double r)
{
   if(!InpShowInfoMarker) return;

   string info = (s.dir == 1 ? "LONG" : "SHORT") + " entry\n";
   info += "Range: " + DoubleToString(s.lockedLow, _Digits) + " - " + DoubleToString(s.lockedHigh, _Digits) + "\n";

   if(s.isImpulse)
   {
      info += "Entry mode: Impulse breakout (body " + DoubleToString(s.impulsePct, 1) + "% beyond range, no retracement wait)\n";
      info += "SL source: pre-breakout candle " + (s.dir == 1 ? "low" : "high") + "\n";
   }
   else
   {
      bool usedFallback = (s.zoneHigh == s.lockedHigh && s.zoneLow == s.lockedLow);
      string zoneDesc = usedFallback ? "range fallback (no qualifying FVG)" : "Fair Value Gap";
      info += "Zone (" + zoneDesc + "): " + DoubleToString(s.zoneLow, _Digits) + " - " + DoubleToString(s.zoneHigh, _Digits) + "\n";
   }

   info += "Entry: " + DoubleToString(s.entryPrice, _Digits) + "   SL: " + DoubleToString(s.slPrice, _Digits) + "\n";
   info += "TP1: " + DoubleToString(s.tp1Price, _Digits);
   if(g_numTPs >= 2) info += "   TP2: " + DoubleToString(s.tp2Price, _Digits);
   if(g_numTPs == 3) info += "   TP3: " + DoubleToString(s.tp3Price, _Digits);
   info += "\n";
   info += "Risk (1R): " + DoubleToString(r, _Digits) + "\n";
   info += "Breakout: " + TimeToString(s.breakoutBarTime, TIME_DATE | TIME_MINUTES)
         + "   Entry: " + TimeToString(s.entryTime, TIME_DATE | TIME_MINUTES);
   if(s.flipsUsed > 0)
      info += "\nFlip #" + IntegerToString(s.flipsUsed) + " on this range after a prior SL";

   string name = s.tag + "_info";
   ObjectCreate(0, name, OBJ_TEXT, 0, s.entryTime, s.entryPrice);
   ObjectSetString(0, name, OBJPROP_TEXT, " i");
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrDeepSkyBlue);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_CENTER);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, info);
}

// Entry/SL/TP price tags that slide forward with the trade -- matching the
// Pine indicator's entryTag/slTag/tp1Tag/etc (label.style_label_left there).
void UpdatePriceTag(string name, datetime t, double price, string prefix, color clr)
{
   string txt = prefix + " (" + DoubleToString(price, _Digits) + ")";
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT);
   }
   ObjectMove(0, name, 0, t, price);
   ObjectSetString(0, name, OBJPROP_TEXT, " " + txt);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

void StretchOpenTradeVisuals()
{
   datetime now = TimeCurrent();
   int n = ArraySize(g_setups);
   for(int i = 0; i < n; i++)
   {
      if(g_setups[i].state != 3) continue;
      SSetup s = g_setups[i];
      string base = s.tag;

      // stopNow: the current (possibly breakeven-adjusted) stop -- everything
      // SL-related (line, risk box, price tag) tracks this, not the original
      // s.slPrice, exactly like the Pine version's per-bar slLine/slTag update.
      double stopNow = (g_numTPs >= 2 && s.tp1Filled && InpMoveToBEAfterTP1) ? s.entryPrice : s.slPrice;

      // Entry/TP lines: extend the right edge, keep the same price.
      string tpNames[4] = {"_entry", "_tp1", "_tp2", "_tp3"};
      for(int k = 0; k < 4; k++)
      {
         string nm = base + tpNames[k];
         if(ObjectFind(0, nm) >= 0)
            ObjectMove(0, nm, 1, now, ObjectGetDouble(0, nm, OBJPROP_PRICE, 1));
      }
      // SL line: extend the right edge AND follow stopNow.
      string slLine = base + "_sl";
      if(ObjectFind(0, slLine) >= 0)
      {
         ObjectMove(0, slLine, 0, s.entryTime, stopNow);
         ObjectMove(0, slLine, 1, now, stopNow);
      }

      // Risk/reward boxes: risk box's SL edge follows stopNow; reward box's
      // TP edge is unchanged, only the time extends.
      string riskBox = base + "_riskbox";
      if(ObjectFind(0, riskBox) >= 0)
      {
         ObjectMove(0, riskBox, 0, s.entryTime, s.entryPrice);
         ObjectMove(0, riskBox, 1, now, stopNow);
      }
      string rewardBox = base + "_rewardbox";
      if(ObjectFind(0, rewardBox) >= 0)
         ObjectMove(0, rewardBox, 1, now, ObjectGetDouble(0, rewardBox, OBJPROP_PRICE, 1));

      // Price tags slide to the same right edge; the SL tag's price/text
      // also follow stopNow, matching the Pine version's slTag update.
      if(InpShowPriceTags)
      {
         UpdatePriceTag(base + "_entrytag", now, s.entryPrice, "Entry", clrWhite);
         UpdatePriceTag(base + "_sltag",    now, stopNow,      "SL",    clrRed);
         UpdatePriceTag(base + "_tp1tag",   now, s.tp1Price,   "TP1",   clrLimeGreen);
         if(g_numTPs >= 2) UpdatePriceTag(base + "_tp2tag", now, s.tp2Price, "TP2", clrLimeGreen);
         if(g_numTPs == 3) UpdatePriceTag(base + "_tp3tag", now, s.tp3Price, "TP3", clrLimeGreen);
      }
   }
}

void DeleteWatchObjects(string tag)
{
   ObjectDelete(0, tag + "_zone");
}

//====================================================================
// MAIN
//====================================================================

void OnTick()
{
   if(IsNewBar())
      ProcessNewBar();

   ProcessPerTick();
}
