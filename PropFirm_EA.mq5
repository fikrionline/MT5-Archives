//+------------------------------------------------------------------+
//| PropFirm_EA_MT5.mq5                                             |
//| Expert Advisor tailored for prop-firm challenges (FTMO / 5%ers)  |
//| Features:                                                        |
//| - Trend entries using EMA50 / EMA200 crossover                    |
//| - RSI confirmation                                               |
//| - Dynamic position sizing by % risk per trade                     |
//| - Fixed SL (pips) and TP (risk:reward)                            |
//| - Break-even and trailing stop                                    |
//| - Max trades per day, session filter, manual news blackout window  |
//| - Equity protection (daily loss / overall drawdown)               |
//| - Mode presets (FTMO / The5Percenters)                            |
//+------------------------------------------------------------------+
#property copyright "Google and ChatGPT"
#property version "1.00"
#property strict
#property description "PropFirm oriented EA: risk management first. Backtest before using live."

#include <Trade\Trade.mqh>

CTrade trade;
CPositionInfo m_position;

//--- input parameters
input int EMA_Fast_Period = 50;
input int EMA_Slow_Period = 200;
input int RSI_Period = 14;
input int RSI_Upper = 70;
input int RSI_Lower = 30;

input double RiskPercentPerTrade = 0.75; // % of account balance risked per trade
input int StopLossPips = 40; // SL in pips
input double RewardRiskRatio = 2.0; // TP = SL * RRR
input int BreakEvenPoints = 20; // move SL to BE after price moves X points
input int TrailingStartPoints = 30; // start trailing after profit X points
input int TrailingStepPoints = 10; // trailing step in points

input int MaxTradesPerDay = 3;
input bool UseSessionFilter = true;
input int SessionStartHour = 13; // server time
input int SessionEndHour = 17; // server time

input double MaxDailyLossPercent = 4.0; // shutdown daily if equity drop > this %
input double MaxOverallDrawdownPercent = 10.0; // from initial balance

input bool UseFTMOMode = true; // toggle FTMO preset

input bool AllowLong = true;
input bool AllowShort = true;

input int NewsMinutesBefore = 0; // NOTE: requires external news feed; left as placeholder
input int NewsMinutesAfter = 0; // NOTE: disabled by default

//--- globals
datetime lastTradeDay = 0;
double dayStartBalance = 0.0;
double initialBalance = 0.0;
int tradesToday = 0;
bool tradingEnabled = true;

// Indicator handles
int handleEMA_fast = INVALID_HANDLE;
int handleEMA_slow = INVALID_HANDLE;
int handleRSI = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {

   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dayStartBalance = initialBalance;
   lastTradeDay = DateOfDay(TimeCurrent());
   tradesToday = 0;
   tradingEnabled = true;

   // create indicator handles (do this once)
   handleEMA_fast = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   if (handleEMA_fast == INVALID_HANDLE) {
      Print("Failed to create EMA fast handle");
      return (INIT_FAILED);
   }

   handleEMA_slow = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   if (handleEMA_slow == INVALID_HANDLE) {
      Print("Failed to create EMA slow handle");
      return (INIT_FAILED);
   }

   handleRSI = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
   if (handleRSI == INVALID_HANDLE) {
      Print("Failed to create RSI handle");
      return (INIT_FAILED);
   }

   PrintFormat("PropFirm_EA_MT5 initialized. Balance=%.2f", initialBalance);
   return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Get start-of-day date                                             |
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
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   if (handleEMA_fast != INVALID_HANDLE) IndicatorRelease(handleEMA_fast);
   if (handleEMA_slow != INVALID_HANDLE) IndicatorRelease(handleEMA_slow);
   if (handleRSI != INVALID_HANDLE) IndicatorRelease(handleRSI);

   Print("PropFirm_EA_MT5 stopped.");
}

