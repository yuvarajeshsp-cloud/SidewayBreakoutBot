// Sideway Breakout Bot -- cTrader cBot
//
// Port of the TradingView Pine Script Indicator/Strategy pair (see ../pine/) into a
// single cAlgo cBot. Unlike Pine, cAlgo's Indicator and cBot classes are genuinely
// different types -- an Indicator can only draw, a cBot can draw AND trade -- so
// "one script that behaves as an indicator until you flip a switch" has to be a cBot
// with trading gated behind a parameter, not a literal merge of two class types.
//
// EnableAutoTrading (Bot Control group) is that switch. The state machine, range
// detection, and all chart drawing run identically whether it's on or off -- only the
// actual ExecuteMarketOrder/ClosePosition/ModifyStopLossPrice calls are gated behind
// it. Turning it on only affects entries taken from that point forward; a setup
// already mid-lifecycle when you flip it on will NOT retroactively open a real
// position at the wrong price.
//
// This is a faithful port of the core state machine (range detector, breakout,
// fakeout confirmation, impulse entry, FVG retracement zone, SL/TP1-3 with breakeven
// and partial closes, SL-flip, retest guard) and the Funded Account Rules block. The
// visual layer is deliberately simplified relative to the Pine Indicator (plain
// rectangles/lines instead of the fade-gradient risk/reward boxes, a compact static-
// text dashboard instead of the full breakdown table, no per-event hover tooltips --
// cAlgo's charting API doesn't have a direct equivalent) -- ask if you want any of
// that built out further.
//
// NOT COMPILE-TESTED: this was written without access to a cAlgo environment. Open it
// in cTrader Automate, build, and report back any compiler errors -- cAlgo.API details
// (exact overload signatures, enum member names) can vary slightly by cTrader version.

using System;
using System.Collections.Generic;
using System.Linq;
using cAlgo.API;
using cAlgo.API.Indicators;
using cAlgo.API.Internals;

namespace cAlgo.Robots
{
    [Robot(TimeZone = TimeZones.UTC, AccessRights = AccessRights.FullAccess)]
    public class SidewayBreakoutBot : Robot
    {
        #region Parameters -- Range Detector

        [Parameter("Minimum Range Length", DefaultValue = 20, MinValue = 2, Group = "Range Detector")]
        public int RangeLength { get; set; }

        [Parameter("Range Width (x ATR)", DefaultValue = 1.0, MinValue = 0, Group = "Range Detector")]
        public double RangeMult { get; set; }

        [Parameter("Range ATR Length", DefaultValue = 200, MinValue = 1, Group = "Range Detector")]
        public int RangeAtrLen { get; set; }

        [Parameter("Max Bars to Wait for Breakout", DefaultValue = 50, MinValue = 1, Group = "Range Detector")]
        public int MaxBarsWatch { get; set; }

        [Parameter("Allow Stacked Entries", DefaultValue = true, Group = "Range Detector")]
        public bool AllowStackedEntries { get; set; }

        [Parameter("Max Concurrent Setups", DefaultValue = 3, MinValue = 1, MaxValue = 10, Group = "Range Detector")]
        public int MaxConcurrentSetups { get; set; }

        [Parameter("Max SL Flips per Range", DefaultValue = 1, MinValue = 0, MaxValue = 5, Group = "Range Detector")]
        public int MaxSlFlips { get; set; }

        [Parameter("Retest Guard Lookback (bars, 0=off)", DefaultValue = 300, MinValue = 0, Group = "Range Detector")]
        public int RetestGuardBars { get; set; }

        [Parameter("Retest Guard Min Overlap (%)", DefaultValue = 80.0, MinValue = 0, MaxValue = 100, Group = "Range Detector")]
        public double RetestGuardOverlapPct { get; set; }

        #endregion

        #region Parameters -- Breakout / Impulse / Zone

        [Parameter("ATR Length (SL/Filters)", DefaultValue = 20, MinValue = 1, Group = "Breakout")]
        public int AtrLength { get; set; }

        [Parameter("Require Min Body Size", DefaultValue = true, Group = "Breakout")]
        public bool UseBodyFilter { get; set; }

        [Parameter("Min Body Size (x ATR)", DefaultValue = 0.5, MinValue = 0, Group = "Breakout")]
        public double BodyAtrMult { get; set; }

        [Parameter("Require Confirmation Candle After Breakout", DefaultValue = true, Group = "Breakout")]
        public bool UseFakeoutFilter { get; set; }

        [Parameter("Enable Impulse Breakout Entry", DefaultValue = true, Group = "Impulse Breakout")]
        public bool EnableImpulseEntry { get; set; }

        [Parameter("Impulse Threshold (% of range beyond boundary)", DefaultValue = 40.0, MinValue = 0, Group = "Impulse Breakout")]
        public double ImpulseThresholdPct { get; set; }

        [Parameter("Zone Scan Lookback (bars)", DefaultValue = 15, MinValue = 3, Group = "Retracement Zone")]
        public int ZoneScanMaxBars { get; set; }

        [Parameter("Min FVG Size (x ATR)", DefaultValue = 0.0, MinValue = 0, Group = "Retracement Zone")]
        public double FvgMinAtrMult { get; set; }

        [Parameter("Retracement Timeout (minutes)", DefaultValue = 30, MinValue = 1, Group = "Retracement Zone")]
        public int RetraceTimeoutMin { get; set; }

        [Parameter("Require Confirmation Candle Before Entry", DefaultValue = true, Group = "Retracement Zone")]
        public bool UseZoneConfirmation { get; set; }

        #endregion

        #region Parameters -- Risk / Take Profit

        [Parameter("Risk % per Trade", DefaultValue = 1.0, MinValue = 0.01, Group = "Risk Management")]
        public double RiskPercent { get; set; }

        [Parameter("SL Buffer (x ATR)", DefaultValue = 0.3, MinValue = 0, Group = "Risk Management")]
        public double SlBufferAtrMult { get; set; }

        [Parameter("Close Stagnant Trade After (bars, 0=off)", DefaultValue = 30, MinValue = 0, Group = "Risk Management")]
        public int StagnationBars { get; set; }

        [Parameter("Max SL Distance (pips, 0=off)", DefaultValue = 200, MinValue = 0, Group = "Risk Management")]
        public double MaxSlPips { get; set; }

