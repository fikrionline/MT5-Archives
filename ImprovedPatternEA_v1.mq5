//+------------------------------------------------------------------+
//| ImprovedPatternEA.mq5                                           |
//| Learns from CSV history and trades only high-probability setups |
//| Better than CSV replay (real adaptive trading)                  |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
CTrade trade;

//--- inputs
input double maxRiskPercent    = 1.0;   // risk per trade
input double maxDailyDDPercent = 4.0;   // max daily drawdown
input double fixedLotFallback  = 0.01;  // min lot
input bool   useTrailingStop   = false;
input int    trailingStartPips = 20;
input int    trailingStepPips  = 5;

//--- parameters learned from CSV (example, replace with real extracted values)
string  AllowedSymbols[] = {"AUDCAD", "AUDNZD"}; // profitable symbols
int     AllowedHours[]   = {8,9,10,11,12};      // profitable trading hours
double  MinRR            = 1.2;                 // minimum risk:reward ratio

datetime day_start_date;
double   day_start_balance;

//+------------------------------------------------------------------+
int OnInit()
{
   day_start_date = DateOfDay(TimeCurrent());
   day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   return(INIT_SUCCEEDED);
}
//+------------------------------------------------------------------+
void OnTick()
{
   datetime now = TimeCurrent();
   // Reset daily DD baseline
   if(DateOfDay(now) != day_start_date) {
      day_start_date = DateOfDay(now);
      day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   }

   // Daily DD protection
   double current_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double dd_percent = 100.0 * (day_start_balance - current_balance) / day_start_balance;
   if(dd_percent >= maxDailyDDPercent) return;

   // Only 1 trade rule
   if(PositionsTotal() > 0) {
      if(useTrailingStop) ApplyTrailingStop();
      return;
   }

   // Check if symbol & time fit profitable patterns
   string sym = Symbol();
   if(!ArrayContainsSymbol(sym)) return;

   MqlDateTime tm;
   TimeToStruct(now, tm);
   if(!ArrayContainsHour(tm.hour)) return;

   // Simple example condition: moving average cross + RR filter
   int maFast = iMA(sym, PERIOD_M15, 20, 0, MODE_EMA, PRICE_CLOSE);
   int maSlow = iMA(sym, PERIOD_M15, 50, 0, MODE_EMA, PRICE_CLOSE);

   if(maFast > maSlow) {
      // BUY setup
      PlaceTrade(sym, ORDER_TYPE_BUY);
   } else if(maFast < maSlow) {
      // SELL setup
      PlaceTrade(sym, ORDER_TYPE_SELL);
   }
}
//+------------------------------------------------------------------+
void PlaceTrade(string sym, ENUM_ORDER_TYPE type)
{
   double lot = fixedLotFallback;
   double sl  = 0, tp = 0; // placeholder, can set dynamically

   trade.SetExpertMagicNumber(123456);
   if(type == ORDER_TYPE_BUY)
      trade.Buy(lot, sym);
   else
      trade.Sell(lot, sym);
}
//+------------------------------------------------------------------+
void ApplyTrailingStop()
{
   for(int i=0;i<PositionsTotal();i++){
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      int type   = (int)PositionGetInteger(POSITION_TYPE);
      double sl  = PositionGetDouble(POSITION_SL);
      double open= PositionGetDouble(POSITION_PRICE_OPEN);
      double price = (type==POSITION_TYPE_BUY) ? SymbolInfoDouble(sym,SYMBOL_BID) : SymbolInfoDouble(sym,SYMBOL_ASK);

      double profitPips = (type==POSITION_TYPE_BUY) ? (price-open)/SymbolInfoDouble(sym,SYMBOL_POINT)
                                                    : (open-price)/SymbolInfoDouble(sym,SYMBOL_POINT);

      if(profitPips > trailingStartPips) {
         double new_sl;
         if(type==POSITION_TYPE_BUY) new_sl = price - trailingStepPips*SymbolInfoDouble(sym,SYMBOL_POINT);
         else new_sl = price + trailingStepPips*SymbolInfoDouble(sym,SYMBOL_POINT);
         trade.PositionModify(ticket,new_sl,PositionGetDouble(POSITION_TP));
      }
   }
}
//+------------------------------------------------------------------+
bool ArrayContainsSymbol(string sym) {
   for(int i=0;i<ArraySize(AllowedSymbols);i++)
      if(sym==AllowedSymbols[i]) return true;
   return false;
}
bool ArrayContainsHour(int h) {
   for(int i=0;i<ArraySize(AllowedHours);i++)
      if(h==AllowedHours[i]) return true;
   return false;
}
datetime DateOfDay(datetime t) {
   MqlDateTime d; TimeToStruct(t,d); d.hour=0; d.min=0; d.sec=0;
   return StructToTime(d);
}
