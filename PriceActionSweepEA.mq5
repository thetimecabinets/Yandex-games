#property copyright "OpenAI"
#property link      "https://openai.com"
#property version   "1.00"

#include <Trade/Trade.mqh>

enum DailyBias
  {
   BIAS_NONE    = 0,
   BIAS_BULLISH = 1,
   BIAS_BEARISH = 2
  };

enum SignalState
  {
   SIGNAL_NONE       = 0,
   SIGNAL_WAIT_BREAK = 1,
   SIGNAL_WAIT_ENTRY = 2
  };

struct StrategySignal
  {
   SignalState state;
   DailyBias   direction;
   datetime    referenceDayTime;
   datetime    sweepBarTime;
   double      sweepExtreme;
   double      structureLevel;
   datetime    breakBarTime;
   double      impulseExtreme;
   double      fibLower;
   double      fibUpper;
  };

input string InpSymbol            = "EURUSD";
input double InpFixedLotSize      = 0.10;
input int    InpMaxSpreadPoints   = 30;
input double InpMinATRPoints      = 20.0;
input double InpMaxATRPoints      = 500.0;
input int    InpATRPeriod         = 14;
input int    InpDeviationPoints   = 20;
input ulong  InpMagicNumber       = 26040701;

CTrade         g_trade;
StrategySignal g_signal;
string         g_symbol          = "";
int            g_atrHandle       = INVALID_HANDLE;
datetime       g_lastH1BarTime   = 0;
double         g_point           = 0.0;
int            g_digits          = 0;

DailyBias GetDailyBias();
bool IsSessionValid(const datetime referenceTime=0);
bool DetectLiquiditySweep(const DailyBias bias,double &sweepExtreme,double &structureLevel);
bool DetectStructureBreak(const DailyBias direction,const double structureLevel,double &impulseExtreme);
bool CalculateFibZone(const DailyBias direction,const double sweepExtreme,const double impulseExtreme,double &fibLower,double &fibUpper);
bool ExecuteTrade();
void ResetSignal();
void ProcessNewClosedBar();
bool HasOpenPosition();
double HighestHigh(const int startShift,const int count);
double LowestLow(const int startShift,const int count);
double GetATRValue(const int shift=1);
bool IsAtrValid(const double atrValue);
bool IsSpreadValid();
double NormalizePrice(const double price);
double NormalizeVolume(const double requestedVolume);
bool ValidateStops(const ENUM_ORDER_TYPE orderType,const double entryPrice,const double stopLoss,const double takeProfit);
int GetServerUtcOffsetSeconds();
int GetVolumeDigits(const double volumeStep);

int OnInit()
  {
   g_symbol=(InpSymbol=="" ? _Symbol : InpSymbol);

   if(!SymbolSelect(g_symbol,true))
     {
      Print("Failed to select symbol ",g_symbol);
      return(INIT_FAILED);
     }

   g_point=SymbolInfoDouble(g_symbol,SYMBOL_POINT);
   g_digits=(int)SymbolInfoInteger(g_symbol,SYMBOL_DIGITS);

   if(g_point<=0.0 || g_digits<0)
     {
      Print("Invalid symbol pricing metadata.");
      return(INIT_FAILED);
     }

   g_atrHandle=iATR(g_symbol,PERIOD_H1,InpATRPeriod);
   if(g_atrHandle==INVALID_HANDLE)
     {
      Print("Failed to create ATR handle.");
      return(INIT_FAILED);
     }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpDeviationPoints);
   g_trade.SetTypeFillingBySymbol(g_symbol);

   ResetSignal();
   g_lastH1BarTime=0;

   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(g_atrHandle!=INVALID_HANDLE)
     {
      IndicatorRelease(g_atrHandle);
      g_atrHandle=INVALID_HANDLE;
     }
  }

