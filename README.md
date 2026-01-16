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

