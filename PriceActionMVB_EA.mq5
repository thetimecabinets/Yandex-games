#property strict

#include <Trade/Trade.mqh>

enum DailyBias
{
   BIAS_NONE = 0,
   BIAS_BULL = 1,
   BIAS_BEAR = -1
};

input string InpStrategyName               = "PriceActionMVB";
input double InpLotSize                    = 0.10;
input ulong  InpMagicNumber                = 2026040701;
input int    InpMaxSpreadPoints            = 25;
input int    InpATRPeriod                  = 14;
input double InpMinATRPoints               = 40.0;
input double InpMaxATRPoints               = 400.0;
input double InpATRStopBufferMultiplier    = 0.3;
input double InpRiskReward                 = 2.0;
input int    InpMaxSlippagePoints          = 20;

struct SignalState
{
   bool     active;
   bool     break_confirmed;
   int      direction;
   datetime sweep_time;
   double   sweep_price;
   double   structure_level;
   datetime break_time;
   double   impulse_high;
   double   impulse_low;
   double   fib_low;
   double   fib_high;
};

CTrade trade;
SignalState g_signal;
int g_atr_handle = INVALID_HANDLE;
datetime g_last_h1_bar_time = 0;

int GetDailyBias();
bool IsSessionValid();
bool DetectLiquiditySweep(const int bias, int &direction, double &sweep_price, double &structure_level, datetime &sweep_time);
bool DetectStructureBreak(const int direction, const double structure_level, const datetime sweep_time, double &impulse_high, double &impulse_low, datetime &break_time);
bool CalculateFibZone(const int direction, const double sweep_price, const double impulse_high, const double impulse_low, double &zone_low, double &zone_high);
bool ExecuteTrade(const int direction, const double sweep_price, const double zone_low, const double zone_high);

bool IsNewH1Bar();
void ProcessClosedBar();
void ResetSignal();
bool HasOpenPosition();
bool IsSpreadValid();
double GetATRValue();
bool IsATRValid(const double atr_value);
double NormalizePrice(const double price);

int OnInit()
{
   ResetSignal();

   g_atr_handle = iATR(_Symbol, PERIOD_H1, InpATRPeriod);
   if(g_atr_handle == INVALID_HANDLE)
   {
      Print("Failed to create ATR handle");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber((long)InpMagicNumber);
   trade.SetDeviationInPoints(InpMaxSlippagePoints);

   g_last_h1_bar_time = iTime(_Symbol, PERIOD_H1, 0);

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(g_atr_handle != INVALID_HANDLE)
   {
      IndicatorRelease(g_atr_handle);
      g_atr_handle = INVALID_HANDLE;
   }
}

void OnTick()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   if(IsNewH1Bar())
      ProcessClosedBar();

   if(!g_signal.active || !g_signal.break_confirmed)
      return;

   if(!IsSessionValid())
      return;

   if(HasOpenPosition())
      return;

   const int bias = GetDailyBias();
   if(bias != g_signal.direction)
      return;

   const double trigger_price = tick.bid;
   if(trigger_price < g_signal.fib_low || trigger_price > g_signal.fib_high)
      return;

   ExecuteTrade(g_signal.direction, g_signal.sweep_price, g_signal.fib_low, g_signal.fib_high);
}

int GetDailyBias()
{
   MqlRates previous_day[1];
   if(CopyRates(_Symbol, PERIOD_D1, 1, 1, previous_day) != 1)
      return BIAS_NONE;

   double current_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(current_price <= 0.0)
      current_price = iClose(_Symbol, PERIOD_H1, 0);

   const double midpoint = (previous_day[0].high + previous_day[0].low) * 0.5;

   if(previous_day[0].close > previous_day[0].open && current_price > midpoint)
      return BIAS_BULL;

   if(previous_day[0].close < previous_day[0].open && current_price < midpoint)
      return BIAS_BEAR;

   return BIAS_NONE;
}

bool IsSessionValid()
{
   MqlDateTime utc_time;
   TimeToStruct(TimeGMT(), utc_time);
   return (utc_time.hour >= 7 && utc_time.hour < 17);
}

