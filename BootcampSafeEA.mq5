//+------------------------------------------------------------------+
//|                                                   BootcampSafeEA |
//|                      Minimal, risk-bounded MT5 EA (H1 EURUSD)    |
//+------------------------------------------------------------------+
#property copyright "Public domain"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
CTrade trade;
CPositionInfo pos;

// ---- Inputs ----
input string InpSymbol            = "EURUSD";   // Trade symbol
input ENUM_TIMEFRAMES InpTF       = PERIOD_H1;  // Legacy entry timeframe (unused)
input ENUM_TIMEFRAMES InpEntryTF  = PERIOD_H1;  // Entry timeframe
input ENUM_TIMEFRAMES InpBiasTF   = PERIOD_H4;  // Bias timeframe
input double InpRiskPercent       = 0.25;       // Risk per trade (% of balance)
input int    InpEMATrendPeriod    = 200;        // Entry trend filter EMA
input int    InpEmaFastPeriod     = 10;         // Pullback zone fast EMA
input int    InpEmaSlowPeriod     = 30;         // Pullback zone slow EMA
input int    InpDailyEmaPeriod    = 50;         // D1 trend filter EMA
input int    InpBiasEmaPeriod     = 50;         // Bias EMA period (Bias TF)
input int    InpATRPeriod         = 14;         // ATR for SL distance
input double InpSL_ATR_Mult       = 2.0;        // SL = ATR * multiplier
input double InpTP_RR             = 2.0;        // TP = RR * SL
input double InpTrailingAtrMult   = 1.5;        // Trailing stop ATR multiplier
input int    InpCooldownMinutes   = 60;         // Wait after closing a trade
input int    InpMaxSpreadPoints   = 60;         // Max spread (points)
input int    InpStartHour         = 7;          // Session start hour
input int    InpEndHour           = 21;         // Session end hour
input int    InpSessionCloseBufferMinutes = 30; // Close positions before session end
input int    InpRolloverHourStart = 21;         // Skip trading from this hour
input int    InpRolloverHourEnd   = 23;         // Skip trading until this hour
input double InpMinAtrPips        = 5.0;        // Minimum ATR (pips)
input int    InpMaxConsecLosses   = 5;          // Pause after consecutive losses
input double InpMaxDailyLossPct   = 2.0;        // Daily equity loss cap (%)
input double InpMaxDrawdownPct    = 4.0;        // Max drawdown (%)
input int    InpMaxTradesPerDay   = 3;          // Max trades per day
input int    InpInactivityDays    = 12;         // Relax filters after inactivity
input double InpRelaxAtrFactor    = 0.5;        // ATR floor multiplier during relax
input double InpRiskTrimFactor    = 0.9;        // Trim risk factor
input int    InpAtrVolPeriod      = 20;         // ATR lookback for vol filter
input double InpHighVolPauseFactor = 2.0;       // Pause if ATR > avg * factor
input double InpHighVolAtrMult    = 3.5;        // High vol ATR multiplier
input double InpHighSpreadFactor  = 0.9;        // High spread factor
input int    InpEmaTouchPoints    = 5;          // Legacy EMA touch tolerance
input bool   InpUseDailyTrendFilter = false;     // Use D1 EMA trend filter
input bool   InpUseCandleConfirm    = false;     // Require candle confirmation
input bool   InpUseHighVolPause     = false;     // Pause trading on high vol
input bool   InpUseBiasFilter       = true;      // Use Bias TF EMA filter
input bool   InpCloseOnFriday       = true;      // Close positions before weekend
input int    InpFridayCloseHour     = 23;        // Friday market close hour
input int    InpFridayCloseBufferMinutes = 60;   // Minutes before close to exit
input double InpLeverage           = 5.0;        // Position leverage (1:X)
input int    InpMagic             = 50525;      // Magic number

