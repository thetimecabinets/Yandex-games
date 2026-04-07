//+------------------------------------------------------------------+
//|                                          PriceActionPhase1.mq5 |
//|                        Rule-based price action EA — Phase 1 MVP |
//+------------------------------------------------------------------+
#property copyright "Price Action Phase 1"
#property version   "1.00"

#include <Trade\Trade.mqh>

input string             InpSymbol          = "EURUSD";   // Trading symbol
input ENUM_TIMEFRAMES    InpTimeframe       = PERIOD_H1;   // Working timeframe
input double             InpLots            = 0.1;         // Fixed lot size
input ulong              InpMagic            = 20250407;   // Magic number
input int                InpMaxSpreadPoints  = 30;         // Max spread (points)
input double             InpMinAtrPoints     = 5.0;        // Min ATR (points)
input double             InpMaxAtrPoints     = 500.0;      // Max ATR (points)
input int                InpAtrPeriod        = 14;         // ATR period
input double             InpSlAtrMult        = 0.3;        // SL buffer: ATR multiplier
input int                InpSlippagePoints   = 20;         // Slippage (points)
input int                InpLookbackBars     = 96;         // H1 bars to scan (relax)

enum ENUM_BIAS
  {
   BIAS_NONE = 0,
   BIAS_BULL = 1,
   BIAS_BEAR = -1
  };

CTrade g_trade;
int    g_atrHandle = INVALID_HANDLE;
string g_sym;
double g_point;
int    g_digits;
int    g_stopsLevelPoints;
int    g_lastSigSweepIdx = -1;
int    g_lastSigBreakIdx = -1;

