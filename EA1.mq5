//+------------------------------------------------------------------+
//|                                                   BootcampSafeEA |
//|                      Minimal, risk-bounded MT5 EA (H1 EURUSD)    |
//+------------------------------------------------------------------+
#property copyright "Public domain"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

// ---- Inputs (keep boring) ----
input string InpSymbol            = "EURUSD";   // Trade symbol (set to EURUSD for simplest pass)
input ENUM_TIMEFRAMES InpTF       = PERIOD_H1;  // Timeframe (H1)
input double InpRiskPercent       = 0.25;       // Risk per trade (% of balance)
input int    InpEMATrendPeriod    = 200;        // Trend filter EMA
input int    InpEMAPullbackPeriod = 20;         // Pullback EMA
input int    InpATRPeriod         = 14;         // ATR for SL distance
input double InpSL_ATR_Mult       = 2.0;        // SL = ATR * multiplier
input double InpTP_RR             = 2.0;        // TP = RR * SL
input int    InpCooldownMinutes   = 360;        // Wait after closing a trade
input int    InpMaxSpreadPoints   = 25;         // Max spread (points) to allow entry
input int    InpStartHour         = 8;          // Session start hour (server time)
input int    InpEndHour           = 20;         // Session end hour (server time)
input int    InpRolloverHourStart = 21;         // Skip trading from this hour (server)
input int    InpRolloverHourEnd   = 23;         // Skip trading until this hour (inclusive)
input double InpMinAtrPips        = 8.0;        // Minimum ATR (pips) to allow trading
input int    InpMaxConsecLosses   = 2;          // Pause after this many consecutive losses
input double InpMaxDailyLossPct   = 1.5;        // Daily equity loss cap (% from day start)
input double InpMaxDrawdownPct    = 5.0;        // Max peak-to-valley equity drawdown (%)
input int    InpMaxTradesPerDay   = 2;          // Max trades per day
input int    InpMagic             = 50525;      // Magic number

// ---- Internal state ----
datetime g_last_bar_time = 0;
datetime g_last_close_time = 0;
datetime g_day_anchor = 0;
double   g_day_equity_start = 0.0;
int      g_day_trades = 0;
double   g_equity_high = 0.0;
int      g_consec_losses = 0;
int      g_handleEmaTrend = INVALID_HANDLE;
int      g_handleEmaPull  = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+

// Ensure we act only once per completed bar (no overtrading on ticks)
bool IsNewBar()
{
   datetime t = iTime(InpSymbol, InpTF, 0);
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
   for(int i=0; i<PositionsTotal(); i++)
   {
      if(PositionSelectByIndex(i))
      {
         string sym = PositionGetString(POSITION_SYMBOL);
         long magic = PositionGetInteger(POSITION_MAGIC);
         if(sym == InpSymbol && magic == InpMagic)
            return true;
      }
   }
   return false;
}

double GetATR(int period)
{
   int handle = iATR(InpSymbol, InpTF, period);
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

// Read a value from a prebuilt EMA handle (keeps handles reusable)
double GetEMAHandle(int handle, int shift)
{
   if(handle == INVALID_HANDLE) return 0.0;

   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, shift, 1, buf) < 1)
      return 0.0;
   return buf[0];
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

// Reset daily counters (equity baseline, trade count, loss streak)
void EnsureDayContext()
{
   datetime today = DayAnchor(TimeCurrent());
   if(g_day_anchor != today)
   {
      g_day_anchor = today;
      g_day_equity_start = AccountInfoDouble(ACCOUNT_EQUITY);
      g_day_trades = 0;
      g_consec_losses = 0;
   }
}

// Allow trading only inside defined session window
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