        [Parameter("Number of Take Profits (1-3)", DefaultValue = 3, MinValue = 1, MaxValue = 3, Group = "Take Profit")]
        public int NumTPs { get; set; }

        [Parameter("TP1 (R multiple)", DefaultValue = 1.0, MinValue = 0.1, Group = "Take Profit")]
        public double Tp1R { get; set; }

        [Parameter("TP2 (R multiple)", DefaultValue = 2.0, MinValue = 0.1, Group = "Take Profit")]
        public double Tp2R { get; set; }

        [Parameter("TP3 (R multiple)", DefaultValue = 3.0, MinValue = 0.1, Group = "Take Profit")]
        public double Tp3R { get; set; }

        [Parameter("TP1 Close %", DefaultValue = 33.0, MinValue = 1, MaxValue = 100, Group = "Take Profit")]
        public double Tp1Qty { get; set; }

        [Parameter("TP2 Close %", DefaultValue = 33.0, MinValue = 1, MaxValue = 100, Group = "Take Profit")]
        public double Tp2Qty { get; set; }

        [Parameter("Move SL to Breakeven after TP1", DefaultValue = true, Group = "Take Profit")]
        public bool MoveToBEAfterTP1 { get; set; }

        #endregion

        #region Parameters -- Session

        [Parameter("Restrict Entries to Session", DefaultValue = true, Group = "Trading Session")]
        public bool UseSessionFilter { get; set; }

        [Parameter("Session Start (HH:mm)", DefaultValue = "10:00", Group = "Trading Session")]
        public string SessionStartStr { get; set; }

        [Parameter("Session End (HH:mm)", DefaultValue = "22:00", Group = "Trading Session")]
        public string SessionEndStr { get; set; }

        [Parameter("Session Timezone Offset (hours from UTC, e.g. 5.5 for IST)", DefaultValue = 5.5, Group = "Trading Session")]
        public double SessionTzOffsetHours { get; set; }

        #endregion

        #region Parameters -- Funded Account Rules

        [Parameter("Enable Max Daily Loss %", DefaultValue = false, Group = "Funded Account Rules")]
        public bool UseDailyLossLimit { get; set; }

        [Parameter("Max Daily Loss %", DefaultValue = 5.0, MinValue = 0, Group = "Funded Account Rules")]
        public double MaxDailyLossPct { get; set; }

        [Parameter("Enable Max Daily Profit %", DefaultValue = false, Group = "Funded Account Rules")]
        public bool UseDailyProfitLimit { get; set; }

        [Parameter("Max Daily Profit %", DefaultValue = 5.0, MinValue = 0, Group = "Funded Account Rules")]
        public double MaxDailyProfitPct { get; set; }

        [Parameter("Daily Reset Hour (0-23, Session Timezone)", DefaultValue = 0, MinValue = 0, MaxValue = 23, Group = "Funded Account Rules")]
        public int DailyResetHour { get; set; }

        [Parameter("Only Allow 1 Trade At A Time", DefaultValue = false, Group = "Funded Account Rules")]
        public bool SingleTradeOnly { get; set; }

        [Parameter("Enable News Blackout Windows", DefaultValue = false, Group = "Funded Account Rules")]
        public bool UseNewsBlackout { get; set; }

        [Parameter("News Blackout Windows (comma-separated HH:mm-HH:mm)", DefaultValue = "", Group = "Funded Account Rules")]
        public string NewsBlackoutWindows { get; set; }

        [Parameter("Weekend Holding Restriction", DefaultValue = false, Group = "Funded Account Rules")]
        public bool UseWeekendRestriction { get; set; }

        [Parameter("Weekend Cutoff Time (Friday, HH:mm)", DefaultValue = "21:00", Group = "Funded Account Rules")]
        public string WeekendCutoffStr { get; set; }

        [Parameter("Block New Entries This Many Minutes Before Weekend Cutoff", DefaultValue = 60, MinValue = 0, Group = "Funded Account Rules")]
        public int WeekendBlockBufferMin { get; set; }

        [Parameter("Overnight Holding Restriction", DefaultValue = false, Group = "Funded Account Rules")]
        public bool UseOvernightRestriction { get; set; }

        [Parameter("Overnight Cutoff Time (Daily, HH:mm)", DefaultValue = "21:00", Group = "Funded Account Rules")]
        public string OvernightCutoffStr { get; set; }

        [Parameter("Block New Entries This Many Minutes Before Overnight Cutoff", DefaultValue = 60, MinValue = 0, Group = "Funded Account Rules")]
        public int OvernightBlockBufferMin { get; set; }

        [Parameter("Minimum Holding Time (minutes, 0=off)", DefaultValue = 0, MinValue = 0, Group = "Funded Account Rules")]
        public int MinHoldingMin { get; set; }

        [Parameter("Cooldown After a Loss (minutes, 0=off)", DefaultValue = 0, MinValue = 0, Group = "Funded Account Rules")]
        public int CooldownAfterLossMin { get; set; }

        #endregion

        #region Parameters -- Bot Control / Visuals

        [Parameter("Enable Auto-Trading", DefaultValue = false, Group = "Bot Control")]
        public bool EnableAutoTrading { get; set; }

        [Parameter("Trade Label", DefaultValue = "SidewayBreakoutBot", Group = "Bot Control")]
        public string TradeLabel { get; set; }

        [Parameter("Show Retracement Zone", DefaultValue = true, Group = "Visuals")]
        public bool ShowZone { get; set; }

        [Parameter("Show Risk/Reward Levels", DefaultValue = true, Group = "Visuals")]
        public bool ShowTradeLevels { get; set; }

        [Parameter("Show Dashboard", DefaultValue = true, Group = "Visuals")]
        public bool ShowDashboard { get; set; }

        #endregion

        #region State

        private AverageTrueRange _rangeAtr;
        private AverageTrueRange _filterAtr;
        private SimpleMovingAverage _sma;

        // Range detector (mirrors the Pine "bx"/"lvl"/rMax/rMin/rOs vars)
        private string _rangeBoxName;
        private string _rangeLineName;
        private double _rMax = double.NaN, _rMin = double.NaN;
        private int _rOs; // 0 = unbroken, 1 = broke up, -1 = broke down
        private int _rangeBoxLeftIdx = -1; // bar index the current range box's left edge is anchored at
        private double _rangeBoxTop, _rangeBoxBottom;
        private int _rCountPrev = -1;
        private int _objCounter; // ever-increasing counter for unique chart object names

