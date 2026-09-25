//+------------------------------------------------------------------+
//| SidewayBreakoutBotSignalEA.mq5                                    |
//|                                                                    |
//| Executes OPEN / MODIFY_SL / CLOSE JSON signals dropped by the      |
//| Python bridge (bridge/webhook_bridge.py) into one file per signal  |
//| under the terminal's COMMON Files folder                           |
//| (…\MetaQuotes\Terminal\Common\Files\<PendingFolder>).               |
//|                                                                    |
//| A single TradingView entry becomes 1-3 "legs" sharing a group_id   |
//| (one leg per enabled TP tier, since MT5 can't attach three separate|
//| take-profits to one position) -- TP1 being hit moves the remaining |
//| legs' SL to breakeven, and a stagnation timeout closes them all.   |
//| A real SL/TP hit needs no message: each leg carries its own real   |
//| SL/TP on the broker, so it closes natively without EA involvement. |
//+------------------------------------------------------------------+
#property copyright "SidewayBreakoutBot"
#property version   "1.00"

input string PendingFolder    = "SidewayBreakoutBot\\pending"; // relative to the terminal's COMMON Files folder -- must match the bridge's PENDING_DIR
input int    PollSeconds      = 2;      // how often to scan the pending folder
input int    MaxFileAgeMin    = 15;     // an unclaimed file (wrong symbol, or a MODIFY_SL/CLOSE with no tracked group) is deleted as stale after this many minutes so the folder doesn't fill up

input bool   EnableAutoTrading = false; // off = log every signal but never actually place/modify/close a real order (dry run) -- flip on only once you've watched the logs and trust what it's about to do
input double FixedLotSize      = 0.01;  // lot size for EACH leg -- a 3-TP signal opens 3 positions of this size, not one position split three ways
input long   MagicNumber       = 20260101;
input int    SlippagePoints    = 20;

// In-memory leg tracking only -- lost on EA restart. Open positions keep their real
// broker-side SL/TP regardless of this; only the breakeven-move and stagnation-close
// features need it to find which tickets belong to a group_id.
string g_groupIds[];
ulong  g_tickets[];

