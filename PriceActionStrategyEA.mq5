#property copyright "OpenAI"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

enum DailyBias
  {
   BIAS_NONE    = 0,
   BIAS_BULLISH = 1,
   BIAS_BEARISH = -1
  };

enum SetupStage
  {
   STAGE_NONE            = 0,
   STAGE_SWEEP_DETECTED  = 1,
   STAGE_BREAK_CONFIRMED = 2
  };

input string InpTradeSymbol       = "EURUSD";
input double InpLotSize           = 0.10;
input uint   InpMagicNumber       = 260407;
input int    InpSlippagePoints    = 20;
input double InpMaxSpreadPoints   = 40.0;
input double InpMinATRPoints      = 20.0;
input double InpMaxATRPoints      = 300.0;
input int    InpSignalExpiryBars  = 24;

CTrade   trade;
string   g_symbol        = "";
double   g_point         = 0.0;
int      g_digits        = 0;
int      g_atrHandle     = INVALID_HANDLE;
datetime g_lastBarTime   = 0;

SetupStage g_stage         = STAGE_NONE;
int        g_direction     = 0;
double     g_sweepPrice    = 0.0;
double     g_structureLevel= 0.0;
double     g_fibZoneLow    = 0.0;
double     g_fibZoneHigh   = 0.0;
datetime   g_sweepTime     = 0;
int        g_stageAgeBars  = 0;

int    GetDailyBias();
bool   IsSessionValid();
bool   DetectLiquiditySweep(int bias,int &direction,double &sweepPrice,double &structureLevel,datetime &sweepTime);
bool   DetectStructureBreak(int direction,double structureLevel,datetime sweepTime,double &impulseHigh,double &impulseLow,datetime &breakTime);
bool   CalculateFibZone(int direction,double sweepPrice,double impulseHigh,double impulseLow,double &zoneLow,double &zoneHigh);
bool   ExecuteTrade(int direction,double sweepPrice,double fibZoneLow,double fibZoneHigh);
bool   IsNewH1Bar();
bool   HasOpenPosition();
bool   IsSpreadValid();
double GetATRValue();
bool   IsATRValid(double atrValue);
double NormalizeVolume(double requestedVolume);
int    VolumeDigitsFromStep(double step);
void   ResetSetup();