        private readonly List<Setup> _setups = new List<Setup>();
        private int _setupCounter;

        private class TradedZone
        {
            public double High, Low;
            public int Dir;
            public DateTime Time;
        }
        private readonly List<TradedZone> _tradedZones = new List<TradedZone>();

        private class TradeRecord
        {
            public DateTime ExitTime;
            public int Dir;
            public string ExitReason; // "SL","Breakeven","TP1","TP2","TP3","Stagnant","Restriction"
            public double RResult;
            public bool IsImpulse;
            public int TpsReached;
        }
        private readonly List<TradeRecord> _tradeHistory = new List<TradeRecord>();

        private class Setup
        {
            public int State; // 1 = watching, 4 = fakeout confirm, 5 = impulse entry wait, 2 = retracement wait, 3 = in trade
            public double LockedHigh, LockedLow;
            public int LockBarIdx;
            public int Dir; // 1 = long, -1 = short, 0 = undetermined
            public DateTime BreakoutTime;
            public int BreakoutBarIdx;
            public bool IsImpulse;
            public double ImpulsePct;
            public double ZoneHigh, ZoneLow;
            public bool TouchedZone;
            public double SlPrice, EntryPrice, Tp1Price, Tp2Price, Tp3Price;
            public bool Tp1Hit, Tp2Hit, Tp3Hit;
            public int FlipsUsed;
            public int EntryBarIdx;
            public DateTime EntryTime;
            public bool LeftEntry;
            public bool ConfirmedOutOfSession;
            public string PositionLabel; // null unless a real position was opened for this setup
            public double QtyAtEntryUnits;
            public string ZoneBoxName;
            public string EntryLineName, SlLineName, Tp1LineName, Tp2LineName, Tp3LineName;
        }

        // Funded-account tracking
        private DateTime _fundedDayKey = DateTime.MinValue;
        private double _fundedDayStartEquity;
        private DateTime _lastLossTime = DateTime.MinValue;
        private bool _hasLastLoss;
        private List<(TimeSpan start, TimeSpan end)> _newsWindows = new List<(TimeSpan, TimeSpan)>();
        private TimeSpan _sessionStart, _sessionEnd, _weekendCutoff, _overnightCutoff;

        private string _dashboardName = "SBB_Dashboard";

        #endregion

        protected override void OnStart()
        {
            _rangeAtr = Indicators.AverageTrueRange(RangeAtrLen, MovingAverageType.WilderSmoothing);
            _filterAtr = Indicators.AverageTrueRange(AtrLength, MovingAverageType.WilderSmoothing);
            _sma = Indicators.SimpleMovingAverage(Bars.ClosePrices, RangeLength);

            _sessionStart = ParseTimeOfDay(SessionStartStr, new TimeSpan(10, 0, 0));
            _sessionEnd = ParseTimeOfDay(SessionEndStr, new TimeSpan(22, 0, 0));
            _weekendCutoff = ParseTimeOfDay(WeekendCutoffStr, new TimeSpan(21, 0, 0));
            _overnightCutoff = ParseTimeOfDay(OvernightCutoffStr, new TimeSpan(21, 0, 0));
            _newsWindows = ParseWindows(NewsBlackoutWindows);

            Bars.BarOpened += Bars_BarOpened;
        }

        private static TimeSpan ParseTimeOfDay(string s, TimeSpan fallback)
        {
            TimeSpan t;
            return TimeSpan.TryParse(s, out t) ? t : fallback;
        }

        private static List<(TimeSpan, TimeSpan)> ParseWindows(string raw)
        {
            var result = new List<(TimeSpan, TimeSpan)>();
            if (string.IsNullOrWhiteSpace(raw)) return result;
            foreach (var part in raw.Split(','))
            {
                var pieces = part.Trim().Split('-');
                if (pieces.Length != 2) continue;
                TimeSpan a, b;
                if (TimeSpan.TryParse(pieces[0].Trim(), out a) && TimeSpan.TryParse(pieces[1].Trim(), out b))
                    result.Add((a, b));
            }
            return result;
        }

        // Fires the instant a new bar opens -- at that point the PREVIOUS bar is fully
        // closed, so `idx` below is that just-closed bar (matches Pine's `barstate.isconfirmed`
        // semantics: open/high/low/close read there are the final, settled values).
        private void Bars_BarOpened(BarOpenedEventArgs args)
        {
            int idx = Bars.Count - 2;
            if (idx < Math.Max(RangeLength, Math.Max(RangeAtrLen, AtrLength)) + 5) return; // not enough history yet

            UpdateRangeDetector(idx);
            AdvanceSetups(idx);
            TryArmNewSetup(idx);
            if (ShowDashboard) UpdateDashboard();
        }

        #region Range Detector

        private void UpdateRangeDetector(int idx)
        {
            double rAtrVal = _rangeAtr.Result[idx] * RangeMult;
            double ma = _sma.Result[idx];

            int rCount = 0;
            for (int i = 0; i < RangeLength; i++)
            {
                int j = idx - i;
                if (j < 0) break;
                if (Math.Abs(Bars.ClosePrices[j] - ma) > rAtrVal) rCount++;
            }

            bool rangeEvent = rCount == 0 && _rCountPrev != 0;
            _rCountPrev = rCount;
            _lastFreshRange = false;

            if (rangeEvent)
            {
                int leftIdx = idx - RangeLength;
                if (_rangeBoxName != null && leftIdx <= _rangeBoxRightIdx)
                {
                    // Merge: the new range's left edge falls within (or before) the
                    // existing box's current right edge -- stretch that same box/line to
                    // cover both instead of starting a new one (mirrors Pine's
                    // n[rangeLength] <= bx.get_right() check).
                    _rMax = Math.Max(ma + rAtrVal, _rangeBoxTop);
                    _rMin = Math.Min(ma - rAtrVal, _rangeBoxBottom);
                    _rangeBoxTop = _rMax;
                    _rangeBoxBottom = _rMin;
                    _rangeBoxRightIdx = idx;
                    DrawRangeBox(idx, Colors.Unbroken);
                }
                else
                {
                    _rMax = ma + rAtrVal;
                    _rMin = ma - rAtrVal;
                    _rangeBoxLeftIdx = leftIdx;
                    _rangeBoxRightIdx = idx;
                    _rangeBoxTop = _rMax;
                    _rangeBoxBottom = _rMin;
                    _objCounter++;
                    _rangeBoxName = "SBB_Range_" + _objCounter;
                    _rangeLineName = "SBB_RangeMid_" + _objCounter;
                    _rOs = 0;
                    DrawRangeBox(idx, Colors.Unbroken);
                    _lastFreshRange = true;
                }
            }
            else if (rCount == 0 && _rangeBoxName != null)
            {
                _rangeBoxRightIdx = idx;
                DrawRangeBox(idx, _rOs == 0 ? Colors.Unbroken : (_rOs == 1 ? Colors.Up : Colors.Down));
            }

            if (_rangeBoxName != null)
            {
                double close = Bars.ClosePrices[idx];
                if (close > _rangeBoxTop)
                {
                    _rOs = 1;
                    DrawRangeBox(idx, Colors.Up);
                }
                else if (close < _rangeBoxBottom)
                {
                    _rOs = -1;
                    DrawRangeBox(idx, Colors.Down);
                }
            }
        }

