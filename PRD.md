# Product Requirements Document (PRD)
ICmarketEA + BootcampSafeEA (MT5 Expert Advisors)

## Overview
This repository contains two MT5 Expert Advisors focused on prop-firm compliant, H1 EMA pullback trading with explicit risk controls and visible SL/TP. The design emphasizes capital preservation, rule compliance, and controlled exposure rather than high frequency trade volume.

Primary artifacts:
- `ICmarketEA.mq5` (PropPullback_v2): IC Markets Raw optimized, controlled leverage + quality scoring.
- `BootcampSafeEA.mq5`: conservative ATR-based strategy aligned with prop bootcamp rules.
- `rules.mdc`: compliance constraints (no arb/HFT, no grid/martingale/recovery, visible SL/TP).
- `README.md`: operational overview and testing checklist.

## Goals
- Provide safe, prop-firm compliant automation for H1 EMA pullback trading.
- Cap per-trade risk and daily loss to prevent rule breaches and account blowups.
- Maintain transparent SL/TP (no stealth), no disallowed strategies (grid/martingale/arb/news).
- Support controlled leverage and quality-based exposure in ICmarketEA.
- Keep BootcampSafeEA conservative, ATR-based, and stress-aware.

## Non-Goals
- High-frequency trading or tick scalping.
- Arbitrage (latency, reverse, hedge) and trade copying.
- Martingale, recovery, or grid logic.
- Hidden/stealth stop-loss.

## Compliance Requirements (from `rules.mdc`)
- No copy trading.
- No tick scalping, HFT, or any arb strategies.
- No emulators.
- No grid/martingale/recovery/news logic.
- Visible SL/TP in platform.
- One position max; H1 only; EMA200 trend filter; EMA20 pullback.
- Leverage-based sizing allowed but capped at 1% risk per trade.
- Daily loss cap: 2% (equity-based).

## User Personas
1) Trader/Operator
   - Wants stable, rule-compliant performance and simple configuration.
2) Developer/Maintainer
   - Needs readable logic and clear testing/acceptance criteria.
3) Prop Firm Compliance Reviewer
   - Requires explicit safeguards and disallowed-strategy avoidance.

## Strategy Summary
### ICmarketEA (PropPullback_v2)
- Timeframe: H1.
- Trend: EMA200 direction filter.
- Entry: EMA20 pullback (wick or close proximity with volume confirmation).
- Controlled leverage:
  - Base leverage input (`InpLeverage`) for position sizing.
  - Quality scoring (1–3) scales leverage; capped at 1% max risk.
- Risk caps:
  - 1% max risk per trade (hard cap in leverage sizing).
  - 2% daily loss cap (equity-based).
- Spread handling:
  - 3-sample spread average filter + hard cap.
  - Entry tax: reduce lots 20% if spread near max.
- Guardrails:
  - Session window + rollover skip.
  - Max trades per day, loss-streak pause, cooldown.
  - New-bar only execution.

### BootcampSafeEA
- Timeframe: H1 (EURUSD default).
- Trend: EMA200 filter.
- Entry: EMA20 pullback.
- SL/TP: ATR-based SL, RR-based TP.
- Risk controls:
  - Fixed fractional risk per trade (default 0.25%).
  - Daily loss cap, drawdown cap, trades/day cap.
  - Stress trim (risk reduction on high spread/vol).
  - Inactivity relax (loosen ATR floor after long inactivity).
- Guardrails:
  - Session window + rollover skip.
  - Loss-streak pause, cooldown.
  - New-bar only execution.

## Core Features
### Shared
- EMA200 trend filter; EMA20 pullback entry.
- H1 only; one position per symbol/magic.
- Visible SL/TP; broker stop-level check.
- Spread filtering and slippage control.
- Cooldown, loss-streak pause, trades/day cap.

### ICmarketEA-only
- Controlled leverage with quality-based scaling.
- Quality score (1–3) based on slope + momentum confirmation.
- Entry tax near max spread.
- Daily loss cap (2%).

### BootcampSafeEA-only
- ATR-based SL/TP and RR targeting.
- Stress trim and inactivity relax.
- Drawdown cap (global) and daily loss cap.

## Inputs (Highlights)
### ICmarketEA
- Risk: `InpRiskPerTrade` (base), `InpLeverage`, `InpMaxDailyLossPct`.
- Spread: `InpMaxSpreadPips`, `InpSpreadMult`, `InpMaxSlippage`.
- Session: `InpStartHour`, `InpEndHour`, `InpRolloverHourStart/End`.
- Guards: `InpMaxTradesPerDay`, `InpMaxConsecLosses`, `InpCooldownMinutes`.

### BootcampSafeEA
- Risk: `InpRiskPercent`, `InpMaxDailyLossPct`, `InpMaxDrawdownPct`.
- Volatility: `InpATRPeriod`, `InpSL_ATR_Mult`, `InpMinAtrPips`.
- Stress trim: `InpRiskTrimFactor`, `InpHighVolAtrMult`, `InpHighSpreadFactor`.
- Session: `InpStartHour`, `InpEndHour`, `InpRolloverHourStart/End`.

## Acceptance Criteria
### Compliance
- No grid/martingale/recovery/news logic.
- No arb/HFT/tick scalping.
- Visible SL/TP on all orders.

### Risk and Safety
- ICmarketEA: max per-trade risk <= 1%; daily equity loss cap at 2%.
- BootcampSafeEA: daily loss cap and drawdown cap enforced.
- Spread cap and stop-level checks prevent invalid orders.

### Behavior
- Trades only on new H1 bars.
- Entries blocked outside session or during rollover.
- One position max per symbol/magic.
- Quality-based leverage scaling only in ICmarketEA.

## Testing Checklist
- Validate spread filtering and entry tax behavior with spread spikes.
- Ensure daily loss cap blocks new entries after 2% equity drawdown.
- Confirm quality score changes risk scaling in ICmarketEA.
- Verify SL/TP respects broker stop levels.
- Check loss-streak pause and cooldown enforcement.
- Confirm no trades during rollover window.

## Open Questions
- Should leverage be disabled by default for certain prop firm profiles?
- Should daily loss cap be configurable per prop firm (default 2%)?

