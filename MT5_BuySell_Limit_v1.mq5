//+------------------------------------------------------------------+
//| MT5 Expert Advisor: Buy/Sell Limit based on H1 lowest/highest open |
//| With separate comments & trailing stop inputs for Buy/Sell         |
//+------------------------------------------------------------------+
#include <Trade/Trade.mqh>
CTrade trade;

//+------------------------------------------------------------------+
//| Custom Functions                                                 |
//+------------------------------------------------------------------+

//--- input params
input ulong   InpMagicNumber       = 191919;   // Magic number for this EA
input double  InpRiskPercent       = 0.5;      // risk per trade in percent of equity (e.g. 0.5 = 0.5%)
input double  InpMinLot            = 0.01;     // minimum lot (broker min)
input int     InpTrailingPointsBuy = 50;      // trailing stop in points for BUY trades
input int     InpTrailingPointsSell= 50;      // trailing stop in points for SELL trades
input int     InpCheckIntervalSec  = 10;       // how often (sec) to check logic
input  ENUM_TIMEFRAMES InpSignalTF = PERIOD_H1; // Timeframe for signal logic

// Session times (server time hours, 0-23)
input int     LondonStartHour      = 7;        // London session start hour (server time)
input int     LondonEndHour        = 16;       // London session end hour (server time)
input int     NewYorkStartHour     = 12;       // NY session start hour (server time)
input int     NewYorkEndHour       = 21;       // NY session end hour (server time)

input string  BuyComment           = "TraderSangatSukses";
input string  SellComment          = "TraderSangatSukses";

//--- globals
datetime lastCheckedH1Close = 0;