// ---- Internal state ----
string   g_symbol = "";
datetime g_last_bar_time = 0;
datetime g_last_close_time = 0;
datetime g_last_trade_time = 0;
datetime g_day_anchor = 0;
double   g_day_equity_start = 0.0;
int      g_day_trades = 0;
double   g_equity_high = 0.0;
int      g_consec_losses = 0;
int      g_handleEmaTrend = INVALID_HANDLE;
int      g_handleEmaFast  = INVALID_HANDLE;
int      g_handleEmaSlow  = INVALID_HANDLE;
int      g_handleEmaDaily = INVALID_HANDLE;
int      g_handleEmaBias  = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
string ResolveSymbol()
{
   if(InpSymbol == "")
      return _Symbol;
   if(SymbolSelect(InpSymbol, true))
      return InpSymbol;
   if(StringFind(_Symbol, InpSymbol) == 0)
      return _Symbol;

   int total = SymbolsTotal(false);
   for(int i = 0; i < total; i++)
   {
      string name = SymbolName(i, false);
      if(StringFind(name, InpSymbol) == 0)
      {
         SymbolSelect(name, true);
         return name;
      }
   }
   return InpSymbol;
}

string GvKey(const string suffix)
{
   return (string)InpMagic + "_" + suffix;
}

double GvGetOrInit(const string key, double init_value)
{
   if(GlobalVariableCheck(key))
      return GlobalVariableGet(key);
   GlobalVariableSet(key, init_value);
   return init_value;
}

void GvSet(const string key, double value)
{
   GlobalVariableSet(key, value);
}

bool IsNewBar()
{
   datetime t = iTime(g_symbol, InpEntryTF, 0);
   if(t == 0) return false;
   if(t != g_last_bar_time)
   {
      g_last_bar_time = t;
      return true;
   }
   return false;
}

bool HasOpenPosition()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(pos.SelectByIndex(i))
      {
         string sym  = pos.Symbol();
         long   magic = pos.Magic();
         if(sym == g_symbol && magic == InpMagic)
            return true;
      }
   }
   return false;
}

double GetATR(int period)
{
   int handle = iATR(g_symbol, InpEntryTF, period);
   if(handle == INVALID_HANDLE) return 0.0;

   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, 0, 2, buf) < 2)
   {
      IndicatorRelease(handle);
      return 0.0;
   }
   IndicatorRelease(handle);
   return buf[0];
}

double GetEMAHandle(int handle, int shift)
{
   if(handle == INVALID_HANDLE) return 0.0;

   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, shift, 1, buf) < 1)
      return 0.0;
   return buf[0];
}

double GetATRValue(ENUM_TIMEFRAMES tf, int period, int shift)
{
   int handle = iATR(g_symbol, tf, period);
   if(handle == INVALID_HANDLE) return 0.0;

   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, shift, 1, buf) < 1)
   {
      IndicatorRelease(handle);
      return 0.0;
   }
   IndicatorRelease(handle);
   return buf[0];
}

double GetATRAverage(ENUM_TIMEFRAMES tf, int period, int start_shift, int bars)
{
   if(bars <= 0) return 0.0;
   int handle = iATR(g_symbol, tf, period);
   if(handle == INVALID_HANDLE) return 0.0;

   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, start_shift, bars, buf) < bars)
   {
      IndicatorRelease(handle);
      return 0.0;
   }
   IndicatorRelease(handle);

   double sum = 0.0;
   for(int i = 0; i < bars; i++)
      sum += buf[i];
   return sum / bars;
}

datetime DayAnchor(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   return StructToTime(dt);
}

void EnsureDayContext()
{
   datetime today = DayAnchor(TimeCurrent());
   if(g_day_anchor != today)
   {
      g_day_anchor = today;
      g_day_equity_start = AccountInfoDouble(ACCOUNT_EQUITY);
      g_day_trades = 0;
      g_consec_losses = 0;
      GvSet(GvKey("day_anchor"), (double)g_day_anchor);
      GvSet(GvKey("day_equity_start"), g_day_equity_start);
      GvSet(GvKey("day_trades"), (double)g_day_trades);
      GvSet(GvKey("consec_losses"), (double)g_consec_losses);
   }
}

bool InactivityRelax()
{
   if(InpInactivityDays <= 0) return false;
   datetime last = g_last_trade_time;
   if(last == 0) return false;
   double diff_sec = (double)(TimeCurrent() - last);
   double threshold = InpInactivityDays * 24.0 * 3600.0;
   return diff_sec >= threshold;
}

bool SessionOk()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(InpStartHour < 0 || InpStartHour > 23 || InpEndHour < 0 || InpEndHour > 24)
      return false;
   if(dt.hour < InpStartHour || dt.hour >= InpEndHour)
      return false;
   return true;
}

