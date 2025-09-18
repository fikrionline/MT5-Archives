//+------------------------------------------------------------------+
//| PriceAction_PropChallenge.mq5                                    |
//| Simple price-action EA: Engulfing + swing breakout + ATR stops   |
//| Risk management: percent risk, daily loss limit, max drawdown    |
//+------------------------------------------------------------------+
#property copyright "Generated"
#property version "1.01"
#property strict

input int LookbackBars = 20; // Bars to find recent swing high/low
input int EngulfingCheckBars = 2; // Engulfing pattern checks last N bars
input double RiskPercentPerTrade = 1.0; // Risk % of equity per trade
input double MaxDailyLossPercent = 5.0; // Stop trading when daily loss % reached
input double MaxDrawdownPercent = 20.0; // Absolute drawdown % limit from peak equity
input int ATRPeriod = 14; // ATR period for stop calculation
input double ATRMultiplierSL = 1.5; // SL = ATR * multiplier
input double ATRMultiplierTP = 2.5; // TP = ATR * multiplier
input bool UseTrailing = true;
input int TrailingStartPoints = 200; // distance in points from entry to start trailing
input int TrailingStepPoints = 50; // trailing step in points
input int MagicNumber = 20250916;
input double MinLot = 0.01;
input double MaxLot = 2.0;
input ENUM_TIMEFRAMES SignalTF = PERIOD_CURRENT; // timeframe for signals (CURRENT by default)
input bool AllowBuy = true;
input bool AllowSell = true;
input bool UseBreakeven = true;
input int BreakevenPoints = 50; // move SL to breakeven after this many points profit