void OnTick()
  {
   if(g_atrHandle==INVALID_HANDLE)
      return;

   datetime currentH1BarTime=iTime(g_symbol,PERIOD_H1,0);
   if(currentH1BarTime==0)
      return;

   datetime currentDayTime=iTime(g_symbol,PERIOD_D1,0);
   if(g_signal.referenceDayTime!=0 && currentDayTime!=0 && currentDayTime!=g_signal.referenceDayTime)
      ResetSignal();

   if(g_lastH1BarTime==0)
     {
      g_lastH1BarTime=currentH1BarTime;
      ProcessNewClosedBar();
     }
   else if(currentH1BarTime!=g_lastH1BarTime)
     {
      g_lastH1BarTime=currentH1BarTime;
      ProcessNewClosedBar();
     }

   if(g_signal.state==SIGNAL_WAIT_ENTRY && !HasOpenPosition())
      ExecuteTrade();
  }

DailyBias GetDailyBias()
  {
   MqlTick tick;
   if(!SymbolInfoTick(g_symbol,tick))
      return(BIAS_NONE);

   double prevOpen=iOpen(g_symbol,PERIOD_D1,1);
   double prevClose=iClose(g_symbol,PERIOD_D1,1);
   double prevHigh=iHigh(g_symbol,PERIOD_D1,1);
   double prevLow=iLow(g_symbol,PERIOD_D1,1);

   if(prevOpen<=0.0 || prevClose<=0.0 || prevHigh<=0.0 || prevLow<=0.0)
      return(BIAS_NONE);

   double midpoint=(prevHigh+prevLow)*0.5;
   double currentPrice=(tick.bid+tick.ask)*0.5;

   if(prevClose>prevOpen && currentPrice>midpoint)
      return(BIAS_BULLISH);

   if(prevClose<prevOpen && currentPrice<midpoint)
      return(BIAS_BEARISH);

   return(BIAS_NONE);
  }

bool IsSessionValid(const datetime referenceTime)
  {
   datetime serverTime=referenceTime;
   if(serverTime==0)
     {
      serverTime=TimeTradeServer();
      if(serverTime==0)
         serverTime=TimeCurrent();
     }

   datetime utcTime=serverTime-GetServerUtcOffsetSeconds();
   MqlDateTime utcStruct;
   if(!TimeToStruct(utcTime,utcStruct))
      return(false);

   return(utcStruct.hour>=7 && utcStruct.hour<17);
  }

bool DetectLiquiditySweep(const DailyBias bias,double &sweepExtreme,double &structureLevel)
  {
   sweepExtreme=0.0;
   structureLevel=0.0;

   double prevDayHigh=iHigh(g_symbol,PERIOD_D1,1);
   double prevDayLow=iLow(g_symbol,PERIOD_D1,1);
   double barHigh=iHigh(g_symbol,PERIOD_H1,1);
   double barLow=iLow(g_symbol,PERIOD_H1,1);
   double barClose=iClose(g_symbol,PERIOD_H1,1);

   if(prevDayHigh<=0.0 || prevDayLow<=0.0 || barHigh<=0.0 || barLow<=0.0 || barClose<=0.0)
      return(false);

   if(bias==BIAS_BULLISH)
     {
      if(barLow<prevDayLow && barClose>prevDayLow)
        {
         double candidateLevel=HighestHigh(2,5);
         if(candidateLevel<=0.0)
            return(false);

         sweepExtreme=barLow;
         structureLevel=candidateLevel;
         return(true);
        }
     }
   else if(bias==BIAS_BEARISH)
     {
      if(barHigh>prevDayHigh && barClose<prevDayHigh)
        {
         double candidateLevel=LowestLow(2,5);
         if(candidateLevel<=0.0)
            return(false);

         sweepExtreme=barHigh;
         structureLevel=candidateLevel;
         return(true);
        }
     }

   return(false);
  }