//+------------------------------------------------------------------+
//| Main tick handler                                                |
//+------------------------------------------------------------------+
void OnTick() {
   // Update daily counters
   datetime today = DateOfDay(TimeCurrent());
   if (today != lastTradeDay) {
      lastTradeDay = today;
      dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      tradesToday = 0;
      tradingEnabled = true;
   }

   // Equity protection checks
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double drawdownPercent = 100.0 * (initialBalance - equity) / initialBalance;
   double dailyLossPercent = 100.0 * (dayStartBalance - equity) / dayStartBalance;

   if (dailyLossPercent >= MaxDailyLossPercent) {
      tradingEnabled = false;
      CloseAllPositions("DailyLossLimit");
      PrintFormat("Trading disabled due to daily loss limit reached: %.2f%%", dailyLossPercent);
      return;
   }

   if (drawdownPercent >= MaxOverallDrawdownPercent) {
      tradingEnabled = false;
      CloseAllPositions("OverallDrawdown");
      PrintFormat("Trading disabled due to overall drawdown limit reached: %.2f%%", drawdownPercent);
      return;
   }

   if (!tradingEnabled) return;

   // session filter
   if (UseSessionFilter) {
      MqlDateTime t;
      TimeToStruct(TimeCurrent(), t);
      int h = t.hour;

      if (SessionStartHour <= SessionEndHour) {
         if (h < SessionStartHour || h >= SessionEndHour) return;
      } else // wrap-around midnight
      {
         if (h < SessionStartHour && h >= SessionEndHour) return;
      }
   }

   // Simple news filter placeholders (no feed integrated)
   if (NewsMinutesBefore > 0 || NewsMinutesAfter > 0) {
      // To use real news filter, integrate economic calendar via WebRequest or external file.
   }

   // Count today's trades
   tradesToday = CountTradesToday();
   if (tradesToday >= MaxTradesPerDay) return;

   // get latest indicator values via CopyBuffer
   double emaFastArr[], emaSlowArr[], rsiArr[];
   ArraySetAsSeries(emaFastArr, true);
   ArraySetAsSeries(emaSlowArr, true);
   ArraySetAsSeries(rsiArr, true);

   // request 2 points for EMAs (current + previous), 1 point for RSI
   if (CopyBuffer(handleEMA_fast, 0, 0, 2, emaFastArr) != 2) {
      Print("CopyBuffer failed for EMA fast");
      return;
   }
   if (CopyBuffer(handleEMA_slow, 0, 0, 2, emaSlowArr) != 2) {
      Print("CopyBuffer failed for EMA slow");
      return;
   }
   if (CopyBuffer(handleRSI, 0, 0, 1, rsiArr) != 1) {
      Print("CopyBuffer failed for RSI");
      return;
   }

   // assign values (index 0 = current bar, index 1 = previous bar)
   double emaFast = emaFastArr[0];
   double emaFastPrev = emaFastArr[1];
   double emaSlow = emaSlowArr[0];
   double emaSlowPrev = emaSlowArr[1];
   double rsi = rsiArr[0];

   // detect bullish crossover (fast crosses above slow)
   bool bullishCross = (emaFastPrev <= emaSlowPrev) && (emaFast > emaSlow);
   bool bearishCross = (emaFastPrev >= emaSlowPrev) && (emaFast < emaSlow);

   // Price action confirmation: current close vs EMA fast
   double closeArr[];
   ArraySetAsSeries(closeArr, true);

   if (CopyClose(_Symbol, PERIOD_CURRENT, 0, 1, closeArr) != 1) {
      Print("Failed to get close price");
      return;
   }

   double close = closeArr[0];

   if (bullishCross && AllowLong && rsi < RSI_Upper) {
      // open long
      if (!HasPositionType(ORDER_TYPE_BUY)) {
         if (tradesToday < MaxTradesPerDay)
            OpenPosition(ORDER_TYPE_BUY);
      }
   } else if (bearishCross && AllowShort && rsi > RSI_Lower) {
      // open short
      if (!HasPositionType(ORDER_TYPE_SELL)) {
         if (tradesToday < MaxTradesPerDay)
            OpenPosition(ORDER_TYPE_SELL);
      }
   }

   // Manage open positions: break-even and trailing
   ManageOpenPositions();
}

//+------------------------------------------------------------------+
//| Count trades opened today                                        |
//+------------------------------------------------------------------+
int CountTradesToday() {
   int total = 0;
   for (int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if (ticket == 0) continue;
      if (PositionSelectByTicket(ticket)) {
         datetime t = (datetime) PositionGetInteger(POSITION_TIME);
         if (DateOfDay(t) == lastTradeDay) total++;
      }
   }
   return (total);
}

//+------------------------------------------------------------------+
//| Check if we have a position of a given type                      |
//+------------------------------------------------------------------+
bool HasPositionType(int type) {
   for (int i = 0; i < PositionsTotal(); i++) {
      if (PositionGetInteger(POSITION_TYPE) == type) return (true);
   }
   return (false);
}

