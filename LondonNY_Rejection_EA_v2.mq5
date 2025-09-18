//+------------------------------------------------------------------+
//|  Name: LondonNY_Rejection_EA_v2.mq5                              |
//|  Purpose: Buy and Sell on rejection after trend.                 |
//|  Rules: London/NewYork sessions only, Risk default 0.5% per trade, RR>=2.0 |
//|  Prop-firm: daily max loss and total max loss protections.       |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

input double  RiskPercent        = 0.5;    // % of equity risk per trade (e.g. 0.5%)
input double  MinRR              = 2.0;    // minimum Reward-to-Risk
input int     MaxTrades          = 1;      // maximum concurrent trades on symbol
input double  DailyMaxLossPct    = 4.0;    // stop trading for the day if daily loss >= this %
input double  TotalMaxLossPct    = 9.0;    // disable trading if total loss >= this %
input int     LondonStartHour    = 7;      // server time hour start (London session)
input int     LondonEndHour      = 16;     // server time hour end
input int     NYStartHour        = 12;     // server time hour start (New York session)
input int     NYEndHour          = 21;     // server time hour end
input double  SlippagePoints     = 5;      // allowed slippage in points
input double  LotStepMultiplier  = 0.01;   // rounding step for lots
input double  MinLot             = 0.01;   // minimum allowed lot (broker)
input double  MaxLot             = 100.0;  // maximum allowed lot
input bool    UseFixedBufferSL   = true;   // use small buffer under/above SL to avoid stop-hunt
input double  SLBufferPoints     = 5;      // buffer points under/above SL
input uint    MagicNumber        = 123456; // magic number for positions

// Global variable names
string g_initial_balance_name = "LNY_EA_INITIAL_BALANCE";
string g_day_start_balance_name = "LNY_EA_DAY_START_BAL";
string g_day_start_day_name     = "LNY_EA_DAY_START_DAY";

CTrade trade;
datetime last_bar_time = 0;

// create a unique global variable name for tracking daily reset
string gv_day_start = "DayStart_" + _Symbol;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   double storedDay = 0;
   
   // If initial balance not set, set it
   if(!GlobalVariableCheck(g_initial_balance_name))
      GlobalVariableSet(g_initial_balance_name, AccountInfoDouble(ACCOUNT_BALANCE));
   // ensure day start recorded
   if(!GlobalVariableCheck(g_day_start_balance_name))
   {
      GlobalVariableSet(g_day_start_balance_name, AccountInfoDouble(ACCOUNT_BALANCE));
      GlobalVariableSet(g_day_start_day_name, TimeDay(TimeCurrent()));
   }
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Helper: is within allowed trading session?                       |
//+------------------------------------------------------------------+
bool IsWithinSessions()
{
   int h = TimeHour(TimeCurrent());
   bool inLondon = (LondonStartHour <= LondonEndHour) ? (h >= LondonStartHour && h < LondonEndHour) 
                                                     : (h >= LondonStartHour || h < LondonEndHour);
   bool inNY     = (NYStartHour <= NYEndHour) ? (h >= NYStartHour && h < NYEndHour)
                                             : (h >= NYStartHour || h < NYEndHour);
   return (inLondon || inNY);
}

//+------------------------------------------------------------------+
//| Helper: get today's starting equity (resets when day changes)    |
//+------------------------------------------------------------------+
double GetDayStartBalance()
{
   int storedDay = (int)GlobalVariableGet(g_day_start_day_name);
   int today = TimeDay(TimeCurrent());
   if(storedDay != today)
   {
      // new day: update start balance
      GlobalVariableSet(g_day_start_day_name, today);
      GlobalVariableSet(g_day_start_balance_name, AccountInfoDouble(ACCOUNT_BALANCE));
   }
   return GlobalVariableGet(g_day_start_balance_name);
}

//+------------------------------------------------------------------+
//| Helper: initial account balance                                 |
//+------------------------------------------------------------------+
double GetInitialBalance()
{
   return GlobalVariableGet(g_initial_balance_name);
}

