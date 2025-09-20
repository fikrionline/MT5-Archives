//+------------------------------------------------------------------+
//| DarvasBox_EA.mq5                                               |
//| Simple MT5 Expert Advisor implementing a Darvas Box breakout    |
//| - Risk management: max 1% risk per trade (configurable)         |
//| - Max daily drawdown limit (configurable)                       |
//| - Only one position at a time                                   |
//| - Now includes chart drawing of Darvas Boxes                    |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>
CTrade trade;

//--- input parameters
input double   InpRiskPercent         = 1.0;
input double   InpMaxDailyDDPercent   = 4.0;
input int      InpLookbackBars        = 200;
input int      InpSwingSize           = 5;
input int      InpMaxBoxes            = 3;
input double   InpBreakBufferPoints   = 10;
input double   InpMinLot              = 0.01;
input double   InpMaxLot              = 2.0;
input ENUM_TIMEFRAMES InpTimeframe    = PERIOD_CURRENT;
input bool     InpDrawBoxes           = true;   // draw Darvas boxes on chart
input bool     InpUseTrailingStop     = false;
input int      InpTrailStartPoints    = 500;
input int      InpTrailStepPoints     = 500;

//--- global state
datetime StartOfDayTime = 0;
double StartOfDayEquity = 0.0;
int TradesToday = 0;

struct DarvasBox {
   double high;
   double low;
   datetime start_time;
   datetime end_time;
   bool active;
};

DarvasBox Boxes[10];
int BoxesCount = 0;

//+------------------------------------------------------------------+
int OnInit() {
   StartOfDayTime = iTime(_Symbol, PERIOD_D1, 0);
   StartOfDayEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   for (int ai = 0; ai < ArraySize(Boxes); ai++) {
      Boxes[ai].high = 0.0;
      Boxes[ai].low = 0.0;
      Boxes[ai].start_time = 0;
      Boxes[ai].end_time = 0;
      Boxes[ai].active = false;
   }
   BoxesCount = 0;
   ObjectsDeleteAll(0, "DarvasBox_");
   return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   ObjectsDeleteAll(0, "DarvasBox_");
}

//+------------------------------------------------------------------+
void OnTick() {
   if (InpUseTrailingStop) ManageTrailing();

   datetime curDay = iTime(_Symbol, PERIOD_D1, 0);
   if (curDay != StartOfDayTime) {
      StartOfDayTime = curDay;
      StartOfDayEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      TradesToday = 0;
   }

   double curEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPercent = 0.0;
   if (StartOfDayEquity > 0) ddPercent = (StartOfDayEquity - curEquity) / StartOfDayEquity * 100.0;
   if (ddPercent >= InpMaxDailyDDPercent) return;

   if (HasOpenPosition()) return;

   DetectDarvasBoxes();
   if (InpDrawBoxes) DrawBoxes();

   TryEntry();

}