bool DetectLiquiditySweep(const int bias, int &direction, double &sweep_price, double &structure_level, datetime &sweep_time)
{
   direction = BIAS_NONE;
   sweep_price = 0.0;
   structure_level = 0.0;
   sweep_time = 0;

   if(bias == BIAS_NONE)
      return false;

   MqlRates previous_day[1];
   if(CopyRates(_Symbol, PERIOD_D1, 1, 1, previous_day) != 1)
      return false;

   const double previous_day_high = previous_day[0].high;
   const double previous_day_low = previous_day[0].low;

   const double bar_high = iHigh(_Symbol, PERIOD_H1, 1);
   const double bar_low = iLow(_Symbol, PERIOD_H1, 1);
   const double bar_close = iClose(_Symbol, PERIOD_H1, 1);
   const datetime bar_time = iTime(_Symbol, PERIOD_H1, 1);
   if(bar_high <= 0.0 || bar_low <= 0.0 || bar_close <= 0.0 || bar_time <= 0)
      return false;

   if(bias == BIAS_BULL)
   {
      if(bar_low < previous_day_low && bar_close > previous_day_low)
      {
         double highest_high = iHigh(_Symbol, PERIOD_H1, 2);
         if(highest_high <= 0.0)
            return false;

         for(int shift = 3; shift <= 6; shift++)
         {
            const double candidate_high = iHigh(_Symbol, PERIOD_H1, shift);
            if(candidate_high <= 0.0)
               return false;
            if(candidate_high > highest_high)
               highest_high = candidate_high;
         }

         direction = BIAS_BULL;
         sweep_price = bar_low;
         structure_level = highest_high;
         sweep_time = bar_time;
         return true;
      }
   }
   else if(bias == BIAS_BEAR)
   {
      if(bar_high > previous_day_high && bar_close < previous_day_high)
      {
         double lowest_low = iLow(_Symbol, PERIOD_H1, 2);
         if(lowest_low <= 0.0)
            return false;

         for(int shift = 3; shift <= 6; shift++)
         {
            const double candidate_low = iLow(_Symbol, PERIOD_H1, shift);
            if(candidate_low <= 0.0)
               return false;
            if(candidate_low < lowest_low)
               lowest_low = candidate_low;
         }

         direction = BIAS_BEAR;
         sweep_price = bar_high;
         structure_level = lowest_low;
         sweep_time = bar_time;
         return true;
      }
   }

   return false;
}

bool DetectStructureBreak(const int direction, const double structure_level, const datetime sweep_time, double &impulse_high, double &impulse_low, datetime &break_time)
{
   impulse_high = 0.0;
   impulse_low = 0.0;
   break_time = 0;

   if(direction == BIAS_NONE || structure_level <= 0.0 || sweep_time <= 0)
      return false;

   const datetime bar_time = iTime(_Symbol, PERIOD_H1, 1);
   if(bar_time <= sweep_time)
      return false;

   const double bar_close = iClose(_Symbol, PERIOD_H1, 1);
   const double bar_high = iHigh(_Symbol, PERIOD_H1, 1);
   const double bar_low = iLow(_Symbol, PERIOD_H1, 1);

   if(bar_close <= 0.0 || bar_high <= 0.0 || bar_low <= 0.0)
      return false;

   if(direction == BIAS_BULL && bar_close > structure_level)
   {
      impulse_high = bar_high;
      impulse_low = bar_low;
      break_time = bar_time;
      return true;
   }

   if(direction == BIAS_BEAR && bar_close < structure_level)
   {
      impulse_high = bar_high;
      impulse_low = bar_low;
      break_time = bar_time;
      return true;
   }

   return false;
}

bool CalculateFibZone(const int direction, const double sweep_price, const double impulse_high, const double impulse_low, double &zone_low, double &zone_high)
{
   zone_low = 0.0;
   zone_high = 0.0;

   if(direction == BIAS_BULL)
   {
      const double range = impulse_high - sweep_price;
      if(range <= _Point)
         return false;

      const double fib50 = impulse_high - (range * 0.5);
      const double fib618 = impulse_high - (range * 0.618);
      zone_low = MathMin(fib50, fib618);
      zone_high = MathMax(fib50, fib618);
      return true;
   }

   if(direction == BIAS_BEAR)
   {
      const double range = sweep_price - impulse_low;
      if(range <= _Point)
         return false;

      const double fib50 = impulse_low + (range * 0.5);
      const double fib618 = impulse_low + (range * 0.618);
      zone_low = MathMin(fib50, fib618);
      zone_high = MathMax(fib50, fib618);
      return true;
   }

   return false;
}