bool DetectStructureBreak(const DailyBias direction,const double structureLevel,double &impulseExtreme)
  {
   impulseExtreme=0.0;

   if(structureLevel<=0.0)
      return(false);

   double barClose=iClose(g_symbol,PERIOD_H1,1);
   if(barClose<=0.0)
      return(false);

   if(direction==BIAS_BULLISH)
     {
      double barHigh=iHigh(g_symbol,PERIOD_H1,1);
      if(barClose>structureLevel && barHigh>0.0)
        {
         impulseExtreme=barHigh;
         return(true);
        }
     }
   else if(direction==BIAS_BEARISH)
     {
      double barLow=iLow(g_symbol,PERIOD_H1,1);
      if(barClose<structureLevel && barLow>0.0)
        {
         impulseExtreme=barLow;
         return(true);
        }
     }

   return(false);
  }

bool CalculateFibZone(const DailyBias direction,const double sweepExtreme,const double impulseExtreme,double &fibLower,double &fibUpper)
  {
   fibLower=0.0;
   fibUpper=0.0;

   if(direction==BIAS_BULLISH)
     {
      double range=impulseExtreme-sweepExtreme;
      if(range<=g_point)
         return(false);

      double fib50=impulseExtreme-(0.500*range);
      double fib618=impulseExtreme-(0.618*range);

      fibLower=MathMin(fib50,fib618);
      fibUpper=MathMax(fib50,fib618);
      return(true);
     }

   if(direction==BIAS_BEARISH)
     {
      double range=sweepExtreme-impulseExtreme;
      if(range<=g_point)
         return(false);

      double fib50=impulseExtreme+(0.500*range);
      double fib618=impulseExtreme+(0.618*range);

      fibLower=MathMin(fib50,fib618);
      fibUpper=MathMax(fib50,fib618);
      return(true);
     }

   return(false);
  }

bool ExecuteTrade()
  {
   if(g_signal.state!=SIGNAL_WAIT_ENTRY || g_signal.direction==BIAS_NONE)
      return(false);

   if(!IsSessionValid())
      return(false);

   if(GetDailyBias()!=g_signal.direction)
      return(false);

   if(!IsSpreadValid())
      return(false);

   double atrValue=GetATRValue(1);
   if(!IsAtrValid(atrValue))
      return(false);

   MqlTick tick;
   if(!SymbolInfoTick(g_symbol,tick))
      return(false);

   double entryPrice=0.0;
   double stopLoss=0.0;
   double takeProfit=0.0;
   double volume=NormalizeVolume(InpFixedLotSize);

   if(g_signal.direction==BIAS_BULLISH)
     {
      entryPrice=tick.ask;
      if(entryPrice<g_signal.fibLower || entryPrice>g_signal.fibUpper)
         return(false);

      stopLoss=NormalizePrice(g_signal.sweepExtreme-(0.3*atrValue));
      if(entryPrice<=stopLoss)
        {
         ResetSignal();
         return(false);
        }

      double risk=entryPrice-stopLoss;
      if(risk<g_point)
         return(false);

      takeProfit=NormalizePrice(entryPrice+(2.0*risk));
      if(!ValidateStops(ORDER_TYPE_BUY,entryPrice,stopLoss,takeProfit))
         return(false);

      if(!g_trade.Buy(volume,g_symbol,0.0,stopLoss,takeProfit,"PA Buy"))
        {
         Print("Buy order failed. Retcode=",g_trade.ResultRetcode()," Description=",g_trade.ResultRetcodeDescription());
         return(false);
        }
     }
   else if(g_signal.direction==BIAS_BEARISH)
     {
      entryPrice=tick.bid;
      if(entryPrice<g_signal.fibLower || entryPrice>g_signal.fibUpper)
         return(false);

      stopLoss=NormalizePrice(g_signal.sweepExtreme+(0.3*atrValue));
      if(stopLoss<=entryPrice)
        {
         ResetSignal();
         return(false);
        }

      double risk=stopLoss-entryPrice;
      if(risk<g_point)
         return(false);

      takeProfit=NormalizePrice(entryPrice-(2.0*risk));
      if(!ValidateStops(ORDER_TYPE_SELL,entryPrice,stopLoss,takeProfit))
         return(false);

      if(!g_trade.Sell(volume,g_symbol,0.0,stopLoss,takeProfit,"PA Sell"))
        {
         Print("Sell order failed. Retcode=",g_trade.ResultRetcode()," Description=",g_trade.ResultRetcodeDescription());
         return(false);
        }
     }
   else
      return(false);

   ResetSignal();
   return(true);
  }

