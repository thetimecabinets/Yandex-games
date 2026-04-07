//+------------------------------------------------------------------+
//|                                               PriceActionEA.mq5  |
//|                        Price Action Strategy — Phase 1 MVP        |
//|                                                                   |
//|  Daily Bias + Session + Liquidity Sweep + Structure Break +       |
//|  Fibonacci Retracement Entry + ATR-based SL/TP                    |
//+------------------------------------------------------------------+
#property copyright "PriceActionEA"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                             |
//+------------------------------------------------------------------+
input double InpLotSize       = 0.1;        // Lot Size
input int    InpMagicNumber   = 123456;     // Magic Number
input int    InpMaxSpread     = 30;         // Max Spread (points)
input double InpMinATR        = 0.0005;     // Minimum ATR value
input double InpMaxATR        = 0.0100;     // Maximum ATR value
input double InpATRPadding    = 0.3;        // ATR multiplier for SL padding
input double InpRiskReward    = 2.0;        // Risk:Reward ratio
input int    InpATRPeriod     = 14;         // ATR period (H1)
input int    InpStructBars    = 5;          // Bars for structure level
input int    InpLondonStart   = 7;          // London start hour (UTC)
input int    InpLondonEnd     = 12;         // London end hour (UTC)
input int    InpNYStart       = 12;         // New York start hour (UTC)
input int    InpNYEnd         = 17;         // New York end hour (UTC)
input int    InpMaxWaitBars   = 12;         // Max bars to wait for fib entry
input string InpComment       = "PriceActionEA"; // Order comment

//+------------------------------------------------------------------+
//| Enums                                                              |
//+------------------------------------------------------------------+
enum ENUM_BIAS   { BIAS_NONE=0, BIAS_BULLISH=1, BIAS_BEARISH=2 };
enum ENUM_SIGNAL { SIG_NONE=0,  SIG_BUY=1,      SIG_SELL=2     };

//+------------------------------------------------------------------+
//| Signal state machine                                               |
//+------------------------------------------------------------------+
enum ENUM_STATE
{
   STATE_IDLE           = 0,
   STATE_SWEEP_FOUND    = 1,
   STATE_BREAK_FOUND    = 2,
   STATE_WAITING_ENTRY  = 3
};

//+------------------------------------------------------------------+
//| Globals                                                            |
//+------------------------------------------------------------------+
CTrade       g_trade;
int          g_atrHandle;
datetime     g_lastBarTime;

ENUM_STATE   g_state;
ENUM_SIGNAL  g_direction;
double       g_sweepLow;
double       g_sweepHigh;
double       g_structureLevel;
double       g_impulseHigh;
double       g_impulseLow;
double       g_fibUpper;
double       g_fibLower;
datetime     g_signalDay;
int          g_waitBarCount;

//+------------------------------------------------------------------+
//| Initialization                                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   g_atrHandle = iATR(_Symbol, PERIOD_H1, InpATRPeriod);
   if(g_atrHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create ATR handle");
      return INIT_FAILED;
   }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(10);
   SetupFillingType();

   ResetState();
   g_lastBarTime = 0;

   Print("PriceActionEA initialized | Symbol=", _Symbol,
         " | Lot=", InpLotSize, " | Magic=", InpMagicNumber);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinitialization                                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
}

//+------------------------------------------------------------------+
//| Auto-detect and set the correct order filling type                 |
//+------------------------------------------------------------------+
void SetupFillingType()
{
   uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & 1) != 0)
      g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((filling & 2) != 0)
      g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

//+------------------------------------------------------------------+
//| Reset signal state to idle                                         |
//+------------------------------------------------------------------+
void ResetState()
{
   g_state          = STATE_IDLE;
   g_direction      = SIG_NONE;
   g_sweepLow       = 0.0;
   g_sweepHigh      = 0.0;
   g_structureLevel = 0.0;
   g_impulseHigh    = 0.0;
   g_impulseLow     = 0.0;
   g_fibUpper       = 0.0;
   g_fibLower       = 0.0;
   g_signalDay      = 0;
   g_waitBarCount   = 0;
}