// Internal
datetime lastTradeDay = 0;
double dayStartEquity = 0.0;
double peakEquity = 0.0;
datetime lastTime = 0;
int atrHandle = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit() {
   atrHandle = iATR(_Symbol, SignalTF, ATRPeriod);
   if (atrHandle == INVALID_HANDLE) {
      Print("OnInit: failed to create ATR handle");
      return (INIT_FAILED);
   }

   lastTradeDay = 0;
   dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   peakEquity = dayStartEquity;
   return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Deinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   if (atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick() {
   datetime currentBarTime = iTime(_Symbol, SignalTF, 0);
   if (lastTime == currentBarTime) return;
   lastTime = currentBarTime;

   // Update peak equity
   double curEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   if (curEquity > peakEquity) peakEquity = curEquity;

   // Stop trading if daily loss or max drawdown exceeded
   if (CheckTradeLimits()) return;

   // Load rates
   MqlRates rates[];
   int copied = CopyRates(_Symbol, SignalTF, 0, LookbackBars + 5, rates);
   if (copied <= LookbackBars + 2) return;
   ArraySetAsSeries(rates, true);

   // Check last closed candle
   int idx = 1;
   bool bullishEngulf = IsBullishEngulfing(rates, idx);
   bool bearishEngulf = IsBearishEngulfing(rates, idx);

   // ATR value
   double atr = 0.0;
   double atrBuf[];
   if (CopyBuffer(atrHandle, 0, 1, 1, atrBuf) == 1)
      atr = atrBuf[0];
   if (atr <= 0.0) return;

   // Swing levels
   double recentSwingHigh = FindSwingHigh(rates, LookbackBars);
   double recentSwingLow = FindSwingLow(rates, LookbackBars);

   // Buy
   if (bullishEngulf && AllowBuy) {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if (ask > recentSwingHigh - _Point * 5)
         TryOpenOrder(ORDER_TYPE_BUY, atr);
   }

   // Sell
   if (bearishEngulf && AllowSell) {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if (bid < recentSwingLow + _Point * 5)
         TryOpenOrder(ORDER_TYPE_SELL, atr);
   }

   // Manage open positions
   ManagePositions();
}

//+------------------------------------------------------------------+
//| Signal Functions                                                 |
//+------------------------------------------------------------------+
bool IsBullishEngulfing(const MqlRates & rates[], int idx) {
   if (idx + 1 >= ArraySize(rates)) return false;
   double open1 = rates[idx + 1].open, close1 = rates[idx + 1].close;
   double open0 = rates[idx].open, close0 = rates[idx].close;

   if (close1 < open1 && close0 > open0) // prev bearish, now bullish
      if (open0 <= close1 && close0 >= open1)
         return true;
   return false;
}

bool IsBearishEngulfing(const MqlRates & rates[], int idx) {
   if (idx + 1 >= ArraySize(rates)) return false;
   double open1 = rates[idx + 1].open, close1 = rates[idx + 1].close;
   double open0 = rates[idx].open, close0 = rates[idx].close;

   if (close1 > open1 && close0 < open0) // prev bullish, now bearish
      if (open0 >= close1 && close0 <= open1)
         return true;
   return false;
}

double FindSwingHigh(const MqlRates & rates[], int lookback) {
   double sh = rates[1].high;
   int maxIdx = MathMin(lookback, ArraySize(rates) - 1);
   for (int i = 1; i <= maxIdx; i++)
      if (rates[i].high > sh) sh = rates[i].high;
   return sh;
}

double FindSwingLow(const MqlRates & rates[], int lookback) {
   double sl = rates[1].low;
   int maxIdx = MathMin(lookback, ArraySize(rates) - 1);
   for (int i = 1; i <= maxIdx; i++)
      if (rates[i].low < sl) sl = rates[i].low;
   return sl;
}

//+------------------------------------------------------------------+
//| Order Execution                                                  |
//+------------------------------------------------------------------+
void TryOpenOrder(ENUM_ORDER_TYPE type, double atr) {
   if (HasOpenPositionOfType(type)) return;

   double stopLossPrice, takeProfitPrice;
   double price = (type == ORDER_TYPE_BUY) ?
      SymbolInfoDouble(_Symbol, SYMBOL_ASK) :
      SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double sl_distance = atr * ATRMultiplierSL;
   double tp_distance = atr * ATRMultiplierTP;

   if (type == ORDER_TYPE_BUY) {
      stopLossPrice = price - sl_distance;
      takeProfitPrice = price + tp_distance;
   } else {
      stopLossPrice = price + sl_distance;
      takeProfitPrice = price - tp_distance;
   }

   double lot = CalculateLotByRisk(price, stopLossPrice, RiskPercentPerTrade);
   lot = NormalizeLot(lot);
   if (lot < MinLot) return;

   MqlTradeRequest req;
   MqlTradeResult res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action = TRADE_ACTION_DEAL;
   req.magic = MagicNumber;
   req.symbol = _Symbol;
   req.volume = lot;
   req.type = type;
   req.price = (type == ORDER_TYPE_BUY) ?
      SymbolInfoDouble(_Symbol, SYMBOL_ASK) :
      SymbolInfoDouble(_Symbol, SYMBOL_BID);
   req.sl = NormalizeDouble(stopLossPrice, (int) SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
   req.tp = NormalizeDouble(takeProfitPrice, (int) SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
   req.deviation = 5;
   req.type_filling = ORDER_FILLING_FOK;

   if (!OrderSend(req, res))
      PrintFormat("OrderSend failed: ret=%d, comment=%s", res.retcode, res.comment);
}

bool HasOpenPositionOfType(ENUM_ORDER_TYPE type) {
   for (int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if (PositionSelectByTicket(ticket)) {
         if (PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
         long posType = PositionGetInteger(POSITION_TYPE);
         if ((type == ORDER_TYPE_BUY && posType == POSITION_TYPE_BUY) ||
            (type == ORDER_TYPE_SELL && posType == POSITION_TYPE_SELL))
            return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Lot Calculation                                                  |
//+------------------------------------------------------------------+
double CalculateLotByRisk(double entryPrice, double slPrice, double riskPercent) {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * (riskPercent / 100.0);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);

   double valuePerPointPerLot = (tickValue / tickSize);
   if (valuePerPointPerLot <= 0) valuePerPointPerLot = contractSize;

   double points = MathAbs(entryPrice - slPrice) / _Point;
   if (points <= 0) return MinLot;

   double lot = riskAmount / (points * valuePerPointPerLot);
   return lot;
}

double NormalizeLot(double lot) {
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLotSym = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if (step <= 0) step = 0.01;

   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLotSym);
   double n = MathFloor(lot / step + 0.5) * step;
   return NormalizeDouble(n, 2);
}

//+------------------------------------------------------------------+
//| Manage Positions (Trailing + BE)                                |
//+------------------------------------------------------------------+
void ManagePositions() {
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if (!PositionSelectByTicket(ticket)) continue;
      if (PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      double price_open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double current_price = (type == POSITION_TYPE_BUY) ?
         SymbolInfoDouble(_Symbol, SYMBOL_BID) :
         SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profit_points = MathAbs((current_price - price_open) / _Point);

      // Breakeven
      if (UseBreakeven && profit_points >= BreakevenPoints) {
         double newSL = (type == POSITION_TYPE_BUY) ? price_open + _Point * 5 : price_open - _Point * 5;
         if ((type == POSITION_TYPE_BUY && newSL > sl) || (type == POSITION_TYPE_SELL && newSL < sl))
            ModifyPositionSLTP(ticket, newSL, tp);
      }

      // Trailing
      if (UseTrailing && profit_points >= TrailingStartPoints) {
         int steps = (int)((profit_points - TrailingStartPoints) / TrailingStepPoints) + 1;
         double newSL;
         if (type == POSITION_TYPE_BUY)
            newSL = current_price - TrailingStepPoints * _Point;
         else
            newSL = current_price + TrailingStepPoints * _Point;

         if ((type == POSITION_TYPE_BUY && newSL > sl) || (type == POSITION_TYPE_SELL && newSL < sl))
            ModifyPositionSLTP(ticket, newSL, tp);
      }
   }
}

bool ModifyPositionSLTP(ulong ticket, double newSL, double newTP) {
   MqlTradeRequest req;
   MqlTradeResult res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action = TRADE_ACTION_SLTP;
   req.position = ticket;
   req.symbol = _Symbol;
   req.sl = NormalizeDouble(newSL, (int) SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
   req.tp = NormalizeDouble(newTP, (int) SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));

   if (!OrderSend(req, res)) {
      PrintFormat("Modify SLTP failed rc=%d comment=%s", res.retcode, res.comment);
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Limits: Daily loss & Drawdown                                    |
//+------------------------------------------------------------------+
bool CheckTradeLimits() {
   datetime today = DateOfDay(TimeCurrent());
   if (lastTradeDay != today) {
      lastTradeDay = today;
      dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   }

   double curEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   double dailyLossPct = 0.0;
   if (dayStartEquity > 0)
      dailyLossPct = (dayStartEquity - curEquity) / dayStartEquity * 100.0;

   if (dailyLossPct >= MaxDailyLossPercent) return true;

   double ddPercent = 0.0;
   if (peakEquity > 0)
      ddPercent = (peakEquity - curEquity) / peakEquity * 100.0;

   if (ddPercent >= MaxDrawdownPercent) return true;

   return false;
}

datetime DateOfDay(datetime t) {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   return StructToTime(dt);
}
