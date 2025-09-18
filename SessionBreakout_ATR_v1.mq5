//+------------------------------------------------------------------+
//| SessionBreakout_ATR_MT5.mq5                                      |
//| Breakout EA designed for prop-firm challenges (FTMO / 5%ers)      |
//| Strategy:                                                          |
//| - Define a "range" during a quiet session (e.g., Asian range)     |
//| - When price breaks above/below the range during London/NY open,  |
//|   enter a market trade in breakout direction                      |
//| - Stop Loss and Take Profit sized by ATR (ATR * SL_ATR_Mult, ATR * TP_ATR_Mult)
//| - Volatility filter: only trade if ATR > MinATR                    |
//| - Fixed fractional risk per trade (RiskPercentPerTrade)           |
//| - Max trades per day, session filter, daily / overall equity stop  |
//+------------------------------------------------------------------+
#property copyright "Fikri"
#property version "1.00"
#property strict

#include <Trade\Trade.mqh>

CTrade trade;
CPositionInfo m_position;

//--- Inputs
input ENUM_TIMEFRAMES RangeTF = PERIOD_H1; // timeframe to build the range (e.g., H1 for Asian range)
input int RangeStartHour = 0; // start hour for range (server time)
input int RangeEndHour = 6; // end hour for range (server time)

input ENUM_TIMEFRAMES TradeTF = PERIOD_M15; // timeframe for breakout checks (tick-based used but kept)
input int TradeStartHour = 13; // session start hour (server time) - e.g., London open
input int TradeEndHour = 17; // session end hour

input double RiskPercentPerTrade = 0.75; // percent risk per trade (of current balance)
input double SL_ATR_Mult = 1.0; // SL = ATR * this
input double TP_ATR_Mult = 2.0; // TP = ATR * this
input double MinATR = 0.0005; // minimum ATR (in price units) to allow trade (set for pair)
input int ATR_Period = 14; // ATR period

input int MaxTradesPerDay = 2; // conservative
input double MaxDailyLossPercent = 4.0; // shutdown if daily loss reached
input double MaxOverallDrawdownPercent = 10.0;

input bool UseFTMOMode = true; // preset conservative daily limit for FTMO

//--- globals
int handleATR = INVALID_HANDLE;
datetime lastDay = 0;
double dayStartBalance = 0.0;
double initialBalance = 0.0;
int tradesToday = 0;
bool tradingEnabled = true;

// Range values
double rangeHigh = 0.0;
double rangeLow = 0.0;
bool rangeCalculated = false;

// working limits (not input constants)
double maxDailyLossLimit;
double maxOverallDrawdownLimit;

