#property version   "1.00"
#property description "H1 price action Expert Advisor using daily bias, session filters, liquidity sweeps, structure breaks, Fibonacci entries, and ATR exits."

#include <Trade/Trade.mqh>

input double InpLots = 0.10;
input ulong InpMagicNumber = 26040701;
input int InpMaxSpreadPoints = 30;
input double InpMinATRPoints = 50.0;
input double InpMaxATRPoints = 2000.0;
input int InpATRPeriod = 14;
input int InpSignalExpiryBars = 12;
input int InpSlippagePoints = 10;

enum BiasDirection
  {
   BIAS_NONE = 0,
   BIAS_BUY  = 1,
   BIAS_SELL = -1
  };

enum SetupStage
  {
   SETUP_NONE         = 0,
   SETUP_WAIT_BREAK   = 1,
   SETUP_WAIT_RETRACE = 2
  };

struct SweepData
  {
   bool              valid;
   int               direction;
   datetime          sweepBarTime;
   double            referenceLevel;
   double            sweepExtreme;
   double            structureLevel;
  };

struct BreakData
  {
   bool              valid;
   datetime          breakBarTime;
   double            impulseHigh;
   double            impulseLow;
  };

struct TradeSetup
  {
   int               stage;
   int               direction;
   datetime          createdDay;
   datetime          sweepBarTime;
   datetime          breakBarTime;
   double            referenceLevel;
   double            sweepExtreme;
   double            structureLevel;
   double            impulseHigh;
   double            impulseLow;
   double            fibZoneLow;
   double            fibZoneHigh;
  };

CTrade g_trade;
int g_atrHandle = INVALID_HANDLE;
datetime g_lastProcessedBarTime = 0;
TradeSetup g_setup;

void ResetSetup();
void ProcessNewBar();
void MaintainSetupValidity();
void LoadSweepIntoSetup(const SweepData &sweep);
int GetDailyBias();
bool IsSessionValid();
bool IsSessionValid(const datetime utcTime);
bool DetectLiquiditySweep(SweepData &sweep);
bool DetectStructureBreak(const SweepData &sweep, BreakData &breakData);
bool CalculateFibZone(const int direction,
                      const double sweepExtreme,
                      const double impulseHigh,
                      const double impulseLow,
                      double &zoneLow,
                      double &zoneHigh);
bool ExecuteTrade();
bool HasOpenPosition();
bool GetATRValue(double &atrValue);
double GetSpreadPoints();
double NormalizePrice(const double price);
double NormalizeVolume(const double requestedVolume);
int VolumeDigits(const double stepVolume);
datetime ServerTimeToUTC(const datetime serverTime);

int OnInit()
  {
   ResetSetup();
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippagePoints);

   g_atrHandle = iATR(_Symbol, PERIOD_H1, InpATRPeriod);
   if(g_atrHandle == INVALID_HANDLE)
      return(INIT_FAILED);

   g_lastProcessedBarTime = iTime(_Symbol, PERIOD_H1, 0);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(g_atrHandle != INVALID_HANDLE)
     {
      IndicatorRelease(g_atrHandle);
      g_atrHandle = INVALID_HANDLE;
     }
  }

void OnTick()
  {
   datetime currentBarTime = iTime(_Symbol, PERIOD_H1, 0);
   if(currentBarTime != 0 && currentBarTime != g_lastProcessedBarTime)
     {
      g_lastProcessedBarTime = currentBarTime;
      ProcessNewBar();
     }

   ExecuteTrade();
  }

void ResetSetup()
  {
   g_setup.stage = SETUP_NONE;
   g_setup.direction = BIAS_NONE;
   g_setup.createdDay = 0;
   g_setup.sweepBarTime = 0;
   g_setup.breakBarTime = 0;
   g_setup.referenceLevel = 0.0;
   g_setup.sweepExtreme = 0.0;
   g_setup.structureLevel = 0.0;
   g_setup.impulseHigh = 0.0;
   g_setup.impulseLow = 0.0;
   g_setup.fibZoneLow = 0.0;
   g_setup.fibZoneHigh = 0.0;
  }