//+------------------------------------------------------------------+
int OnInit() {
   EventSetTimer(InpCheckIntervalSec);
   return (INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   EventKillTimer();
}

//+------------------------------------------------------------------+
void OnTimer() {
   MainLogic();
}

//+------------------------------------------------------------------+
void MainLogic() {
   datetime latest_closed_h1_time = iTime(_Symbol, InpSignalTF, 1);
   if (latest_closed_h1_time != lastCheckedH1Close) {
      OnH1CandleClose();
      lastCheckedH1Close = latest_closed_h1_time;
   }

   ApplyTrailingStops();

   if (IsInTradingSession()) {
      if (HasOpenPositionMissingTP()) return;

      if (!HasPendingOrders()) {
         PlaceBuyLimitFromTodayLowestOpen();
         PlaceSellLimitFromTodayHighestOpen();
      }
   }
}

//+------------------------------------------------------------------+
bool IsInTradingSession() {
   datetime now = TimeCurrent();
   MqlDateTime t;
   TimeToStruct(now, t);
   int hour = t.hour;

   if (hour >= LondonStartHour && hour < LondonEndHour) return true;
   if (hour >= NewYorkStartHour && hour < NewYorkEndHour) return true;
   return false;
}

//+------------------------------------------------------------------+
void OnH1CandleClose() {
   for (int i = OrdersTotal() - 1; i >= 0; --i) {
      ulong ticket = OrderGetTicket(i);
      if (!OrderSelect(ticket)) continue;

      long type = OrderGetInteger(ORDER_TYPE);
      string com = OrderGetString(ORDER_COMMENT);
      long magic = OrderGetInteger(ORDER_MAGIC);

      if ((type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_SELL_LIMIT) &&
         (StringFind(com, BuyComment) == 0 || StringFind(com, SellComment) == 0) &&
         magic == (long) InpMagicNumber) {
         OrderDelete(ticket);
      }
   }
}

//+------------------------------------------------------------------+
void PlaceBuyLimitFromTodayLowestOpen() {

   double YesterdayLowestOpen = GetDayOpenRange(_Symbol, InpSignalTF, 1, false);

   double TodayLowestOpen = GetDayOpenRange(_Symbol, InpSignalTF, 0, false);

   if (YesterdayLowestOpen > TodayLowestOpen) return;

   double lastHigh = iHigh(_Symbol, InpSignalTF, 1);
   double lastLow = iLow(_Symbol, InpSignalTF, 1);
   double range = MathAbs(lastHigh - lastLow);
   if (range <= SymbolInfoDouble(_Symbol, SYMBOL_POINT)) return;

   double price = TodayLowestOpen;
   double sl_price = price - range;
   double tp_price = price + range;
   if (sl_price <= 0 || tp_price <= 0) return;

   double volume = CalculateVolume(range);

   MqlTradeRequest req;
   MqlTradeResult res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action = TRADE_ACTION_PENDING;
   req.symbol = _Symbol;
   req.volume = volume;
   req.type = ORDER_TYPE_BUY_LIMIT;
   req.price = price;
   req.sl = sl_price;
   req.tp = tp_price;
   req.deviation = 10;
   req.type_filling = ORDER_FILLING_FOK;
   req.type_time = ORDER_TIME_GTC;
   req.comment = BuyComment;
   req.magic = InpMagicNumber;

   if (!OrderSend(req, res))
      PrintFormat("BuyLimit OrderSend failed. Retcode=%d", res.retcode);
}

//+------------------------------------------------------------------+
void PlaceSellLimitFromTodayHighestOpen() {

   double YesterdayHighestOpen = GetDayOpenRange(_Symbol, InpSignalTF, 1, true);

   double TodayHighestOpen = GetDayOpenRange(_Symbol, InpSignalTF, 0, true);

   if (YesterdayHighestOpen < TodayHighestOpen) return;

   double lastHigh = iHigh(_Symbol, InpSignalTF, 1);
   double lastLow = iLow(_Symbol, InpSignalTF, 1);
   double range = MathAbs(lastHigh - lastLow);
   if (range <= SymbolInfoDouble(_Symbol, SYMBOL_POINT)) return;

   double price = TodayHighestOpen;
   double sl_price = price + range;
   double tp_price = price - range;
   if (tp_price <= 0) return;

   double volume = CalculateVolume(range);

   MqlTradeRequest req;
   MqlTradeResult res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action = TRADE_ACTION_PENDING;
   req.symbol = _Symbol;
   req.volume = volume;
   req.type = ORDER_TYPE_SELL_LIMIT;
   req.price = price;
   req.sl = sl_price;
   req.tp = tp_price;
   req.deviation = 10;
   req.type_filling = ORDER_FILLING_FOK;
   req.type_time = ORDER_TIME_GTC;
   req.comment = SellComment;
   req.magic = InpMagicNumber;

   if (!OrderSend(req, res))
      PrintFormat("SellLimit OrderSend failed. Retcode=%d", res.retcode);
}

//+------------------------------------------------------------------+
double CalculateVolume(double sl_distance) {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_money = equity * (InpRiskPercent / 100.0);

   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if (tick_size <= 0 || tick_value <= 0) tick_size = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   double ticks = sl_distance / tick_size;
   if (ticks <= 0) return InpMinLot;
   double loss_per_lot = ticks * tick_value;
   if (loss_per_lot <= 0) loss_per_lot = 0.0001;

   double volume = risk_money / loss_per_lot;

   double vol_min = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vol_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vol_max = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if (vol_min <= 0) vol_min = InpMinLot;
   if (vol_step <= 0) vol_step = 0.01;

   if (volume < vol_min) volume = vol_min;
   if (volume < InpMinLot) volume = InpMinLot;

   double steps = MathFloor((volume - vol_min) / vol_step + 0.5);
   volume = vol_min + steps * vol_step;
   volume = MathMax(vol_min, MathMin(volume, vol_max));
   return volume;
}

//+------------------------------------------------------------------+
bool HasOpenPositionMissingTP() {
   for (int i = PositionsTotal() - 1; i >= 0; --i) {
      ulong ticket = PositionGetTicket(i);
      if (!PositionSelectByTicket(ticket)) continue;
      if (PositionGetInteger(POSITION_MAGIC) != (long) InpMagicNumber) continue;
      double tp = PositionGetDouble(POSITION_TP);
      if (tp == 0.0) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
void ApplyTrailingStops() {
   for (int i = PositionsTotal() - 1; i >= 0; --i) {
      ulong ticket = PositionGetTicket(i);
      if (!PositionSelectByTicket(ticket)) continue;
      if (PositionGetInteger(POSITION_MAGIC) != (long) InpMagicNumber) continue;
      string pos_symbol = PositionGetString(POSITION_SYMBOL);
      if (pos_symbol != _Symbol) continue;
      long type = (int) PositionGetInteger(POSITION_TYPE);
      double current_sl = PositionGetDouble(POSITION_SL);
      double price;
      double desired_sl;
      if (type == POSITION_TYPE_BUY) {
         price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         desired_sl = price - InpTrailingPointsBuy * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
         if (desired_sl > current_sl + SymbolInfoDouble(_Symbol, SYMBOL_POINT))
            ModifySLTP(ticket, desired_sl, PositionGetDouble(POSITION_TP));
      } else if (type == POSITION_TYPE_SELL) {
         price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         desired_sl = price + InpTrailingPointsSell * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
         if (desired_sl < current_sl - SymbolInfoDouble(_Symbol, SYMBOL_POINT) || current_sl == 0.0)
            ModifySLTP(ticket, desired_sl, PositionGetDouble(POSITION_TP));
      }
   }
}

//+------------------------------------------------------------------+
void ModifySLTP(ulong ticket, double sl, double tp) {
   MqlTradeRequest req;
   MqlTradeResult res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action = TRADE_ACTION_SLTP;
   req.position = ticket;
   req.sl = NormalizeDouble(sl, (int) SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
   req.tp = tp;
   if (!OrderSend(req, res))
      PrintFormat("ModifySLTP failed. Retcode=%d", res.retcode);
}

//+------------------------------------------------------------------+
bool OrderDelete(ulong ticket) {
   MqlTradeRequest req;
   MqlTradeResult res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action = TRADE_ACTION_REMOVE;
   req.order = ticket;
   bool ok = OrderSend(req, res);
   if (!ok) PrintFormat("OrderDelete failed %I64u ret=%d", ticket, res.retcode);
   return ok;
}
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Generic function: get highest/lowest open of a given day         |
//| shift = 0 (today), 1 (yesterday), etc.                           |
//+------------------------------------------------------------------+
double GetDayOpenRange(string symbol, ENUM_TIMEFRAMES tf, int shift, bool findHighest) {
   datetime todayStart = StringToTime(TimeToString(TimeCurrent(), TIME_DATE)); // midnight today
   datetime dayStart = todayStart - 86400 * shift;
   datetime nextDayStart = dayStart + 86400;

   double result = findHighest ? -DBL_MAX : DBL_MAX;

   int bars = Bars(symbol, tf);
   for (int i = 0; i < bars; i++) {
      datetime barTime = iTime(symbol, tf, i);
      if (barTime < dayStart) break; // no more relevant bars
      if (barTime >= dayStart && barTime < nextDayStart) {
         double op = iOpen(symbol, tf, i);
         if (findHighest) {
            if (op > result) result = op;
         } else {
            if (op < result) result = op;
         }
      }
   }

   // failsafe return
   if (result == DBL_MAX || result == -DBL_MAX) return 0.0;
   return result;
}

// Check if there is any open position (Buy/Sell) with this EA's magic number
bool HasOpenPosition() {
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if (PositionSelectByTicket(ticket)) {
         if ((ulong) PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
            return true;
      }
   }
   return false;
}

// Delete all pending orders with this EA's magic number
void DeleteAllPendings() {
   for (int i = OrdersTotal() - 1; i >= 0; i--) {
      ulong ticket = OrderGetTicket(i);
      if (OrderSelect(ticket)) {
         if ((ulong) OrderGetInteger(ORDER_MAGIC) == InpMagicNumber) {
            int type = (int) OrderGetInteger(ORDER_TYPE);
            if (type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_SELL_LIMIT) {
               trade.OrderDelete(ticket);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
bool HasPendingOrders() {
   for (int i = OrdersTotal() - 1; i >= 0; --i) {
      ulong ticket = OrderGetTicket(i);
      if (!OrderSelect(ticket)) continue;

      long type = OrderGetInteger(ORDER_TYPE);
      long magic = OrderGetInteger(ORDER_MAGIC);

      if (type == ORDER_TYPE_BUY_LIMIT && magic == (long) InpMagicNumber)
         return true;

      if (type == ORDER_TYPE_SELL_LIMIT && magic == (long) InpMagicNumber)
         return true;
   }
   return false;
}
