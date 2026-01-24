# Product Requirements Document (PRD)
LiveEA + BootcampEA (MT5 Expert Advisors)

## Overview
This repository contains two MT5 Expert Advisors focused on prop-firm compliant, H1 Keltner Channel Breakout trading with explicit risk controls and visible SL/TP. The design emphasizes capital preservation, rule compliance, and controlled exposure.

Primary artifacts:
- `LiveEA.mq5`: Aggressive configuration for live/personal accounts (higher risk, wider drawdowns).
- `BootcampEA.mq5`: Conservative configuration for prop firm challenges (strict risk, tight drawdowns).
- `rules.mdc`: Compliance constraints (no arb/HFT, no grid/martingale, visible SL/TP).
- `README.md`: Operational overview and usage guide.

## Goals
- Provide safe, prop-firm compliant automation for H1 Keltner Breakout trading.
- Cap per-trade risk and daily loss to prevent rule breaches.
- Maintain transparent SL/TP (no stealth), no disallowed strategies.
- Adapt to market conditions using ATR-based volatility filters and dynamic risk adjustment.

## Non-Goals
- High-frequency trading or tick scalping.
- Arbitrage (latency, reverse, hedge) and trade copying.
- Martingale, recovery, or grid logic.
- Hidden/stealth stop-loss.

## Strategy Summary
### Core Logic (Shared)
- **Timeframe**: H1.
- **Trend**: Daily EMA (default 200) defines the directional bias.
- **Entry**: Breakout of Keltner Channels (EMA + ATR bands).
  - Buy if Close > Upper Band AND Price > Daily EMA.
  - Sell if Close < Lower Band AND Price < Daily EMA.
- **Exit**:
  - Initial SL based on ATR (e.g., 2.0 * ATR).
  - TP based on Risk:Reward ratio (e.g., 2.0 * SL).
  - Trailing Stop (ATR-based).
  - Breakeven trigger (ATR-based).
- **Filters**:
  - Session window (Start/End hour).
  - Rollover skip (avoid high spreads).
  - Max Spread check.
  - Min ATR (avoid dead markets).
  - High Volatility Pause (avoid news spikes).
  - Cooldown (wait after close).
  - Consecutive Loss Pause.

### LiveEA (Aggressive)
- **Risk**: Higher default risk (e.g., 2.5% per trade).
- **Drawdown**: Wider max drawdown tolerance (e.g., 15%).
- **Leverage**: Lower leverage setting (5.0) - *Note: Leverage input acts as a cap/sizing mechanism.*

### BootcampEA (Conservative)
- **Risk**: Strict risk (e.g., 2.0% per trade).
- **Drawdown**: Tight max drawdown (e.g., 4.9%) to pass prop challenges.
- **Leverage**: Higher leverage setting (10.0) allowed by logic, but constrained by risk % cap.

## Inputs (Highlights)
- **Risk**: `InpRiskPercent`, `InpMaxDailyLossPct`, `InpMaxDrawdownPct`.
- **Strategy**: `InpKeltnerPeriod`, `InpKeltnerMult`, `InpDailyEmaPeriod`.
- **Exits**: `InpATRPeriod`, `InpSL_ATR_Mult`, `InpTP_RR`, `InpTrailingAtrMult`.
- **Filters**: `InpStartHour`, `InpEndHour`, `InpRolloverHourStart/End`, `InpMaxSpreadPoints`.
- **Advanced**: `InpInactivityDays` (relax filters), `InpRiskTrimFactor` (stress management).

## Acceptance Criteria
### Compliance
- No grid/martingale/recovery/news logic.
- No arb/HFT/tick scalping.
- Visible SL/TP on all orders.

### Risk and Safety
- **BootcampEA**: Max drawdown < 5%, Daily loss < 2% (configurable).
- **LiveEA**: Max drawdown < 15%, Daily loss < 2%.
- Spread cap and stop-level checks prevent invalid orders.

### Behavior
- Trades only on new H1 bars.
- Entries blocked outside session or during rollover.
- One position max per symbol/magic.