//+------------------------------------------------------------------+
//| Main tick handler                                                  |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Fib entry check runs on every tick for precision
   if(g_state == STATE_WAITING_ENTRY && !HasOpenPosition())
   {
      if(IsSessionValid())
         CheckFibEntry();
   }

   //--- All signal logic runs only on new H1 bar close
   datetime barTime = iTime(_Symbol, PERIOD_H1, 0);
   if(barTime == g_lastBarTime)
      return;
   g_lastBarTime = barTime;

   //--- Day boundary reset
   MqlDateTime dtNow;
   TimeCurrent(dtNow);
   datetime today = (datetime)(StringToTime(
      IntegerToString(dtNow.year) + "." +
      IntegerToString(dtNow.mon)  + "." +
      IntegerToString(dtNow.day)));

   if(g_signalDay != 0 && g_signalDay != today)
      ResetState();

   //--- Timeout waiting state
   if(g_state == STATE_WAITING_ENTRY)
   {
      g_waitBarCount++;
      if(g_waitBarCount > InpMaxWaitBars)
      {
         Print("Fib entry wait timed out after ", g_waitBarCount, " bars");
         ResetState();
      }
   }

   //--- Skip if we already have an open position
   if(HasOpenPosition())
      return;

   //--- Session filter
   if(!IsSessionValid())
      return;

   //--- Spread filter
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpread)
      return;

   //--- ATR filter
   double atr = GetATR();
   if(atr <= 0.0 || atr < InpMinATR || atr > InpMaxATR)
      return;

   //--- Previous day data
   double prevDayHigh  = iHigh(_Symbol, PERIOD_D1, 1);
   double prevDayLow   = iLow(_Symbol, PERIOD_D1, 1);
   double prevDayOpen  = iOpen(_Symbol, PERIOD_D1, 1);
   double prevDayClose = iClose(_Symbol, PERIOD_D1, 1);
   if(prevDayHigh == 0.0 || prevDayLow == 0.0)
      return;

   //=== STATE MACHINE ===

   //--- IDLE: look for liquidity sweep
   if(g_state == STATE_IDLE)
   {
      ENUM_BIAS bias = GetDailyBias();
      if(bias == BIAS_NONE)
         return;

      ENUM_SIGNAL sweep = DetectLiquiditySweep(prevDayHigh, prevDayLow, bias);
      if(sweep == SIG_NONE)
         return;

      g_direction = sweep;
      g_signalDay = today;

      //--- Store the structure level now (based on candles before the sweep)
      ComputeStructureLevel();

      g_state = STATE_SWEEP_FOUND;
      Print("SWEEP detected: ", (sweep == SIG_BUY ? "BUY" : "SELL"),
            " | SweepLow=", g_sweepLow, " SweepHigh=", g_sweepHigh,
            " | StructLevel=", g_structureLevel);
   }

   //--- SWEEP_FOUND: look for structure break
   if(g_state == STATE_SWEEP_FOUND)
   {
      if(DetectStructureBreak())
      {
         g_state = STATE_BREAK_FOUND;
         Print("STRUCTURE BREAK: dir=", (g_direction == SIG_BUY ? "BUY" : "SELL"),
               " | ImpHi=", g_impulseHigh, " ImpLo=", g_impulseLow);
      }
   }

   //--- BREAK_FOUND: calculate fib zone and move to waiting
   if(g_state == STATE_BREAK_FOUND)
   {
      CalculateFibZone();
      g_waitBarCount = 0;
      g_state = STATE_WAITING_ENTRY;
      Print("FIB ZONE: Upper=", g_fibUpper, " Lower=", g_fibLower);
   }
}

