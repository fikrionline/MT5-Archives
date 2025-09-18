//+------------------------------------------------------------------+
//|                                                   PriceActionEA  |
//|                  Scalping/Prop Firm Challenge EA                |
//+------------------------------------------------------------------+
#include <Trade/Trade.mqh>
CTrade trade;

//--- Input parameters
input double RiskPercent = 1;        // Max risk per trade (%)
input double RewardRatio = 2;      // Risk:Reward ratio
input int EMA_Fast = 50;             // Fast EMA
input int EMA_Slow = 200;            // Slow EMA

//--- Indicator handles
int emaFastHandle;
int emaSlowHandle;

double openArray[];
double closeArray[];
double highArray[];
double lowArray[];

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    emaFastHandle = iMA(_Symbol, PERIOD_M15, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
    emaSlowHandle = iMA(_Symbol, PERIOD_M15, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

    if(emaFastHandle == INVALID_HANDLE || emaSlowHandle == INVALID_HANDLE)
    {
        Print("Failed to create EMA handles");
        return(INIT_FAILED);
    }

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Get latest indicator value                                        |
//+------------------------------------------------------------------+
double GetEMA(int handle)
{
    double buffer[];
    if(CopyBuffer(handle,0,0,1,buffer) > 0)
        return buffer[0];
    return 0;
}

//+------------------------------------------------------------------+
//| Calculate lot size                                                |
//+------------------------------------------------------------------+
double CalculateLot(double stopLossPips)
{
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskAmount = balance * (RiskPercent / 100.0);

    double tickValue = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
    double lot = riskAmount / (stopLossPips * tickValue / tickSize);

    double lotStep = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
    lot = MathFloor(lot/lotStep)*lotStep;

    double minLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
    if(lot<minLot) lot = minLot;

    return lot;
}

//--- Detect Bullish Pin Bar
bool IsBullishPinBar(int shift)
{
    double body = MathAbs(openArray[shift] - closeArray[shift]);
    double upperWick = highArray[shift] - MathMax(openArray[shift], closeArray[shift]);
    double lowerWick = MathMin(openArray[shift], closeArray[shift]) - lowArray[shift];

    if (body < lowerWick && upperWick < lowerWick * 0.3)
    {
        return true;
    }
    return false;
}

//--- Detect Bearish Pin Bar
bool IsBearishPinBar(int shift)
{
    double body = MathAbs(openArray[shift] - closeArray[shift]);
    double upperWick = highArray[shift] - MathMax(openArray[shift], closeArray[shift]);
    double lowerWick = MathMin(openArray[shift], closeArray[shift]) - lowArray[shift];

    if (body < upperWick && lowerWick < upperWick * 0.3)
    {
        return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| Open Trade                                                        |
//+------------------------------------------------------------------+
void OpenTrade()
{
    if(PositionSelect(_Symbol)) return; // Already in position

    double emaFast = GetEMA(emaFastHandle);
    double emaSlow = GetEMA(emaSlowHandle);
    double lot = 0;
    double price = 0;
    double sl = 0;
    double tp = 0;

    // Bullish signal
    if(IsBullishPinBar(1) && emaFast > emaSlow)
    {
        price = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
        sl = lowArray[1] - _Point*5; // use lowArray instead of Low[1]
        tp = price + (price-sl)*RewardRatio/_Point*_Point;
        lot = CalculateLot((price-sl)/_Point);
        trade.Buy(lot,_Symbol,price,sl,tp);
    }

    // Bearish signal
    if(IsBearishPinBar(1) && emaFast < emaSlow)
    {
        price = SymbolInfoDouble(_Symbol,SYMBOL_BID);
        sl = highArray[1] + _Point*5; // use highArray instead of High[1]
        tp = price - (sl-price)*RewardRatio/_Point*_Point;
        lot = CalculateLot((sl-price)/_Point);
        trade.Sell(lot,_Symbol,price,sl,tp);
    }
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
// Copy last 2 candles (0 = current, 1 = previous)
if(CopyOpen(_Symbol, PERIOD_M15, 0, 2, openArray) < 0) return;
if(CopyClose(_Symbol, PERIOD_M15, 0, 2, closeArray) < 0) return;
if(CopyHigh(_Symbol, PERIOD_M15, 0, 2, highArray) < 0) return;
if(CopyLow(_Symbol, PERIOD_M15, 0, 2, lowArray) < 0) return;

OpenTrade();
}