bool ExecuteTrade(const int direction, const double sweep_price, const double zone_low, const double zone_high)
{
   if(direction == BIAS_NONE)
      return false;

   if(!IsSpreadValid())
      return false;

   const double atr_value = GetATRValue();
   if(!IsATRValid(atr_value))
      return false;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   const double trigger_price = tick.bid;
   if(trigger_price < zone_low || trigger_price > zone_high)
      return false;

   double entry_price = 0.0;
   double sl = 0.0;
   double tp = 0.0;
   double risk = 0.0;
   const double atr_buffer = InpATRStopBufferMultiplier * atr_value;

   if(direction == BIAS_BULL)
   {
      entry_price = tick.ask;
      sl = sweep_price - atr_buffer;
      risk = entry_price - sl;
      if(risk <= _Point)
         return false;

      tp = entry_price + (InpRiskReward * risk);

      sl = NormalizePrice(sl);
      tp = NormalizePrice(tp);

      if(trade.Buy(InpLotSize, _Symbol, 0.0, sl, tp, InpStrategyName + " BUY"))
      {
         ResetSignal();
         return true;
      }

      return false;
   }

   if(direction == BIAS_BEAR)
   {
      entry_price = tick.bid;
      sl = sweep_price + atr_buffer;
      risk = sl - entry_price;
      if(risk <= _Point)
         return false;

      tp = entry_price - (InpRiskReward * risk);

      sl = NormalizePrice(sl);
      tp = NormalizePrice(tp);

      if(trade.Sell(InpLotSize, _Symbol, 0.0, sl, tp, InpStrategyName + " SELL"))
      {
         ResetSignal();
         return true;
      }

      return false;
   }

   return false;
}

bool IsNewH1Bar()
{
   const datetime current_bar_time = iTime(_Symbol, PERIOD_H1, 0);
   if(current_bar_time <= 0)
      return false;

   if(current_bar_time != g_last_h1_bar_time)
   {
      g_last_h1_bar_time = current_bar_time;
      return true;
   }

   return false;
}

void ProcessClosedBar()
{
   if(!IsSessionValid())
      return;

   const int bias = GetDailyBias();
   if(bias == BIAS_NONE)
   {
      ResetSignal();
      return;
   }

   if(!g_signal.active)
   {
      int direction = BIAS_NONE;
      double sweep_price = 0.0;
      double structure_level = 0.0;
      datetime sweep_time = 0;

      if(DetectLiquiditySweep(bias, direction, sweep_price, structure_level, sweep_time))
      {
         g_signal.active = true;
         g_signal.break_confirmed = false;
         g_signal.direction = direction;
         g_signal.sweep_price = sweep_price;
         g_signal.structure_level = structure_level;
         g_signal.sweep_time = sweep_time;
      }
      return;
   }

   if(g_signal.active && !g_signal.break_confirmed)
   {
      if(bias != g_signal.direction)
      {
         ResetSignal();
         return;
      }

      double impulse_high = 0.0;
      double impulse_low = 0.0;
      datetime break_time = 0;

      if(DetectStructureBreak(g_signal.direction, g_signal.structure_level, g_signal.sweep_time, impulse_high, impulse_low, break_time))
      {
         double fib_low = 0.0;
         double fib_high = 0.0;
         if(CalculateFibZone(g_signal.direction, g_signal.sweep_price, impulse_high, impulse_low, fib_low, fib_high))
         {
            g_signal.break_confirmed = true;
            g_signal.break_time = break_time;
            g_signal.impulse_high = impulse_high;
            g_signal.impulse_low = impulse_low;
            g_signal.fib_low = fib_low;
            g_signal.fib_high = fib_high;
         }
         else
         {
            ResetSignal();
         }
      }
   }
}

void ResetSignal()
{
   g_signal.active = false;
   g_signal.break_confirmed = false;
   g_signal.direction = BIAS_NONE;
   g_signal.sweep_time = 0;
   g_signal.sweep_price = 0.0;
   g_signal.structure_level = 0.0;
   g_signal.break_time = 0;
   g_signal.impulse_high = 0.0;
   g_signal.impulse_low = 0.0;
   g_signal.fib_low = 0.0;
   g_signal.fib_high = 0.0;
}

bool HasOpenPosition()
{
   const int total_positions = PositionsTotal();
   for(int i = total_positions - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      const long magic = PositionGetInteger(POSITION_MAGIC);
      if((ulong)magic == InpMagicNumber)
         return true;
   }

   return false;
}

bool IsSpreadValid()
{
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return false;

   const double spread_points = (ask - bid) / _Point;
   return (spread_points <= InpMaxSpreadPoints);
}

double GetATRValue()
{
   if(g_atr_handle == INVALID_HANDLE)
      return 0.0;

   double atr_buffer[1];
   if(CopyBuffer(g_atr_handle, 0, 1, 1, atr_buffer) != 1)
      return 0.0;

   if(atr_buffer[0] <= 0.0)
      return 0.0;

   return atr_buffer[0];
}

bool IsATRValid(const double atr_value)
{
   if(atr_value <= 0.0)
      return false;

   const double atr_points = atr_value / _Point;
   if(atr_points < InpMinATRPoints)
      return false;
   if(atr_points > InpMaxATRPoints)
      return false;

   return true;
}

double NormalizePrice(const double price)
{
   return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}