//+------------------------------------------------------------------+
//| DAILY BIAS — previous D1 candle + current price vs midpoint       |
//+------------------------------------------------------------------+
ENUM_BIAS GetDailyBias()
{
   double prevOpen  = iOpen(_Symbol, PERIOD_D1, 1);
   double prevClose = iClose(_Symbol, PERIOD_D1, 1);
   double prevHigh  = iHigh(_Symbol, PERIOD_D1, 1);
   double prevLow   = iLow(_Symbol, PERIOD_D1, 1);

   if(prevOpen <= 0.0 || prevClose <= 0.0)
      return BIAS_NONE;

   double midpoint     = (prevHigh + prevLow) / 2.0;
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(prevClose > prevOpen && currentPrice > midpoint)
      return BIAS_BULLISH;

   if(prevClose < prevOpen && currentPrice < midpoint)
      return BIAS_BEARISH;

   return BIAS_NONE;
}

//+------------------------------------------------------------------+
//| SESSION FILTER — London or New York (UTC)                          |
//+------------------------------------------------------------------+
bool IsSessionValid()
{
   MqlDateTime dt;
   TimeGMT(dt);
   int h = dt.hour;

   if(h >= InpLondonStart && h < InpLondonEnd)
      return true;
   if(h >= InpNYStart && h < InpNYEnd)
      return true;

   return false;
}

//+------------------------------------------------------------------+
//| LIQUIDITY SWEEP on closed H1 candles (1 and 2)                     |
//| Returns SIG_BUY for bullish sweep or SIG_SELL for bearish sweep    |
//+------------------------------------------------------------------+
ENUM_SIGNAL DetectLiquiditySweep(double pdHigh, double pdLow, ENUM_BIAS bias)
{
   for(int idx = 1; idx <= 2; idx++)
   {
      double bHigh  = iHigh(_Symbol, PERIOD_H1, idx);
      double bLow   = iLow(_Symbol, PERIOD_H1, idx);
      double bClose = iClose(_Symbol, PERIOD_H1, idx);

      if(bHigh == 0.0)
         continue;

      //--- BUY: wick below prev day low, close above it (bullish bias only)
      if(bias == BIAS_BULLISH && bLow < pdLow && bClose > pdLow)
      {
         g_sweepLow = bLow;
         return SIG_BUY;
      }

      //--- SELL: wick above prev day high, close below it (bearish bias only)
      if(bias == BIAS_BEARISH && bHigh > pdHigh && bClose < pdHigh)
      {
         g_sweepHigh = bHigh;
         return SIG_SELL;
      }
   }

   return SIG_NONE;
}

//+------------------------------------------------------------------+
//| Compute the structure level from candles before the sweep          |
//| Called once right after sweep detection                             |
//+------------------------------------------------------------------+
void ComputeStructureLevel()
{
   if(g_direction == SIG_BUY)
   {
      //--- Last lower high = highest high of N candles before sweep
      double highestHigh = 0.0;
      for(int i = 2; i <= InpStructBars + 1; i++)
      {
         double h = iHigh(_Symbol, PERIOD_H1, i);
         if(h > highestHigh)
            highestHigh = h;
      }
      g_structureLevel = highestHigh;
   }
   else if(g_direction == SIG_SELL)
   {
      //--- Last higher low = lowest low of N candles before sweep
      double lowestLow = DBL_MAX;
      for(int i = 2; i <= InpStructBars + 1; i++)
      {
         double l = iLow(_Symbol, PERIOD_H1, i);
         if(l < lowestLow)
            lowestLow = l;
      }
      g_structureLevel = lowestLow;
   }
}

