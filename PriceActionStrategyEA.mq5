#property strict
#property version   "1.00"

#include <Trade/Trade.mqh>

enum TradeBias
  {
   BIAS_NONE    = 0,
   BIAS_BULLISH = 1,
   BIAS_BEARISH = -1
  };

input string InpTradeSymbol      = "EURUSD";
input double InpFixedLotSize     = 0.10;
input int    InpMaxSpreadPoints  = 25;
input double InpMinAtrPoints     = 50.0;
input double InpMaxAtrPoints     = 500.0;
input int    InpAtrPeriod        = 14;
input int    InpLookbackBars     = 24;
input ulong  InpMagicNumber      = 24040726;
input int    InpSlippagePoints   = 10;

struct TradeSignal
  {
   bool      is_valid;
   TradeBias bias;
   int       sweep_shift;
   int       break_shift;
   datetime  sweep_time;
   datetime  break_time;
   double    sweep_price;
   double    structure_level;
   double    impulse_price;
   double    fib_low;
   double    fib_high;
   double    stop_loss;
   string    signal_id;
  };

CTrade g_trade;
string g_trade_symbol            = "";
int    g_atr_handle              = INVALID_HANDLE;
string g_last_executed_signal_id = "";

void ResetSignal(TradeSignal &signal)
  {
   signal.is_valid        = false;
   signal.bias            = BIAS_NONE;
   signal.sweep_shift     = -1;
   signal.break_shift     = -1;
   signal.sweep_time      = 0;
   signal.break_time      = 0;
   signal.sweep_price     = 0.0;
   signal.structure_level = 0.0;
   signal.impulse_price   = 0.0;
   signal.fib_low         = 0.0;
   signal.fib_high        = 0.0;
   signal.stop_loss       = 0.0;
   signal.signal_id       = "";
  }

int GetVolumeDigits(const double step)
  {
   int digits = 0;
   double scaled_step = step;

   while(digits < 8 && MathAbs(scaled_step - MathRound(scaled_step)) > 0.0000001)
     {
      scaled_step *= 10.0;
      digits++;
     }

   return digits;
  }

double NormalizeVolume(const double requested_volume)
  {
   double min_volume = SymbolInfoDouble(g_trade_symbol,SYMBOL_VOLUME_MIN);
   double max_volume = SymbolInfoDouble(g_trade_symbol,SYMBOL_VOLUME_MAX);
   double step       = SymbolInfoDouble(g_trade_symbol,SYMBOL_VOLUME_STEP);

   if(min_volume <= 0.0 || max_volume <= 0.0 || step <= 0.0)
      return 0.0;

   double clamped_volume = requested_volume;

   if(clamped_volume < min_volume)
      clamped_volume = min_volume;
   if(clamped_volume > max_volume)
      clamped_volume = max_volume;

   double normalized_volume = MathFloor((clamped_volume / step) + 0.0000001) * step;

   if(normalized_volume < min_volume)
      normalized_volume = min_volume;
   if(normalized_volume > max_volume)
      normalized_volume = max_volume;

   return NormalizeDouble(normalized_volume,GetVolumeDigits(step));
  }

double NormalizePrice(const double price)
  {
   int digits = (int)SymbolInfoInteger(g_trade_symbol,SYMBOL_DIGITS);
   return NormalizeDouble(price,digits);
  }

string BuildSignalId(const TradeBias bias,const datetime sweep_time,const datetime break_time)
  {
   return IntegerToString((int)bias) + "_" + IntegerToString((int)sweep_time) + "_" + IntegerToString((int)break_time);
  }

bool GetAtrValues(double &atr_price,double &atr_points)
  {
   atr_price  = 0.0;
   atr_points = 0.0;

   if(g_atr_handle == INVALID_HANDLE)
      return false;

   double buffer[1];
   if(CopyBuffer(g_atr_handle,0,1,1,buffer) != 1)
      return false;

   double point = SymbolInfoDouble(g_trade_symbol,SYMBOL_POINT);
   if(point <= 0.0 || buffer[0] <= 0.0)
      return false;

   atr_price  = buffer[0];
   atr_points = atr_price / point;
   return true;
  }

double GetCurrentSpreadPoints()
  {
   MqlTick tick;
   if(!SymbolInfoTick(g_trade_symbol,tick))
      return 10000000000.0;

   double point = SymbolInfoDouble(g_trade_symbol,SYMBOL_POINT);
   if(point <= 0.0)
      return 10000000000.0;

   return (tick.ask - tick.bid) / point;
  }

