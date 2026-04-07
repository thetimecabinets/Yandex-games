//+------------------------------------------------------------------+
//|                                    PriceActionStrategyBot.mq5     |
//|                          Price Action Strategy — Phase 1 MVP      |
//+------------------------------------------------------------------+
#property copyright "PriceActionBot"
#property link      ""
#property version   "1.00"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input double   InpLotSize        = 0.1;     // Lot Size
input int      InpATRPeriod      = 14;      // ATR Period
input double   InpATRMultSL      = 0.3;     // ATR Multiplier for SL padding
input double   InpRiskReward     = 2.0;     // Risk:Reward Ratio
input double   InpMaxSpread      = 30.0;    // Max Spread (points)
input double   InpMinATR         = 0.0005;  // Minimum ATR (avoid dead market)
input double   InpMaxATR         = 0.0100;  // Maximum ATR (avoid extreme volatility)
input int      InpMagicNumber    = 123456;  // Magic Number
input int      InpStructureBars  = 5;       // Bars for structure detection
input int      InpLondonStart    = 7;       // London Session Start (UTC hour)
input int      InpLondonEnd      = 12;      // London Session End (UTC hour)
input int      InpNewYorkStart   = 12;      // New York Session Start (UTC hour)
input int      InpNewYorkEnd     = 17;      // New York Session End (UTC hour)
input double   InpFibLevelUpper  = 0.618;   // Fibonacci Upper Level
input double   InpFibLevelLower  = 0.50;    // Fibonacci Lower Level
input int      InpBrokerUTCOffset = 0;      // Broker Server UTC Offset (hours)

//+------------------------------------------------------------------+
//| Enumerations                                                      |
//+------------------------------------------------------------------+
enum ENUM_BIAS
{
   BIAS_NONE    = 0,
   BIAS_BULLISH = 1,
   BIAS_BEARISH = 2
};

enum ENUM_SWEEP
{
   SWEEP_NONE = 0,
   SWEEP_BUY  = 1,
   SWEEP_SELL = 2
};

//+------------------------------------------------------------------+
//| Global Variables                                                   |
//+------------------------------------------------------------------+
CTrade         trade;
int            atrHandle;
datetime       lastBarTime;

// State tracking for multi-bar logic
double         sweepLow;
double         sweepHigh;
double         prevDayHigh;
double         prevDayLow;

bool           waitingForEntry;
double         fibEntryUpper;
double         fibEntryLower;
double         entrySL;
double         entryTP;
ENUM_SWEEP     tradeDirection;
datetime       signalExpiry;

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   atrHandle = iATR(_Symbol, PERIOD_H1, InpATRPeriod);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("Failed to create ATR indicator handle");
      return INIT_FAILED;
   }

   lastBarTime        = 0;
   waitingForEntry    = false;
   tradeDirection     = SWEEP_NONE;
   signalExpiry       = 0;

   Print("PriceActionStrategyBot initialized on ", _Symbol);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime currentBarTime = iTime(_Symbol, PERIOD_H1, 0);
   if(currentBarTime == lastBarTime)
      return;
   lastBarTime = currentBarTime;

   if(HasOpenPosition())
      return;

   // Expire signals older than 12 hours
   if(waitingForEntry && TimeCurrent() > signalExpiry)
   {
      ResetState();
   }

   double atrValue = GetATR();
   if(atrValue <= 0.0)
      return;

   if(!CheckSafetyFilters(atrValue))
   {
      return;
   }

   if(!IsSessionValid())
   {
      return;
   }

   // Step 1: Determine daily bias
   ENUM_BIAS bias = GetDailyBias();
   if(bias == BIAS_NONE)
   {
      return;
   }

   // Fetch previous day levels
   GetPreviousDayLevels();

   // Step 5: Check if waiting for Fibonacci retracement entry
   if(waitingForEntry)
   {
      double closePrice = iClose(_Symbol, PERIOD_H1, 1);
      if(tradeDirection == SWEEP_BUY && bias == BIAS_BULLISH)
      {
         if(closePrice <= fibEntryUpper && closePrice >= fibEntryLower)
         {
            ExecuteTrade(ORDER_TYPE_BUY, entrySL, entryTP);
            ResetState();
            return;
         }
         // If price went below the fib zone too far, invalidate
         if(closePrice < fibEntryLower - atrValue)
         {
            ResetState();
         }
      }
      else if(tradeDirection == SWEEP_SELL && bias == BIAS_BEARISH)
      {
         if(closePrice >= fibEntryLower && closePrice <= fibEntryUpper)
         {
            ExecuteTrade(ORDER_TYPE_SELL, entrySL, entryTP);
            ResetState();
            return;
         }
         // If price went above the fib zone too far, invalidate
         if(closePrice > fibEntryUpper + atrValue)
         {
            ResetState();
         }
      }
      return;
   }

   // Step 2: Detect liquidity sweep
   ENUM_SWEEP sweep = DetectLiquiditySweep();
   if(sweep == SWEEP_NONE)
   {
      return;
   }

   // Validate sweep aligns with bias
   if(sweep == SWEEP_BUY && bias != BIAS_BULLISH)
      return;
   if(sweep == SWEEP_SELL && bias != BIAS_BEARISH)
      return;

   // Step 3: Detect market structure break
   double sLevel = 0.0;
   double impHi  = 0.0;
   double impLo  = 0.0;

   if(!DetectStructureBreak(sweep, sLevel, impHi, impLo))
   {
      return;
   }

   // Step 4: Calculate Fibonacci zone and prepare entry
   double fibUpper = 0.0, fibLower = 0.0, sl = 0.0, tp = 0.0;

   if(!CalculateFibZone(sweep, impHi, impLo, atrValue, fibUpper, fibLower, sl, tp))
   {
      return;
   }

   // Save entry state — wait for price to retrace into fib zone
   waitingForEntry = true;
   fibEntryUpper   = fibUpper;
   fibEntryLower   = fibLower;
   entrySL         = sl;
   entryTP         = tp;
   tradeDirection  = sweep;
   signalExpiry    = TimeCurrent() + 12 * 3600;

   Print("Signal detected: ", (sweep == SWEEP_BUY ? "BUY" : "SELL"),
         " | Fib zone: ", DoubleToString(fibLower, _Digits), " - ", DoubleToString(fibUpper, _Digits),
         " | SL: ", DoubleToString(sl, _Digits), " | TP: ", DoubleToString(tp, _Digits));
}