//+------------------------------------------------------------------+
//| Helper: check drawdown rules                                     |
//+------------------------------------------------------------------+
bool AllowedToTrade()
{
   double initBal = GetInitialBalance();
   double dayStart = GetDayStartBalance();
   double curEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   // total loss check
   if(curEquity <= initBal * (1.0 - TotalMaxLossPct/100.0))
   {
      PrintFormat("Total drawdown exceeded: equity %.2f <= allowed %.2f, disabling trading permanently.", curEquity, initBal*(1.0-TotalMaxLossPct/100.0));
      return false;
   }

   // daily drawdown check
   if(curEquity <= dayStart * (1.0 - DailyMaxLossPct/100.0))
   {
      PrintFormat("Daily drawdown exceeded: equity %.2f <= allowed %.2f, stop trading for today.", curEquity, dayStart*(1.0-DailyMaxLossPct/100.0));
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk money and SL (in points)        |
//+------------------------------------------------------------------+
double CalculateLotFromRisk(double riskMoney, double slPoints)
{
   if(slPoints <= 0) return(0.0);

   // For MT5 get tick value and tick size for the symbol
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tick_value <= 0 || tick_size <= 0)
   {
      // Fallback: approximate using point and assuming not CFD exotic
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double contract_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
      if(point <= 0 || contract_size <= 0)
         return(0.0);
      double riskPerLot = slPoints * point * contract_size;
      double lots = riskMoney / riskPerLot;
      return(NormalizeDouble(lots,2));
   }
   // risk per lot approx = slPoints * tick_value
   double riskPerLot = slPoints * tick_value;
   if(riskPerLot <= 0) return(0.0);
   double lots = riskMoney / riskPerLot;

   // normalize to lot step
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = LotStepMultiplier;
   double normalized = MathFloor(lots / step) * step;
   if(normalized < MinLot) normalized = 0.0;
   if(normalized > MaxLot) normalized = MaxLot;
   return(NormalizeDouble(normalized,2));
}

//+------------------------------------------------------------------+
//| Place buy order                                                  |
//+------------------------------------------------------------------+
bool PlaceBuy(double lots, double entry, double sl, double tp)
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviation((int)SlippagePoints);
   bool ok = trade.Buy(lots, NULL, entry, sl, tp, "LNY_Rejection_Buy");
   if(ok)
      PrintFormat("Buy placed: lots=%.2f entry=%.5f SL=%.5f TP=%.5f", lots, entry, sl, tp);
   else
      PrintFormat("Buy failed: %s", trade.ResultRetcodeDescription());
   return ok;
}

//+------------------------------------------------------------------+
//| Place sell order                                                 |
//+------------------------------------------------------------------+
bool PlaceSell(double lots, double entry, double sl, double tp)
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviation((int)SlippagePoints);
   bool ok = trade.Sell(lots, NULL, entry, sl, tp, "LNY_Rejection_Sell");
   if(ok)
      PrintFormat("Sell placed: lots=%.2f entry=%.5f SL=%.5f TP=%.5f", lots, entry, sl, tp);
   else
      PrintFormat("Sell failed: %s", trade.ResultRetcodeDescription());
   return ok;
}