//+------------------------------------------------------------------+
int OnInit()
  {
   EventSetTimer(MathMax(PollSeconds, 1));
   PrintFormat("[SidewayBreakoutBot] EA started. AutoTrading=%s PendingFolder=%s", (EnableAutoTrading ? "ON" : "OFF (dry run)"), PendingFolder);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

void OnTimer()
  {
   ProcessPendingFolder();
  }

//+------------------------------------------------------------------+
//| Minimal flat-JSON field readers -- our messages are always a      |
//| single flat object with string or number values, so a full JSON   |
//| parser would be overkill.                                         |
//+------------------------------------------------------------------+
string JGetStr(const string json, const string key)
  {
   string pattern = "\"" + key + "\":\"";
   int p = StringFind(json, pattern);
   if(p < 0)
      return "";
   p += StringLen(pattern);
   int q = StringFind(json, "\"", p);
   if(q < 0)
      return "";
   return StringSubstr(json, p, q - p);
  }

double JGetNum(const string json, const string key)
  {
   string pattern = "\"" + key + "\":";
   int p = StringFind(json, pattern);
   if(p < 0)
      return 0.0;
   p += StringLen(pattern);
   int q = p;
   int len = StringLen(json);
   while(q < len)
     {
      ushort c = StringGetCharacter(json, q);
      if(c == ',' || c == '}')
         break;
      q++;
     }
   return StringToDouble(StringSubstr(json, p, q - p));
  }

//+------------------------------------------------------------------+
//| Folder scan                                                       |
//+------------------------------------------------------------------+
void ProcessPendingFolder()
  {
   string fname;
   long handle = FileFindFirst(PendingFolder + "\\*.json", fname, FILE_COMMON);
   if(handle == INVALID_HANDLE)
      return; // folder doesn't exist yet or is empty -- nothing to do
   do
     {
      ProcessFile(fname);
     }
   while(FileFindNext(handle, fname));
   FileFindClose(handle);
  }

int FileAgeSeconds(const string fname)
  {
   int us = StringFind(fname, "_");
   if(us <= 0)
      return 0;
   long ms = StringToInteger(StringSubstr(fname, 0, us));
   long nowMs = (long)TimeGMT() * 1000;
   return (int)((nowMs - ms) / 1000);
  }

void DeleteSignalFile(const string relPath)
  {
   FileDelete(relPath, FILE_COMMON);
  }

void ProcessFile(const string fname)
  {
   string relPath = PendingFolder + "\\" + fname;
   int h = FileOpen(relPath, FILE_COMMON | FILE_READ | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE)
      return;
   string content = "";
   while(!FileIsEnding(h))
      content += FileReadString(h);
   FileClose(h);

   string action  = JGetStr(content, "action");
   string groupId = JGetStr(content, "group_id");

   if(action == "OPEN")
     {
      string sym = JGetStr(content, "symbol");
      if(sym != _Symbol)
        {
         // Not this EA's symbol -- leave it for the instance running on that chart,
         // unless it's been sitting unclaimed long enough to be considered orphaned.
         if(FileAgeSeconds(fname) > MaxFileAgeMin * 60)
            DeleteSignalFile(relPath);
         return;
        }
      HandleOpen(content, groupId);
      DeleteSignalFile(relPath);
     }
   else if(action == "MODIFY_SL")
     {
      if(!HasGroup(groupId))
        {
         if(FileAgeSeconds(fname) > MaxFileAgeMin * 60)
            DeleteSignalFile(relPath);
         return;
        }
      HandleModifySl(content, groupId);
      DeleteSignalFile(relPath);
     }
   else if(action == "CLOSE")
     {
      if(!HasGroup(groupId))
        {
         if(FileAgeSeconds(fname) > MaxFileAgeMin * 60)
            DeleteSignalFile(relPath);
         return;
        }
      HandleClose(groupId);
      DeleteSignalFile(relPath);
     }
   else
     {
      // Unrecognized/malformed -- drop it rather than let it sit forever.
      DeleteSignalFile(relPath);
     }
  }

//+------------------------------------------------------------------+
//| Leg tracking                                                      |
//+------------------------------------------------------------------+
bool HasGroup(const string groupId)
  {
   for(int i = 0; i < ArraySize(g_groupIds); i++)
      if(g_groupIds[i] == groupId)
         return true;
   return false;
  }

void TrackLeg(const string groupId, const ulong ticket)
  {
   int n = ArraySize(g_groupIds);
   ArrayResize(g_groupIds, n + 1);
   ArrayResize(g_tickets, n + 1);
   g_groupIds[n] = groupId;
   g_tickets[n] = ticket;
  }

ENUM_ORDER_TYPE_FILLING GetFillingMode()
  {
   int filling = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0)
      return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) != 0)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