//+------------------------------------------------------------------+
//| Get Daily Bias                                                    |
//+------------------------------------------------------------------+
ENUM_BIAS GetDailyBias()
{
   double prevOpen  = iOpen(_Symbol, PERIOD_D1, 1);
   double prevClose = iClose(_Symbol, PERIOD_D1, 1);
   double prevHigh  = iHigh(_Symbol, PERIOD_D1, 1);
   double prevLow   = iLow(_Symbol, PERIOD_D1, 1);

   if(prevOpen == 0.0 || prevClose == 0.0)
      return BIAS_NONE;

   double midpoint    = (prevHigh + prevLow) / 2.0;
   double currentBid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Bullish: prev candle closed above open AND current price above midpoint
   if(prevClose > prevOpen && currentBid > midpoint)
      return BIAS_BULLISH;

   // Bearish: prev candle closed below open AND current price below midpoint
   if(prevClose < prevOpen && currentBid < midpoint)
      return BIAS_BEARISH;

   return BIAS_NONE;
}

//+------------------------------------------------------------------+
//| Check if current time is within allowed sessions                  |
//+------------------------------------------------------------------+
bool IsSessionValid()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int hour = dt.hour - InpBrokerUTCOffset;
   if(hour < 0)  hour += 24;
   if(hour >= 24) hour -= 24;

   // London: 07:00–12:00 UTC
   if(hour >= InpLondonStart && hour < InpLondonEnd)
      return true;

   // New York: 12:00–17:00 UTC
   if(hour >= InpNewYorkStart && hour < InpNewYorkEnd)
      return true;

   return false;
}

//+------------------------------------------------------------------+
//| Get previous day high and low                                     |
//+------------------------------------------------------------------+
void GetPreviousDayLevels()
{
   prevDayHigh = iHigh(_Symbol, PERIOD_D1, 1);
   prevDayLow  = iLow(_Symbol, PERIOD_D1, 1);
}

//+------------------------------------------------------------------+
//| Detect Liquidity Sweep on closed H1 candles                      |
//+------------------------------------------------------------------+
ENUM_SWEEP DetectLiquiditySweep()
{
   if(prevDayHigh == 0.0 || prevDayLow == 0.0)
      return SWEEP_NONE;

   // Check last few closed candles for sweep pattern
   for(int lookback = 1; lookback <= 3; lookback++)
   {
      double barLow   = iLow(_Symbol, PERIOD_H1, lookback);
      double barHigh  = iHigh(_Symbol, PERIOD_H1, lookback);
      double barClose = iClose(_Symbol, PERIOD_H1, lookback);

      // BUY sweep: price wicked below previous day low then closed back above
      if(barLow < prevDayLow && barClose > prevDayLow)
      {
         sweepLow = barLow;
         return SWEEP_BUY;
      }

      // SELL sweep: price wicked above previous day high then closed back below
      if(barHigh > prevDayHigh && barClose < prevDayHigh)
      {
         sweepHigh = barHigh;
         return SWEEP_SELL;
      }
   }

   return SWEEP_NONE;
}