//+------------------------------------------------------------------+
int OnInit() {
   // presets
   if (UseFTMOMode)
      maxDailyLossLimit = 5.0 * 0.8; // use conservative 80% of FTMO daily allowed
   else
      maxDailyLossLimit = MaxDailyLossPercent;
   maxOverallDrawdownLimit = MaxOverallDrawdownPercent;

   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dayStartBalance = initialBalance;
   lastDay = DateOfDay(TimeCurrent());
   tradesToday = 0;
   tradingEnabled = true;

   // create ATR handle
   handleATR = iATR(_Symbol, RangeTF, ATR_Period);
   if (handleATR == INVALID_HANDLE) {
      Print("Failed to create ATR handle");
      return (INIT_FAILED);
   }

   PrintFormat("SessionBreakout_ATR initialized. Balance=%.2f", initialBalance);
   return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
datetime DateOfDay(datetime t) {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   return (StructToTime(dt));
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   if (handleATR != INVALID_HANDLE) IndicatorRelease(handleATR);
   Print("SessionBreakout_ATR stopped.");
}

//+------------------------------------------------------------------+
void OnTick() {
   // daily reset
   datetime today = DateOfDay(TimeCurrent());
   if (today != lastDay) {
      lastDay = today;
      dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      tradesToday = 0;
      tradingEnabled = true;
      rangeCalculated = false; // recalc range next day
   }

   // equity protections
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double drawdownPercent = 100.0 * (initialBalance - equity) / initialBalance;
   double dailyLossPercent = 100.0 * (dayStartBalance - equity) / dayStartBalance;
   if (dailyLossPercent >= maxDailyLossLimit) {
      tradingEnabled = false;
      CloseAllPositions("DailyLossLimit");
      PrintFormat("Trading disabled due to daily loss: %.2f%%", dailyLossPercent);
      return;
   }
   if (drawdownPercent >= maxOverallDrawdownLimit) {
      tradingEnabled = false;
      CloseAllPositions("OverallDrawdown");
      PrintFormat("Trading disabled due to overall drawdown: %.2f%%", drawdownPercent);
      return;
   }

   if (!tradingEnabled) return;

   // count trades today (positions opened today)
   tradesToday = CountTradesToday();
   if (tradesToday >= MaxTradesPerDay) return;

   // calculate range if not done
   if (!rangeCalculated) CalculateRange();
   if (rangeHigh == 0 || rangeLow == 0) return;

   // session time check
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   int hour = t.hour;
   if (!IsHourInSession(hour, TradeStartHour, TradeEndHour)) return;

   // get latest price
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double price = (bid + ask) / 2.0;

   // get ATR value (latest)
   double atrArr[];
   ArraySetAsSeries(atrArr, true);
   if (CopyBuffer(handleATR, 0, 0, 1, atrArr) != 1) {
      Print("Failed to get ATR");
      return;
   }
   double atr = atrArr[0];
   if (atr < MinATR) return; // volatility filter

   // breakout checks
   // buy breakout
   if (price > rangeHigh) {
      if (!HasOpenPositionOfType(POSITION_TYPE_BUY)) {
         OpenBreakoutTrade(ORDER_TYPE_BUY, atr);
      }
   }
   // sell breakout
   else if (price < rangeLow) {
      if (!HasOpenPositionOfType(POSITION_TYPE_SELL)) {
         OpenBreakoutTrade(ORDER_TYPE_SELL, atr);
      }
   }
}

//+------------------------------------------------------------------+
void CalculateRange() {
   // copy high/low candles from RangeTF between RangeStartHour and RangeEndHour of the previous completed bars
   // We'll scan last 48 bars to find candles with hours in range
   int barsToScan = 48;
   double highs[];
   double lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);
   if (CopyHigh(_Symbol, RangeTF, 0, barsToScan, highs) != barsToScan || CopyLow(_Symbol, RangeTF, 0, barsToScan, lows) != barsToScan) {
      Print("Failed to copy high/low for range calculation");
      return;
   }

   rangeHigh = 0.0;
   rangeLow = 0.0;
   // check corresponding times
   datetime times[];
   ArraySetAsSeries(times, true);
   if (CopyTime(_Symbol, RangeTF, 0, barsToScan, times) != barsToScan) {
      Print("Failed to copy times for range calculation");
      return;
   }

   for (int i = 0; i < barsToScan; i++) {
      MqlDateTime bt;
      TimeToStruct(times[i], bt);
      int h = bt.hour;
      if (IsHourInSession(h, RangeStartHour, RangeEndHour)) {
         if (rangeHigh == 0.0 || highs[i] > rangeHigh) rangeHigh = highs[i];
         if (rangeLow == 0.0 || lows[i] < rangeLow) rangeLow = lows[i];
      }
   }

   if (rangeHigh > 0 && rangeLow > 0) {
      rangeCalculated = true;
      PrintFormat("Range calculated: High=%.5f Low=%.5f", rangeHigh, rangeLow);
   } else {
      Print("Range not found in scanned bars");
   }
}

//+------------------------------------------------------------------+
bool IsHourInSession(int hour, int startH, int endH) {
   if (startH <= endH)
      return (hour >= startH && hour < endH);
   else // wrap-around
      return (hour >= startH || hour < endH);
}

