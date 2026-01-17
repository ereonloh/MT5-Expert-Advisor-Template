//+------------------------------------------------------------------+
//|                                              PropPullback_v2.mq5 |
//|   IC Markets Raw Spread optimized (EMA200/20, 0.25% risk, H1)    |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

//--- Inputs
input double   InpRiskPerTrade   = 0.25;     // Risk per Trade (%)
input int      InpFastEMA        = 20;       // Entry EMA (Signal)
input int      InpSlowEMA        = 200;      // Trend EMA (Filter)
input int      InpStopLossPips   = 15;       // Hard SL in pips (15.0 pips)
input int      InpTakeProfitPips = 30;       // TP in pips (30.0 pips)
input int      InpStartHour      = 8;        // Session start (server)
input int      InpEndHour        = 20;       // Session end (server)
input int      InpMagicNum       = 123456;   // Unique ID for Trades
input double   InpMaxSlippage    = 3.0;      // Max slippage (pips)
input double   InpSpreadMult     = 1.5;      // Spread must be < avg(3) * this
input double   InpMaxSpreadPips  = 2.5;      // Absolute max spread allowed (pips)
input int      InpRolloverHourStart = 22;    // Skip trading from this hour (server)
input int      InpRolloverHourEnd   = 23;    // Skip trading until this hour (inclusive)
input int      InpMaxTradesPerDay   = 2;     // Max trades per day (0 = unlimited)
input int      InpMaxConsecLosses   = 2;     // Pause after this many consecutive losses (0 = off)
input int      InpCooldownMinutes   = 0;     // Cooldown after a close (0 = none)

CTrade         trade;
CPositionInfo  pos;

int handleFast, handleSlow;

// Spread stats
double g_spread_hist[3] = {0,0,0};
int    g_spread_idx = 0;
bool   g_spread_filled = false;
datetime g_day_anchor = 0;
int      g_day_trades = 0;
int      g_consec_losses = 0;
datetime g_last_close_time = 0;

// Pip & slippage utilities
// Pip size (price units per pip) for 3/4/5-digit symbols
double PipPoints()
{
   return ((_Digits == 3 || _Digits == 5) ? 10.0 * _Point : _Point);
}

// Ensure SL/TP respect broker minimum distance
bool StopsLevelOk(double entry, double sl, double tp)
{
   int stops = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minDist = stops * point;
   if(minDist <= 0) return true; // no restriction
   if(MathAbs(entry - sl) < minDist) return false;
   if(MathAbs(entry - tp) < minDist) return false;
   return true;
}

double SlippagePoints()
{
   double pipPoints = PipPoints();
   return(InpMaxSlippage * pipPoints / _Point);
}

void UpdateSpreadStats()
{
   int spreadPts = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   g_spread_hist[g_spread_idx] = spreadPts;
   g_spread_idx = (g_spread_idx + 1) % 3;
   if(g_spread_idx == 0) g_spread_filled = true;
}

bool SpreadOk()
{
   if(!g_spread_filled) return false; // need 3 samples
   double sum = g_spread_hist[0] + g_spread_hist[1] + g_spread_hist[2];
   double avg = sum / 3.0;
   int cur = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double maxSpreadPts = InpMaxSpreadPips * PipPoints() / _Point;
   if(cur <= 0) return false;
   if(cur > maxSpreadPts) return false;
   return cur < avg * InpSpreadMult;
}

bool SessionOk()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   return (dt.hour >= InpStartHour && dt.hour < InpEndHour);
}

// Rollover/illiquid-hour skip
bool RolloverOk()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(InpRolloverHourStart < 0 || InpRolloverHourStart > 23 || InpRolloverHourEnd < 0 || InpRolloverHourEnd > 23)
      return true;
   if(InpRolloverHourStart <= InpRolloverHourEnd)
      return !(dt.hour >= InpRolloverHourStart && dt.hour <= InpRolloverHourEnd);
   // wrap-around case
   return (dt.hour > InpRolloverHourEnd && dt.hour < InpRolloverHourStart);
}