void ResetSignal()
  {
   g_signal.state=SIGNAL_NONE;
   g_signal.direction=BIAS_NONE;
   g_signal.referenceDayTime=0;
   g_signal.sweepBarTime=0;
   g_signal.sweepExtreme=0.0;
   g_signal.structureLevel=0.0;
   g_signal.breakBarTime=0;
   g_signal.impulseExtreme=0.0;
   g_signal.fibLower=0.0;
   g_signal.fibUpper=0.0;
  }

void ProcessNewClosedBar()
  {
   if(HasOpenPosition())
      return;

   if(Bars(g_symbol,PERIOD_H1)<10 || Bars(g_symbol,PERIOD_D1)<3)
      return;

   datetime currentDayTime=iTime(g_symbol,PERIOD_D1,0);
   if(currentDayTime==0)
      return;

   double sweepExtreme=0.0;
   double structureLevel=0.0;
   DailyBias currentBias=GetDailyBias();

   if(g_signal.state!=SIGNAL_WAIT_ENTRY &&
      currentBias!=BIAS_NONE &&
      DetectLiquiditySweep(currentBias,sweepExtreme,structureLevel))
     {
      g_signal.state=SIGNAL_WAIT_BREAK;
      g_signal.direction=currentBias;
      g_signal.referenceDayTime=currentDayTime;
      g_signal.sweepBarTime=iTime(g_symbol,PERIOD_H1,1);
      g_signal.sweepExtreme=sweepExtreme;
      g_signal.structureLevel=structureLevel;
      g_signal.breakBarTime=0;
      g_signal.impulseExtreme=0.0;
      g_signal.fibLower=0.0;
      g_signal.fibUpper=0.0;
      return;
     }

   if(g_signal.state!=SIGNAL_WAIT_BREAK)
      return;

   if(g_signal.referenceDayTime!=currentDayTime)
     {
      ResetSignal();
      return;
     }

   datetime closedBarTime=iTime(g_symbol,PERIOD_H1,1);
   if(closedBarTime<=g_signal.sweepBarTime)
      return;

   double impulseExtreme=0.0;
   if(!DetectStructureBreak(g_signal.direction,g_signal.structureLevel,impulseExtreme))
      return;

   double fibLower=0.0;
   double fibUpper=0.0;
   if(!CalculateFibZone(g_signal.direction,g_signal.sweepExtreme,impulseExtreme,fibLower,fibUpper))
     {
      ResetSignal();
      return;
     }

   g_signal.state=SIGNAL_WAIT_ENTRY;
   g_signal.breakBarTime=closedBarTime;
   g_signal.impulseExtreme=impulseExtreme;
   g_signal.fibLower=fibLower;
   g_signal.fibUpper=fibUpper;
  }