void ProcessNewBar()
  {
   MaintainSetupValidity();
   if(HasOpenPosition())
      return;

   if(g_setup.stage == SETUP_WAIT_BREAK)
     {
      SweepData latestSweep;
      if(DetectLiquiditySweep(latestSweep) && latestSweep.direction == g_setup.direction && latestSweep.sweepBarTime > g_setup.sweepBarTime)
        {
         LoadSweepIntoSetup(latestSweep);
         return;
        }

      SweepData activeSweep;
      activeSweep.valid = true;
      activeSweep.direction = g_setup.direction;
      activeSweep.sweepBarTime = g_setup.sweepBarTime;
      activeSweep.referenceLevel = g_setup.referenceLevel;
      activeSweep.sweepExtreme = g_setup.sweepExtreme;
      activeSweep.structureLevel = g_setup.structureLevel;

      BreakData breakData;
      if(DetectStructureBreak(activeSweep, breakData))
        {
         double zoneLow = 0.0;
         double zoneHigh = 0.0;
         if(CalculateFibZone(g_setup.direction,
                             g_setup.sweepExtreme,
                             breakData.impulseHigh,
                             breakData.impulseLow,
                             zoneLow,
                             zoneHigh))
           {
            g_setup.stage = SETUP_WAIT_RETRACE;
            g_setup.breakBarTime = breakData.breakBarTime;
            g_setup.impulseHigh = breakData.impulseHigh;
            g_setup.impulseLow = breakData.impulseLow;
            g_setup.fibZoneLow = zoneLow;
            g_setup.fibZoneHigh = zoneHigh;
           }
        }
      return;
     }

   if(g_setup.stage == SETUP_WAIT_RETRACE)
      return;

   SweepData newSweep;
   if(DetectLiquiditySweep(newSweep))
      LoadSweepIntoSetup(newSweep);
  }

void MaintainSetupValidity()
  {
   if(g_setup.stage == SETUP_NONE)
      return;

   datetime currentDay = iTime(_Symbol, PERIOD_D1, 0);
   if(currentDay != 0 && currentDay != g_setup.createdDay)
     {
      ResetSetup();
      return;
     }

   int bias = GetDailyBias();
   if(bias != g_setup.direction)
     {
      ResetSetup();
      return;
     }

   int expiryBars = (InpSignalExpiryBars < 1) ? 1 : InpSignalExpiryBars;
   if(g_setup.stage == SETUP_WAIT_BREAK)
     {
      int barsSinceSweep = iBarShift(_Symbol, PERIOD_H1, g_setup.sweepBarTime, false);
      if(barsSinceSweep < 0 || barsSinceSweep > expiryBars)
        {
         ResetSetup();
         return;
        }
     }

   if(g_setup.stage == SETUP_WAIT_RETRACE)
     {
      int barsSinceBreak = iBarShift(_Symbol, PERIOD_H1, g_setup.breakBarTime, false);
      if(barsSinceBreak < 0 || barsSinceBreak > expiryBars)
         ResetSetup();
     }
  }

void LoadSweepIntoSetup(const SweepData &sweep)
  {
   ResetSetup();
   g_setup.stage = SETUP_WAIT_BREAK;
   g_setup.direction = sweep.direction;
   g_setup.createdDay = iTime(_Symbol, PERIOD_D1, 0);
   g_setup.sweepBarTime = sweep.sweepBarTime;
   g_setup.referenceLevel = sweep.referenceLevel;
   g_setup.sweepExtreme = sweep.sweepExtreme;
   g_setup.structureLevel = sweep.structureLevel;
  }