//+------------------------------------------------------------------+
//| Signal handlers                                                   |
//+------------------------------------------------------------------+
void HandleOpen(const string content, const string groupId)
  {
   string dir       = JGetStr(content, "dir");
   double sl        = JGetNum(content, "sl");
   double tp        = JGetNum(content, "tp");
   int    leg       = (int)JGetNum(content, "leg");
   int    legsTotal = (int)JGetNum(content, "legs_total");

   if(!EnableAutoTrading)
     {
      PrintFormat("[SidewayBreakoutBot] DRY RUN -- would OPEN %s leg %d/%d group=%s sl=%.5f tp=%.5f", dir, leg, legsTotal, groupId, sl, tp);
      return;
     }

   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);
   request.action       = TRADE_ACTION_DEAL;
   request.symbol       = _Symbol;
   request.volume        = FixedLotSize;
   request.type          = (dir == "BUY") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   request.price         = (dir == "BUY") ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   request.sl             = NormalizeDouble(sl, _Digits);
   request.tp             = NormalizeDouble(tp, _Digits);
   request.deviation     = SlippagePoints;
   request.magic          = MagicNumber;
   request.comment        = StringSubstr(groupId, 0, 20) + "#" + IntegerToString(leg);
   request.type_filling   = GetFillingMode();

   if(!OrderSend(request, result))
     {
      PrintFormat("[SidewayBreakoutBot] OPEN send failed group=%s leg=%d err=%d", groupId, leg, GetLastError());
      return;
     }
   if(result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_DONE_PARTIAL)
     {
      PrintFormat("[SidewayBreakoutBot] OPEN rejected group=%s leg=%d retcode=%d", groupId, leg, result.retcode);
      return;
     }

   ulong positionId = 0;
   if(HistoryDealSelect(result.deal))
      positionId = (ulong)HistoryDealGetInteger(result.deal, DEAL_POSITION_ID);
   if(positionId == 0)
      positionId = result.order; // fallback, shouldn't normally be needed

   TrackLeg(groupId, positionId);
   PrintFormat("[SidewayBreakoutBot] Opened %s leg %d/%d group=%s position=%d sl=%.5f tp=%.5f", dir, leg, legsTotal, groupId, (long)positionId, sl, tp);
  }

void HandleModifySl(const string content, const string groupId)
  {
   double sl = JGetNum(content, "sl");

   if(!EnableAutoTrading)
     {
      PrintFormat("[SidewayBreakoutBot] DRY RUN -- would MODIFY_SL group=%s sl=%.5f", groupId, sl);
      return;
     }

   for(int i = 0; i < ArraySize(g_groupIds); i++)
     {
      if(g_groupIds[i] != groupId)
         continue;
      ulong ticket = g_tickets[i];
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue; // already closed natively (hit its own TP/SL) -- nothing to modify

      MqlTradeRequest request;
      MqlTradeResult  result;
      ZeroMemory(request);
      ZeroMemory(result);
      request.action   = TRADE_ACTION_SLTP;
      request.position = ticket;
      request.symbol   = _Symbol;
      request.sl       = NormalizeDouble(sl, _Digits);
      request.tp       = PositionGetDouble(POSITION_TP);

      if(!OrderSend(request, result))
         PrintFormat("[SidewayBreakoutBot] MODIFY_SL failed group=%s ticket=%d err=%d", groupId, (long)ticket, GetLastError());
      else
         PrintFormat("[SidewayBreakoutBot] MODIFY_SL group=%s ticket=%d -> sl=%.5f", groupId, (long)ticket, sl);
     }
  }

void HandleClose(const string groupId)
  {
   if(!EnableAutoTrading)
     {
      PrintFormat("[SidewayBreakoutBot] DRY RUN -- would CLOSE group=%s", groupId);
      return;
     }

   for(int i = 0; i < ArraySize(g_groupIds); i++)
     {
      if(g_groupIds[i] != groupId)
         continue;
      ulong ticket = g_tickets[i];
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue; // already closed natively

      MqlTradeRequest request;
      MqlTradeResult  result;
      ZeroMemory(request);
      ZeroMemory(result);
      bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      request.action       = TRADE_ACTION_DEAL;
      request.position     = ticket;
      request.symbol       = _Symbol;
      request.volume       = PositionGetDouble(POSITION_VOLUME);
      request.type         = isBuy ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      request.price        = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      request.deviation    = SlippagePoints;
      request.magic        = MagicNumber;
      request.type_filling = GetFillingMode();

      if(!OrderSend(request, result))
         PrintFormat("[SidewayBreakoutBot] CLOSE failed group=%s ticket=%d err=%d", groupId, (long)ticket, GetLastError());
      else
         PrintFormat("[SidewayBreakoutBot] CLOSE group=%s ticket=%d", groupId, (long)ticket);
     }
  }
//+------------------------------------------------------------------+
