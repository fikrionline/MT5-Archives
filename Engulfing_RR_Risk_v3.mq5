//+------------------------------------------------------------------+
//| Engulfing_RR_Risk.mq5                                           |
//| Engulfing EA with Money Mgmt + RR + Filters + Breakeven         |
//+------------------------------------------------------------------+
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- input parameters
input double RiskPercent       = 1.0;      // Risk per trade (% of balance)
input double MinRR             = 2.0;      // Reward:Risk
input int    MagicNumber       = 20250917; // Magic number
input double EntryOffsetPts    = 2.0;      // Entry offset (points)
input double SLBufferPts       = 2.0;      // SL buffer (points)
input double MaxSpreadPoints   = 500.0;    // Max spread (points)
input double MinLot            = 0.01;     
input double MaxLot            = 100.0;    
input ENUM_ORDER_TYPE_FILLING Filling = ORDER_FILLING_FOK;
input double BodyToRangeMax = 0.30; // Body must be <= this fraction of range
input double WickToRangeMin = 0.60; // One wick must be >= this fraction of range

//--- session filter (broker/server time)
input int LondonStartHour   = 8;
input int LondonEndHour     = 17;
input int NYStartHour       = 13;
input int NYEndHour         = 22;

//--- risk control
input double MaxDailyLossPercent = 5.0;  // max daily loss in % of start balance
input int    MaxTradesPerDay     = 3;    // maximum trades per day

//--- breakeven
input bool   UseBreakeven        = true;
input double BreakevenTriggerRR  = 1.0;  // when trade hits +1R, move SL to BE

//--- global
datetime last_bar_time = 0;
double start_balance = 0.0;
datetime last_reset_day = 0;
int trades_today = 0;

//+------------------------------------------------------------------+
int OnInit() {
   start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   last_bar_time = iTime(_Symbol, PERIOD_CURRENT, 0);
   last_reset_day = DateOfDay(TimeCurrent());
   trades_today = 0;
   return (INIT_SUCCEEDED);
}

//--- normalize volume
double NormalizeVolume(double vol) {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if (step <= 0) step = 0.01;
   double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if (minv <= 0) minv = MinLot;
   if (maxv <= 0) maxv = MaxLot;
   double result = MathMax(minv, MathMin(maxv, MathFloor(vol / step + 0.0000001) * step));
   return result;
}

//--- volume calc by risk
double ComputeVolumeByRisk(double riskMoney, double stopPoints) {
   if (stopPoints <= 0) return 0;
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if (tick_size <= 0) tick_size = _Point;
   double value_per_point_per_lot = tick_value / (tick_size / _Point);
   double loss_per_lot = stopPoints * value_per_point_per_lot;
   if (loss_per_lot <= 0) return 0;
   return NormalizeVolume(riskMoney / loss_per_lot);
}

//--- delete pending orders for this EA
void DeleteOldPendings() {
   for (int i = OrdersTotal() - 1; i >= 0; i--) {
      ulong ticket = OrderGetTicket(i);
      if (ticket > 0 && OrderSelect(ticket)) {
         if (OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == MagicNumber) {
            MqlTradeRequest req;
            MqlTradeResult res;
            ZeroMemory(req);
            ZeroMemory(res);

            req.action = TRADE_ACTION_REMOVE;
            req.order = ticket;

            if (!OrderSend(req, res))
               Print("Failed to delete pending order. Error: ", GetLastError());
            else if (res.retcode != TRADE_RETCODE_DONE)
               Print("Delete request returned: ", res.retcode, " - ", res.comment);
            else
               Print("Deleted pending order ticket: ", req.order);
         }
      }
   }
}

//--- session filter
bool InTradingSession() {
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   int hour = t.hour;
   int day = t.day_of_week;

   bool london = (hour >= LondonStartHour && hour < LondonEndHour);
   bool ny = (hour >= NYStartHour && hour < NYEndHour);

   if (day == 5 && hour >= NYEndHour) return false;
   if (day == 0 || day == 6) return false;

   return (london || ny);
}

//--- check daily limits
bool BlockTradingToday() {
   datetime today = DateOfDay(TimeCurrent());
   if (today != last_reset_day) {
      start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
      last_reset_day = today;
      trades_today = 0;
   }

   double maxLoss = start_balance * MaxDailyLossPercent / 100.0;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if (equity < (start_balance - maxLoss)) return true;
   if (trades_today >= MaxTradesPerDay) return true;
   return false;
}

//--- helper
datetime DateOfDay(datetime t) {
   return StringToTime(TimeToString(t, TIME_DATE));
}

//--- place pending
bool PlacePending(int type, double entry, double sl, double tp, double vol) {
   MqlTradeRequest req;
   MqlTradeResult res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action = TRADE_ACTION_PENDING;
   req.symbol = _Symbol;
   req.volume = vol;
   req.type = (ENUM_ORDER_TYPE) type;
   req.price = entry;
   req.sl = sl;
   req.tp = tp;
   req.magic = MagicNumber;
   req.type_time = ORDER_TIME_GTC;
   req.type_filling = Filling;

   if (!OrderSend(req, res)) return false;
   if (res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_PLACED) return false;

   trades_today++;
   return true;
}