bool RolloverOk()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(InpRolloverHourStart < 0 || InpRolloverHourStart > 23 || InpRolloverHourEnd < 0 || InpRolloverHourEnd > 23)
      return true;
   if(InpRolloverHourStart <= InpRolloverHourEnd)
      return !(dt.hour >= InpRolloverHourStart && dt.hour <= InpRolloverHourEnd);
   return (dt.hour > InpRolloverHourEnd && dt.hour < InpRolloverHourStart);
}

bool SpreadOk()
{
   int spread = (int)SymbolInfoInteger(g_symbol, SYMBOL_SPREAD);
   return (spread >= 0 && spread <= InpMaxSpreadPoints);
}

double CalcLotsByLeverageAndRisk(double sl_distance_price, double maxRiskPct)
{
   if(sl_distance_price <= 0) return 0.0;

   // SAFETY CAP: Risk-based maximum (prevent catastrophic loss)
   double cappedRiskPct = MathMin(maxRiskPct, 1.0); // Enforce 1% hard cap
   double maxRiskLots = CalcMaxLotsByRisk(sl_distance_price, cappedRiskPct);
   
   // Use risk-based lots only (strict 1% cap priority)
   double lots = maxRiskLots;
   
   // Debug: show calculations
   PrintFormat("LOT CALC: MaxRisk(%.2f%%)=%.4f | Using=%.4f",
               cappedRiskPct, maxRiskLots, lots);

   double minLot  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);

   if(lotStep <= 0) lotStep = 0.01;

   lots = MathMax(minLot, MathMin(maxLot, lots));
   lots = MathFloor(lots / lotStep) * lotStep;

   if(lots < minLot) lots = minLot;

   return lots;
}

double CalcMaxLotsByRisk(double sl_distance_price, double maxRiskPct)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * (maxRiskPct / 100.0);

   double tick_value = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tick_value <= 0 || tick_size <= 0) return 0.01;

   double ticks = sl_distance_price / tick_size;
   if(ticks <= 0) return 0.01;

   double lossPerLot = ticks * tick_value;
   if(lossPerLot <= 0) return 0.01;

   return riskMoney / lossPerLot;
}

double CalcLotsByLeverage()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // At 1:X leverage, position value = X * equity
   double targetNotional = equity * InpLeverage;
   
   // Get contract size and price to calculate notional value per lot
   double contractSize = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double price = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   
   if(contractSize <= 0 || price <= 0)
      return SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   
   // Notional value per 1 lot = contractSize * price
   double notionalPer1Lot = contractSize * price;
   
   double lots = targetNotional / notionalPer1Lot;
   
   // Normalize to broker constraints
   double lotStep = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   if(lotStep <= 0) lotStep = 0.01;
   
   lots = MathMin(lots, maxLot);
   lots = MathFloor(lots / lotStep) * lotStep;
   if(lots < minLot) lots = minLot;
   
   return lots;
}

bool RiskLimitsOk()
{
   EnsureDayContext();

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double prev_equity_high = g_equity_high;
   g_equity_high = MathMax(g_equity_high, eq);
   if(g_equity_high != prev_equity_high)
      GvSet(GvKey("equity_high"), g_equity_high);

   if(InpMaxDrawdownPct > 0.0)
   {
      double dd_floor = g_equity_high * (1.0 - InpMaxDrawdownPct / 100.0);
      if(eq <= dd_floor)
         return false;
   }

   if(InpMaxDailyLossPct > 0.0)
   {
      double daily_floor = g_day_equity_start * (1.0 - InpMaxDailyLossPct / 100.0);
      if(eq <= daily_floor)
         return false;
   }

   if(InpMaxTradesPerDay > 0 && g_day_trades >= InpMaxTradesPerDay)
      return false;

   return true;
}

bool CooldownOk()
{
   if(g_last_close_time == 0) return true;
   return (TimeCurrent() - g_last_close_time) >= (InpCooldownMinutes * 60);
}