        private bool _lastFreshRange;
        private int _rangeBoxRightIdx = -1; // logical "box.get_right()" -- the last bar index the box was actually extended to (distinct from the current bar, since a broken box stops extending)

        private void DrawRangeBox(int idx, Color color)
        {
            Chart.DrawRectangle(_rangeBoxName, Bars.OpenTimes[_rangeBoxLeftIdx], _rangeBoxTop, Bars.OpenTimes[idx], _rangeBoxBottom, color, 1, LineStyle.Solid).IsFilled = true;
            double mid = (_rangeBoxTop + _rangeBoxBottom) / 2.0;
            Chart.DrawTrendLine(_rangeLineName, Bars.OpenTimes[_rangeBoxLeftIdx], mid, Bars.OpenTimes[idx], mid, color, 1, LineStyle.Dots);
        }

        private static class Colors
        {
            public static readonly Color Unbroken = Color.FromArgb(120, 33, 87, 243);
            public static readonly Color Up = Color.FromArgb(120, 8, 153, 129);
            public static readonly Color Down = Color.FromArgb(120, 242, 54, 69);
        }

        #endregion

        #region Zone (FVG) scan

        // Mirrors Pine's f_findZone: scans the breakout leg for the nearest 3-candle Fair
        // Value Gap; falls back to the locked range's own high/low if none qualifies.
        private (double zoneHigh, double zoneLow) FindZone(int dir, int lockBarIdx, double lockedHigh, double lockedLow, int idx)
        {
            int scanLen = Math.Min(idx - lockBarIdx, ZoneScanMaxBars);
            double atrVal = _filterAtr.Result[idx];

            if (scanLen >= 3)
            {
                for (int i = 1; i <= scanLen - 2; i++)
                {
                    int a = idx - i;       // candle i
                    int b = idx - i - 2;   // candle i+2
                    if (b < 0) break;
                    if (dir == 1)
                    {
                        if (Bars.LowPrices[a] > Bars.HighPrices[b] && (Bars.LowPrices[a] - Bars.HighPrices[b]) >= FvgMinAtrMult * atrVal)
                            return (Bars.LowPrices[a], Bars.HighPrices[b]);
                    }
                    else
                    {
                        if (Bars.HighPrices[a] < Bars.LowPrices[b] && (Bars.LowPrices[b] - Bars.HighPrices[a]) >= FvgMinAtrMult * atrVal)
                            return (Bars.LowPrices[b], Bars.HighPrices[a]);
                    }
                }
            }
            return (lockedHigh, lockedLow);
        }

        #endregion

        #region Retest guard

        private void PruneTradedZones(int idx)
        {
            if (RetestGuardBars <= 0) return;
            var cutoff = Bars.OpenTimes[idx] - TimeSpan.FromMinutes(RetestGuardBars * BarMinutes(idx));
            while (_tradedZones.Count > 0 && _tradedZones[0].Time < cutoff)
                _tradedZones.RemoveAt(0);
        }

        private double BarMinutes(int idx)
        {
            // Bar duration measured directly from consecutive bar timestamps rather than
            // TimeFrame (which has no well-defined duration for non-time-based bar types) --
            // for the retest-guard bar-count-to-time conversion (RetestGuardBars is a BAR
            // count, same as Pine).
            if (idx <= 0) return 1;
            double mins = (Bars.OpenTimes[idx] - Bars.OpenTimes[idx - 1]).TotalMinutes;
            return mins > 0 ? mins : 1;
        }

        private bool ZoneAlreadyTraded(int dir, double hi, double lo, int idx)
        {
            PruneTradedZones(idx);
            if (RetestGuardBars <= 0) return false;
            foreach (var z in _tradedZones)
            {
                if (z.Dir != dir) continue;
                double ov = Math.Min(hi, z.High) - Math.Max(lo, z.Low);
                double span = Math.Min(hi - lo, z.High - z.Low);
                if (ov > 0 && span > 0 && ov / span * 100.0 >= RetestGuardOverlapPct)
                    return true;
            }
            return false;
        }

        #endregion

        #region Funded account rules