//+------------------------------------------------------------------+
void AutoDetectOrderFilling()
  {
   const long mode = SymbolInfoInteger(g_sym, SYMBOL_FILLING_MODE);
   if((mode & SYMBOL_FILLING_IOC) != 0)
      g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else if((mode & SYMBOL_FILLING_RETURN) != 0)
      g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
   else
      g_trade.SetTypeFilling(ORDER_FILLING_FOK);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_sym = (InpSymbol == "" ? _Symbol : InpSymbol);
   if(!SymbolSelect(g_sym, true))
     {
      Print("SymbolSelect failed: ", g_sym);
      return INIT_FAILED;
     }

   g_trade.SetExpertMagicNumber((int)InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetAsyncMode(false);

   g_point = SymbolInfoDouble(g_sym, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(g_sym, SYMBOL_DIGITS);
   g_stopsLevelPoints = (int)SymbolInfoInteger(g_sym, SYMBOL_TRADE_STOPS_LEVEL);

   AutoDetectOrderFilling();

   g_atrHandle = iATR(g_sym, InpTimeframe, InpAtrPeriod);
   if(g_atrHandle == INVALID_HANDLE)
     {
      Print("iATR failed");
      return INIT_FAILED;
     }

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(!IsNewBar(InpTimeframe))
      return;

   if(HasOurPosition())
      return;

   if(!PassesSafetyFilters())
      return;

   const ENUM_BIAS bias = GetDailyBias();
   if(bias == BIAS_NONE)
      return;

   if(!IsSessionValid())
      return;

   double pdHigh = 0.0;
   double pdLow = 0.0;
   if(!GetPreviousDayHighLow(pdHigh, pdLow))
      return;

   double atr = 0.0;
   if(!GetAtr1(atr))
      return;

   if(bias == BIAS_BULL)
     {
      int sweepIdx = -1;
      int breakIdx = -1;
      double structLevel = 0.0;
      double swingLow = 0.0;
      double swingHigh = 0.0;
      double zoneLo = 0.0;
      double zoneHi = 0.0;

      if(!DetectLiquiditySweepBuy(pdLow, sweepIdx))
         return;
      if(!DetectStructureBreakBuy(sweepIdx, structLevel, breakIdx))
         return;
      if(!GetSwingPointsBuy(sweepIdx, breakIdx, swingLow, swingHigh))
         return;
      if(!CalculateFibZoneBuy(swingLow, swingHigh, zoneLo, zoneHi))
         return;

      if(!BarTouchesZone(1, zoneLo, zoneHi))
         return;

      if(!IsChronologyValidBuy(sweepIdx, breakIdx))
         return;

      if(sweepIdx == g_lastSigSweepIdx && breakIdx == g_lastSigBreakIdx)
         return;

      ExecuteTradeBuy(sweepIdx, breakIdx, swingLow, atr);
     }
   else if(bias == BIAS_BEAR)
     {
      int sweepIdx = -1;
      int breakIdx = -1;
      double structLevel = 0.0;
      double swingHigh = 0.0;
      double swingLow = 0.0;
      double zoneLo = 0.0;
      double zoneHi = 0.0;

      if(!DetectLiquiditySweepSell(pdHigh, sweepIdx))
         return;
      if(!DetectStructureBreakSell(sweepIdx, structLevel, breakIdx))
         return;
      if(!GetSwingPointsSell(sweepIdx, breakIdx, swingHigh, swingLow))
         return;
      if(!CalculateFibZoneSell(swingHigh, swingLow, zoneLo, zoneHi))
         return;

      if(!BarTouchesZone(1, zoneLo, zoneHi))
         return;

      if(!IsChronologyValidSell(sweepIdx, breakIdx))
         return;

      if(sweepIdx == g_lastSigSweepIdx && breakIdx == g_lastSigBreakIdx)
         return;

      ExecuteTradeSell(sweepIdx, breakIdx, swingHigh, atr);
     }
  }

//+------------------------------------------------------------------+
bool IsNewBar(const ENUM_TIMEFRAMES tf)
  {
   static datetime lastBar = 0;
   datetime t = iTime(g_sym, tf, 0);
   if(t == 0)
      return false;
   if(t == lastBar)
      return false;
   lastBar = t;
   return true;
  }

//+------------------------------------------------------------------+
bool HasOurPosition()
  {
   const int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_sym)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
bool PassesSafetyFilters()
  {
   long spreadPts = 0;
   if(!SymbolInfoInteger(g_sym, SYMBOL_SPREAD, spreadPts))
      return false;
   if((int)spreadPts > InpMaxSpreadPoints)
      return false;
   return true;
  }

//+------------------------------------------------------------------+
ENUM_BIAS GetDailyBias()
  {
   const double dOpen = iOpen(g_sym, PERIOD_D1, 1);
   const double dClose = iClose(g_sym, PERIOD_D1, 1);
   const double dHigh = iHigh(g_sym, PERIOD_D1, 1);
   const double dLow = iLow(g_sym, PERIOD_D1, 1);
   if(dOpen == 0.0 || dClose == 0.0 || dHigh == 0.0 || dLow == 0.0)
      return BIAS_NONE;

   const double mid = 0.5 * (dHigh + dLow);
   const double cur = iClose(g_sym, InpTimeframe, 1);
   if(cur == 0.0)
      return BIAS_NONE;

   if(dClose > dOpen && cur > mid)
      return BIAS_BULL;
   if(dClose < dOpen && cur < mid)
      return BIAS_BEAR;
   return BIAS_NONE;
  }

//+------------------------------------------------------------------+
bool IsSessionValid()
  {
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   const int h = dt.hour;
   if(h >= 7 && h < 12)
      return true;
   if(h >= 12 && h < 17)
      return true;
   return false;
  }

//+------------------------------------------------------------------+
bool GetPreviousDayHighLow(double &pdHigh, double &pdLow)
  {
   pdHigh = iHigh(g_sym, PERIOD_D1, 1);
   pdLow = iLow(g_sym, PERIOD_D1, 1);
   return (pdHigh > 0.0 && pdLow > 0.0 && pdHigh > pdLow);
  }

//+------------------------------------------------------------------+
bool GetAtr1(double &atr)
  {
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) != 1)
      return false;
   atr = buf[0];
   if(atr <= 0.0)
      return false;

   const double atrPts = atr / g_point;
   if(atrPts < InpMinAtrPoints || atrPts > InpMaxAtrPoints)
      return false;
   return true;
  }

//+------------------------------------------------------------------+
// BUY: sweep = wick below prev day low, close back above
bool DetectLiquiditySweepBuy(const double pdLow, int &sweepIdxOut)
  {
   sweepIdxOut = -1;
   const int last = InpLookbackBars;
   if(iBars(g_sym, InpTimeframe) < last + 7)
      return false;

   for(int i = 6; i <= last; i++)
     {
      const double lo = iLow(g_sym, InpTimeframe, i);
      const double cl = iClose(g_sym, InpTimeframe, i);
      if(lo < pdLow && cl > pdLow)
        {
         sweepIdxOut = i;
         break;
        }
     }
   return (sweepIdxOut > 0);
  }

