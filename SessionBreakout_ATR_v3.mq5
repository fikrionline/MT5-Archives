//+------------------------------------------------------------------+
//| SessionBreakout_ATR_v2_MT5.mq5                                   |
//| Improved version with trend filter, time exit, 1 trade/day,      |
//| and dynamic RR for better prop firm performance                  |
//+------------------------------------------------------------------+
#property copyright "Fikri"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Indicators\Indicators.mqh>
CTrade trade;
CPositionInfo m_position;

//--- Inputs
input ENUM_TIMEFRAMES  RangeTF = PERIOD_H1;     // timeframe to build the range
input int              RangeStartHour = 0;      // start hour for range
input int              RangeEndHour   = 6;      // end hour for range

input int              TradeStartHour = 13;     // session start hour (server time)
input int              TradeEndHour   = 17;     // session end hour
input int              TimeExitHour   = 20;     // forced exit hour

input double           RiskPercentPerTrade = 0.75; // percent risk per trade
input double           SL_ATR_Mult = 1.0;      // SL = ATR * this
input double           TP_ATR_MinMult = 1.5;   // dynamic min RR
input double           TP_ATR_MaxMult = 3.0;   // dynamic max RR
input double           MinATR = 0.0005;        // min ATR to allow trade
input int              ATR_Period = 14;

input int              MaxTradesPerDay = 1;   // now stricter
input double           MaxDailyLossPercent = 4.0;
input double           MaxOverallDrawdownPercent = 10.0;

input bool             UseFTMOMode = true;

//--- globals
int      handleATR = INVALID_HANDLE;
int      handleEMA = INVALID_HANDLE;
datetime lastDay = 0;
double   dayStartBalance = 0.0;
double   initialBalance = 0.0;
int      tradesToday = 0;
bool     tradingEnabled = true;

double   rangeHigh = 0.0;
double   rangeLow  = 0.0;
bool     rangeCalculated = false;