        private bool FundedBlockEntry(DateTime barTimeUtc, int idx)
        {
            var local = barTimeUtc.AddHours(SessionTzOffsetHours);

            // Daily loss/profit, measured against real account equity (this is a real
            // cBot, so unlike the Pine Indicator's simulated approximation we can just
            // use Account.Equity directly -- it already reflects floating P&L too).
            var shifted = local.AddHours(-DailyResetHour);
            var dayKey = shifted.Date;
            if (_fundedDayKey != dayKey)
            {
                _fundedDayKey = dayKey;
                _fundedDayStartEquity = Account.Equity;
            }
            double todayPnLPct = _fundedDayStartEquity > 0 ? (Account.Equity - _fundedDayStartEquity) / _fundedDayStartEquity * 100.0 : 0.0;
            bool dailyLossBreached = UseDailyLossLimit && todayPnLPct <= -MaxDailyLossPct;
            bool dailyProfitBreached = UseDailyProfitLimit && todayPnLPct >= MaxDailyProfitPct;

            bool inNewsBlackout = UseNewsBlackout && _newsWindows.Any(w => InWindow(local.TimeOfDay, w.start, w.end));

            bool isFriday = local.DayOfWeek == DayOfWeek.Friday;
            bool isWeekendDay = local.DayOfWeek == DayOfWeek.Saturday || local.DayOfWeek == DayOfWeek.Sunday;
            bool weekendBlock = UseWeekendRestriction && (isWeekendDay || (isFriday && local.TimeOfDay >= _weekendCutoff - TimeSpan.FromMinutes(WeekendBlockBufferMin)));
            bool overnightBlock = UseOvernightRestriction && local.TimeOfDay >= _overnightCutoff - TimeSpan.FromMinutes(OvernightBlockBufferMin);

            bool cooldownActive = CooldownAfterLossMin > 0 && _hasLastLoss && (barTimeUtc - _lastLossTime).TotalMinutes < CooldownAfterLossMin;

            return dailyLossBreached || dailyProfitBreached || inNewsBlackout || weekendBlock || overnightBlock || cooldownActive;
        }

        private bool FundedForceFlatten(DateTime barTimeUtc)
        {
            var local = barTimeUtc.AddHours(SessionTzOffsetHours);
            bool isFriday = local.DayOfWeek == DayOfWeek.Friday;
            bool isWeekendDay = local.DayOfWeek == DayOfWeek.Saturday || local.DayOfWeek == DayOfWeek.Sunday;
            bool weekendPast = UseWeekendRestriction && (isWeekendDay || (isFriday && local.TimeOfDay >= _weekendCutoff));
            bool overnightPast = UseOvernightRestriction && local.TimeOfDay >= _overnightCutoff;
            return weekendPast || overnightPast;
        }

        private static bool InWindow(TimeSpan t, TimeSpan start, TimeSpan end)
        {
            return start <= end ? (t >= start && t < end) : (t >= start || t < end);
        }

        private bool InSession(DateTime barTimeUtc)
        {
            if (!UseSessionFilter) return true;
            var t = barTimeUtc.AddHours(SessionTzOffsetHours).TimeOfDay;
            return InWindow(t, _sessionStart, _sessionEnd);
        }

        #endregion

        #region Setup state machine

        private void AdvanceSetups(int idx)
        {
            var barTime = Bars.OpenTimes[idx];
            double open = Bars.OpenPrices[idx], high = Bars.HighPrices[idx], low = Bars.LowPrices[idx], close = Bars.ClosePrices[idx];
            double atrVal = _filterAtr.Result[idx];
            bool inSession = InSession(barTime);
            bool fundedBlock = FundedBlockEntry(barTime, idx);
            bool fundedFlatten = FundedForceFlatten(barTime);

            for (int i = _setups.Count - 1; i >= 0; i--)
            {
                var s = _setups[i];
                bool removeThis = false;

                if (s.State == 3)
                {
                    removeThis = AdvanceState3(s, idx, barTime, open, high, low, close, fundedFlatten);
                }
                else if (s.State == 1)
                {
                    removeThis = AdvanceState1(s, idx, barTime, open, high, low, close, atrVal);
                }
                else if (s.State == 4)
                {
                    removeThis = AdvanceState4(s, idx, barTime, open, high, low, close);
                }
                else if (s.State == 5)
                {
                    removeThis = AdvanceState5(s, idx, barTime, open, close, atrVal, inSession, fundedBlock);
                }
                else if (s.State == 2)
                {
                    removeThis = AdvanceState2(s, idx, barTime, open, high, low, close, atrVal, inSession, fundedBlock);
                }

                if (removeThis) _setups.RemoveAt(i);
            }
        }

        // ---- STATE 1: watching for a full-body breakout ----
        private bool AdvanceState1(Setup s, int idx, DateTime barTime, double open, double high, double low, double close, double atrVal)
        {
            double bodySize = Math.Abs(close - open);
            bool passesBody = !UseBodyFilter || bodySize >= BodyAtrMult * atrVal;
            bool bullBreak = Math.Min(open, close) > s.LockedHigh && passesBody;
            bool bearBreak = Math.Max(open, close) < s.LockedLow && passesBody;

            if (bullBreak || bearBreak)
            {
                s.Dir = bullBreak ? 1 : -1;
                s.BreakoutTime = barTime;
                s.BreakoutBarIdx = idx;

                double rangeHeight = s.LockedHigh - s.LockedLow;
                double breakoutDist = bullBreak ? close - s.LockedHigh : s.LockedLow - close;
                bool isImpulse = EnableImpulseEntry && rangeHeight > 0 && breakoutDist >= ImpulseThresholdPct / 100.0 * rangeHeight;

                if (isImpulse)
                {
                    s.IsImpulse = true;
                    s.ImpulsePct = breakoutDist / rangeHeight * 100.0;
                    s.State = 5;
                }
                else if (UseFakeoutFilter)
                {
                    s.State = 4;
                }
                else
                {
                    var (zh, zl) = FindZone(s.Dir, s.LockBarIdx, s.LockedHigh, s.LockedLow, idx);
                    s.ZoneHigh = zh; s.ZoneLow = zl; s.TouchedZone = false;
                    s.State = 2;
                    DrawZoneBox(s, idx);
                }
                return false;
            }
            if (idx - s.LockBarIdx > MaxBarsWatch)
                return true;
            return false;
        }

