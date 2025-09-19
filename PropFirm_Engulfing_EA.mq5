//+------------------------------------------------------------------+
//| PropFirm_Engulfing_EA.mq5                                        |
//| MT5 Expert Advisor: Engulfing strategy for prop-firm rules       |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>
CTrade trade;

input double   RiskPercent = 1.0;           // Risk percent per trade (default 1%)
input double   RiskReward  = 2.0;           // Risk-to-Reward ratio (default 1:2)
input ENUM_TIMEFRAMES Timeframe = PERIOD_CURRENT; // timeframe to trade
input bool     UseSymbolForRisk = true;     // true: calculate using instrument tick value
input double   MinLot = 0.01;               // default minimum lot if symbol info not available

// Session inputs
input int      LondonStartHour = 8;         // London session start (server time)
input int      LondonEndHour   = 17;        // London session end
input int      NYStartHour     = 13;        // New York session start (server time)
input int      NYEndHour       = 22;        // New York session end

datetime lastProcessedTime = 0;

//--- helper: check if current time is within London or NY session
bool InTradingSession()
{
   datetime now = TimeCurrent();
   MqlDateTime tm;
   TimeToStruct(now, tm);    // convert datetime -> struct
   int hourNow = tm.hour;    // extract hour

   bool inLondon = (hourNow >= LondonStartHour && hourNow < LondonEndHour);
   bool inNY     = (hourNow >= NYStartHour && hourNow < NYEndHour);

   return (inLondon || inNY);
}

//--- helper: calculate lot size by risk money and SL distance
double CalculateLotByRisk(double priceEntry, double priceSL)
{
   string symbol = _Symbol;
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * (RiskPercent/100.0);
   double distance = MathAbs(priceEntry - priceSL);
   if(distance<=0) return(0);

   double tick_value = 0.0, tick_size = 0.0;
   if(UseSymbolForRisk)
   {
      tick_value = SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE);
      tick_size  = SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
   }

   double value_per_point_per_lot;
   if(tick_value>0 && tick_size>0)
   {
      value_per_point_per_lot = tick_value / tick_size;
   }
   else
   {
      double contract = SymbolInfoDouble(symbol,SYMBOL_TRADE_CONTRACT_SIZE);
      if(contract<=0) contract = 100000;
      double point = SymbolInfoDouble(symbol,SYMBOL_POINT);
      value_per_point_per_lot = contract * point;
   }

   double lot = riskMoney / (value_per_point_per_lot * distance);

   double lot_min = SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
   double lot_max = SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
   if(lot_step<=0) lot_step = 0.01;
   if(lot_min<=0) lot_min = MinLot;
   if(lot_max<=0) lot_max = 100.0;

   lot = MathFloor(lot/lot_step) * lot_step;
   if(lot < lot_min) lot = lot_min;
   if(lot > lot_max) lot = lot_max;

   if(lot<=0) return(0);
   return(NormalizeDouble(lot, (int)MathMax(0, MathRound(-MathLog10(lot_step)))));
}

//--- delete all buy_stop/sell_stop pending orders for this symbol
void DeletePendingStops()
{
   int total = OrdersTotal();
   for(int i=total-1; i>=0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket)) continue;

      string ordSymbol = OrderGetString(ORDER_SYMBOL);
      ENUM_ORDER_TYPE ordType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(ordSymbol == _Symbol &&
         (ordType==ORDER_TYPE_BUY_STOP || ordType==ORDER_TYPE_SELL_STOP))
      {
         MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
         req.action = TRADE_ACTION_REMOVE;
         req.order  = ticket;

         if(!OrderSend(req,res))
            PrintFormat("Failed to delete order ticket=%I64u ret=%d", ticket, res.retcode);
         else
            PrintFormat("Deleted pending order ticket=%I64u", ticket);
      }
   }
}

//--- place pending order
bool PlacePendingOrder(bool bullish,double entry,double sl,double tp,double lot)
{
   MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
   req.action = TRADE_ACTION_PENDING;
   req.symbol = _Symbol;
   req.volume = lot;
   req.deviation = 5;
   req.type_filling = ORDER_FILLING_FOK;
   req.type_time = ORDER_TIME_GTC;

   if(bullish)
   {
      req.type = ORDER_TYPE_BUY_STOP;
      req.price = entry;
      req.sl = sl;
      req.tp = tp;
   }
   else
   {
      req.type = ORDER_TYPE_SELL_STOP;
      req.price = entry;
      req.sl = sl;
      req.tp = tp;
   }

   if(!OrderSend(req,res))
   {
      PrintFormat("OrderSend failed: ret=%d, comment=%s", res.retcode, res.comment);
      return(false);
   }
   else
   {
      PrintFormat("Pending order placed ticket=%I64u type=%d price=%.5f lot=%.2f SL=%.5f TP=%.5f", res.order, req.type, req.price, req.volume, req.sl, req.tp);
      return(true);
   }
}

//--- engulfing detection: returns 1 for bullish engulf, -1 for bearish, 0 for none
int IsEngulfing()
{
   double open1 = iOpen(_Symbol,Timeframe,1);
   double close1 = iClose(_Symbol,Timeframe,1);
   double open2 = iOpen(_Symbol,Timeframe,2);
   double close2 = iClose(_Symbol,Timeframe,2);

   if(close1>open1 && close2<open2 && open1<=close2 && close1>=open2)
      return(1);
   if(close1<open1 && close2>open2 && open1>=close2 && close1<=open2)
      return(-1);

   return(0);
}

//+------------------------------------------------------------------+
int OnInit()
{
   lastProcessedTime = 0;
   EventSetTimer(1);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

void OnTimer()
{
   OnTick();
}

//+------------------------------------------------------------------+
void OnTick()
{
   datetime timeBar1 = (datetime)iTime(_Symbol,Timeframe,1);
   if(timeBar1==0) return;

   if(timeBar1==lastProcessedTime) return;
   lastProcessedTime = timeBar1;

   if(!InTradingSession())
   {
      Print("Outside trading session, skipping.");
      return;
   }

   int eng = IsEngulfing();
   if(eng==0) return;

   DeletePendingStops();

   double entry = iClose(_Symbol,Timeframe,2);
   double sl = 0, tp = 0;
   bool bullish = (eng==1);
   if(bullish)
   {
      sl = iLow(_Symbol,Timeframe,2);
      double riskDist = MathAbs(entry - sl);
      tp = entry + RiskReward * riskDist;
   }
   else
   {
      sl = iHigh(_Symbol,Timeframe,2);
      double riskDist = MathAbs(entry - sl);
      tp = entry - RiskReward * riskDist;
   }

   double lot = CalculateLotByRisk(entry,sl);
   if(lot<=0)
   {
      Print("Lot calculation returned zero or negative. Order skipped.");
      return;
   }

   bool ok = PlacePendingOrder(bullish, entry, sl, tp, lot);
   if(!ok)
      Print("Failed to place pending order.");
}

//+------------------------------------------------------------------+
// End of file
//+------------------------------------------------------------------+