void UpdateLastCloseTime()
{
   HistorySelect(TimeCurrent() - 7*24*3600, TimeCurrent());

   int deals = HistoryDealsTotal();
   datetime last = g_last_close_time;

   for(int i = deals-1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;

      string sym = HistoryDealGetString(ticket, DEAL_SYMBOL);
      long magic  = (long)HistoryDealGetInteger(ticket, DEAL_MAGIC);
      long entry  = (long)HistoryDealGetInteger(ticket, DEAL_ENTRY);

      if(sym == g_symbol && magic == InpMagic && entry == DEAL_ENTRY_OUT)
      {
         datetime t = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
         if(t > last) last = t;
         break;
      }
   }
   g_last_close_time = last;
}

bool StopsLevelOk(double entry, double sl, double tp)
{
   int stops_level_points = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   double min_dist = stops_level_points * point;
   if(min_dist <= 0) return true;

   if(MathAbs(entry - sl) < min_dist) return false;
   if(MathAbs(entry - tp) < min_dist) return false;
   return true;
}

bool VolatilityOk(double atr_points)
{
   double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   if(point <= 0) return false;
   double pip = point * 10.0;
   if(pip <= 0) return false;
   double atr_pips = atr_points / pip;
   double minAtr = InpMinAtrPips;
   if(InactivityRelax() && InpRelaxAtrFactor > 0)
      minAtr = InpMinAtrPips * InpRelaxAtrFactor;
   return (atr_pips >= minAtr);
}

bool HighVolatilityPause()
{
   if(!InpUseHighVolPause) return false;
   if(InpAtrVolPeriod <= 1 || InpHighVolPauseFactor <= 1.0) return false;
   double atr_now = GetATRValue(PERIOD_D1, InpAtrVolPeriod, 1);
   double atr_avg = GetATRAverage(PERIOD_D1, InpAtrVolPeriod, 1, InpAtrVolPeriod);
   if(atr_now <= 0.0 || atr_avg <= 0.0) return false;
   return (atr_now >= atr_avg * InpHighVolPauseFactor);
}

bool IsBullishEngulfing(int shift)
{
   double open1 = iOpen(g_symbol, InpEntryTF, shift);
   double close1 = iClose(g_symbol, InpEntryTF, shift);
   double open2 = iOpen(g_symbol, InpEntryTF, shift + 1);
   double close2 = iClose(g_symbol, InpEntryTF, shift + 1);
   if(open1 == 0 || close1 == 0 || open2 == 0 || close2 == 0) return false;
   return (close1 > open1 && open2 > close2 && open1 <= close2 && close1 >= open2);
}

bool IsBearishEngulfing(int shift)
{
   double open1 = iOpen(g_symbol, InpEntryTF, shift);
   double close1 = iClose(g_symbol, InpEntryTF, shift);
   double open2 = iOpen(g_symbol, InpEntryTF, shift + 1);
   double close2 = iClose(g_symbol, InpEntryTF, shift + 1);
   if(open1 == 0 || close1 == 0 || open2 == 0 || close2 == 0) return false;
   return (close1 < open1 && open2 < close2 && open1 >= close2 && close1 <= open2);
}

bool IsBullishPinBar(int shift)
{
   double open1 = iOpen(g_symbol, InpEntryTF, shift);
   double close1 = iClose(g_symbol, InpEntryTF, shift);
   double high1 = iHigh(g_symbol, InpEntryTF, shift);
   double low1 = iLow(g_symbol, InpEntryTF, shift);
   if(open1 == 0 || close1 == 0 || high1 == 0 || low1 == 0) return false;
   double body = MathAbs(close1 - open1);
   double upper = high1 - MathMax(open1, close1);
   double lower = MathMin(open1, close1) - low1;
   if(body <= 0) return false;
   return (close1 > open1 && lower >= body * 2.0 && upper <= body);
}

bool IsBearishPinBar(int shift)
{
   double open1 = iOpen(g_symbol, InpEntryTF, shift);
   double close1 = iClose(g_symbol, InpEntryTF, shift);
   double high1 = iHigh(g_symbol, InpEntryTF, shift);
   double low1 = iLow(g_symbol, InpEntryTF, shift);
   if(open1 == 0 || close1 == 0 || high1 == 0 || low1 == 0) return false;
   double body = MathAbs(close1 - open1);
   double upper = high1 - MathMax(open1, close1);
   double lower = MathMin(open1, close1) - low1;
   if(body <= 0) return false;
   return (close1 < open1 && upper >= body * 2.0 && lower <= body);
}