        // ---- STATE 4: fakeout confirmation ----
        private bool AdvanceState4(Setup s, int idx, DateTime barTime, double open, double high, double low, double close)
        {
            double atrVal = _filterAtr.Result[idx];
            double bodySize = Math.Abs(close - open);
            bool passesBody = !UseBodyFilter || bodySize >= BodyAtrMult * atrVal;
            bool confirmed = s.Dir == 1
                ? Math.Min(open, close) > s.LockedHigh && passesBody
                : Math.Max(open, close) < s.LockedLow && passesBody;

            if (confirmed)
            {
                s.BreakoutTime = barTime;
                var (zh, zl) = FindZone(s.Dir, s.LockBarIdx, s.LockedHigh, s.LockedLow, idx);
                s.ZoneHigh = zh; s.ZoneLow = zl;
                int scanLen2 = Math.Max(Math.Min(idx - s.BreakoutBarIdx + 1, ZoneScanMaxBars), 1);
                double zoneStart2 = s.Dir == 1 ? s.ZoneHigh : s.ZoneLow;
                double lowest = double.MaxValue, highest = double.MinValue;
                for (int k = 0; k < scanLen2; k++)
                {
                    int j = idx - k;
                    if (j < 0) break;
                    lowest = Math.Min(lowest, Bars.LowPrices[j]);
                    highest = Math.Max(highest, Bars.HighPrices[j]);
                }
                s.TouchedZone = s.Dir == 1 ? lowest <= zoneStart2 : highest >= zoneStart2;
                s.State = 2;
                DrawZoneBox(s, idx);
                return false;
            }
            // Fakeout -- go back to state 1, same range.
            s.Dir = 0;
            s.BreakoutTime = DateTime.MinValue;
            s.State = 1;
            return false;
        }

        // ---- STATE 5: impulse breakout -- enter next candle, no wait ----
        private bool AdvanceState5(Setup s, int idx, DateTime barTime, double open, double close, double atrVal, bool inSession, bool fundedBlock)
        {
            bool invalidated5 = s.Dir == 1 ? Bars.LowPrices[idx] < s.LockedLow : Bars.HighPrices[idx] > s.LockedHigh;
            double minutesSince = (barTime - s.BreakoutTime).TotalMinutes;

            if (invalidated5 || minutesSince > RetraceTimeoutMin)
                return true;

            if (!inSession || fundedBlock) return false;

            double candidateEntry = open;
            double buffer = SlBufferAtrMult * atrVal;
            double candidateSl = s.Dir == 1 ? s.LockedLow - buffer : s.LockedHigh + buffer;
            double r = Math.Abs(candidateEntry - candidateSl);
            double slPips = r / Symbol.PipSize;

            if (r <= 0 || (MaxSlPips > 0 && slPips > MaxSlPips) || ZoneAlreadyTraded(s.Dir, s.LockedHigh, s.LockedLow, idx))
                return true;

            EnterTrade(s, idx, barTime, candidateEntry, candidateSl, r);
            return false;
        }

        // ---- STATE 2: wait for retracement into the zone, then a confirmation candle ----
        private bool AdvanceState2(Setup s, int idx, DateTime barTime, double open, double high, double low, double close, double atrVal, bool inSession, bool fundedBlock)
        {
            double zoneStart = s.Dir == 1 ? s.ZoneHigh : s.ZoneLow;
            bool touched = s.Dir == 1 ? low <= zoneStart : high >= zoneStart;
            if (touched) s.TouchedZone = true;

            bool confirmBull = close > open && close > zoneStart;
            bool confirmBear = close < open && close < zoneStart;
            // When UseZoneConfirmation is off, the touch alone is enough -- entry fires
            // on the very candle that reaches the zone, at its close, instead of waiting
            // for a candle that also happens to close back beyond the edge (which can
            // take many bars).
            bool confirmation = s.TouchedZone && (!UseZoneConfirmation || (s.Dir == 1 ? confirmBull : confirmBear));

            bool invalidated = s.Dir == 1 ? low < s.LockedLow : high > s.LockedHigh;
            double minutesSince = (barTime - s.BreakoutTime).TotalMinutes;

            if (confirmation && !inSession) s.ConfirmedOutOfSession = true;

            if (confirmation && inSession && !fundedBlock)
            {
                double candidateEntry = close;
                double buffer = SlBufferAtrMult * atrVal;
                double candidateSl = s.Dir == 1 ? s.LockedLow - buffer : s.LockedHigh + buffer;
                double r = Math.Abs(candidateEntry - candidateSl);
                double slPips = r / Symbol.PipSize;

                if (r <= 0 || (MaxSlPips > 0 && slPips > MaxSlPips) || ZoneAlreadyTraded(s.Dir, s.LockedHigh, s.LockedLow, idx))
                {
                    RemoveZoneBox(s);
                    return true;
                }
                RemoveZoneBox(s);
                EnterTrade(s, idx, barTime, candidateEntry, candidateSl, r);
                return false;
            }
            if (invalidated || minutesSince > RetraceTimeoutMin)
            {
                RemoveZoneBox(s);
                return true;
            }
            return false;
        }