int OnInit()
  {
   g_symbol=(InpTradeSymbol=="")?_Symbol:InpTradeSymbol;
   if(!SymbolSelect(g_symbol,true))
     {
      Print("Failed to select symbol: ",g_symbol);
      return(INIT_FAILED);
     }

   g_point=SymbolInfoDouble(g_symbol,SYMBOL_POINT);
   g_digits=(int)SymbolInfoInteger(g_symbol,SYMBOL_DIGITS);
   if(g_point<=0.0 || g_digits<0)
     {
      Print("Invalid symbol properties for: ",g_symbol);
      return(INIT_FAILED);
     }

   g_atrHandle=iATR(g_symbol,PERIOD_H1,14);
   if(g_atrHandle==INVALID_HANDLE)
     {
      Print("Failed to create ATR handle");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber((long)InpMagicNumber);
   trade.SetDeviationInPoints((ulong)InpSlippagePoints);
   trade.SetTypeFillingBySymbol(g_symbol);

   g_lastBarTime=iTime(g_symbol,PERIOD_H1,0);
   ResetSetup();

   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   switch(reason)
     {
      case REASON_PROGRAM:
      case REASON_REMOVE:
      case REASON_RECOMPILE:
      case REASON_CHARTCHANGE:
      case REASON_CHARTCLOSE:
      case REASON_PARAMETERS:
      case REASON_ACCOUNT:
      case REASON_TEMPLATE:
      case REASON_INITFAILED:
      case REASON_CLOSE:
      default:
         break;
     }

   if(g_atrHandle!=INVALID_HANDLE)
     {
      IndicatorRelease(g_atrHandle);
      g_atrHandle=INVALID_HANDLE;
     }
  }

void OnTick()
  {
   MqlTick tick;
   if(!SymbolInfoTick(g_symbol,tick))
      return;

   if(g_stage==STAGE_BREAK_CONFIRMED && !HasOpenPosition() && IsSessionValid())
     {
      if(ExecuteTrade(g_direction,g_sweepPrice,g_fibZoneLow,g_fibZoneHigh))
        {
         ResetSetup();
        }
     }

   if(!IsNewH1Bar())
      return;

   if(g_stage!=STAGE_NONE)
     {
      g_stageAgeBars++;
      if(g_stageAgeBars>InpSignalExpiryBars)
        {
         ResetSetup();
        }
     }

   if(HasOpenPosition())
     {
      ResetSetup();
      return;
     }

   if(!IsSessionValid())
      return;

   const double atrValue=GetATRValue();
   if(!IsATRValid(atrValue))
      return;

   const int bias=GetDailyBias();
   if(bias==BIAS_NONE)
     {
      if(g_stage==STAGE_SWEEP_DETECTED)
         ResetSetup();
      return;
     }

   if(g_stage!=STAGE_NONE)
     {
      if((g_direction==1 && bias!=BIAS_BULLISH) || (g_direction==-1 && bias!=BIAS_BEARISH))
        {
         ResetSetup();
         return;
        }
     }

   if(g_stage==STAGE_NONE)
     {
      int      direction=0;
      double   sweepPrice=0.0;
      double   structureLevel=0.0;
      datetime sweepTime=0;
      if(DetectLiquiditySweep(bias,direction,sweepPrice,structureLevel,sweepTime))
        {
         g_stage=STAGE_SWEEP_DETECTED;
         g_direction=direction;
         g_sweepPrice=sweepPrice;
         g_structureLevel=structureLevel;
         g_sweepTime=sweepTime;
         g_stageAgeBars=0;
        }
      return;
     }

   if(g_stage==STAGE_SWEEP_DETECTED)
     {
      double   impulseHigh=0.0;
      double   impulseLow=0.0;
      datetime breakTime=0;
      if(DetectStructureBreak(g_direction,g_structureLevel,g_sweepTime,impulseHigh,impulseLow,breakTime))
        {
         double zoneLow=0.0;
         double zoneHigh=0.0;
         if(CalculateFibZone(g_direction,g_sweepPrice,impulseHigh,impulseLow,zoneLow,zoneHigh))
           {
            g_stage=STAGE_BREAK_CONFIRMED;
            g_fibZoneLow=zoneLow;
            g_fibZoneHigh=zoneHigh;
            g_stageAgeBars=0;
            if(IsSessionValid() && !HasOpenPosition())
              {
               if(ExecuteTrade(g_direction,g_sweepPrice,g_fibZoneLow,g_fibZoneHigh))
                  ResetSetup();
              }
           }
         else
           {
            ResetSetup();
           }
        }
     }
  }

int GetDailyBias()
  {
   const double prevOpen=iOpen(g_symbol,PERIOD_D1,1);
   const double prevClose=iClose(g_symbol,PERIOD_D1,1);
   const double prevHigh=iHigh(g_symbol,PERIOD_D1,1);
   const double prevLow=iLow(g_symbol,PERIOD_D1,1);
   if(prevOpen<=0.0 || prevClose<=0.0 || prevHigh<=0.0 || prevLow<=0.0)
      return(BIAS_NONE);

   double currentPrice=0.0;
   if(!SymbolInfoDouble(g_symbol,SYMBOL_BID,currentPrice))
      return(BIAS_NONE);

   const double midpoint=(prevHigh+prevLow)*0.5;

   if(prevClose>prevOpen && currentPrice>midpoint)
      return(BIAS_BULLISH);

   if(prevClose<prevOpen && currentPrice<midpoint)
      return(BIAS_BEARISH);

   return(BIAS_NONE);
  }

bool IsSessionValid()
  {
   MqlDateTime dt;
   if(!TimeToStruct(TimeGMT(),dt))
      return(false);
   const bool london=(dt.hour>=7 && dt.hour<12);
   const bool newyork=(dt.hour>=12 && dt.hour<17);
   return(london || newyork);
  }

bool DetectLiquiditySweep(int bias,int &direction,double &sweepPrice,double &structureLevel,datetime &sweepTime)
  {
   direction=0;
   sweepPrice=0.0;
   structureLevel=0.0;
   sweepTime=0;

   if(Bars(g_symbol,PERIOD_H1)<20)
      return(false);

   const double prevDayHigh=iHigh(g_symbol,PERIOD_D1,1);
   const double prevDayLow=iLow(g_symbol,PERIOD_D1,1);
   if(prevDayHigh<=0.0 || prevDayLow<=0.0)
      return(false);

   const double candleLow=iLow(g_symbol,PERIOD_H1,1);
   const double candleHigh=iHigh(g_symbol,PERIOD_H1,1);
   const double candleClose=iClose(g_symbol,PERIOD_H1,1);
   const datetime candleTime=(datetime)iTime(g_symbol,PERIOD_H1,1);

   if(bias==BIAS_BULLISH && candleLow<prevDayLow && candleClose>prevDayLow)
     {
      direction=1;
      sweepPrice=candleLow;
      sweepTime=candleTime;

      structureLevel=iHigh(g_symbol,PERIOD_H1,2);
      for(int i=3;i<=6;i++)
        {
         const double h=iHigh(g_symbol,PERIOD_H1,i);
         if(h>structureLevel)
            structureLevel=h;
        }
      return(true);
     }

   if(bias==BIAS_BEARISH && candleHigh>prevDayHigh && candleClose<prevDayHigh)
     {
      direction=-1;
      sweepPrice=candleHigh;
      sweepTime=candleTime;

      structureLevel=iLow(g_symbol,PERIOD_H1,2);
      for(int i=3;i<=6;i++)
        {
         const double l=iLow(g_symbol,PERIOD_H1,i);
         if(l<structureLevel)
            structureLevel=l;
        }
      return(true);
     }

   return(false);
  }

bool DetectStructureBreak(int direction,double structureLevel,datetime sweepTime,double &impulseHigh,double &impulseLow,datetime &breakTime)
  {
   impulseHigh=0.0;
   impulseLow=0.0;
   breakTime=0;

   const datetime candleTime=(datetime)iTime(g_symbol,PERIOD_H1,1);
   if(candleTime<=sweepTime)
      return(false);

   const double candleClose=iClose(g_symbol,PERIOD_H1,1);
   if(direction==1 && candleClose>structureLevel)
     {
      impulseHigh=iHigh(g_symbol,PERIOD_H1,1);
      impulseLow=iLow(g_symbol,PERIOD_H1,1);
      breakTime=candleTime;
      return(true);
     }

   if(direction==-1 && candleClose<structureLevel)
     {
      impulseHigh=iHigh(g_symbol,PERIOD_H1,1);
      impulseLow=iLow(g_symbol,PERIOD_H1,1);
      breakTime=candleTime;
      return(true);
     }

   return(false);
  }

bool CalculateFibZone(int direction,double sweepPrice,double impulseHigh,double impulseLow,double &zoneLow,double &zoneHigh)
  {
   zoneLow=0.0;
   zoneHigh=0.0;

   if(direction==1)
     {
      if(impulseHigh<=sweepPrice)
         return(false);

      const double range=impulseHigh-sweepPrice;
      const double fib50=impulseHigh-(range*0.5);
      const double fib618=impulseHigh-(range*0.618);

      zoneLow=MathMin(fib50,fib618);
      zoneHigh=MathMax(fib50,fib618);
      return(zoneHigh>zoneLow);
     }

   if(direction==-1)
     {
      if(sweepPrice<=impulseLow)
         return(false);

      const double range=sweepPrice-impulseLow;
      const double fib50=impulseLow+(range*0.5);
      const double fib618=impulseLow+(range*0.618);

      zoneLow=MathMin(fib50,fib618);
      zoneHigh=MathMax(fib50,fib618);
      return(zoneHigh>zoneLow);
     }

   return(false);
  }

bool ExecuteTrade(int direction,double sweepPrice,double fibZoneLow,double fibZoneHigh)
  {
   if(direction!=1 && direction!=-1)
      return(false);
   if(HasOpenPosition())
      return(false);
   if(!IsSpreadValid())
      return(false);

   const double atrValue=GetATRValue();
   if(!IsATRValid(atrValue))
      return(false);

   MqlTick tick;
   if(!SymbolInfoTick(g_symbol,tick))
      return(false);

   const double zoneLow=MathMin(fibZoneLow,fibZoneHigh);
   const double zoneHigh=MathMax(fibZoneLow,fibZoneHigh);
   const double midPrice=(tick.bid+tick.ask)*0.5;
   const double zoneTolerance=(tick.ask-tick.bid)*0.5;

   if(midPrice<(zoneLow-zoneTolerance) || midPrice>(zoneHigh+zoneTolerance))
      return(false);

   const int stopsLevelPoints=(int)SymbolInfoInteger(g_symbol,SYMBOL_TRADE_STOPS_LEVEL);
   const double minStopDistance=stopsLevelPoints*g_point;
   const double volume=NormalizeVolume(InpLotSize);
   if(volume<=0.0)
      return(false);

   if(direction==1)
     {
      const double entry=tick.ask;
      double sl=sweepPrice-(0.3*atrValue);
      if(entry-sl<minStopDistance)
         sl=entry-minStopDistance;

      const double risk=entry-sl;
      if(risk<=2.0*g_point)
         return(false);

      double tp=entry+(2.0*risk);

      sl=NormalizeDouble(sl,g_digits);
      tp=NormalizeDouble(tp,g_digits);

      if(!trade.Buy(volume,g_symbol,0.0,sl,tp,"PA_MVB_BUY"))
         return(false);

      return(true);
     }

   const double entry=tick.bid;
   double sl=sweepPrice+(0.3*atrValue);
   if(sl-entry<minStopDistance)
      sl=entry+minStopDistance;

   const double risk=sl-entry;
   if(risk<=2.0*g_point)
      return(false);

   double tp=entry-(2.0*risk);

   sl=NormalizeDouble(sl,g_digits);
   tp=NormalizeDouble(tp,g_digits);

   if(!trade.Sell(volume,g_symbol,0.0,sl,tp,"PA_MVB_SELL"))
      return(false);

   return(true);
  }

bool IsNewH1Bar()
  {
   const datetime currentBarTime=(datetime)iTime(g_symbol,PERIOD_H1,0);
   if(currentBarTime==0)
      return(false);

   if(currentBarTime!=g_lastBarTime)
     {
      g_lastBarTime=currentBarTime;
      return(true);
     }

   return(false);
  }

bool HasOpenPosition()
  {
   const int total=PositionsTotal();
   for(int i=total-1;i>=0;i--)
     {
      const ulong ticket=PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;

      const string symbol=PositionGetString(POSITION_SYMBOL);
      const long magic=PositionGetInteger(POSITION_MAGIC);
      if(symbol!="" && magic==(long)InpMagicNumber)
         return(true);
     }
   return(false);
  }

bool IsSpreadValid()
  {
   double ask=0.0;
   double bid=0.0;
   if(!SymbolInfoDouble(g_symbol,SYMBOL_ASK,ask) || !SymbolInfoDouble(g_symbol,SYMBOL_BID,bid))
      return(false);

   if(ask<=0.0 || bid<=0.0 || ask<bid)
      return(false);

   const double spreadPoints=(ask-bid)/g_point;
   return(spreadPoints<=InpMaxSpreadPoints);
  }

double GetATRValue()
  {
   if(g_atrHandle==INVALID_HANDLE)
      return(0.0);

   double atrBuffer[1];
   const int copied=CopyBuffer(g_atrHandle,0,1,1,atrBuffer);
   if(copied!=1)
      return(0.0);

   return(atrBuffer[0]);
  }

bool IsATRValid(double atrValue)
  {
   if(atrValue<=0.0)
      return(false);

   const double atrPoints=atrValue/g_point;
   if(atrPoints<InpMinATRPoints)
      return(false);
   if(atrPoints>InpMaxATRPoints)
      return(false);
   return(true);
  }

double NormalizeVolume(double requestedVolume)
  {
   const double minVolume=SymbolInfoDouble(g_symbol,SYMBOL_VOLUME_MIN);
   const double maxVolume=SymbolInfoDouble(g_symbol,SYMBOL_VOLUME_MAX);
   const double step=SymbolInfoDouble(g_symbol,SYMBOL_VOLUME_STEP);
   if(minVolume<=0.0 || maxVolume<=0.0 || step<=0.0)
      return(0.0);

   double volume=MathMax(minVolume,MathMin(maxVolume,requestedVolume));
   volume=MathFloor((volume/step)+1e-10)*step;
   if(volume<minVolume)
      volume=minVolume;
   if(volume>maxVolume)
      volume=maxVolume;

   const int volumeDigits=VolumeDigitsFromStep(step);
   return(NormalizeDouble(volume,volumeDigits));
  }

int VolumeDigitsFromStep(double step)
  {
   int digits=0;
   while(digits<8)
     {
      const double scaled=step*MathPow(10.0,digits);
      if(MathAbs(scaled-MathRound(scaled))<1e-8)
         break;
      digits++;
     }
   return(digits);
  }

void ResetSetup()
  {
   g_stage=STAGE_NONE;
   g_direction=0;
   g_sweepPrice=0.0;
   g_structureLevel=0.0;
   g_fibZoneLow=0.0;
   g_fibZoneHigh=0.0;
   g_sweepTime=0;
   g_stageAgeBars=0;
  }