bool HasOpenPosition()
  {
   int total=PositionsTotal();
   for(int index=0; index<total; ++index)
     {
      ulong ticket=PositionGetTicket(index);
      if(ticket==0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string positionSymbol=PositionGetString(POSITION_SYMBOL);
      long positionMagic=PositionGetInteger(POSITION_MAGIC);

      if(positionSymbol==g_symbol && positionMagic==(long)InpMagicNumber)
         return(true);
     }

   return(false);
  }

double HighestHigh(const int startShift,const int count)
  {
   if(count<=0)
      return(0.0);

   double highest=iHigh(g_symbol,PERIOD_H1,startShift);
   if(highest<=0.0)
      return(0.0);

   for(int shift=startShift+1; shift<startShift+count; ++shift)
     {
      double value=iHigh(g_symbol,PERIOD_H1,shift);
      if(value<=0.0)
         return(0.0);

      if(value>highest)
         highest=value;
     }

   return(highest);
  }

double LowestLow(const int startShift,const int count)
  {
   if(count<=0)
      return(0.0);

   double lowest=iLow(g_symbol,PERIOD_H1,startShift);
   if(lowest<=0.0)
      return(0.0);

   for(int shift=startShift+1; shift<startShift+count; ++shift)
     {
      double value=iLow(g_symbol,PERIOD_H1,shift);
      if(value<=0.0)
         return(0.0);

      if(value<lowest)
         lowest=value;
     }

   return(lowest);
  }

double GetATRValue(const int shift)
  {
   if(g_atrHandle==INVALID_HANDLE)
      return(0.0);

   double atrBuffer[1];
   if(CopyBuffer(g_atrHandle,0,shift,1,atrBuffer)!=1)
      return(0.0);

   return(atrBuffer[0]);
  }

bool IsAtrValid(const double atrValue)
  {
   if(atrValue<=0.0 || g_point<=0.0)
      return(false);

   double atrPoints=atrValue/g_point;
   return(atrPoints>=InpMinATRPoints && atrPoints<=InpMaxATRPoints);
  }

bool IsSpreadValid()
  {
   MqlTick tick;
   if(!SymbolInfoTick(g_symbol,tick))
      return(false);

   double spreadPoints=(tick.ask-tick.bid)/g_point;
   return(spreadPoints<=(double)InpMaxSpreadPoints);
  }

double NormalizePrice(const double price)
  {
   return(NormalizeDouble(price,g_digits));
  }

double NormalizeVolume(const double requestedVolume)
  {
   double volumeMin=SymbolInfoDouble(g_symbol,SYMBOL_VOLUME_MIN);
   double volumeMax=SymbolInfoDouble(g_symbol,SYMBOL_VOLUME_MAX);
   double volumeStep=SymbolInfoDouble(g_symbol,SYMBOL_VOLUME_STEP);

   if(volumeMin<=0.0 || volumeMax<=0.0 || volumeStep<=0.0)
      return(requestedVolume);

   double clipped=MathMax(volumeMin,MathMin(requestedVolume,volumeMax));
   double normalized=volumeMin+MathFloor((clipped-volumeMin)/volumeStep+0.0000001)*volumeStep;
   normalized=MathMax(volumeMin,MathMin(normalized,volumeMax));

   return(NormalizeDouble(normalized,GetVolumeDigits(volumeStep)));
  }

bool ValidateStops(const ENUM_ORDER_TYPE orderType,const double entryPrice,const double stopLoss,const double takeProfit)
  {
   double minimumDistance=(double)SymbolInfoInteger(g_symbol,SYMBOL_TRADE_STOPS_LEVEL)*g_point;

   if(orderType==ORDER_TYPE_BUY)
     {
      if(entryPrice<=stopLoss || takeProfit<=entryPrice)
         return(false);

      if((entryPrice-stopLoss)<minimumDistance || (takeProfit-entryPrice)<minimumDistance)
         return(false);
     }
   else if(orderType==ORDER_TYPE_SELL)
     {
      if(stopLoss<=entryPrice || entryPrice<=takeProfit)
         return(false);

      if((stopLoss-entryPrice)<minimumDistance || (entryPrice-takeProfit)<minimumDistance)
         return(false);
     }

   return(true);
  }

int GetServerUtcOffsetSeconds()
  {
   datetime serverTime=TimeTradeServer();
   if(serverTime==0)
      serverTime=TimeCurrent();

   return((int)(serverTime-TimeGMT()));
  }

int GetVolumeDigits(const double volumeStep)
  {
   int digits=0;
   double scaledStep=volumeStep;

   while(digits<8 && MathAbs(scaledStep-MathRound(scaledStep))>0.00000001)
     {
      scaledStep*=10.0;
      ++digits;
     }

   return(digits);
  }