        // ---- STATE 3: in trade -- SL / TP1-3 / stagnation / funded-restriction close ----
        private bool AdvanceState3(Setup s, int idx, DateTime barTime, double open, double high, double low, double close, bool fundedFlatten)
        {
            if (!s.Tp1Hit && (s.Dir == 1 ? high >= s.Tp1Price : low <= s.Tp1Price))
            {
                s.Tp1Hit = true;
                if (EnableAutoTrading && s.PositionLabel != null)
                {
                    var pos = Positions.Find(s.PositionLabel);
                    if (pos != null && NumTPs >= 2)
                    {
                        double closeVol = Symbol.NormalizeVolumeInUnits(s.QtyAtEntryUnits * Tp1Qty / 100.0, RoundingMode.Down);
                        if (closeVol > 0 && closeVol < pos.VolumeInUnits) ClosePosition(pos, closeVol);
                        pos.ModifyStopLossPrice(s.EntryPrice);
                    }
                    else if (pos != null)
                    {
                        ClosePosition(pos);
                    }
                }
            }
            if (NumTPs >= 2 && s.Tp1Hit && !s.Tp2Hit && (s.Dir == 1 ? high >= s.Tp2Price : low <= s.Tp2Price))
            {
                s.Tp2Hit = true;
                if (EnableAutoTrading && s.PositionLabel != null)
                {
                    var pos = Positions.Find(s.PositionLabel);
                    if (pos != null && NumTPs >= 3)
                    {
                        double closeVol = Symbol.NormalizeVolumeInUnits(s.QtyAtEntryUnits * Tp2Qty / 100.0, RoundingMode.Down);
                        if (closeVol > 0 && closeVol < pos.VolumeInUnits) ClosePosition(pos, closeVol);
                    }
                    else if (pos != null)
                    {
                        ClosePosition(pos);
                    }
                }
            }
            if (NumTPs >= 3 && s.Tp2Hit && !s.Tp3Hit && (s.Dir == 1 ? high >= s.Tp3Price : low <= s.Tp3Price))
            {
                s.Tp3Hit = true;
                if (EnableAutoTrading && s.PositionLabel != null)
                {
                    var pos = Positions.Find(s.PositionLabel);
                    if (pos != null) ClosePosition(pos);
                }
            }

            double stopNow = (NumTPs >= 2 && s.Tp1Hit && MoveToBEAfterTP1) ? s.EntryPrice : s.SlPrice;
            bool stopHit = s.Dir == 1 ? low <= stopNow : high >= stopNow;

            if (!s.LeftEntry && (s.Dir == 1 ? high > s.EntryPrice : low < s.EntryPrice))
                s.LeftEntry = true;
            bool pastMinHold = MinHoldingMin <= 0 || (barTime - s.EntryTime).TotalMinutes >= MinHoldingMin;
            bool stagnant = StagnationBars > 0 && !s.LeftEntry && (idx - s.EntryBarIdx) >= StagnationBars && pastMinHold;

            bool finalTpHit = NumTPs == 1 ? s.Tp1Hit : (NumTPs == 2 ? s.Tp2Hit : s.Tp3Hit);
            double riskDistance = Math.Abs(s.EntryPrice - s.SlPrice);
            int tpsReachedNow = (s.Tp1Hit ? 1 : 0) + (s.Tp2Hit ? 1 : 0) + (s.Tp3Hit ? 1 : 0);

            if (ShowTradeLevels) UpdateTradeLevels(s, idx, stopNow);

            if (stopHit)
            {
                if (EnableAutoTrading && s.PositionLabel != null)
                {
                    var pos = Positions.Find(s.PositionLabel);
                    if (pos != null) ClosePosition(pos);
                }
                double rResult = RealizedR(tpsReachedNow, stopNow, s.EntryPrice, riskDistance, s.Dir);
                _tradeHistory.Add(new TradeRecord { ExitTime = barTime, Dir = s.Dir, ExitReason = stopNow == s.EntryPrice ? "Breakeven" : "SL", RResult = rResult, IsImpulse = s.IsImpulse, TpsReached = tpsReachedNow });
                if (stopNow != s.EntryPrice) { _lastLossTime = barTime; _hasLastLoss = true; }
                RemoveTradeLevels(s);

                if (s.FlipsUsed < MaxSlFlips)
                {
                    _setupCounter++;
                    var flip = new Setup
                    {
                        State = 1,
                        LockedHigh = s.LockedHigh,
                        LockedLow = s.LockedLow,
                        LockBarIdx = idx,
                        Dir = 0,
                        FlipsUsed = s.FlipsUsed + 1
                    };
                    _setups.Add(flip);
                }
                return true;
            }
            if (finalTpHit)
            {
                double finalTpPrice = NumTPs == 1 ? s.Tp1Price : (NumTPs == 2 ? s.Tp2Price : s.Tp3Price);
                double rResult = RealizedR(tpsReachedNow, finalTpPrice, s.EntryPrice, riskDistance, s.Dir);
                _tradeHistory.Add(new TradeRecord { ExitTime = barTime, Dir = s.Dir, ExitReason = "TP" + NumTPs, RResult = rResult, IsImpulse = s.IsImpulse, TpsReached = tpsReachedNow });
                RemoveTradeLevels(s);
                return true;
            }
            if (stagnant)
            {
                if (EnableAutoTrading && s.PositionLabel != null)
                {
                    var pos = Positions.Find(s.PositionLabel);
                    if (pos != null) ClosePosition(pos);
                }
                double rResult = RealizedR(tpsReachedNow, close, s.EntryPrice, riskDistance, s.Dir);
                _tradeHistory.Add(new TradeRecord { ExitTime = barTime, Dir = s.Dir, ExitReason = "Stagnant", RResult = rResult, IsImpulse = s.IsImpulse, TpsReached = tpsReachedNow });
                RemoveTradeLevels(s);
                return true;
            }
            if (fundedFlatten)
            {
                if (EnableAutoTrading && s.PositionLabel != null)
                {
                    var pos = Positions.Find(s.PositionLabel);
                    if (pos != null) ClosePosition(pos);
                }
                double rResult = RealizedR(tpsReachedNow, close, s.EntryPrice, riskDistance, s.Dir);
                _tradeHistory.Add(new TradeRecord { ExitTime = barTime, Dir = s.Dir, ExitReason = "Restriction", RResult = rResult, IsImpulse = s.IsImpulse, TpsReached = tpsReachedNow });
                RemoveTradeLevels(s);
                return true;
            }
            return false;
        }

        // R-weighted realized result: each reached TP tier books its own R at its own
        // close %, only the unclosed remainder marks to the actual exit price.
        private double RealizedR(int reached, double exitPrice, double entryPrice, double riskDistance, int dir)
        {
            double pctT1 = NumTPs == 1 ? 100.0 : Tp1Qty;
            double pctT2 = NumTPs == 2 ? 100.0 - Tp1Qty : Tp2Qty;
            double pctT3 = Math.Max(0.0, 100.0 - pctT1 - pctT2);
            double booked = 0.0, used = 0.0;
            if (reached >= 1) { booked += pctT1 / 100.0 * Tp1R; used += pctT1; }
            if (reached >= 2) { booked += pctT2 / 100.0 * Tp2R; used += pctT2; }
            if (reached >= 3) { booked += pctT3 / 100.0 * Tp3R; used += pctT3; }
            double exitR = riskDistance > 0 ? (exitPrice - entryPrice) / riskDistance * dir : 0.0;
            return booked + Math.Max(100.0 - used, 0.0) / 100.0 * exitR;
        }