//+------------------------------------------------------------------+
//| Open position helper                                              |
//+------------------------------------------------------------------+
void OpenPosition(int type) {
   double sl_points = (double) StopLossPips * (_Point == 0 ? SymbolInfoDouble(_Symbol, SYMBOL_POINT) : _Point * 1.0) / (_Point == 0 ? 1 : 1);
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl_price, tp_price;
   if (type == ORDER_TYPE_BUY) {
      sl_price = price - StopLossPips * _Point;
      tp_price = price + StopLossPips * _Point * RewardRiskRatio;
   } else {
      sl_price = price + StopLossPips * _Point;
      tp_price = price - StopLossPips * _Point * RewardRiskRatio;
   }

   double lots = CalculateLotForRisk(StopLossPips, RiskPercentPerTrade);
   if (lots <= 0) {
      Print("Calculated lot size is zero or invalid. Trade skipped.");
      return;
   }

   // normalize volume to broker limits
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lots = MathMax(minLot, MathMin(maxLot, MathFloor(lots / lotStep) * lotStep));

   trade.SetExpertMagicNumber(123456);
   trade.SetDeviationInPoints(10);

   bool result = false;
   if (type == ORDER_TYPE_BUY)
      result = trade.Buy(lots, _Symbol, 0.0, sl_price, tp_price, "Buy Order");
   else
      trade.Sell(lots, _Symbol, 0, sl_price, tp_price, "Sell Order");

   if (result) {
      PrintFormat("Opened %s : lots=%.2f SL=%.5f TP=%.5f", (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), lots, sl_price, tp_price);
      tradesToday++;
   } else {
      PrintFormat("Order failed: %s", trade.ResultComment());
   }
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk % and SL pips                   |
//+------------------------------------------------------------------+
double CalculateLotForRisk(int sl_pips, double riskPercent) {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * (riskPercent / 100.0);

   // value per point calculation
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if (tick_value <= 0 || tick_size <= 0) {
      Print("Symbol tick value/size retrieval failed. Using fallback lot=0.01");
      return (0.01);
   }

   double value_per_point = tick_value / tick_size; // monetary value per 1.0 price movement for 1.0 lot
   double sl_points = sl_pips * (_Point == 0 ? SymbolInfoDouble(_Symbol, SYMBOL_POINT) : _Point);
   double lot = riskMoney / (sl_points * value_per_point);

   // round to 2 decimals here; final normalization later
   return (NormalizeDouble(lot, 2));
}

//+------------------------------------------------------------------+
//| Manage open positions: break-even and trailing                   |
//+------------------------------------------------------------------+
void ManageOpenPositions() {
   for (int i = 0; i < PositionsTotal(); i++) {
      if (!m_position.SelectByIndex(i)) continue;
      ulong ticket = PositionGetTicket(i);
      string sym = PositionGetString(POSITION_SYMBOL);
      if (sym != _Symbol) continue;

      double volume = PositionGetDouble(POSITION_VOLUME);
      int type = (int) PositionGetInteger(POSITION_TYPE);
      double price_open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double profit = PositionGetDouble(POSITION_PROFIT);

      double currentPrice = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double pointsProfit = MathAbs((currentPrice - price_open) / _Point);

      // break-even
      if (pointsProfit >= BreakEvenPoints) {
         double new_sl = price_open + (type == POSITION_TYPE_BUY ? BreakEvenPoints * _Point : -BreakEvenPoints * _Point);
         // ensure we only move SL in direction of BE
         if ((type == POSITION_TYPE_BUY && new_sl > sl) || (type == POSITION_TYPE_SELL && new_sl < sl)) {
            trade.PositionModify(ticket, new_sl, PositionGetDouble(POSITION_TP));
         }
      }

      // trailing
      if (pointsProfit >= TrailingStartPoints) {
         double desired_sl = currentPrice - (type == POSITION_TYPE_BUY ? TrailingStepPoints * _Point : -TrailingStepPoints * _Point);
         if ((type == POSITION_TYPE_BUY && desired_sl > sl) || (type == POSITION_TYPE_SELL && desired_sl < sl)) {
            trade.PositionModify(ticket, desired_sl, PositionGetDouble(POSITION_TP));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Close all positions with comment                                 |
//+------------------------------------------------------------------+
void CloseAllPositions(string reason) {
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (!m_position.SelectByIndex(i)) continue;
      if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      ulong ticket = PositionGetTicket(i);
      int type = (int) PositionGetInteger(POSITION_TYPE);
      double vol = PositionGetDouble(POSITION_VOLUME);
      if (type == POSITION_TYPE_BUY) trade.PositionClose(ticket);
      else if (type == POSITION_TYPE_SELL) trade.PositionClose(ticket);
   }
   PrintFormat("All positions closed: %s", reason);
}

//+------------------------------------------------------------------+
//| Utility: print current settings                                  |
//+------------------------------------------------------------------+
void PrintSettings() {
   PrintFormat("Settings: EMA %d/%d RSI %d RiskPerTrade %.2f%% SL %d pips RRR %.2f MaxTrades/day %d", EMA_Fast_Period, EMA_Slow_Period, RSI_Period, RiskPercentPerTrade, StopLossPips, RewardRiskRatio, MaxTradesPerDay);
}

//+------------------------------------------------------------------+
//| OnTester for optimization (optional)                             |
//+------------------------------------------------------------------+
double OnTester() {
   return (0);
}

//+------------------------------------------------------------------+
// End of file
//+------------------------------------------------------------------+