bool BullishConfirm(int shift)
{
   return IsBullishEngulfing(shift) || IsBullishPinBar(shift);
}

bool BearishConfirm(int shift)
{
   return IsBearishEngulfing(shift) || IsBearishPinBar(shift);
}

double AdjustRiskPercent(double spread_points, double atr_points)
{
   double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   if(point <= 0) return InpRiskPercent;

   double pip = point * 10.0;
   double atr_pips = atr_points / pip;

   bool highSpread = (spread_points > InpMaxSpreadPoints * InpHighSpreadFactor);
   bool highVol    = (atr_pips >= InpMinAtrPips * InpHighVolAtrMult);

   if((highSpread || highVol) && InpRiskTrimFactor > 0.0)
      return InpRiskPercent * InpRiskTrimFactor;

   return InpRiskPercent;
}

bool LossStreakOk()
{
   if(InpMaxConsecLosses > 0 && g_consec_losses >= InpMaxConsecLosses)
      return false;
   return true;
}

bool ShouldCloseBeforeSessionEnd()
{
   if(InpSessionCloseBufferMinutes <= 0) return false;
   if(InpEndHour < 0 || InpEndHour > 24) return false;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int minutesNow = dt.hour * 60 + dt.min;
   int endMinutes = InpEndHour * 60;
   return (minutesNow >= (endMinutes - InpSessionCloseBufferMinutes) && minutesNow < endMinutes);
}

bool ShouldCloseOnFriday()
{
   if(!InpCloseOnFriday) return false;
   if(InpFridayCloseBufferMinutes <= 0) return false;
   if(InpFridayCloseHour < 0 || InpFridayCloseHour > 23) return false;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week != 5) return false; // Friday

   int minutesNow = dt.hour * 60 + dt.min;
   int closeMinutes = InpFridayCloseHour * 60;
   return (minutesNow >= (closeMinutes - InpFridayCloseBufferMinutes) && minutesNow < closeMinutes);
}

void ClosePositionsBeforeSessionEnd()
{
   if(!ShouldCloseBeforeSessionEnd()) return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i))
         continue;
      if(pos.Symbol() != g_symbol || pos.Magic() != InpMagic)
         continue;
      trade.PositionClose(pos.Ticket());
   }
}

void ClosePositionsBeforeFridayClose()
{
   if(!ShouldCloseOnFriday()) return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i))
         continue;
      if(pos.Symbol() != g_symbol || pos.Magic() != InpMagic)
         continue;
      trade.PositionClose(pos.Ticket());
   }
}

void ApplyTrailingStops()
{
   if(InpTrailingAtrMult <= 0.0) return;
   double atr = GetATR(InpATRPeriod);
   if(atr <= 0.0) return;

   double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   int stops_level_points = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double min_dist = stops_level_points * point;

   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i))
         continue;
      if(pos.Symbol() != g_symbol || pos.Magic() != InpMagic)
         continue;

      double entry = pos.PriceOpen();
      double orig_dist = 0.0;
      if(GlobalVariableCheck(GvKey("orig_sl_dist")))
         orig_dist = GlobalVariableGet(GvKey("orig_sl_dist"));

      double sl = pos.StopLoss();
      double tp = pos.TakeProfit();
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)pos.PositionType();

      if(type == POSITION_TYPE_BUY)
      {
         double new_sl = NormalizeDouble(bid - atr * InpTrailingAtrMult, digits);
         if(new_sl <= 0.0) continue;
         if((bid - new_sl) < min_dist) continue;
         if(orig_dist > 0.0)
         {
            double max_sl = NormalizeDouble(entry - orig_dist, digits);
            if(new_sl < max_sl)
               new_sl = max_sl;
         }
         if(sl == 0.0 || new_sl > sl + point)
            trade.PositionModify(pos.Ticket(), new_sl, tp);
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double new_sl = NormalizeDouble(ask + atr * InpTrailingAtrMult, digits);
         if(new_sl <= 0.0) continue;
         if((new_sl - ask) < min_dist) continue;
         if(orig_dist > 0.0)
         {
            double max_sl = NormalizeDouble(entry + orig_dist, digits);
            if(new_sl > max_sl)
               new_sl = max_sl;
         }
         if(sl == 0.0 || new_sl < sl - point)
            trade.PositionModify(pos.Ticket(), new_sl, tp);
      }
   }
}