        private void EnterTrade(Setup s, int idx, DateTime barTime, double entryPrice, double slPrice, double r)
        {
            _tradedZones.Add(new TradedZone { High = s.LockedHigh, Low = s.LockedLow, Dir = s.Dir, Time = barTime });

            s.EntryPrice = entryPrice;
            s.SlPrice = slPrice;
            s.Tp1Price = s.Dir == 1 ? entryPrice + r * Tp1R : entryPrice - r * Tp1R;
            s.Tp2Price = s.Dir == 1 ? entryPrice + r * Tp2R : entryPrice - r * Tp2R;
            s.Tp3Price = s.Dir == 1 ? entryPrice + r * Tp3R : entryPrice - r * Tp3R;
            s.State = 3;
            s.EntryBarIdx = idx;
            s.EntryTime = barTime;

            if (EnableAutoTrading)
            {
                double riskAmount = Account.Balance * (RiskPercent / 100.0);
                double slPips = r / Symbol.PipSize;
                double volumeUnits = slPips > 0 ? riskAmount / (slPips * Symbol.PipValue) : 0;
                volumeUnits = Symbol.NormalizeVolumeInUnits(volumeUnits, RoundingMode.Down);
                if (volumeUnits >= Symbol.VolumeInUnitsMin)
                {
                    _setupCounter++;
                    string label = TradeLabel + "_" + _setupCounter;
                    var tradeType = s.Dir == 1 ? TradeType.Buy : TradeType.Sell;
                    var result = ExecuteMarketOrder(tradeType, SymbolName, volumeUnits, label);
                    if (result.IsSuccessful)
                    {
                        s.PositionLabel = label;
                        s.QtyAtEntryUnits = volumeUnits;
                        result.Position.ModifyStopLossPrice(slPrice);
                        // TP is managed manually (partial closes at TP1/TP2 above) rather
                        // than a broker-side take-profit order, so it can be split by %.
                    }
                    else
                    {
                        Print("SidewayBreakoutBot: order failed - " + result.Error);
                    }
                }
                else
                {
                    Print("SidewayBreakoutBot: computed volume below broker minimum, skipping real order (visual/simulated tracking continues).");
                }
            }

            if (ShowTradeLevels) UpdateTradeLevels(s, idx, s.SlPrice);
        }

        #endregion

        #region Arm new setups

        private void TryArmNewSetup(int idx)
        {
            if (!_lastFreshRange) return;
            int cap = SingleTradeOnly ? 1 : (AllowStackedEntries ? MaxConcurrentSetups : 1);
            if (_setups.Count >= cap) return;

            _setupCounter++;
            var s = new Setup
            {
                State = 1,
                LockedHigh = _rMax,
                LockedLow = _rMin,
                LockBarIdx = idx,
                Dir = 0
            };
            _setups.Add(s);
        }

        #endregion

        #region Drawing helpers

        private void DrawZoneBox(Setup s, int idx)
        {
            if (!ShowZone) return;
            _objCounter++;
            s.ZoneBoxName = "SBB_Zone_" + _objCounter;
            Chart.DrawRectangle(s.ZoneBoxName, Bars.OpenTimes[idx], s.ZoneHigh, Bars.OpenTimes[idx], s.ZoneLow, Color.FromArgb(90, 255, 165, 0)).IsFilled = true;
        }

        private void RemoveZoneBox(Setup s)
        {
            if (s.ZoneBoxName != null) Chart.RemoveObject(s.ZoneBoxName);
        }

        private void UpdateTradeLevels(Setup s, int idx, double currentStop)
        {
            var t0 = Bars.OpenTimes[s.EntryBarIdx];
            var t1 = Bars.OpenTimes[idx];
            if (s.EntryLineName == null)
            {
                _objCounter++;
                s.EntryLineName = "SBB_Entry_" + _objCounter;
                s.SlLineName = "SBB_SL_" + _objCounter;
                s.Tp1LineName = "SBB_TP1_" + _objCounter;
                if (NumTPs >= 2) s.Tp2LineName = "SBB_TP2_" + _objCounter;
                if (NumTPs >= 3) s.Tp3LineName = "SBB_TP3_" + _objCounter;
            }
            Chart.DrawTrendLine(s.EntryLineName, t0, s.EntryPrice, t1, s.EntryPrice, Color.White, 1, LineStyle.Solid);
            Chart.DrawTrendLine(s.SlLineName, t0, currentStop, t1, currentStop, Colors.Down, 1, LineStyle.Dots);
            Chart.DrawTrendLine(s.Tp1LineName, t0, s.Tp1Price, t1, s.Tp1Price, Colors.Up, 2, LineStyle.Dots);
            if (NumTPs >= 2) Chart.DrawTrendLine(s.Tp2LineName, t0, s.Tp2Price, t1, s.Tp2Price, Colors.Up, 1, LineStyle.Dots);
            if (NumTPs >= 3) Chart.DrawTrendLine(s.Tp3LineName, t0, s.Tp3Price, t1, s.Tp3Price, Colors.Up, 1, LineStyle.Dots);
        }

        private void RemoveTradeLevels(Setup s)
        {
            if (s.EntryLineName != null) Chart.RemoveObject(s.EntryLineName);
            if (s.SlLineName != null) Chart.RemoveObject(s.SlLineName);
            if (s.Tp1LineName != null) Chart.RemoveObject(s.Tp1LineName);
            if (s.Tp2LineName != null) Chart.RemoveObject(s.Tp2LineName);
            if (s.Tp3LineName != null) Chart.RemoveObject(s.Tp3LineName);
            RemoveZoneBox(s);
        }

        private void UpdateDashboard()
        {
            int total = _tradeHistory.Count;
            int sl = _tradeHistory.Count(r => r.ExitReason == "SL");
            int be = _tradeHistory.Count(r => r.ExitReason == "Breakeven");
            int tp1 = _tradeHistory.Count(r => r.ExitReason == "TP1");
            int tp2 = _tradeHistory.Count(r => r.ExitReason == "TP2");
            int tp3 = _tradeHistory.Count(r => r.ExitReason == "TP3");
            int stag = _tradeHistory.Count(r => r.ExitReason == "Stagnant");
            int restr = _tradeHistory.Count(r => r.ExitReason == "Restriction");
            double totalR = _tradeHistory.Sum(r => r.RResult);

            string text = string.Format(
                "Sideway Breakout Bot {0}\nTrades: {1}  |  SL: {2}  BE: {3}\nTP1: {4}  TP2: {5}  TP3: {6}\nStagnant: {7}  Restriction: {8}\nTotal R: {9:0.##}\nOpen setups: {10}  |  Equity: {11:0.##}",
                EnableAutoTrading ? "[LIVE]" : "[Indicator mode]",
                total, sl, be, tp1, tp2, tp3, stag, restr, totalR, _setups.Count, Account.Equity);

            Chart.DrawStaticText(_dashboardName, text, VerticalAlignment.Top, HorizontalAlignment.Right, Color.White);
        }

        #endregion
    }
}