//+------------------------------------------------------------------+
//| STRUCTURE BREAK — check if last closed candle breaks the level     |
//+------------------------------------------------------------------+
bool DetectStructureBreak()
{
   double barClose = iClose(_Symbol, PERIOD_H1, 1);
   double barHigh  = iHigh(_Symbol, PERIOD_H1, 1);
   double barLow   = iLow(_Symbol, PERIOD_H1, 1);

   if(barClose == 0.0)
      return false;

   if(g_direction == SIG_BUY)
   {
      if(barClose > g_structureLevel)
      {
         g_impulseHigh = barHigh;
         g_impulseLow  = barLow;
         return true;
      }
   }
   else if(g_direction == SIG_SELL)
   {
      if(barClose < g_structureLevel)
      {
         g_impulseHigh = barHigh;
         g_impulseLow  = barLow;
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| FIBONACCI ZONE — 50% to 61.8% retracement                         |
//+------------------------------------------------------------------+
void CalculateFibZone()
{
   if(g_direction == SIG_BUY)
   {
      double swingLow  = g_sweepLow;
      double swingHigh = g_impulseHigh;
      double range     = swingHigh - swingLow;

      //--- BUY retracement: price pulls back from high toward low
      g_fibUpper = swingHigh - range * 0.50;   // 50% level (higher)
      g_fibLower = swingHigh - range * 0.618;  // 61.8% level (lower)
   }
   else if(g_direction == SIG_SELL)
   {
      double swingHigh = g_sweepHigh;
      double swingLow  = g_impulseLow;
      double range     = swingHigh - swingLow;

      //--- SELL retracement: price pulls back from low toward high
      g_fibLower = swingLow + range * 0.50;    // 50% level (lower)
      g_fibUpper = swingLow + range * 0.618;   // 61.8% level (higher)
   }
}

//+------------------------------------------------------------------+
//| Check if current price is inside the fib entry zone                |
//+------------------------------------------------------------------+
void CheckFibEntry()
{
   if(g_state != STATE_WAITING_ENTRY)
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(g_direction == SIG_BUY)
   {
      if(bid <= g_fibUpper && bid >= g_fibLower)
         ExecuteTrade(SIG_BUY);
   }
   else if(g_direction == SIG_SELL)
   {
      if(bid >= g_fibLower && bid <= g_fibUpper)
         ExecuteTrade(SIG_SELL);
   }
}

//+------------------------------------------------------------------+
//| Execute a trade with ATR-based SL/TP                               |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_SIGNAL dir)
{
   if(HasOpenPosition())
      return;

   //--- Final spread check
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpread)
      return;

   //--- Final ATR check
   double atr = GetATR();
   if(atr <= 0.0 || atr < InpMinATR || atr > InpMaxATR)
      return;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pad = InpATRPadding * atr;

   if(dir == SIG_BUY)
   {
      double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl    = NormalizeDouble(g_sweepLow - pad, digits);
      double risk  = price - sl;
      if(risk <= 0.0)
      {
         Print("BUY rejected: risk <= 0 | price=", price, " sl=", sl);
         return;
      }
      double tp = NormalizeDouble(price + risk * InpRiskReward, digits);

      Print(">>> BUY | Price=", price, " SL=", sl, " TP=", tp,
            " Risk=", risk, " ATR=", atr);

      if(!g_trade.Buy(InpLotSize, _Symbol, price, sl, tp, InpComment))
         Print("BUY FAILED: ", g_trade.ResultRetcode(),
               " | ", g_trade.ResultRetcodeDescription());
      else
         Print("BUY ORDER PLACED | Ticket=", g_trade.ResultOrder());
   }
   else if(dir == SIG_SELL)
   {
      double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl    = NormalizeDouble(g_sweepHigh + pad, digits);
      double risk  = sl - price;
      if(risk <= 0.0)
      {
         Print("SELL rejected: risk <= 0 | price=", price, " sl=", sl);
         return;
      }
      double tp = NormalizeDouble(price - risk * InpRiskReward, digits);

      Print(">>> SELL | Price=", price, " SL=", sl, " TP=", tp,
            " Risk=", risk, " ATR=", atr);

      if(!g_trade.Sell(InpLotSize, _Symbol, price, sl, tp, InpComment))
         Print("SELL FAILED: ", g_trade.ResultRetcode(),
               " | ", g_trade.ResultRetcodeDescription());
      else
         Print("SELL ORDER PLACED | Ticket=", g_trade.ResultOrder());
   }

   ResetState();
}

//+------------------------------------------------------------------+
//| Check if this EA already has an open position on the symbol        |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Get the current ATR(14) value on H1                                |
//+------------------------------------------------------------------+
double GetATR()
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_atrHandle, 0, 0, 1, buf) <= 0)
      return 0.0;
   return buf[0];
}
//+------------------------------------------------------------------+