void ManageOpenPositions()
{
   ClosePositionsBeforeFridayClose();
   ClosePositionsBeforeSessionEnd();
   ApplyTrailingStops();
}

//+------------------------------------------------------------------+
//| Entry logic                                                      |
//+------------------------------------------------------------------+
void TryEnter()
{
   if(_Period != InpEntryTF) return;
   if(_Symbol != g_symbol) return;
   if(!SpreadOk()) return;
   if(!SessionOk()) return;
   if(!RolloverOk()) return;
   if(!RiskLimitsOk()) return;
   if(!LossStreakOk()) return;
   if(HighVolatilityPause()) return;
   if(HasOpenPosition()) return;
   UpdateLastCloseTime();
   if(!CooldownOk()) return;

   // Indicators
   double emaTrend1 = GetEMAHandle(g_handleEmaTrend, 1);
   double emaFast1  = GetEMAHandle(g_handleEmaFast, 1);
   double emaSlow1  = GetEMAHandle(g_handleEmaSlow, 1);
   double emaDaily1 = GetEMAHandle(g_handleEmaDaily, 1);
   double emaBias1  = GetEMAHandle(g_handleEmaBias, 1);

   if(emaTrend1 == 0 || emaFast1 == 0 || emaSlow1 == 0) return;

   // Prices (use last closed bar)
   double close1 = iClose(g_symbol, InpEntryTF, 1);
   double open1  = iOpen(g_symbol, InpEntryTF, 1);
   double low1   = iLow(g_symbol, InpEntryTF, 1);
   double high1  = iHigh(g_symbol, InpEntryTF, 1);
   double dailyClose1 = iClose(g_symbol, PERIOD_D1, 1);
   double biasClose1  = iClose(g_symbol, InpBiasTF, 1);

   if(close1 == 0 || open1 == 0 || low1 == 0 || high1 == 0) return;
   if(InpUseDailyTrendFilter && (dailyClose1 == 0 || emaDaily1 == 0)) return;
   if(InpUseBiasFilter && (biasClose1 == 0 || emaBias1 == 0)) return;

   // Trend direction
   bool dailyUp   = (!InpUseDailyTrendFilter || dailyClose1 > emaDaily1);
   bool dailyDown = (!InpUseDailyTrendFilter || dailyClose1 < emaDaily1);
   bool biasUp    = (!InpUseBiasFilter || biasClose1 > emaBias1);
   bool biasDown  = (!InpUseBiasFilter || biasClose1 < emaBias1);
   bool upTrend   = (close1 > emaTrend1 && dailyUp && biasUp);
   bool downTrend = (close1 < emaTrend1 && dailyDown && biasDown);

   // Pullback zone between EMA10 and EMA30 + candle confirmation
   double zoneLow = MathMin(emaFast1, emaSlow1);
   double zoneHigh = MathMax(emaFast1, emaSlow1);
   bool inZone = (low1 <= zoneHigh && high1 >= zoneLow);
   bool bullishBias = (close1 > open1) && (close1 > emaFast1);
   bool bearishBias = (close1 < open1) && (close1 < emaFast1);
   bool bullConfirmOk = (BullishConfirm(1) || bullishBias);
   bool bearConfirmOk = (BearishConfirm(1) || bearishBias);
   if(!InpUseCandleConfirm)
   {
      bullConfirmOk = true;
      bearConfirmOk = true;
   }
   bool buySignal  = upTrend && inZone && bullConfirmOk;
   bool sellSignal = downTrend && inZone && bearConfirmOk;

   if(!buySignal && !sellSignal) return;

   // SL distance using ATR
   double atr = GetATR(InpATRPeriod);
   if(atr <= 0) return;
   if(!VolatilityOk(atr)) return;

   int spread_points = (int)SymbolInfoInteger(g_symbol, SYMBOL_SPREAD);
   double dynRiskPct = AdjustRiskPercent((double)spread_points, atr);

   double sl_dist = atr * InpSL_ATR_Mult;

   // Prices for order
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   int digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);

   double entry = buySignal ? ask : bid;
   double sl    = buySignal ? (entry - sl_dist) : (entry + sl_dist);
   double tp    = buySignal ? (entry + sl_dist * InpTP_RR) : (entry - sl_dist * InpTP_RR);

   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   if(sl <= 0 || tp <= 0) return;
   if(!StopsLevelOk(entry, sl, tp)) return;

   // Lot size by leverage (with risk cap)
   double lots = CalcLotsByLeverageAndRisk(MathAbs(entry - sl), dynRiskPct);
   if(lots <= 0) return;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(20);

   bool ok = false;
   if(buySignal)
      ok = trade.Buy(lots, g_symbol, entry, sl, tp, "BootcampSafe BUY");
   else if(sellSignal)
      ok = trade.Sell(lots, g_symbol, entry, sl, tp, "BootcampSafe SELL");

   if(ok)
   {
      g_day_trades++;
      g_last_trade_time = TimeCurrent();
      GvSet(GvKey("orig_sl_dist"), MathAbs(entry - sl));
      GvSet(GvKey("day_trades"), (double)g_day_trades);
      GvSet(GvKey("last_trade_time"), (double)g_last_trade_time);
   }
}