// New-bar guard to prevent multi-fires within a candle
bool IsNewBar()
{
   datetime t = iTime(_Symbol, _Period, 0);
   static datetime last = 0;
   if(t == 0) return false;
   if(t != last)
   {
      last = t;
      return true;
   }
   return false;
}

bool PositionExists()
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(pos.SelectByIndex(i) && pos.Magic() == InpMagicNum && pos.Symbol() == _Symbol)
         return true;
   }
   return false;
}

// Require EMA200 to have a modest slope to confirm trend (avoid flat filters)
bool TrendOk(const double emaS[])
{
   // emaS[0]=current, emaS[1]=prev, emaS[2]=prev2 (already copied)
   double slopeUp   = emaS[0] - emaS[2];
   double slopeDown = emaS[2] - emaS[0];
   double minSlope = 0.5 * PipPoints(); // 0.5 pip over 2 bars
   bool up   = (emaS[1] < emaS[0]) && (slopeUp >= minSlope);
   bool down = (emaS[1] > emaS[0]) && (slopeDown >= minSlope);
   return (up || down);
}

datetime DayAnchor(datetime t)
{
   MqlDateTime dt; TimeToStruct(t, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
}

void EnsureDayContext()
{
   datetime today = DayAnchor(TimeCurrent());
   if(g_day_anchor != today)
   {
      g_day_anchor = today;
      g_day_trades = 0;
      g_consec_losses = 0;
   }
}

bool TradesPerDayOk()
{
   if(InpMaxTradesPerDay <= 0) return true;
   return g_day_trades < InpMaxTradesPerDay;
}

bool LossStreakOk()
{
   if(InpMaxConsecLosses <= 0) return true;
   return g_consec_losses < InpMaxConsecLosses;
}

bool CooldownOk()
{
   if(InpCooldownMinutes <= 0) return true;
   if(g_last_close_time == 0) return true;
   return (TimeCurrent() - g_last_close_time) >= (InpCooldownMinutes * 60);
}

int OnInit()
{
   if(!SymbolSelect(_Symbol, true))
      return(INIT_FAILED);

   handleFast = iMA(_Symbol, _Period, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   handleSlow = iMA(_Symbol, _Period, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);

   if(handleFast == INVALID_HANDLE || handleSlow == INVALID_HANDLE)
      return(INIT_FAILED);

   trade.SetExpertMagicNumber(InpMagicNum);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   return(INIT_SUCCEEDED);
}

void OnTick()
{
   uint tickStart = GetTickCount();
   UpdateSpreadStats();

   // Avoid multiple entries per bar
   if(!IsNewBar()) return;

   if(!SessionOk()) return;
   if(!RolloverOk()) return;
   EnsureDayContext();
   if(!TradesPerDayOk()) return;
   if(!LossStreakOk()) return;
   if(!CooldownOk()) return;
   if(PositionExists()) { ManageBreakeven(); return; }

   double emaF[], emaS[], close[];
   ArraySetAsSeries(emaF, true);
   ArraySetAsSeries(emaS, true);
   ArraySetAsSeries(close, true);

   if(CopyBuffer(handleFast, 0, 0, 3, emaF) < 3) return;
   if(CopyBuffer(handleSlow, 0, 0, 3, emaS) < 3) return;
   if(CopyClose(_Symbol, _Period, 0, 3, close) < 3) return;

   if(!SpreadOk()) return;

   bool isUptrend  = (close[1] > emaS[1]);
   bool isDowntrend = (close[1] < emaS[1]);
   if(!TrendOk(emaS)) return;

   bool buySignal  = isUptrend  && close[1] <= emaF[1] && close[2] > emaF[2];
   bool sellSignal = isDowntrend && close[1] >= emaF[1] && close[2] < emaF[2];

   if(!buySignal && !sellSignal) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return;

   double pipPoints = PipPoints();
   double slDist = InpStopLossPips * pipPoints;
   double tpDist = InpTakeProfitPips * pipPoints;

   double entry = buySignal ? ask : bid;
   double sl    = buySignal ? (entry - slDist) : (entry + slDist);
   double tp    = buySignal ? (entry + tpDist) : (entry - tpDist);

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   if(!StopsLevelOk(entry, sl, tp)) return;

   double lots = CalcLotsByRisk(slDist);
   if(lots <= 0) return;

   trade.SetDeviationInPoints((int)SlippagePoints());

   int curSpread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   uint preSend = GetTickCount();
   PrintFormat("Attempting order | buy=%s sell=%s | Ask=%.5f Bid=%.5f | Spread=%d pts | SlippagePts=%.1f | TickDelay=%ums",
               buySignal ? "1" : "0",
               sellSignal ? "1" : "0",
               ask, bid, curSpread, SlippagePoints(), (preSend - tickStart));

   bool ok = false;
   if(buySignal)
      ok = trade.Buy(lots, _Symbol, 0.0, sl, tp, "Pullback BUY");   // use 0.0 to fill at market
   else if(sellSignal)
      ok = trade.Sell(lots, _Symbol, 0.0, sl, tp, "Pullback SELL"); // use 0.0 to fill at market

   uint postSend = GetTickCount();
   PrintFormat("Order result ok=%s | last_error=%d | sendLatency=%ums",
               ok ? "1" : "0",
               _LastError,
               (postSend - preSend));

   if(ok)
      g_day_trades++;
}

// Lot size from % risk and SL distance (price units)
double CalcLotsByRisk(double sl_distance_price)
{
   if(sl_distance_price <= 0) return 0.0;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * (InpRiskPerTrade / 100.0);

   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tick_value <= 0 || tick_size <= 0) return 0.0;

   double ticks = sl_distance_price / tick_size;
   if(ticks <= 0) return 0.0;

   double lossPerLot = ticks * tick_value;
   if(lossPerLot <= 0) return 0.0;

   double lots = riskMoney / lossPerLot;

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep <= 0) lotStep = 0.01;

   lots = MathMax(minLot, MathMin(maxLot, lots));
   lots = MathFloor(lots / lotStep) * lotStep;
   if(lots < minLot) lots = minLot;

   return lots;
}

