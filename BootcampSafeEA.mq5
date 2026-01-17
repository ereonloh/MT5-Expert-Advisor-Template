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
input ENUM_TIMEFRAMES InpTF       = PERIOD_H1;  // Timeframe (H1)
input double InpRiskPercent       = 0.25;       // Risk per trade (% of balance)
input int    InpEMATrendPeriod    = 200;        // Trend filter EMA
input int    InpEMAPullbackPeriod = 20;         // Pullback EMA
input int    InpATRPeriod         = 14;         // ATR for SL distance
input double InpSL_ATR_Mult       = 1.8;        // SL = ATR * multiplier
input double InpTP_RR             = 2.0;        // TP = RR * SL
input int    InpCooldownMinutes   = 240;        // Wait after closing a trade
input int    InpMaxSpreadPoints   = 60;         // Max spread (points)
input int    InpStartHour         = 8;          // Session start hour
input int    InpEndHour           = 20;         // Session end hour
input int    InpRolloverHourStart = 21;         // Skip trading from this hour
input int    InpRolloverHourEnd   = 23;         // Skip trading until this hour
input double InpMinAtrPips        = 7.0;        // Minimum ATR (pips)
input int    InpMaxConsecLosses   = 2;          // Pause after consecutive losses
input double InpMaxDailyLossPct   = 1.5;        // Daily equity loss cap (%)
input double InpMaxDrawdownPct    = 5.0;        // Max drawdown (%)
input int    InpMaxTradesPerDay   = 2;          // Max trades per day
input int    InpInactivityDays    = 12;         // Relax filters after inactivity
input double InpRelaxAtrFactor    = 0.5;        // ATR floor multiplier during relax
input double InpRiskTrimFactor    = 0.6;        // Trim risk factor
input double InpHighVolAtrMult    = 2.5;        // High vol ATR multiplier
input double InpHighSpreadFactor  = 0.9;        // High spread factor
input int    InpEmaTouchPoints    = 5;          // EMA20 touch tolerance (points)
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
int      g_handleEmaPull  = INVALID_HANDLE;

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
   datetime t = iTime(g_symbol, InpTF, 0);
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
   int handle = iATR(g_symbol, InpTF, period);
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

double CalcLotsByLeverageAndRisk(double sl_distance_price)
{
   if(sl_distance_price <= 0) return 0.0;

   // PRIMARY: Leverage-based sizing (1:X means position = X * equity)
   double leverageLots = CalcLotsByLeverage();
   
   // SAFETY CAP: Risk-based maximum (prevent catastrophic loss)
   double maxRiskLots = CalcMaxLotsByRisk(sl_distance_price, 1.0);  // Cap at 1% max risk per trade
   
   // Use leverage-based lots, but cap by max risk
   double lots = MathMin(leverageLots, maxRiskLots);
   
   // Debug: show calculations
   PrintFormat("LOT CALC: Leverage(1:%.0f)=%.4f | MaxRisk(1%%)=%.4f | Using=%.4f",
               InpLeverage, leverageLots, maxRiskLots, lots);

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

//+------------------------------------------------------------------+
//| Entry logic                                                      |
//+------------------------------------------------------------------+
void TryEnter()
{
   if(_Period != InpTF) return;
   if(_Symbol != g_symbol) return;
   if(!SpreadOk()) return;
   if(!SessionOk()) return;
   if(!RolloverOk()) return;
   if(!RiskLimitsOk()) return;
   if(!LossStreakOk()) return;
   if(HasOpenPosition()) return;
   UpdateLastCloseTime();
   if(!CooldownOk()) return;

   // Indicators
   double emaTrend1 = GetEMAHandle(g_handleEmaTrend, 1);
   double emaPull1  = GetEMAHandle(g_handleEmaPull, 1);

   if(emaTrend1 == 0 || emaPull1 == 0) return;

   // Prices (use last closed bar)
   double close1 = iClose(g_symbol, InpTF, 1);
   double low1   = iLow(g_symbol, InpTF, 1);
   double high1  = iHigh(g_symbol, InpTF, 1);

   if(close1 == 0 || low1 == 0 || high1 == 0) return;

   // Trend direction
   bool upTrend   = (close1 > emaTrend1);
   bool downTrend = (close1 < emaTrend1);

   // Pullback trigger: wick touches EMA20 within tolerance
   double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   double emaTouchTol = (point > 0.0 && InpEmaTouchPoints > 0) ? (InpEmaTouchPoints * point) : 0.0;
   
   bool buySignal  = upTrend && (close1 > emaPull1) && (low1 <= emaPull1 + emaTouchTol);
   bool sellSignal = downTrend && (close1 < emaPull1) && (high1 >= emaPull1 - emaTouchTol);

   if(!buySignal && !sellSignal) return;

   // SL distance using ATR
   double atr = GetATR(InpATRPeriod);
   if(atr <= 0) return;
   if(!VolatilityOk(atr)) return;

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
   double lots = CalcLotsByLeverageAndRisk(MathAbs(entry - sl));
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

   g_handleEmaTrend = iMA(g_symbol, InpTF, InpEMATrendPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_handleEmaPull  = iMA(g_symbol, InpTF, InpEMAPullbackPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_handleEmaTrend == INVALID_HANDLE || g_handleEmaPull == INVALID_HANDLE)
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
   GvSet(GvKey("last_trade_time"), (double)g_last_trade_time);
   GvSet(GvKey("day_trades"), (double)g_day_trades);
}