// working limits
double   maxDailyLossLimit;
double   maxOverallDrawdownLimit;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(UseFTMOMode)
     maxDailyLossLimit = 5.0 * 0.8;
   else
     maxDailyLossLimit = MaxDailyLossPercent;
   maxOverallDrawdownLimit = MaxOverallDrawdownPercent;

   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dayStartBalance = initialBalance;
   lastDay = DateOfDay(TimeCurrent());
   tradesToday = 0;
   tradingEnabled = true;

   handleATR = iATR(_Symbol, RangeTF, ATR_Period);
   if(handleATR==INVALID_HANDLE)
     return(INIT_FAILED);

   handleEMA = iMA(_Symbol, PERIOD_H4, 200, 0, MODE_EMA, PRICE_CLOSE);
   if(handleEMA==INVALID_HANDLE)
     return(INIT_FAILED);

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
datetime DateOfDay(datetime t)
  {
   MqlDateTime dt; TimeToStruct(t,dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return(StructToTime(dt));
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(handleATR!=INVALID_HANDLE) IndicatorRelease(handleATR);
   if(handleEMA!=INVALID_HANDLE) IndicatorRelease(handleEMA);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   // daily reset
   datetime today = DateOfDay(TimeCurrent());
   if(today != lastDay)
     {
      lastDay = today;
      dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      tradesToday = 0;
      tradingEnabled = true;
      rangeCalculated = false;
     }

   // equity protections
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double drawdownPercent = 100.0*(initialBalance - equity)/initialBalance;
   double dailyLossPercent = 100.0*(dayStartBalance - equity)/dayStartBalance;
   if(dailyLossPercent >= maxDailyLossLimit || drawdownPercent >= maxOverallDrawdownLimit)
     {
      tradingEnabled = false;
      CloseAllPositions("Equity Protection");
      return;
     }

   if(!tradingEnabled) return;
   if(tradesToday >= MaxTradesPerDay) return;

   // calculate range
   if(!rangeCalculated) CalculateRange();
   if(rangeHigh==0 || rangeLow==0) return;

   // session check
   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   int hour = t.hour;
   if(hour==TimeExitHour) { CloseAllPositions("TimeExit"); return; }
   if(!IsHourInSession(hour, TradeStartHour, TradeEndHour)) return;

   // get ATR
   double atrArr[]; ArraySetAsSeries(atrArr,true);
   if(CopyBuffer(handleATR,0,0,1,atrArr)!=1) return;
   double atr = atrArr[0];
   if(atr < MinATR) return;

   // get EMA200 trend
   double emaArr[]; ArraySetAsSeries(emaArr,true);
   if(CopyBuffer(handleEMA,0,0,1,emaArr)!=1) return;
   double ema = emaArr[0];
   double price = (SymbolInfoDouble(_Symbol,SYMBOL_BID)+SymbolInfoDouble(_Symbol,SYMBOL_ASK))/2;

   // breakout with trend filter
   if(price > rangeHigh && price > ema)
     {
      if(!HasOpenPositionOfType(POSITION_TYPE_BUY))
        OpenBreakoutTrade(ORDER_TYPE_BUY, atr, ema);
     }
   else if(price < rangeLow && price < ema)
     {
      if(!HasOpenPositionOfType(POSITION_TYPE_SELL))
        OpenBreakoutTrade(ORDER_TYPE_SELL, atr, ema);
     }
  }

//+------------------------------------------------------------------+
void CalculateRange()
  {
   int barsToScan = 48;
   double highs[]; double lows[]; datetime times[];
   ArraySetAsSeries(highs,true); ArraySetAsSeries(lows,true); ArraySetAsSeries(times,true);
   if(CopyHigh(_Symbol, RangeTF, 0, barsToScan, highs)<=0) return;
   if(CopyLow(_Symbol, RangeTF, 0, barsToScan, lows)<=0) return;
   if(CopyTime(_Symbol, RangeTF, 0, barsToScan, times)<=0) return;

   rangeHigh=0.0; rangeLow=0.0;
   for(int i=0;i<barsToScan;i++)
     {
      MqlDateTime bt; TimeToStruct(times[i], bt);
      if(IsHourInSession(bt.hour, RangeStartHour, RangeEndHour))
        {
         if(rangeHigh==0.0 || highs[i]>rangeHigh) rangeHigh = highs[i];
         if(rangeLow==0.0 || lows[i]<rangeLow) rangeLow = lows[i];
        }
     }
   if(rangeHigh>0 && rangeLow>0) rangeCalculated=true;
  }

//+------------------------------------------------------------------+
bool IsHourInSession(int hour, int startH, int endH)
  {
   if(startH <= endH) return (hour >= startH && hour < endH);
   else return (hour >= startH || hour < endH);
  }

//+------------------------------------------------------------------+
bool HasOpenPositionOfType(int type)
  {
   for(int i=0;i<PositionsTotal();i++)
     {
      if (!m_position.SelectByIndex(i)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      int ptype = (int)PositionGetInteger(POSITION_TYPE);
      if(ptype==type) return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
void OpenBreakoutTrade(int orderType, double atr, double ema)
  {
   double entryPrice, sl_price, tp_price;
   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);

   double sl_dist = atr * SL_ATR_Mult;
   double rr_mult = (ema>0 ? TP_ATR_MaxMult : TP_ATR_MinMult); // dynamic factor
   double tp_dist = atr * rr_mult;

   if(orderType==ORDER_TYPE_BUY)
     {
      entryPrice = ask;
      sl_price = entryPrice - sl_dist;
      tp_price = entryPrice + tp_dist;
     }
   else
     {
      entryPrice = bid;
      sl_price = entryPrice + sl_dist;
      tp_price = entryPrice - tp_dist;
     }

   double lots = CalculateLotForRiskFromPriceDist(sl_dist);
   if(lots<=0) return;

   double minLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0) step=0.01;
   lots = MathMax(minLot, MathMin(maxLot, MathFloor(lots/step)*step));

   trade.SetDeviationInPoints(10);
   trade.SetExpertMagicNumber(20250916);

   bool res=false;
   if(orderType==ORDER_TYPE_BUY)
     res=trade.Buy(lots,_Symbol,0,sl_price,tp_price,"BreakoutBuy");
   else
     res=trade.Sell(lots,_Symbol,0,sl_price,tp_price,"BreakoutSell");

   if(res) tradesToday++;
  }

//+------------------------------------------------------------------+
double CalculateLotForRiskFromPriceDist(double sl_price_dist)
  {
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_value<=0 || tick_size<=0) return(0);

   double value_per_priceunit = tick_value / tick_size;
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * (RiskPercentPerTrade/100.0);
   double lot = riskMoney / (sl_price_dist * value_per_priceunit);
   return(NormalizeDouble(lot,2));
  }

//+------------------------------------------------------------------+
void CloseAllPositions(string reason)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      if (!m_position.SelectByIndex(i)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      ulong ticket=PositionGetInteger(POSITION_TICKET);
      trade.PositionClose(ticket);
     }
  }

//+------------------------------------------------------------------+
double OnTester()
  {
   return AccountInfoDouble(ACCOUNT_BALANCE);
  }
//+------------------------------------------------------------------+
