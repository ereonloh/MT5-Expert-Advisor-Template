ICmarketEA (PropPullback_v2 for IC Markets Raw)
==============================================

Overview
--------
PropPullback_v2 is an H1 EMA200/EMA20 pullback EA tuned for IC Markets Raw. It keeps risk small (base 0.25%/trade), uses controlled leverage with a 1% risk cap, IOC market execution, slippage limits, a dynamic spread filter, and a simple breakeven step. One position max per symbol/magic; no martingale/grid/arb; visible SL/TP.

Key logic
- Trend + trigger: EMA200 filter, EMA20 pullback cross.
- SL/TP: fixed pip distances (inputs, now 15/30 pips by default); lots sized by controlled leverage and quality scoring, capped at 1% risk. Uses correct pip sizing for 3/4/5-digit symbols.
- Execution: IOC fill, slippage capped via input; dynamic spread guard uses 3-sample avg * multiplier.
- Breakeven: at 1R, SL moves to entry +0.5 pip.
- New-bar only: avoids multiple entries per bar.
- Guardrails: session window plus rollover skip; trades/day cap (default 2), loss-streak pause (default 2), cooldown after a close, daily loss cap (2%).
- Added safety: absolute max spread cap (pips) and EMA200 slope check to avoid trading in flat trend conditions.

Inputs
- Risk: `InpRiskPerTrade` (default 0.25%).
- Trend/trigger: `InpSlowEMA=200`, `InpFastEMA=20`.
- SL/TP: `InpStopLossPips`, `InpTakeProfitPips`.
- Session: `InpStartHour`, `InpEndHour` (server time).
- Execution safety: `InpMaxSlippage` (pips), `InpSpreadMult` (multiplier on 3-bar avg spread).
- Spread hard cap: `InpMaxSpreadPips`.
- Leverage: `InpLeverage` (base 1:X, 0 disables leverage mode).
- Daily loss cap: `InpMaxDailyLossPct`.
- Magic: `InpMagicNum`.
- Guardrails: `InpRolloverHourStart/End`, `InpMaxTradesPerDay`, `InpMaxConsecLosses`, `InpCooldownMinutes`.

Operational notes
- Symbol is auto-selected on init; uses IOC filling.
- Uses a 3-tick warm-up for spread averaging before trading.
- New-bar guard avoids duplicate entries on the same candle.
- Stops-level check prevents invalid SL/TP placement.

Testing checklist
- Confirm spread filter blocks trades when current spread exceeds avg*mult.
- Check SL/TP placement respects broker stop levels.
- Verify daily loss cap blocks new entries after drawdown reaches 2%.
- Verify breakeven moves SL after 1R and does not leap over TP.
- Run with slippage and spread spikes to ensure orders respect deviation and filter.
BootcampSafeEA (EURUSD H1, 5ers-friendly)
==========================================

Overview
--------
BootcampSafeEA is a conservative MT5 Expert Advisor for EURUSD on H1. It trades a simple EMA200 trend + EMA20 pullback pattern with ATR-based SL/TP, fixed fractional risk, and multiple prop-safe guardrails (no martingale/grid/arb; visible SL/TP). It includes optional “inactivity relax” (lower ATR floor after many no-trade days) and “stress trim” (auto-reduce risk when spread or volatility is elevated).

Key features (prop-rule aligned)
- H1 only, 1 position max, visible SL/TP (no stealth).
- Risk per trade default 0.25% of balance; SL from ATR * multiplier; TP at 2R.
- Filters: spread cap, session window, rollover skip, min ATR (volatility floor), inactivity relax after X no-trade days, cooldown, loss-streak brake, daily loss cap, global drawdown cap, trades-per-day cap.
- Stress trim: auto-reduce risk when spread widens or ATR is high; keeps drawdowns shallow under stress.
- Stops-level check to avoid broker rejections; new-bar-only execution.

Inputs (essentials)
- Symbol/timeframe: `InpSymbol="EURUSD"`, `InpTF=H1`.
- Risk/levels: `InpRiskPercent`, `InpSL_ATR_Mult`, `InpTP_RR`.
- Filters: `InpMaxSpreadPoints`, `InpStartHour/InpEndHour`, `InpRolloverHourStart/End`, `InpMinAtrPips`.
- Risk brakes: `InpMaxDailyLossPct`, `InpMaxDrawdownPct`, `InpMaxTradesPerDay`, `InpMaxConsecLosses`, `InpCooldownMinutes`.
- Inactivity relax: `InpInactivityDays` (days with no trades before relaxing), `InpRelaxAtrFactor` (ATR floor multiplier when relaxed).
- Stress trim: `InpRiskTrimFactor` (risk multiplier when stressed), `InpHighVolAtrMult` (ATR*pips trigger), `InpHighSpreadFactor` (fraction of max spread that triggers trim).

How it trades
1) Runs once per new H1 bar. Skips if spread high, outside session, during rollover, below min ATR (or relaxed ATR if inactive too long), loss streak hit, cooldown active, or risk caps/trade caps hit.
2) Trend filter: EMA200 slope/position. Entry trigger: price crosses back over EMA20 in trend direction.
3) SL = ATR * multiplier; TP = SL * RR; lots sized to risk % of balance.
4) Orders sent with visible SL/TP; failure logs `_LastError`.

Safety defaults
- 0.25% risk per trade, 1.5% daily loss cap, 5% global drawdown cap, max 2 trades/day, skip 21–23h server, min ATR 8 pips, cooldown 360 minutes, loss streak pause after 2 losses.
- Inactivity relax: after 12 days without trades, ATR floor halves (0.5x) until a trade occurs.
- Stress trim: if spread > 80% of max or ATR >= 2x min ATR, risk is trimmed to 50% of normal for that trade.

Deployment
- Attach to EURUSD H1 chart. Ensure algo trading enabled. Leave inputs at defaults for prop bootcamp; adjust hours to your broker server time.

Testing checklist
- Back/forward-test with variable spread; confirm entries block when spread > cap.
- Check min ATR, inactivity relax, and rollover windows: verify relax lowers ATR floor only after no-trade window elapses, then resets after a trade.
- Trigger loss streak, daily loss cap, and drawdown cap in tester to confirm trade pause.
- Verify stops distance passes broker stops-level and SL/TP are visible.
- Force high-spread/high-ATR scenarios to see risk trim reduce lot size; confirm it reverts when normal.

Notes
- Designed to be boring and low-frequency; intended to avoid drawdown spikes and rule breaches rather than maximize trade count.