//+------------------------------------------------------------------+
//| Detect Market Structure Break                                     |
//+------------------------------------------------------------------+
bool DetectStructureBreak(ENUM_SWEEP sweep, double &outLevel, double &outImpHi, double &outImpLo)
{
   double close1 = iClose(_Symbol, PERIOD_H1, 1);

   if(sweep == SWEEP_BUY)
   {
      // Find last lower high: highest high of last N candles before current
      double lastLowerHigh = -DBL_MAX;
      for(int i = 2; i <= InpStructureBars + 1; i++)
      {
         double h = iHigh(_Symbol, PERIOD_H1, i);
         if(h > lastLowerHigh)
            lastLowerHigh = h;
      }

      if(lastLowerHigh <= 0.0)
         return false;

      // Confirm break: last closed candle closes above the structure level
      if(close1 > lastLowerHigh)
      {
         outLevel = lastLowerHigh;
         outImpHi = iHigh(_Symbol, PERIOD_H1, 1);
         outImpLo = iLow(_Symbol, PERIOD_H1, 1);
         return true;
      }
   }
   else if(sweep == SWEEP_SELL)
   {
      // Find last higher low: lowest low of last N candles before current
      double lastHigherLow = DBL_MAX;
      for(int i = 2; i <= InpStructureBars + 1; i++)
      {
         double l = iLow(_Symbol, PERIOD_H1, i);
         if(l < lastHigherLow)
            lastHigherLow = l;
      }

      if(lastHigherLow >= DBL_MAX)
         return false;

      // Confirm break: last closed candle closes below the structure level
      if(close1 < lastHigherLow)
      {
         outLevel = lastHigherLow;
         outImpHi = iHigh(_Symbol, PERIOD_H1, 1);
         outImpLo = iLow(_Symbol, PERIOD_H1, 1);
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| Calculate Fibonacci Retracement Zone                              |
//+------------------------------------------------------------------+
bool CalculateFibZone(ENUM_SWEEP sweep, double impHi, double impLo, double atrValue,
                      double &fibUpper, double &fibLower, double &sl, double &tp)
{
   if(sweep == SWEEP_BUY)
   {
      double swingLow  = sweepLow;
      double swingHigh = impHi;
      double range     = swingHigh - swingLow;

      if(range <= 0.0)
         return false;

      // Retracement levels (price descends from swingHigh)
      double fib50  = swingHigh - range * InpFibLevelLower;
      double fib618 = swingHigh - range * InpFibLevelUpper;

      fibUpper = fib50;   // Higher price in the zone
      fibLower = fib618;  // Lower price in the zone

      sl = swingLow - InpATRMultSL * atrValue;
      double risk = fibLower - sl;
      if(risk <= 0.0)
         return false;

      tp = fibLower + risk * InpRiskReward;
   }
   else if(sweep == SWEEP_SELL)
   {
      double swingHigh = sweepHigh;
      double swingLow  = impLo;
      double range     = swingHigh - swingLow;

      if(range <= 0.0)
         return false;

      // Retracement levels (price ascends from swingLow)
      double fib50  = swingLow + range * InpFibLevelLower;
      double fib618 = swingLow + range * InpFibLevelUpper;

      fibLower = fib50;   // Lower price in the zone
      fibUpper = fib618;  // Higher price in the zone

      sl = swingHigh + InpATRMultSL * atrValue;
      double risk = sl - fibUpper;
      if(risk <= 0.0)
         return false;

      tp = fibUpper - risk * InpRiskReward;
   }
   else
   {
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Execute Trade                                                     |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE orderType, double sl, double tp)
{
   double price = 0.0;
   if(orderType == ORDER_TYPE_BUY)
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   else
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(price <= 0.0)
      return;

   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);
   price = NormalizeDouble(price, _Digits);

   string comment = "PA_Bot";

   bool result = false;
   if(orderType == ORDER_TYPE_BUY)
      result = trade.Buy(InpLotSize, _Symbol, price, sl, tp, comment);
   else
      result = trade.Sell(InpLotSize, _Symbol, price, sl, tp, comment);

   if(result)
   {
      Print("Trade opened: ", (orderType == ORDER_TYPE_BUY ? "BUY" : "SELL"),
            " | Price: ", DoubleToString(price, _Digits),
            " | SL: ", DoubleToString(sl, _Digits),
            " | TP: ", DoubleToString(tp, _Digits));
   }
   else
   {
      Print("Trade failed: ", trade.ResultRetcodeDescription(),
            " | Retcode: ", trade.ResultRetcode());
   }
}

//+------------------------------------------------------------------+
//| Get ATR value                                                     |
//+------------------------------------------------------------------+
double GetATR()
{
   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);

   if(CopyBuffer(atrHandle, 0, 1, 1, atrBuffer) <= 0)
   {
      Print("Failed to read ATR buffer");
      return 0.0;
   }

   return atrBuffer[0];
}

//+------------------------------------------------------------------+
//| Check if there is already an open position with our magic number |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber)
      {
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Safety Filters                                                    |
//+------------------------------------------------------------------+
bool CheckSafetyFilters(double atrValue)
{
   // Spread filter
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if((double)spread > InpMaxSpread)
   {
      return false;
   }

   // ATR filters
   if(atrValue < InpMinATR)
   {
      return false;
   }

   if(atrValue > InpMaxATR)
   {
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Reset signal state                                                |
//+------------------------------------------------------------------+
void ResetState()
{
   waitingForEntry = false;
   tradeDirection  = SWEEP_NONE;
   signalExpiry    = 0;
   fibEntryUpper   = 0.0;
   fibEntryLower   = 0.0;
   entrySL         = 0.0;
   entryTP         = 0.0;
}
//+------------------------------------------------------------------+