//+------------------------------------------------------------------+
// SELL: wick above prev day high, close back below
bool DetectLiquiditySweepSell(const double pdHigh, int &sweepIdxOut)
  {
   sweepIdxOut = -1;
   const int last = InpLookbackBars;
   if(iBars(g_sym, InpTimeframe) < last + 7)
      return false;

   for(int i = 6; i <= last; i++)
     {
      const double hi = iHigh(g_sym, InpTimeframe, i);
      const double cl = iClose(g_sym, InpTimeframe, i);
      if(hi > pdHigh && cl < pdHigh)
        {
         sweepIdxOut = i;
         break;
        }
     }
   return (sweepIdxOut > 0);
  }

//+------------------------------------------------------------------+
// Highest high of 5 bars before sweep (older: sweepIdx+1 .. sweepIdx+5)
bool DetectStructureBreakBuy(const int sweepIdx, double &structHighOut, int &breakIdxOut)
  {
   structHighOut = 0.0;
   breakIdxOut = -1;
   if(sweepIdx < 6)
      return false;

   const int idx1 = sweepIdx + 1;
   double mx = iHigh(g_sym, InpTimeframe, idx1);
   for(int k = 2; k <= 5; k++)
     {
      const int idx = sweepIdx + k;
      const double h = iHigh(g_sym, InpTimeframe, idx);
      if(h > mx)
         mx = h;
     }
   structHighOut = mx;

   for(int j = sweepIdx - 1; j >= 1; j--)
     {
      const double c = iClose(g_sym, InpTimeframe, j);
      if(c > structHighOut)
        {
         breakIdxOut = j;
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
// Lowest low of 5 bars before sweep
bool DetectStructureBreakSell(const int sweepIdx, double &structLowOut, int &breakIdxOut)
  {
   structLowOut = 0.0;
   breakIdxOut = -1;
   if(sweepIdx < 6)
      return false;

   const int idx1s = sweepIdx + 1;
   double mn = iLow(g_sym, InpTimeframe, idx1s);
   for(int k = 2; k <= 5; k++)
     {
      const int idx = sweepIdx + k;
      const double l = iLow(g_sym, InpTimeframe, idx);
      if(l < mn)
         mn = l;
     }
   structLowOut = mn;

   for(int j = sweepIdx - 1; j >= 1; j--)
     {
      const double c = iClose(g_sym, InpTimeframe, j);
      if(c < structLowOut)
        {
         breakIdxOut = j;
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
bool GetSwingPointsBuy(const int sweepIdx, const int breakIdx, double &swingLow, double &swingHigh)
  {
   swingLow = iLow(g_sym, InpTimeframe, sweepIdx);
   swingHigh = iHigh(g_sym, InpTimeframe, breakIdx);
   return (swingLow > 0.0 && swingHigh > swingLow);
  }

//+------------------------------------------------------------------+
bool GetSwingPointsSell(const int sweepIdx, const int breakIdx, double &swingHigh, double &swingLow)
  {
   swingHigh = iHigh(g_sym, InpTimeframe, sweepIdx);
   swingLow = iLow(g_sym, InpTimeframe, breakIdx);
   return (swingHigh > swingLow && swingLow > 0.0);
  }

//+------------------------------------------------------------------+
// BUY: retracement down into zone between 61.8% and 50% from top
bool CalculateFibZoneBuy(const double swingLow, const double swingHigh,
                         double &zoneLo, double &zoneHi)
  {
   const double r = swingHigh - swingLow;
   if(r <= 0.0)
      return false;
   const double lev618 = swingHigh - 0.618 * r;
   const double lev50 = swingHigh - 0.5 * r;
   zoneLo = MathMin(lev618, lev50);
   zoneHi = MathMax(lev618, lev50);
   return true;
  }

//+------------------------------------------------------------------+
// SELL: retracement up into zone between 50% and 61.8% from bottom
bool CalculateFibZoneSell(const double swingHigh, const double swingLow,
                          double &zoneLo, double &zoneHi)
  {
   const double r = swingHigh - swingLow;
   if(r <= 0.0)
      return false;
   const double lev50 = swingLow + 0.5 * r;
   const double lev618 = swingLow + 0.618 * r;
   zoneLo = MathMin(lev50, lev618);
   zoneHi = MathMax(lev50, lev618);
   return true;
  }

//+------------------------------------------------------------------+
bool BarTouchesZone(const int shift, const double zoneLo, const double zoneHi)
  {
   const double hi = iHigh(g_sym, InpTimeframe, shift);
   const double lo = iLow(g_sym, InpTimeframe, shift);
   if(hi <= 0.0 || lo <= 0.0)
      return false;
   return (lo <= zoneHi && hi >= zoneLo);
  }

//+------------------------------------------------------------------+
bool IsChronologyValidBuy(const int sweepIdx, const int breakIdx)
  {
   if(breakIdx <= 0 || sweepIdx <= 0)
      return false;
   if(breakIdx >= sweepIdx)
      return false;
   const datetime tBreak = iTime(g_sym, InpTimeframe, breakIdx);
   const datetime tSweep = iTime(g_sym, InpTimeframe, sweepIdx);
   const datetime tEntry = iTime(g_sym, InpTimeframe, 1);
   if(tBreak == 0 || tSweep == 0 || tEntry == 0)
      return false;
   return (tSweep < tBreak && tBreak < tEntry);
  }

//+------------------------------------------------------------------+
bool IsChronologyValidSell(const int sweepIdx, const int breakIdx)
  {
   if(breakIdx <= 0 || sweepIdx <= 0)
      return false;
   if(breakIdx >= sweepIdx)
      return false;
   const datetime tBreak = iTime(g_sym, InpTimeframe, breakIdx);
   const datetime tSweep = iTime(g_sym, InpTimeframe, sweepIdx);
   const datetime tEntry = iTime(g_sym, InpTimeframe, 1);
   if(tBreak == 0 || tSweep == 0 || tEntry == 0)
      return false;
   return (tSweep < tBreak && tBreak < tEntry);
  }

//+------------------------------------------------------------------+
bool NormalizeStops(const double price, double &sl, double &tp, const bool isBuy)
  {
   sl = NormalizeDouble(sl, g_digits);
   tp = NormalizeDouble(tp, g_digits);

   const double minDist = g_stopsLevelPoints * g_point;
   if(minDist <= 0.0)
      return true;

   if(isBuy)
     {
      if(price - sl < minDist)
         sl = NormalizeDouble(price - minDist, g_digits);
      if(tp - price < minDist)
         tp = NormalizeDouble(price + minDist, g_digits);
     }
   else
     {
      if(sl - price < minDist)
         sl = NormalizeDouble(price + minDist, g_digits);
      if(price - tp < minDist)
         tp = NormalizeDouble(price - minDist, g_digits);
     }
   return true;
  }

//+------------------------------------------------------------------+
void ExecuteTradeBuy(const int sweepIdx, const int breakIdx, const double sweepLow, const double atr)
  {
   double ask = 0.0;
   if(!SymbolInfoDouble(g_sym, SYMBOL_ASK, ask))
      return;

   const double slRaw = sweepLow - InpSlAtrMult * atr;
   double sl = slRaw;
   const double risk = ask - sl;
   if(risk <= 0.0)
      return;
   double tp = ask + 2.0 * risk;

   NormalizeStops(ask, sl, tp, true);

   if(g_trade.Buy(InpLots, g_sym, ask, sl, tp, "PA_P1_BUY"))
     {
      g_lastSigSweepIdx = sweepIdx;
      g_lastSigBreakIdx = breakIdx;
     }
   else
      Print("Buy failed: ", GetLastError(), " retcode=", g_trade.ResultRetcode());
  }

//+------------------------------------------------------------------+
void ExecuteTradeSell(const int sweepIdx, const int breakIdx, const double sweepHigh, const double atr)
  {
   double bid = 0.0;
   if(!SymbolInfoDouble(g_sym, SYMBOL_BID, bid))
      return;

   const double slRaw = sweepHigh + InpSlAtrMult * atr;
   double sl = slRaw;
   const double risk = sl - bid;
   if(risk <= 0.0)
      return;
   double tp = bid - 2.0 * risk;

   NormalizeStops(bid, sl, tp, false);

   if(g_trade.Sell(InpLots, g_sym, bid, sl, tp, "PA_P1_SELL"))
     {
      g_lastSigSweepIdx = sweepIdx;
      g_lastSigBreakIdx = breakIdx;
     }
   else
      Print("Sell failed: ", GetLastError(), " retcode=", g_trade.ResultRetcode());
  }

//+------------------------------------------------------------------+