// Skip trading around rollover / swap hours
bool RolloverOk()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(InpRolloverHourStart < 0 || InpRolloverHourStart > 23 || InpRolloverHourEnd < 0 || InpRolloverHourEnd > 23)
      return true;
   if(InpRolloverHourStart <= InpRolloverHourEnd)
      return !(dt.hour >= InpRolloverHourStart && dt.hour <= InpRolloverHourEnd);
   // If start > end (wrap midnight), block outside the allowed window
   return (dt.hour > InpRolloverHourEnd && dt.hour < InpRolloverHourStart);
}

// Basic spread guard
bool SpreadOk()
{
   int spread = (int)SymbolInfoInteger(InpSymbol, SYMBOL_SPREAD);
   return (spread > 0 && spread <= InpMaxSpreadPoints);
}

// Risk-based lot size from % risk and SL distance (price units)
double CalcLotsByRisk(double sl_distance_price)
{
   if(sl_distance_price <= 0) return 0.0;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * (InpRiskPercent / 100.0);

   // Tick value and tick size
   double tick_value = SymbolInfoDouble(InpSymbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(InpSymbol, SYMBOL_TRADE_TICK_SIZE);

   if(tick_value <= 0 || tick_size <= 0) return 0.0;

   // How many ticks is the SL distance?
   double ticks = sl_distance_price / tick_size;
   if(ticks <= 0) return 0.0;

   // Money per 1.0 lot if SL hits:
   double lossPerLot = ticks * tick_value;

   if(lossPerLot <= 0) return 0.0;

   double lots = riskMoney / lossPerLot;

   // Normalize to broker constraints
   double minLot  = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_STEP);

   if(lotStep <= 0) lotStep = 0.01;

   // Clamp
   lots = MathMax(minLot, MathMin(maxLot, lots));

   // Round down to step
   lots = MathFloor(lots / lotStep) * lotStep;

   // Safety: if rounded to 0
   if(lots < minLot) lots = minLot;

   return lots;
}

// Daily loss cap, global drawdown cap, and trades-per-day guard
bool RiskLimitsOk()
{
   EnsureDayContext();

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   g_equity_high = MathMax(g_equity_high, eq);

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

// Enforce cooldown between trades
bool CooldownOk()
{
   if(g_last_close_time == 0) return true;
   return (TimeCurrent() - g_last_close_time) >= (InpCooldownMinutes * 60);
}

// Find last close time for our symbol/magic (supports cooldown)
void UpdateLastCloseTime()
{
   // Look for last close deal for our magic+symbol
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

      if(sym == InpSymbol && magic == InpMagic && entry == DEAL_ENTRY_OUT)
      {
         datetime t = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
         if(t > last) last = t;
         break;
      }
   }
   g_last_close_time = last;
}

// Ensure SL/TP are outside broker minimum distance
bool StopsLevelOk(double entry, double sl, double tp)
{
   int stops_level_points = (int)SymbolInfoInteger(InpSymbol, SYMBOL_TRADE_STOPS_LEVEL);
   double point = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
   double min_dist = stops_level_points * point;
   if(min_dist <= 0) return true; // broker says no restriction

   if(MathAbs(entry - sl) < min_dist) return false;
   if(MathAbs(entry - tp) < min_dist) return false;
   return true;
}

// Require minimum ATR (converted to pips) to avoid dead markets
bool VolatilityOk(double atr_points)
{
   double point = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
   if(point <= 0) return false;
   double pip = point * 10.0;
   if(pip <= 0) return false;
   double atr_pips = atr_points / pip;
   return (atr_pips >= InpMinAtrPips);
}

// Pause trading after too many consecutive losses
bool LossStreakOk()
{
   if(InpMaxConsecLosses > 0 && g_consec_losses >= InpMaxConsecLosses)
      return false;
   return true;
}