//+------------------------------------------------------------------+
bool HasOpenPosition() {
   for (int i = 0; i < PositionsTotal(); i++) {
      if (PositionGetSymbol(i) == _Symbol) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
void DetectDarvasBoxes() {
   BoxesCount = 0;
   int bars = InpLookbackBars;
   if (bars < InpSwingSize * 2 + 10) bars = InpSwingSize * 2 + 10;

   int swingHighIndex[100];
   int shc = 0;
   int swingLowIndex[100];
   int slc = 0;

   for (int i = InpSwingSize; i < bars - InpSwingSize; i++) {
      double hi = iHigh(_Symbol, InpTimeframe, i);
      bool isHigh = true;
      for (int j = 1; j <= InpSwingSize; j++)
         if (iHigh(_Symbol, InpTimeframe, i - j) >= hi || iHigh(_Symbol, InpTimeframe, i + j) >= hi) {
            isHigh = false;
            break;
         }
      if (isHigh) {
         swingHighIndex[shc++] = i;
         if (shc >= 100) break;
      }

      double lo = iLow(_Symbol, InpTimeframe, i);
      bool isLow = true;
      for (int j = 1; j <= InpSwingSize; j++)
         if (iLow(_Symbol, InpTimeframe, i - j) <= lo || iLow(_Symbol, InpTimeframe, i + j) <= lo) {
            isLow = false;
            break;
         }
      if (isLow) {
         swingLowIndex[slc++] = i;
         if (slc >= 100) break;
      }
   }

   for (int s = 0; s < shc && BoxesCount < InpMaxBoxes; s++) {
      int idxHigh = swingHighIndex[s];
      int foundLowIndex = -1;
      for (int t = 0; t < slc; t++) {
         if (swingLowIndex[t] < idxHigh) continue;
         foundLowIndex = swingLowIndex[t];
         break;
      }
      if (foundLowIndex == -1) continue;

      double boxHigh = iHigh(_Symbol, InpTimeframe, idxHigh);
      double boxLow = iLow(_Symbol, InpTimeframe, foundLowIndex);
      datetime startt = iTime(_Symbol, InpTimeframe, idxHigh);
      datetime endt = iTime(_Symbol, InpTimeframe, foundLowIndex);

      if (boxHigh > boxLow) {
         Boxes[BoxesCount].high = boxHigh;
         Boxes[BoxesCount].low = boxLow;
         Boxes[BoxesCount].start_time = startt;
         Boxes[BoxesCount].end_time = endt;
         Boxes[BoxesCount].active = true;
         BoxesCount++;
      }
   }
}

//+------------------------------------------------------------------+
void DrawBoxes() {
   for (int i = 0; i < BoxesCount; i++) {
      string nameHigh = "DarvasBox_" + string(i) + "_H";
      string nameLow = "DarvasBox_" + string(i) + "_L";
      if (!ObjectFind(0, nameHigh)) ObjectCreate(0, nameHigh, OBJ_HLINE, 0, 0, 0);
      if (!ObjectFind(0, nameLow)) ObjectCreate(0, nameLow, OBJ_HLINE, 0, 0, 0);

      ObjectSetInteger(0, nameHigh, OBJPROP_COLOR, clrLime);
      ObjectSetInteger(0, nameLow, OBJPROP_COLOR, clrRed);
      ObjectSetDouble(0, nameHigh, OBJPROP_PRICE, Boxes[i].high);
      ObjectSetDouble(0, nameLow, OBJPROP_PRICE, Boxes[i].low);
   }
}

//+------------------------------------------------------------------+
void TryEntry() {
   if (BoxesCount <= 0) return;
   DarvasBox box = Boxes[0];

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   double longTrigger = box.high + InpBreakBufferPoints * point;
   double shortTrigger = box.low - InpBreakBufferPoints * point;

   if (ask > longTrigger) {
      double slPrice = box.low;
      double stopLossPoints = MathAbs(ask - slPrice) / point;
      if (stopLossPoints < 5) return;

      double lot = CalculateLotSize(stopLossPoints);
      lot = MathMax(InpMinLot, MathMin(lot, InpMaxLot));

      trade.SetDeviationInPoints(10);
      if (trade.Buy(lot, NULL, ask, slPrice, 0, "DBuy")) TradesToday++;
      return;
   }

   if (bid < shortTrigger) {
      double slPrice = box.high;
      double stopLossPoints = MathAbs(slPrice - bid) / point;
      if (stopLossPoints < 5) return;

      double lot = CalculateLotSize(stopLossPoints);
      lot = MathMax(InpMinLot, MathMin(lot, InpMaxLot));

      trade.SetDeviationInPoints(10);
      if (trade.Sell(lot, NULL, bid, slPrice, 0, "DSell")) TradesToday++;
      return;
   }
}

//+------------------------------------------------------------------+
double CalculateLotSize(double stopLossPoints) {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * InpRiskPercent / 100.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   double valuePerPointPerLot = 0.0;
   if (tickSize > 0) valuePerPointPerLot = (tickValue / tickSize) * point;
   if (valuePerPointPerLot <= 0) valuePerPointPerLot = 1.0;

   double lot = riskAmount / (stopLossPoints * valuePerPointPerLot);

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if (lotStep <= 0) lotStep = 0.01;
   double normalizedLot = MathFloor(lot / lotStep) * lotStep;
   if (normalizedLot < minLot) normalizedLot = minLot;

   return NormalizeDouble(normalizedLot, 2);
}

//+------------------------------------------------------------------+
void ManageTrailing() {
   for (int i = 0; i < PositionsTotal(); i++) {
      if (PositionGetSymbol(i) != _Symbol) continue;
      ulong ticket = PositionGetInteger(POSITION_TICKET);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

      long type = PositionGetInteger(POSITION_TYPE);

      if (type == POSITION_TYPE_BUY) {
         double profitPoints = (currentBid - openPrice) / point;
         if (profitPoints >= InpTrailStartPoints) {
            double newSL = MathMax(openPrice, currentBid - InpTrailStepPoints * point);
            if (newSL > currentSL + point) // only move if strictly higher
               trade.PositionModify(ticket, newSL, 0.0);
         }
      } else if (type == POSITION_TYPE_SELL) {
         double profitPoints = (openPrice - currentAsk) / point;
         if (profitPoints >= InpTrailStartPoints) {
            double newSL = MathMin(openPrice, currentAsk + InpTrailStepPoints * point);
            if (currentSL == 0.0 || newSL < currentSL - point) // only move if strictly lower
               trade.PositionModify(ticket, newSL, 0.0);
         }
      }
   }
}

//+------------------------------------------------------------------+
string PositionGetSymbol(int index) {
   ulong ticket = PositionGetTicket(index);
   if (ticket == 0) return ("");
   if (!PositionSelectByTicket(ticket)) return ("");
   return (PositionGetString(POSITION_SYMBOL));
}

//+------------------------------------------------------------------+
// End of file
//+------------------------------------------------------------------+