int GetDailyBias()
  {
   double prevOpen = iOpen(_Symbol, PERIOD_D1, 1);
   double prevClose = iClose(_Symbol, PERIOD_D1, 1);
   double prevHigh = iHigh(_Symbol, PERIOD_D1, 1);
   double prevLow = iLow(_Symbol, PERIOD_D1, 1);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(prevOpen == 0.0 || prevClose == 0.0 || prevHigh == 0.0 || prevLow == 0.0 || currentBid <= 0.0)
      return(BIAS_NONE);

   double midpoint = (prevHigh + prevLow) * 0.5;
   if(prevClose > prevOpen && currentBid > midpoint)
      return(BIAS_BUY);

   if(prevClose < prevOpen && currentBid < midpoint)
      return(BIAS_SELL);

   return(BIAS_NONE);
  }

bool IsSessionValid()
  {
   return(IsSessionValid(TimeGMT()));
  }

bool IsSessionValid(const datetime utcTime)
  {
   MqlDateTime timeParts;
   TimeToStruct(utcTime, timeParts);

   int hour = timeParts.hour;
   bool londonSession = (hour >= 7 && hour < 12);
   bool newYorkSession = (hour >= 12 && hour < 17);

   return(londonSession || newYorkSession);
  }

bool DetectLiquiditySweep(SweepData &sweep)
  {
   sweep.valid = false;
   sweep.direction = BIAS_NONE;
   sweep.sweepBarTime = 0;
   sweep.referenceLevel = 0.0;
   sweep.sweepExtreme = 0.0;
   sweep.structureLevel = 0.0;

   if(Bars(_Symbol, PERIOD_H1) < 7 || Bars(_Symbol, PERIOD_D1) < 2)
      return(false);

   int bias = GetDailyBias();
   if(bias == BIAS_NONE)
      return(false);

   datetime sweepBarTime = iTime(_Symbol, PERIOD_H1, 1);
   if(sweepBarTime == 0)
      return(false);

   datetime sweepCloseUtc = ServerTimeToUTC((datetime)(sweepBarTime + PeriodSeconds(PERIOD_H1)));
   if(!IsSessionValid(sweepCloseUtc))
      return(false);

   double prevDayHigh = iHigh(_Symbol, PERIOD_D1, 1);
   double prevDayLow = iLow(_Symbol, PERIOD_D1, 1);
   double candleHigh = iHigh(_Symbol, PERIOD_H1, 1);
   double candleLow = iLow(_Symbol, PERIOD_H1, 1);
   double candleClose = iClose(_Symbol, PERIOD_H1, 1);

   if(prevDayHigh == 0.0 || prevDayLow == 0.0 || candleHigh == 0.0 || candleLow == 0.0 || candleClose == 0.0)
      return(false);

   if(bias == BIAS_BUY && candleLow < prevDayLow && candleClose > prevDayLow)
     {
      double structureLevel = iHigh(_Symbol, PERIOD_H1, 2);
      for(int shift = 3; shift <= 6; ++shift)
        {
         double barHigh = iHigh(_Symbol, PERIOD_H1, shift);
         if(barHigh > structureLevel)
            structureLevel = barHigh;
        }

      sweep.valid = true;
      sweep.direction = BIAS_BUY;
      sweep.sweepBarTime = sweepBarTime;
      sweep.referenceLevel = prevDayLow;
      sweep.sweepExtreme = candleLow;
      sweep.structureLevel = structureLevel;
      return(true);
     }

   if(bias == BIAS_SELL && candleHigh > prevDayHigh && candleClose < prevDayHigh)
     {
      double structureLevel = iLow(_Symbol, PERIOD_H1, 2);
      for(int shift = 3; shift <= 6; ++shift)
        {
         double barLow = iLow(_Symbol, PERIOD_H1, shift);
         if(barLow < structureLevel)
            structureLevel = barLow;
        }

      sweep.valid = true;
      sweep.direction = BIAS_SELL;
      sweep.sweepBarTime = sweepBarTime;
      sweep.referenceLevel = prevDayHigh;
      sweep.sweepExtreme = candleHigh;
      sweep.structureLevel = structureLevel;
      return(true);
     }

   return(false);
  }

