//+------------------------------------------------------------------+
//|                                                      PropScalper |
//|                     Scalping EA for The5ers Challenge            |
//+------------------------------------------------------------------+
#include <Trade/Trade.mqh>
CTrade trade;

//--- Input parameters
input double RiskPercent = 1;       // Max risk per trade (%)
input double SL_Pips = 20;          // Stop Loss in pips
input double TP_Pips = 20;          // Take Profit in pips
input int EMA_Fast = 50;            // Fast EMA
input int EMA_Slow = 200;           // Slow EMA
input int RSI_Period = 14;          // Optional RSI filter
input int RSI_Overbought = 70;
input int RSI_Oversold = 30;

//--- Indicator handles
int emaFastHandle;
int emaSlowHandle;
int rsiHandle;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // Create indicator handles
    emaFastHandle = iMA(_Symbol, PERIOD_M15, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
    emaSlowHandle = iMA(_Symbol, PERIOD_M15, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
    rsiHandle = iRSI(_Symbol, PERIOD_M15, RSI_Period, PRICE_CLOSE);

    if(emaFastHandle == INVALID_HANDLE || emaSlowHandle == INVALID_HANDLE || rsiHandle == INVALID_HANDLE)
    {
        Print("Failed to create indicator handles");
        return(INIT_FAILED);
    }

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk                                  |
//+------------------------------------------------------------------+
double CalculateLot(double stopLossPips)
{
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskAmount = balance * (RiskPercent / 100.0);

    // Approximate lot calculation
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double lot = riskAmount / (stopLossPips * tickValue / tickSize);

    // Normalize to broker step
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    lot = MathFloor(lot / lotStep) * lotStep;

    // Ensure minimum lot size
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    if(lot < minLot) lot = minLot;

    return lot;
}

//+------------------------------------------------------------------+
//| Get latest value from indicator                                   |
//+------------------------------------------------------------------+
double GetIndicatorValue(int handle)
{
    double buffer[];
    if(CopyBuffer(handle, 0, 0, 1, buffer) > 0)
        return buffer[0];
    return 0;
}

//+------------------------------------------------------------------+
//| Check entry conditions                                            |
//+------------------------------------------------------------------+
int CheckEntry()
{
    double emaFast = GetIndicatorValue(emaFastHandle);
    double emaSlow = GetIndicatorValue(emaSlowHandle);
    double rsi = GetIndicatorValue(rsiHandle);

    // Buy condition
    if(emaFast > emaSlow && rsi < RSI_Overbought) return 1;

    // Sell condition
    if(emaFast < emaSlow && rsi > RSI_Oversold) return -1;

    return 0; // No trade
}

//+------------------------------------------------------------------+
//| Open trade                                                        |
//+------------------------------------------------------------------+
void OpenTrade()
{
    int signal = CheckEntry();
    if(signal == 0) return; // No trade

    if(PositionSelect(_Symbol)) return; // Already a position

    double lot = CalculateLot(SL_Pips);
    double price = 0;
    double sl = 0;
    double tp = 0;

    if(signal == 1) // Buy
    {
        price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        sl = price - SL_Pips * _Point;
        tp = price + TP_Pips * _Point;
        trade.Buy(lot, _Symbol, price, sl, tp);
    }
    else if(signal == -1) // Sell
    {
        price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        sl = price + SL_Pips * _Point;
        tp = price - TP_Pips * _Point;
        trade.Sell(lot, _Symbol, price, sl, tp);
    }
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
    OpenTrade();
}

//+------------------------------------------------------------------+