//+------------------------------------------------------------------+
//| Entry logic                                                      |
//+------------------------------------------------------------------+
void TryEnter()
{
   // Hard guards
   if(_Period != InpTF) return;
   if(!SpreadOk()) return;
   if(!SessionOk()) return;
    if(!RolloverOk()) return;
   if(!RiskLimitsOk()) return;
   if(!LossStreakOk()) return;
   if(HasOpenPosition()) return;
   UpdateLastCloseTime();
   if(!CooldownOk()) return;

   // Indicators
   double emaTrend0 = GetEMAHandle(g_handleEmaTrend, 0);
   double emaTrend1 = GetEMAHandle(g_handleEmaTrend, 1);
   double emaPull0  = GetEMAHandle(g_handleEmaPull, 0);
   double emaPull1  = GetEMAHandle(g_handleEmaPull, 1);

   if(emaTrend0 == 0 || emaPull0 == 0) return;

   // Prices
   double close0 = iClose(InpSymbol, InpTF, 0);
   double close1 = iClose(InpSymbol, InpTF, 1);

   if(close0 == 0 || close1 == 0) return;

   // Trend direction (simple): price above EMA200 = uptrend, below = downtrend
   bool upTrend   = (close1 > emaTrend1) && (emaTrend0 >= emaTrend1);
   bool downTrend = (close1 < emaTrend1) && (emaTrend0 <= emaTrend1);

   // Pullback trigger: close crosses EMA20 back in trend direction
   bool buySignal  = upTrend   && (close1 < emaPull1) && (close0 > emaPull0);
   bool sellSignal = downTrend && (close1 > emaPull1) && (close0 < emaPull0);

   if(!buySignal && !sellSignal) return;

   // SL distance using ATR
   double atr = GetATR(InpATRPeriod);
   if(atr <= 0) return;
   if(!VolatilityOk(atr)) return;

   double sl_dist = atr * InpSL_ATR_Mult; // price distance

   // Prices for order
   double bid = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   int digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);

   double entry = buySignal ? ask : bid;
   double sl    = buySignal ? (entry - sl_dist) : (entry + sl_dist);
   double tp    = buySignal ? (entry + sl_dist * InpTP_RR) : (entry - sl_dist * InpTP_RR);

   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   // Mandatory: SL must be valid
   if(sl <= 0 || tp <= 0) return;
   if(!StopsLevelOk(entry, sl, tp)) return;

   // Lot size by risk
   double lots = CalcLotsByRisk(MathAbs(entry - sl));
   if(lots <= 0) return;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(20);

   bool ok = false;
   if(buySignal)
      ok = trade.Buy(lots, InpSymbol, entry, sl, tp, "BootcampSafe BUY");
   else if(sellSignal)
      ok = trade.Sell(lots, InpSymbol, entry, sl, tp, "BootcampSafe SELL");

   // If order sent, we’re done.
   if(ok)
      g_day_trades++;
   else
      PrintFormat("Order send failed (buy=%s, sell=%s), last_error=%d",
                  buySignal ? "1" : "0",
                  sellSignal ? "1" : "0",
                  _LastError);
}

//+------------------------------------------------------------------+
//| Expert init / tick                                               |
//+------------------------------------------------------------------+
int OnInit()
{
   // Basic sanity checks and indicator handle setup
   if(!SymbolSelect(InpSymbol, true))
      return(INIT_FAILED);

   g_handleEmaTrend = iMA(InpSymbol, InpTF, InpEMATrendPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_handleEmaPull  = iMA(InpSymbol, InpTF, InpEMAPullbackPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_handleEmaTrend == INVALID_HANDLE || g_handleEmaPull == INVALID_HANDLE)
      return(INIT_FAILED);

   g_last_bar_time = 0;
   g_last_close_time = 0;
   g_day_anchor = DayAnchor(TimeCurrent());
   g_day_equity_start = AccountInfoDouble(ACCOUNT_EQUITY);
   g_day_trades = 0;
   g_equity_high = AccountInfoDouble(ACCOUNT_EQUITY);
   g_consec_losses = 0;
   return(INIT_SUCCEEDED);
}

void OnTick()
{
   // Only act once per new H1 bar to avoid overtrading
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

   if(sym != InpSymbol || magic != InpMagic)
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
}