bool DetectStructureBreak(const SweepData &sweep, BreakData &breakData)
  {
   breakData.valid = false;
   breakData.breakBarTime = 0;
   breakData.impulseHigh = 0.0;
   breakData.impulseLow = 0.0;

   if(sweep.sweepBarTime == 0)
      return(false);

   datetime breakBarTime = iTime(_Symbol, PERIOD_H1, 1);
   if(breakBarTime == 0 || breakBarTime <= sweep.sweepBarTime)
      return(false);

   datetime breakCloseUtc = ServerTimeToUTC((datetime)(breakBarTime + PeriodSeconds(PERIOD_H1)));
   if(!IsSessionValid(breakCloseUtc))
      return(false);

   double closePrice = iClose(_Symbol, PERIOD_H1, 1);
   double highPrice = iHigh(_Symbol, PERIOD_H1, 1);
   double lowPrice = iLow(_Symbol, PERIOD_H1, 1);

   if(closePrice == 0.0 || highPrice == 0.0 || lowPrice == 0.0)
      return(false);

   if(sweep.direction == BIAS_BUY && closePrice > sweep.structureLevel)
     {
      breakData.valid = true;
      breakData.breakBarTime = breakBarTime;
      breakData.impulseHigh = highPrice;
      breakData.impulseLow = lowPrice;
      return(true);
     }

   if(sweep.direction == BIAS_SELL && closePrice < sweep.structureLevel)
     {
      breakData.valid = true;
      breakData.breakBarTime = breakBarTime;
      breakData.impulseHigh = highPrice;
      breakData.impulseLow = lowPrice;
      return(true);
     }

   return(false);
  }

bool CalculateFibZone(const int direction,
                      const double sweepExtreme,
                      const double impulseHigh,
                      const double impulseLow,
                      double &zoneLow,
                      double &zoneHigh)
  {
   zoneLow = 0.0;
   zoneHigh = 0.0;

   if(direction == BIAS_BUY)
     {
      double range = impulseHigh - sweepExtreme;
      if(range <= _Point)
         return(false);

      zoneLow = impulseHigh - (range * 0.618);
      zoneHigh = impulseHigh - (range * 0.500);
     }
   else if(direction == BIAS_SELL)
     {
      double range = sweepExtreme - impulseLow;
      if(range <= _Point)
         return(false);

      zoneLow = impulseLow + (range * 0.500);
      zoneHigh = impulseLow + (range * 0.618);
     }
   else
     {
      return(false);
     }

   if(zoneLow > zoneHigh)
     {
      double temp = zoneLow;
      zoneLow = zoneHigh;
      zoneHigh = temp;
     }

   zoneLow = NormalizePrice(zoneLow);
   zoneHigh = NormalizePrice(zoneHigh);
   return(true);
  }

