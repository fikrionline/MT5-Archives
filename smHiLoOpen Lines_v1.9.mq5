//+------------------------------------------------------------------+
//|              smHiLoOpen Lines v1.9 (MT5 Full Conversion)         |
//|   Multi-timeframe + Pip Grid + Ask/Bid + Labels + Boxes          |
//+------------------------------------------------------------------+
#property version   "1.90"
#property indicator_chart_window
#property indicator_buffers 1
#property indicator_plots   0   // we only use chart objects

double DummyBuffer[];

//---------------- Inputs ----------------
input bool Draw_Daily_Lines   = true;
input bool Draw_Weekly_Lines  = true;
input bool Draw_Monthly_Lines = true;

input bool Draw_Pip_Lines     = true;
input double PipIncrement     = 5.0;   
input int    NumPipLines      = 5;
input color  PipLineColor     = clrGray;

input bool  Draw_Ask_Bid      = true;
input int   AskWingDing       = 165;
input int   BidWingDing       = 165;
input color ColorAsk          = clrRed;
input color ColorBid          = clrBlue;

input bool Draw_Labels        = true;
input int  LabelFontSize      = 9;
input color LabelColor        = clrBlack;

input bool Draw_Boxes         = true;
input color DailyBoxColor     = clrAliceBlue;
input color WeeklyBoxColor    = clrLavenderBlush;
input color MonthlyBoxColor   = clrHoneydew;
input int   BoxTransparency   = 40; // 0-255

input bool Draw_Extreme_H1    = true;
input color ExtremeColor      = clrMagenta;

input bool Draw_TrendLine     = true;
input color TrendColor        = clrDarkGray;
input int   TrendWidth        = 2;

//---------------- Utility Functions ----------------
void CreateHLine(string name, double price, color clr, int width = 1, ENUM_LINE_STYLE style = STYLE_SOLID) {
   if (ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
}

void CreateText(string name, string text, double price, color clr, int fontsize = 9, int xShift = 20) {
   if (ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TEXT, 0, 0, price);

   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontsize);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, xShift);
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
}

void CreateBox(string name, datetime t1, datetime t2, double price1, double price2, color clr, int alpha) {
   if (ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, price1, t2, price2);

   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   //ObjectSetInteger(0, name, OBJPROP_TRANSPARENCY, alpha);
}