//+------------------------------------------------------------------+
int CountTradesToday() {
   int total = 0;
   for (int i = 0; i < PositionsTotal(); i++) {
      if (!m_position.SelectByIndex(i)) continue;
      if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      datetime t = (datetime) PositionGetInteger(POSITION_TIME);
      if (DateOfDay(t) == lastDay) total++;
   }
   return (total);
}

//+------------------------------------------------------------------+
bool HasOpenPositionOfType(int type) {
   for (int i = 0; i < PositionsTotal(); i++) {
      if (!m_position.SelectByIndex(i)) continue;
      if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      int ptype = (int) PositionGetInteger(POSITION_TYPE);
      if (ptype == type) return (true);
   }
   return (false);
}

//+------------------------------------------------------------------+
void OpenBreakoutTrade(int orderType, double atr) {
   // calculate SL and TP prices
   double sl_price, tp_price, entryPrice;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double digits = (double) SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double sl_dist = atr * SL_ATR_Mult;
   double tp_dist = atr * TP_ATR_Mult;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if (orderType == ORDER_TYPE_BUY) {
      entryPrice = ask;
      sl_price = entryPrice - sl_dist;
      tp_price = entryPrice + tp_dist;
   } else {
      entryPrice = bid;
      sl_price = entryPrice + sl_dist;
      tp_price = entryPrice - tp_dist;
   }

   // calculate lot size
   double lots = CalculateLotForRiskFromPriceDist(sl_dist);
   if (lots <= 0) {
      Print("Lot calculation returned <=0");
      return;
   }

   // normalize to broker limits
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if (step <= 0) step = 0.01;
   double lot = MathMax(minLot, MathMin(maxLot, MathFloor(lots / step) * step));

   trade.SetDeviationInPoints(10);
   trade.SetExpertMagicNumber(20250916);

   bool res = false;
   if (orderType == ORDER_TYPE_BUY)
      res = trade.Buy(lot, _Symbol, 0.0, sl_price, tp_price, "BreakoutBuy");
   else
      res = trade.Sell(lot, _Symbol, 0.0, sl_price, tp_price, "BreakoutSell");

   if (res) {
      tradesToday++;
      PrintFormat("Opened %s lot=%.2f SL=%.5f TP=%.5f", (orderType == ORDER_TYPE_BUY ? "BUY" : "SELL"), lot, sl_price, tp_price);
   } else
      PrintFormat("Order failed: %s", trade.ResultComment());
}

//+------------------------------------------------------------------+
double CalculateLotForRiskFromPriceDist(double sl_price_dist) {
   // sl_price_dist is in price units (e.g., 0.0012)
   // compute how much money per lot equals 1 price unit: value_per_point = tick_value / tick_size
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if (tick_value <= 0 || tick_size <= 0) {
      // fallback for FX major pairs: assume 10 USD per standard lot per 1 pip (0.0001)
      double approx_per_point = 10.0 / point; // this is rough
      double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * (RiskPercentPerTrade / 100.0);
      double lot = riskMoney / (sl_price_dist * approx_per_point);
      return (NormalizeDouble(lot, 2));
   }

   double value_per_priceunit = tick_value / tick_size; // money per 1.0 price movement for 1 lot
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * (RiskPercentPerTrade / 100.0);
   double lot = riskMoney / (sl_price_dist * value_per_priceunit);
   return (NormalizeDouble(lot, 2));
}

//+------------------------------------------------------------------+
void CloseAllPositions(string reason) {
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (!m_position.SelectByIndex(i)) continue;
      if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      ulong ticket = PositionGetInteger(POSITION_TICKET);
      trade.PositionClose(ticket);
   }
   PrintFormat("All positions closed: %s", reason);
}

//+------------------------------------------------------------------+
double OnTester() {
   // optional fitness metric for optimizer
   return AccountInfoDouble(ACCOUNT_BALANCE);
}

//+------------------------------------------------------------------+
// End of file
//+------------------------------------------------------------------+