bool ExecuteTrade()
  {
   if(g_setup.stage != SETUP_WAIT_RETRACE)
      return(false);

   if(HasOpenPosition())
      return(false);

   MaintainSetupValidity();
   if(g_setup.stage != SETUP_WAIT_RETRACE)
      return(false);

   if(!IsSessionValid())
      return(false);

   double atrValue = 0.0;
   if(!GetATRValue(atrValue))
      return(false);

   double atrPoints = atrValue / _Point;
   if(atrPoints < InpMinATRPoints || atrPoints > InpMaxATRPoints)
      return(false);

   if(GetSpreadPoints() > (double)InpMaxSpreadPoints)
      return(false);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return(false);

   double entryPrice = (g_setup.direction == BIAS_BUY) ? ask : bid;
   if(entryPrice < g_setup.fibZoneLow || entryPrice > g_setup.fibZoneHigh)
      return(false);

   long stopsLevelPoints = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDistance = (double)stopsLevelPoints * _Point;
   double stopLoss = 0.0;
   double takeProfit = 0.0;

   if(g_setup.direction == BIAS_BUY)
     {
      double baseStop = g_setup.sweepExtreme - (0.3 * atrValue);
      double brokerStop = entryPrice - minStopDistance;
      stopLoss = MathMin(baseStop, brokerStop);
      if(stopLoss >= entryPrice)
         return(false);

      double risk = entryPrice - stopLoss;
      if(risk <= _Point)
         return(false);

      takeProfit = entryPrice + (2.0 * risk);
     }
   else if(g_setup.direction == BIAS_SELL)
     {
      double baseStop = g_setup.sweepExtreme + (0.3 * atrValue);
      double brokerStop = entryPrice + minStopDistance;
      stopLoss = MathMax(baseStop, brokerStop);
      if(stopLoss <= entryPrice)
         return(false);

      double risk = stopLoss - entryPrice;
      if(risk <= _Point)
         return(false);

      takeProfit = entryPrice - (2.0 * risk);
     }
   else
     {
      return(false);
     }

   stopLoss = NormalizePrice(stopLoss);
   takeProfit = NormalizePrice(takeProfit);

   double volume = NormalizeVolume(InpLots);
   if(volume <= 0.0)
      return(false);

   string comment = (g_setup.direction == BIAS_BUY) ? "PA-H1-BUY" : "PA-H1-SELL";
   bool placed = false;

   if(g_setup.direction == BIAS_BUY)
      placed = g_trade.Buy(volume, _Symbol, 0.0, stopLoss, takeProfit, comment);
   else
      placed = g_trade.Sell(volume, _Symbol, 0.0, stopLoss, takeProfit, comment);

   if(placed)
      ResetSetup();

   return(placed);
  }

bool HasOpenPosition()
  {
   int totalPositions = PositionsTotal();
   for(int index = totalPositions - 1; index >= 0; --index)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string positionSymbol = PositionGetString(POSITION_SYMBOL);
      ulong positionMagic = (ulong)PositionGetInteger(POSITION_MAGIC);
      if(positionSymbol == _Symbol && positionMagic == InpMagicNumber)
         return(true);
     }

   return(false);
  }

bool GetATRValue(double &atrValue)
  {
   atrValue = 0.0;
   if(g_atrHandle == INVALID_HANDLE)
      return(false);

   double atrBuffer[1];
   if(CopyBuffer(g_atrHandle, 0, 1, 1, atrBuffer) != 1)
      return(false);

   if(atrBuffer[0] <= 0.0)
      return(false);

   atrValue = atrBuffer[0];
   return(true);
  }

double GetSpreadPoints()
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0 || _Point <= 0.0)
      return(DBL_MAX);

   return((ask - bid) / _Point);
  }

double NormalizePrice(const double price)
  {
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return(NormalizeDouble(price, digits));
  }

double NormalizeVolume(const double requestedVolume)
  {
   double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(minVolume <= 0.0 || maxVolume <= 0.0 || stepVolume <= 0.0)
      return(0.0);

   double clampedVolume = MathMax(minVolume, MathMin(maxVolume, requestedVolume));
   double steps = MathFloor(((clampedVolume - minVolume) / stepVolume) + 0.0000001);
   double normalizedVolume = minVolume + (steps * stepVolume);

   if(normalizedVolume < minVolume)
      normalizedVolume = minVolume;

   if(normalizedVolume > maxVolume)
      normalizedVolume = maxVolume;

   return(NormalizeDouble(normalizedVolume, VolumeDigits(stepVolume)));
  }

int VolumeDigits(const double stepVolume)
  {
   int digits = 0;
   double scaledStep = stepVolume;

   while(digits < 8 && MathAbs(scaledStep - MathRound(scaledStep)) > 0.00000001)
     {
      scaledStep *= 10.0;
      ++digits;
     }

   return(digits);
  }

datetime ServerTimeToUTC(const datetime serverTime)
  {
   datetime serverNow = TimeTradeServer();
   if(serverNow == 0)
      serverNow = TimeCurrent();

   datetime utcNow = TimeGMT();
   long offsetSeconds = (long)(serverNow - utcNow);
   return((datetime)(serverTime - offsetSeconds));
  }