//---------------- Core ----------------
int OnInit() {
   SetIndexBuffer(0, DummyBuffer, INDICATOR_DATA);
   ArraySetAsSeries(DummyBuffer, true);

   ObjectsDeleteAll(0, 0, -1);
   return (INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   ObjectsDeleteAll(0, 0, -1);
}

int OnCalculate(const int rates_total,
   const int prev_calculated,
      const datetime & time[],
         const double & open[],
            const double & high[],
               const double & low[],
                  const double & close[],
                     const long & tick_volume[],
                        const long & volume[],
                           const int & spread[]) {
   // fill dummy buffer to keep MT5 happy
   for (int i = 0; i < rates_total; i++)
      DummyBuffer[i] = 0.0;

   datetime tNow = TimeCurrent();

   //---------------- Daily ----------------
   if (Draw_Daily_Lines) {
      double dOpen[], dHigh[], dLow[];
      if (CopyOpen(_Symbol, PERIOD_D1, 1, 1, dOpen) > 0 &&
         CopyHigh(_Symbol, PERIOD_D1, 1, 1, dHigh) > 0 &&
         CopyLow(_Symbol, PERIOD_D1, 1, 1, dLow) > 0) {
         CreateHLine("D_Open", dOpen[0], clrBlack);
         CreateHLine("D_High", dHigh[0], clrRed);
         CreateHLine("D_Low", dLow[0], clrBlue);

         if (Draw_Labels) {
            CreateText("D_Open_lbl", "D-Open", dOpen[0], LabelColor, LabelFontSize);
            CreateText("D_High_lbl", "D-High", dHigh[0], LabelColor, LabelFontSize);
            CreateText("D_Low_lbl", "D-Low", dLow[0], LabelColor, LabelFontSize);
         }

         if (Draw_Boxes) {
            datetime dayStart = iTime(_Symbol, PERIOD_D1, 1);
            datetime dayEnd = iTime(_Symbol, PERIOD_D1, 0);
            CreateBox("D_Box", dayStart, dayEnd, dHigh[0], dLow[0], DailyBoxColor, BoxTransparency);
         }
      }
   }

   //---------------- Weekly ----------------
   if (Draw_Weekly_Lines) {
      double wOpen[], wHigh[], wLow[];
      if (CopyOpen(_Symbol, PERIOD_W1, 1, 1, wOpen) > 0 &&
         CopyHigh(_Symbol, PERIOD_W1, 1, 1, wHigh) > 0 &&
         CopyLow(_Symbol, PERIOD_W1, 1, 1, wLow) > 0) {
         CreateHLine("W_Open", wOpen[0], clrDarkOrange);
         CreateHLine("W_High", wHigh[0], clrTomato);
         CreateHLine("W_Low", wLow[0], clrRoyalBlue);

         if (Draw_Labels) {
            CreateText("W_Open_lbl", "W-Open", wOpen[0], LabelColor, LabelFontSize);
            CreateText("W_High_lbl", "W-High", wHigh[0], LabelColor, LabelFontSize);
            CreateText("W_Low_lbl", "W-Low", wLow[0], LabelColor, LabelFontSize);
         }

         if (Draw_Boxes) {
            datetime wStart = iTime(_Symbol, PERIOD_W1, 1);
            datetime wEnd = iTime(_Symbol, PERIOD_W1, 0);
            CreateBox("W_Box", wStart, wEnd, wHigh[0], wLow[0], WeeklyBoxColor, BoxTransparency);
         }
      }
   }

   //---------------- Monthly ----------------
   if (Draw_Monthly_Lines) {
      double mOpen[], mHigh[], mLow[];
      if (CopyOpen(_Symbol, PERIOD_MN1, 1, 1, mOpen) > 0 &&
         CopyHigh(_Symbol, PERIOD_MN1, 1, 1, mHigh) > 0 &&
         CopyLow(_Symbol, PERIOD_MN1, 1, 1, mLow) > 0) {
         CreateHLine("M_Open", mOpen[0], clrDarkGreen);
         CreateHLine("M_High", mHigh[0], clrCrimson);
         CreateHLine("M_Low", mLow[0], clrDodgerBlue);

         if (Draw_Labels) {
            CreateText("M_Open_lbl", "M-Open", mOpen[0], LabelColor, LabelFontSize);
            CreateText("M_High_lbl", "M-High", mHigh[0], LabelColor, LabelFontSize);
            CreateText("M_Low_lbl", "M-Low", mLow[0], LabelColor, LabelFontSize);
         }

         if (Draw_Boxes) {
            datetime mStart = iTime(_Symbol, PERIOD_MN1, 1);
            datetime mEnd = iTime(_Symbol, PERIOD_MN1, 0);
            CreateBox("M_Box", mStart, mEnd, mHigh[0], mLow[0], MonthlyBoxColor, BoxTransparency);
         }
      }
   }

   //---------------- Extreme H1 Open ----------------
   if (Draw_Extreme_H1) {
      double o[];
      if (CopyOpen(_Symbol, PERIOD_H1, 0, 24, o) > 0) {
         double maxopen = o[ArrayMaximum(o, 24, 0)];
         double minopen = o[ArrayMinimum(o, 24, 0)];
         CreateHLine("Extreme_H1_HighOpen", maxopen, ExtremeColor, 1, STYLE_DOT);
         CreateHLine("Extreme_H1_LowOpen", minopen, ExtremeColor, 1, STYLE_DOT);
      }
   }

   //---------------- Trendline ----------------
   if (Draw_TrendLine) {
      double c[];
      if (CopyClose(_Symbol, PERIOD_H1, 0, 20, c) > 0) {
         datetime t1 = iTime(_Symbol, PERIOD_H1, 20);
         datetime t2 = iTime(_Symbol, PERIOD_H1, 0);
         if (ObjectFind(0, "TrendLine") < 0)
            ObjectCreate(0, "TrendLine", OBJ_TREND, 0, t1, c[19], t2, c[0]);
         ObjectSetInteger(0, "TrendLine", OBJPROP_COLOR, TrendColor);
         ObjectSetInteger(0, "TrendLine", OBJPROP_WIDTH, TrendWidth);
      }
   }

   //---------------- Pip lines ----------------
   if (Draw_Pip_Lines) {
      double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double pip = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      if (_Digits == 3 || _Digits == 5) pip *= 10;

      for (int i = 1; i <= NumPipLines; i++) {
         double up = price + i * PipIncrement * pip;
         double dn = price - i * PipIncrement * pip;
         CreateHLine("PipLine_Up_" + IntegerToString(i), up, PipLineColor, 1, STYLE_DOT);
         CreateHLine("PipLine_Dn_" + IntegerToString(i), dn, PipLineColor, 1, STYLE_DOT);
      }
   }

   //---------------- Ask/Bid ----------------
   if (Draw_Ask_Bid) {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      CreateText("Ask_Marker", CharToString((uchar) AskWingDing), ask, ColorAsk, 12, 25);
      CreateText("Bid_Marker", CharToString((uchar) BidWingDing), bid, ColorBid, 12, -25);
   }

   return (rates_total);
}
//+------------------------------------------------------------------+