//+------------------------------------------------------------------+
//| Check existing trades count for this symbol                      |
//+------------------------------------------------------------------+
int CountOpenTrades()
{
   int count = 0;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Determine patterns and attempt entries                           |
//+------------------------------------------------------------------+
void CheckPatternAndTrade()
{
   // Only if allowed by drawdown rules
   if(!AllowedToTrade()) return;

   // Only trade within sessions
   if(!IsWithinSessions()) return;

   // Limit number of trades
   if(CountOpenTrades() >= MaxTrades) return;

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
   
   double o3 = iOpen(_Symbol, Period(), 3);
   double c3 = iClose(_Symbol, Period(), 3);
   
   double o4 = iOpen(_Symbol, Period(), 4);
   double c4 = iClose(_Symbol, Period(), 4);

   // ---------------------------
   // Long (BUY) logic (as before)
   // ---------------------------
   bool three_bear_before = (c4 < o4) && (c3 < o3) && (c2 < o2);
   if(three_bear_before)
   {
      double body1 = MathAbs(c1 - o1);
      double lowerWick1 = (MathMin(o1,c1) - l1);
      double upperWick1 = (h1 - MathMax(o1,c1));
      if(body1 > 0)
      {
         bool isBullish = (c1 > o1);
         bool hasLongLowerWick = (lowerWick1 >= body1 * 1.5) && (lowerWick1 > upperWick1);
         bool smallBody = (body1 < (h1 - l1) * 0.5);
         if(isBullish && hasLongLowerWick && smallBody)
         {
            // entry when last closed candle breaks above high of rejection (h1)
            if(c0 > h1)
            {
               double entryPrice = c0;
               double stopLoss = l1;
               if(UseFixedBufferSL) stopLoss -= SLBufferPoints * _Point;
               double slPoints = MathAbs(entryPrice - stopLoss) / _Point;
               if(slPoints >= 1)
               {
                  double equity = AccountInfoDouble(ACCOUNT_EQUITY);
                  double riskMoney = equity * (RiskPercent / 100.0);
                  double lots = CalculateLotFromRisk(riskMoney, slPoints);
                  if(lots > 0)
                  {
                     double rewardPoints = slPoints * MinRR;
                     double tpPrice = entryPrice + rewardPoints * _Point;
                     if(tpPrice > entryPrice)
                     {
                        PlaceBuy(lots, SymbolInfoDouble(_Symbol,SYMBOL_ASK), stopLoss, tpPrice);
                        return; // limit to one entry per check
                     }
                  }
               }
            }
         }
      }
   }

   // ---------------------------
   // Short (SELL) symmetrical logic
   // ---------------------------
   // Check for three bullish candles preceding
   bool three_bull_before = (c4 > o4) && (c3 > o3) && (c2 > o2);
   if(three_bull_before)
   {
      // rejection candidate = index 1 (bearish small body with long upper wick)
      double body1_s = MathAbs(c1 - o1);
      double lowerWick1_s = (MathMin(o1,c1) - l1);
      double upperWick1_s = (h1 - MathMax(o1,c1));
      if(body1_s > 0)
      {
         bool isBearish = (c1 < o1);
         bool hasLongUpperWick = (upperWick1_s >= body1_s * 1.5) && (upperWick1_s > lowerWick1_s);
         bool smallBody_s = (body1_s < (h1 - l1) * 0.5);
         if(isBearish && hasLongUpperWick && smallBody_s)
         {
            // entry when last closed candle breaks below low of rejection (l1)
            if(c0 < l1)
            {
               double entryPrice = c0;
               double stopLoss = h1;
               if(UseFixedBufferSL) stopLoss += SLBufferPoints * _Point;
               double slPoints = MathAbs(entryPrice - stopLoss) / _Point;
               if(slPoints >= 1)
               {
                  double equity = AccountInfoDouble(ACCOUNT_EQUITY);
                  double riskMoney = equity * (RiskPercent / 100.0);
                  double lots = CalculateLotFromRisk(riskMoney, slPoints);
                  if(lots > 0)
                  {
                     double rewardPoints = slPoints * MinRR;
                     double tpPrice = entryPrice - rewardPoints * _Point;
                     if(tpPrice < entryPrice)
                     {
                        PlaceSell(lots, SymbolInfoDouble(_Symbol,SYMBOL_BID), stopLoss, tpPrice);
                        return; // limit to one entry per check
                     }
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   // update daily start if needed
   GetDayStartBalance();

   // check new bar
   static datetime lastTime = 0;
   datetime curBarTime = iTime(_Symbol, Period(), 0);
   if(curBarTime != lastTime)
   {
      // new bar
      lastTime = curBarTime;
      // perform pattern check on closed bars
      CheckPatternAndTrade();
   }
}

//+------------------------------------------------------------------+
//| Expert deinit                                                    |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // nothing special
}