// Track loss streak and last close time
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

   if(sym != _Symbol || magic != InpMagicNum)
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

// Break-even manager: move SL to entry + 0.5 pip when 1R is reached
void ManageBreakeven()
{
   double pipPoints = PipPoints();
   double beOffset = 0.5 * pipPoints;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
       if(!pos.SelectByIndex(i)) continue;
       if(pos.Magic() != InpMagicNum || pos.Symbol() != _Symbol) continue;

       double entry = pos.PriceOpen();
       double sl    = pos.SL();
       double tp    = pos.TP();
       long   type  = pos.PositionType();

       double riskDist = MathAbs(entry - sl);
       if(riskDist <= 0) continue;

       double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
       double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
       double current = (type == POSITION_TYPE_BUY) ? bid : ask;

       // Has price reached 1R?
       if(MathAbs(current - entry) < riskDist) continue;

       double newSL = sl;
       if(type == POSITION_TYPE_BUY)
          newSL = entry + beOffset;
       else
          newSL = entry - beOffset;

       // Do not move SL past TP
       if(type == POSITION_TYPE_BUY && newSL >= tp) continue;
       if(type == POSITION_TYPE_SELL && newSL <= tp) continue;

       int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
       newSL = NormalizeDouble(newSL, digits);

       if(trade.PositionModify(_Symbol, newSL, tp))
       {
          PrintFormat("BREAKEVEN: moved SL to %.5f (entry=%.5f, tp=%.5f)", newSL, entry, tp);
       }
       else
       {
          PrintFormat("BREAKEVEN FAILED: last_error=%d", _LastError);
       }
   }
}

void OnDeinit(const int)
{
   if(handleFast != INVALID_HANDLE) IndicatorRelease(handleFast);
   if(handleSlow != INVALID_HANDLE) IndicatorRelease(handleSlow);
}