//--- manage breakeven
void CheckBreakeven() {
   if (!UseBreakeven) return;

   for (int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if (PositionSelectByTicket(ticket)) {
         if (PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            double entry = PositionGetDouble(POSITION_PRICE_OPEN);
            double sl = PositionGetDouble(POSITION_SL);
            long type = PositionGetInteger(POSITION_TYPE);
            double volume = PositionGetDouble(POSITION_VOLUME);

            if (type == POSITION_TYPE_BUY) {
               double stop = entry - sl;
               double trigger = entry + stop * BreakevenTriggerRR;
               if (SymbolInfoDouble(_Symbol, SYMBOL_BID) >= trigger && sl < entry) {
                  trade.PositionModify(_Symbol, entry, PositionGetDouble(POSITION_TP));
                  Print("Moved SL to BE for BUY ticket: ", ticket);
               }
            } else if (type == POSITION_TYPE_SELL) {
               double stop = sl - entry;
               double trigger = entry - stop * BreakevenTriggerRR;
               if (SymbolInfoDouble(_Symbol, SYMBOL_ASK) <= trigger && sl > entry) {
                  trade.PositionModify(_Symbol, entry, PositionGetDouble(POSITION_TP));
                  Print("Moved SL to BE for SELL ticket: ", ticket);
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
void OnTick() {
   //--- check breakeven on every tick
   CheckBreakeven();

   //--- new bar logic
   datetime cur_time = iTime(_Symbol, PERIOD_CURRENT, 0);
   if (cur_time == last_bar_time) return;
   last_bar_time = cur_time;

   if (!InTradingSession()) return;
   if (BlockTradingToday()) return;

   double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   if (spread > MaxSpreadPoints * _Point) return;
   
   // Need at least 6 bars on chart
   if(Bars(_Symbol,Period()) < 6) return;
   
   // Read recent bars: index 0 = last (current) closed bar may be 0 depending on timeframe - we use closed bars:
   // We'll reference indices: 0 = last closed, 1 = previous closed, etc.
   double o0 = iOpen(_Symbol, Period(), 0);
   double c0 = iClose(_Symbol, Period(), 0);
   double h0 = iHigh(_Symbol, Period(), 0);
   double l0 = iLow(_Symbol, Period(), 0);

   double o1 = iOpen(_Symbol, Period(), 1);
   double c1 = iClose(_Symbol, Period(), 1);
   double h1 = iHigh(_Symbol, Period(), 1);
   double l1 = iLow(_Symbol, Period(), 1);

   double o2 = iOpen(_Symbol, Period(), 2);
   double c2 = iClose(_Symbol, Period(), 2);
   double h2 = iHigh(_Symbol, Period(), 1);
   double l2 = iLow(_Symbol, Period(), 1);
   
   double o3 = iOpen(_Symbol, Period(), 3);
   double c3 = iClose(_Symbol, Period(), 3);
   
   double o4 = iOpen(_Symbol, Period(), 4);
   double c4 = iClose(_Symbol, Period(), 4);
   
   bool confirm_candle_before_buy = (c1 > o1) && (c2 > o2) && (c1 > c2) && (c3 < o3) && (c1 > o3) && IsBullishPinbar(_Symbol, PERIOD_CURRENT, 2);
   bool confirm_candle_before_sell = (c1 < o1) && (c2 < o2) && (c1 < c2) && (c3 > o3) && (c1 < o3) && IsBearishPinbar(_Symbol, PERIOD_CURRENT, 2);
   
   //-------------------------------------------------------------------------------------------------------------------
   //double open1 = iOpen(_Symbol, PERIOD_CURRENT, 1), close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   //double high1 = iHigh(_Symbol, PERIOD_CURRENT, 1), low1 = iLow(_Symbol, PERIOD_CURRENT, 1);
   //double open2 = iOpen(_Symbol, PERIOD_CURRENT, 2), close2 = iClose(_Symbol, PERIOD_CURRENT, 2);

   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
   double entry, sl, tp, stopPts, vol;

   if (confirm_candle_before_buy) {
      entry = c2;
      sl = l2;
      stopPts = (entry - sl) / _Point;
      if (stopPts <= 0) return;
      tp = entry + MinRR * (entry - sl);
      vol = ComputeVolumeByRisk(riskMoney, stopPts);

      if (vol > 0) {
         DeleteOldPendings();
         PlacePending(ORDER_TYPE_BUY_STOP, entry, sl, tp, vol);
      }
   } else if (confirm_candle_before_sell) {
      entry = c2;
      sl = h2;
      stopPts = (sl - entry) / _Point;
      if (stopPts <= 0) return;
      tp = entry - MinRR * (sl - entry);
      vol = ComputeVolumeByRisk(riskMoney, stopPts);

      if (vol > 0) {
         DeleteOldPendings();
         PlacePending(ORDER_TYPE_SELL_STOP, entry, sl, tp, vol);
      }
   }
}
//+------------------------------------------------------------------+

bool IsBullishPinbar(const string symbol, ENUM_TIMEFRAMES timeframe, int shift) {
   double open = iOpen(symbol, timeframe, shift);
   double close = iClose(symbol, timeframe, shift);
   double high = iHigh(symbol, timeframe, shift);
   double low = iLow(symbol, timeframe, shift);

   double range = high - low;
   double upperWick = high - MathMax(open, close);
   double lowerWick = MathMin(open, close) - low;

   // bullish pinbar: long lower wick, close near high
   if (lowerWick >= range * WickToRangeMin && close > open) return true;
   return false;
}

//+------------------------------------------------------------------+
bool IsBearishPinbar(const string symbol, ENUM_TIMEFRAMES timeframe, int shift) {
   double open = iOpen(symbol, timeframe, shift);
   double close = iClose(symbol, timeframe, shift);
   double high = iHigh(symbol, timeframe, shift);
   double low = iLow(symbol, timeframe, shift);

   double range = high - low;
   double upperWick = high - MathMax(open, close);
   double lowerWick = MathMin(open, close) - low;

   // bearish pinbar: long upper wick, close near low
   if (upperWick >= range * WickToRangeMin && close < open) return true;
   return false;
}