//+------------------------------------------------------------------+
//| Expert init / tick                                               |
//+------------------------------------------------------------------+
int OnInit()
{
   g_symbol = ResolveSymbol();
   if(!SymbolSelect(g_symbol, true))
      return(INIT_FAILED);

   g_handleEmaTrend = iMA(g_symbol, InpEntryTF, InpEMATrendPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_handleEmaFast  = iMA(g_symbol, InpEntryTF, InpEmaFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_handleEmaSlow  = iMA(g_symbol, InpEntryTF, InpEmaSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_handleEmaDaily = iMA(g_symbol, PERIOD_D1, InpDailyEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_handleEmaBias  = iMA(g_symbol, InpBiasTF, InpBiasEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_handleEmaTrend == INVALID_HANDLE || g_handleEmaFast == INVALID_HANDLE ||
      g_handleEmaSlow == INVALID_HANDLE || g_handleEmaDaily == INVALID_HANDLE ||
      g_handleEmaBias == INVALID_HANDLE)
      return(INIT_FAILED);

   g_last_bar_time = 0;
   g_last_close_time = 0;
   g_day_anchor = (datetime)GvGetOrInit(GvKey("day_anchor"), (double)DayAnchor(TimeCurrent()));
   g_day_equity_start = GvGetOrInit(GvKey("day_equity_start"), AccountInfoDouble(ACCOUNT_EQUITY));
   g_day_trades = (int)GvGetOrInit(GvKey("day_trades"), 0.0);
   g_equity_high = GvGetOrInit(GvKey("equity_high"), AccountInfoDouble(ACCOUNT_EQUITY));
   g_consec_losses = (int)GvGetOrInit(GvKey("consec_losses"), 0.0);
   g_last_trade_time = (datetime)GvGetOrInit(GvKey("last_trade_time"), 0.0);
   return(INIT_SUCCEEDED);
}

void OnTick()
{
   ManageOpenPositions();
   if(!IsNewBar()) return;
   TryEnter();
}

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest&     request,
                        const MqlTradeResult&      result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   ulong deal = trans.deal;
   if(deal == 0)
      return;

   string sym = HistoryDealGetString(deal, DEAL_SYMBOL);
   long   magic = HistoryDealGetInteger(deal, DEAL_MAGIC);
   long   entry = HistoryDealGetInteger(deal, DEAL_ENTRY);

   if(sym != g_symbol || magic != InpMagic)
      return;

   if(entry != DEAL_ENTRY_OUT)
      return;

   double profit = HistoryDealGetDouble(deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(deal, DEAL_SWAP)
                 + HistoryDealGetDouble(deal, DEAL_COMMISSION);

   if(profit < 0)
      g_consec_losses++;
   else
      g_consec_losses = 0;

   datetime t = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
   if(t > g_last_close_time)
      g_last_close_time = t;
   g_last_trade_time = t;
   GvSet(GvKey("consec_losses"), (double)g_consec_losses);
   GvSet(GvKey("orig_sl_dist"), 0.0);
   GvSet(GvKey("last_trade_time"), (double)g_last_trade_time);
   GvSet(GvKey("day_trades"), (double)g_day_trades);
}