bool HasOpenPosition()
  {
   int total_positions = PositionsTotal();

   for(int index = 0; index < total_positions; index++)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      long magic_number = PositionGetInteger(POSITION_MAGIC);
      if((ulong)magic_number == InpMagicNumber)
         return true;
     }

   return false;
  }

bool IsStopsDistanceValid(const TradeBias bias,const double entry_price,const double stop_loss,const double take_profit)
  {
   double point = SymbolInfoDouble(g_trade_symbol,SYMBOL_POINT);
   if(point <= 0.0)
      return false;

   int stops_level_points = (int)SymbolInfoInteger(g_trade_symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minimum_distance = stops_level_points * point;

   if(bias == BIAS_BULLISH)
      return ((entry_price - stop_loss) > minimum_distance && (take_profit - entry_price) > minimum_distance);

   if(bias == BIAS_BEARISH)
      return ((stop_loss - entry_price) > minimum_distance && (entry_price - take_profit) > minimum_distance);

   return false;
  }

TradeBias GetDailyBias()
  {
   MqlTick tick;
   if(!SymbolInfoTick(g_trade_symbol,tick))
      return BIAS_NONE;

   double previous_open  = iOpen(g_trade_symbol,PERIOD_D1,1);
   double previous_high  = iHigh(g_trade_symbol,PERIOD_D1,1);
   double previous_low   = iLow(g_trade_symbol,PERIOD_D1,1);
   double previous_close = iClose(g_trade_symbol,PERIOD_D1,1);

   if(previous_open == 0.0 || previous_high == 0.0 || previous_low == 0.0 || previous_close == 0.0)
      return BIAS_NONE;

   double midpoint = (previous_high + previous_low) * 0.5;
   double current_price = (tick.bid + tick.ask) * 0.5;

   if(previous_close > previous_open && current_price > midpoint)
      return BIAS_BULLISH;

   if(previous_close < previous_open && current_price < midpoint)
      return BIAS_BEARISH;

   return BIAS_NONE;
  }

bool IsSessionValid()
  {
   MqlDateTime utc_time;
   TimeToStruct(TimeGMT(),utc_time);

   if(utc_time.hour >= 7 && utc_time.hour < 17)
      return true;

   return false;
  }

bool DetectLiquiditySweep(const MqlRates &rates[],const int total_bars,const TradeBias bias,const int sweep_shift,
                          const double previous_day_high,const double previous_day_low,double &sweep_price,datetime &sweep_time)
  {
   if(sweep_shift < 1 || sweep_shift >= total_bars)
      return false;

   if(bias == BIAS_BULLISH)
     {
      if(rates[sweep_shift].low < previous_day_low && rates[sweep_shift].close > previous_day_low)
        {
         sweep_price = rates[sweep_shift].low;
         sweep_time  = rates[sweep_shift].time;
         return true;
        }

      return false;
     }

   if(bias == BIAS_BEARISH)
     {
      if(rates[sweep_shift].high > previous_day_high && rates[sweep_shift].close < previous_day_high)
        {
         sweep_price = rates[sweep_shift].high;
         sweep_time  = rates[sweep_shift].time;
         return true;
        }

      return false;
     }

   return false;
  }

bool DetectStructureBreak(const MqlRates &rates[],const int total_bars,const TradeBias bias,const int sweep_shift,
                          double &structure_level,int &break_shift,double &impulse_price,datetime &break_time)
  {
   if(sweep_shift < 2 || sweep_shift + 5 >= total_bars)
      return false;

   if(bias == BIAS_BULLISH)
     {
      structure_level = rates[sweep_shift + 1].high;
      for(int shift = sweep_shift + 2; shift <= sweep_shift + 5; shift++)
        {
         if(rates[shift].high > structure_level)
            structure_level = rates[shift].high;
        }

      for(int shift = sweep_shift - 1; shift >= 1; shift--)
        {
         if(rates[shift].close > structure_level)
           {
            break_shift   = shift;
            impulse_price = rates[shift].high;
            break_time    = rates[shift].time;
            return true;
           }
        }

      return false;
     }

   if(bias == BIAS_BEARISH)
     {
      structure_level = rates[sweep_shift + 1].low;
      for(int shift = sweep_shift + 2; shift <= sweep_shift + 5; shift++)
        {
         if(rates[shift].low < structure_level)
            structure_level = rates[shift].low;
        }

      for(int shift = sweep_shift - 1; shift >= 1; shift--)
        {
         if(rates[shift].close < structure_level)
           {
            break_shift   = shift;
            impulse_price = rates[shift].low;
            break_time    = rates[shift].time;
            return true;
           }
        }

      return false;
     }

   return false;
  }

bool CalculateFibZone(const TradeBias bias,const double sweep_price,const double impulse_price,const double atr_price,
                      double &fib_low,double &fib_high,double &stop_loss)
  {
   fib_low   = 0.0;
   fib_high  = 0.0;
   stop_loss = 0.0;

   if(atr_price <= 0.0)
      return false;

   if(bias == BIAS_BULLISH)
     {
      double range = impulse_price - sweep_price;
      if(range <= 0.0)
         return false;

      double fib_50  = impulse_price - (range * 0.500);
      double fib_618 = impulse_price - (range * 0.618);

      fib_low   = MathMin(fib_50,fib_618);
      fib_high  = MathMax(fib_50,fib_618);
      stop_loss = sweep_price - (atr_price * 0.3);
      return (stop_loss < fib_low);
     }

   if(bias == BIAS_BEARISH)
     {
      double range = sweep_price - impulse_price;
      if(range <= 0.0)
         return false;

      double fib_50  = impulse_price + (range * 0.500);
      double fib_618 = impulse_price + (range * 0.618);

      fib_low   = MathMin(fib_50,fib_618);
      fib_high  = MathMax(fib_50,fib_618);
      stop_loss = sweep_price + (atr_price * 0.3);
      return (stop_loss > fib_high);
     }

   return false;
  }

bool BuildActiveSignal(const TradeBias bias,const double atr_price,TradeSignal &selected_signal)
  {
   ResetSignal(selected_signal);

   int requested_bars = InpLookbackBars + 16;
   if(requested_bars < 64)
      requested_bars = 64;

   MqlRates rates[];
   ArraySetAsSeries(rates,true);

   int total_bars = CopyRates(g_trade_symbol,PERIOD_H1,0,requested_bars,rates);
   if(total_bars < 12)
      return false;

   double previous_day_high = iHigh(g_trade_symbol,PERIOD_D1,1);
   double previous_day_low  = iLow(g_trade_symbol,PERIOD_D1,1);
   datetime current_day_open = iTime(g_trade_symbol,PERIOD_D1,0);

   if(previous_day_high == 0.0 || previous_day_low == 0.0 || current_day_open == 0)
      return false;

   int current_day_shift = iBarShift(g_trade_symbol,PERIOD_H1,current_day_open,false);
   if(current_day_shift < 1)
      return false;

   int max_sweep_shift = current_day_shift;
   if(max_sweep_shift > InpLookbackBars)
      max_sweep_shift = InpLookbackBars;
   if(max_sweep_shift > total_bars - 6)
      max_sweep_shift = total_bars - 6;
   if(max_sweep_shift < 1)
      return false;

   bool signal_found = false;

   for(int sweep_shift = 1; sweep_shift <= max_sweep_shift; sweep_shift++)
     {
      double sweep_price = 0.0;
      datetime sweep_time = 0;

      if(!DetectLiquiditySweep(rates,total_bars,bias,sweep_shift,previous_day_high,previous_day_low,sweep_price,sweep_time))
         continue;

      double structure_level = 0.0;
      double impulse_price   = 0.0;
      datetime break_time    = 0;
      int break_shift        = -1;

      if(!DetectStructureBreak(rates,total_bars,bias,sweep_shift,structure_level,break_shift,impulse_price,break_time))
         continue;

      double fib_low = 0.0;
      double fib_high = 0.0;
      double stop_loss = 0.0;

      if(!CalculateFibZone(bias,sweep_price,impulse_price,atr_price,fib_low,fib_high,stop_loss))
         continue;

      if(!signal_found || break_shift < selected_signal.break_shift || (break_shift == selected_signal.break_shift && sweep_shift < selected_signal.sweep_shift))
        {
         selected_signal.is_valid        = true;
         selected_signal.bias            = bias;
         selected_signal.sweep_shift     = sweep_shift;
         selected_signal.break_shift     = break_shift;
         selected_signal.sweep_time      = sweep_time;
         selected_signal.break_time      = break_time;
         selected_signal.sweep_price     = sweep_price;
         selected_signal.structure_level = structure_level;
         selected_signal.impulse_price   = impulse_price;
         selected_signal.fib_low         = fib_low;
         selected_signal.fib_high        = fib_high;
         selected_signal.stop_loss       = stop_loss;
         selected_signal.signal_id       = BuildSignalId(bias,sweep_time,break_time);
         signal_found = true;
        }
     }

   return signal_found;
  }

bool ExecuteTrade(const TradeSignal &signal)
  {
   if(!signal.is_valid)
      return false;

   if(!IsSessionValid())
      return false;

   if(HasOpenPosition())
      return false;

   double atr_price = 0.0;
   double atr_points = 0.0;
   if(!GetAtrValues(atr_price,atr_points))
      return false;

   if(atr_price <= 0.0)
      return false;

   if(atr_points < InpMinAtrPoints || atr_points > InpMaxAtrPoints)
      return false;

   double spread_points = GetCurrentSpreadPoints();
   if(spread_points > InpMaxSpreadPoints)
      return false;

   MqlTick tick;
   if(!SymbolInfoTick(g_trade_symbol,tick))
      return false;

   double volume = NormalizeVolume(InpFixedLotSize);
   if(volume <= 0.0)
      return false;

   if(signal.bias == BIAS_BULLISH)
     {
      double entry_price = NormalizePrice(tick.ask);
      if(entry_price < signal.fib_low || entry_price > signal.fib_high)
         return false;

      double stop_loss = NormalizePrice(signal.stop_loss);
      if(entry_price <= stop_loss)
         return false;

      double take_profit = NormalizePrice(entry_price + ((entry_price - stop_loss) * 2.0));
      if(take_profit <= entry_price)
         return false;

      if(!IsStopsDistanceValid(signal.bias,entry_price,stop_loss,take_profit))
         return false;

      bool submitted = g_trade.Buy(volume,g_trade_symbol,0.0,stop_loss,take_profit,"PA_Fib_Buy");
      if(!submitted)
        {
         PrintFormat("Buy order failed. Retcode=%u",g_trade.ResultRetcode());
         return false;
        }

      uint retcode = g_trade.ResultRetcode();
      if(retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED || retcode == TRADE_RETCODE_DONE_PARTIAL)
        {
         g_last_executed_signal_id = signal.signal_id;
         return true;
        }

      PrintFormat("Buy order rejected. Retcode=%u",retcode);
      return false;
     }

   if(signal.bias == BIAS_BEARISH)
     {
      double entry_price = NormalizePrice(tick.bid);
      if(entry_price < signal.fib_low || entry_price > signal.fib_high)
         return false;

      double stop_loss = NormalizePrice(signal.stop_loss);
      if(entry_price >= stop_loss)
         return false;

      double take_profit = NormalizePrice(entry_price - ((stop_loss - entry_price) * 2.0));
      if(take_profit >= entry_price)
         return false;

      if(!IsStopsDistanceValid(signal.bias,entry_price,stop_loss,take_profit))
         return false;

      bool submitted = g_trade.Sell(volume,g_trade_symbol,0.0,stop_loss,take_profit,"PA_Fib_Sell");
      if(!submitted)
        {
         PrintFormat("Sell order failed. Retcode=%u",g_trade.ResultRetcode());
         return false;
        }

      uint retcode = g_trade.ResultRetcode();
      if(retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED || retcode == TRADE_RETCODE_DONE_PARTIAL)
        {
         g_last_executed_signal_id = signal.signal_id;
         return true;
        }

      PrintFormat("Sell order rejected. Retcode=%u",retcode);
      return false;
     }

   return false;
  }

int OnInit()
  {
   if(InpFixedLotSize <= 0.0 || InpAtrPeriod <= 0 || InpLookbackBars < 6 || InpMaxSpreadPoints <= 0)
      return INIT_PARAMETERS_INCORRECT;

   if(InpMinAtrPoints < 0.0 || InpMaxAtrPoints <= 0.0 || InpMaxAtrPoints < InpMinAtrPoints)
      return INIT_PARAMETERS_INCORRECT;

   g_trade_symbol = InpTradeSymbol;
   if(StringLen(g_trade_symbol) == 0)
      g_trade_symbol = _Symbol;

   if(!SymbolSelect(g_trade_symbol,true))
      return INIT_FAILED;

   g_trade.SetExpertMagicNumber((long)InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(g_trade_symbol);

   g_atr_handle = iATR(g_trade_symbol,PERIOD_H1,InpAtrPeriod);
   if(g_atr_handle == INVALID_HANDLE)
      return INIT_FAILED;

   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   (void)reason;

   if(g_atr_handle != INVALID_HANDLE)
     {
      IndicatorRelease(g_atr_handle);
      g_atr_handle = INVALID_HANDLE;
     }
  }

void OnTick()
  {
   TradeBias bias = GetDailyBias();
   if(bias == BIAS_NONE)
      return;

   double atr_price = 0.0;
   double atr_points = 0.0;
   if(!GetAtrValues(atr_price,atr_points))
      return;

   if(atr_points < InpMinAtrPoints || atr_points > InpMaxAtrPoints)
      return;

   TradeSignal signal;
   if(!BuildActiveSignal(bias,atr_price,signal))
      return;

   if(signal.signal_id == g_last_executed_signal_id)
      return;

   ExecuteTrade(signal);
  }
