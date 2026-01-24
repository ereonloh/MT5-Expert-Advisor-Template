# MT5 Expert Advisor Template (Keltner Breakout)

## Overview
This project contains two MT5 Expert Advisors implementing a **Keltner Channel Breakout** strategy on the H1 timeframe. The EAs are designed with strict risk management and compliance features suitable for prop firm trading.

- **LiveEA.mq5**: Tuned for live accounts with higher risk tolerance.
- **BootcampEA.mq5**: Tuned for prop firm challenges (e.g., 5ers Bootcamp) with strict drawdown limits.

## Strategy
**Type**: Trend-Following Breakout
**Timeframe**: H1 (Entry), Daily (Trend Bias)

1.  **Trend Filter**: Trades are only taken in the direction of the Daily EMA (default 200-period).
2.  **Entry Trigger**: Candle Close outside the Keltner Channel (EMA +/- ATR * Multiplier).
3.  **Risk Management**:
    *   **Stop Loss**: ATR-based (e.g., 2.0 * ATR).
    *   **Take Profit**: Risk:Reward based (e.g., 2.0 * Risk).
    *   **Trailing Stop**: Activates to lock in profits.
    *   **Breakeven**: Moves SL to entry after a fixed profit distance.

## Key Features
- **Prop Firm Compliant**: No grid, martingale, or arbitrage. Visible SL/TP.
- **Risk Controls**:
    *   Max Daily Loss (% Equity).
    *   Max Total Drawdown (% High Watermark).
    *   Max Consecutive Losses Pause.
    *   Max Trades Per Day.
- **Filters**:
    *   **Session**: Trade only during specific hours (e.g., London/NY).
    *   **Rollover**: Skip trading during swap rollover (high spreads).
    *   **Spread**: Hard cap on spread points.
    *   **Volatility**: Minimum ATR required to trade; Pause on extreme volatility.
    *   **Inactivity Relax**: Automatically loosens filters if no trades occur for X days.

## Installation
1.  Copy `.mq5` files to your MT5 `MQL5/Experts/` folder.
2.  Compile in MetaEditor.
3.  Attach `LiveEA` or `BootcampEA` to an H1 chart (e.g., EURUSD).

## Configuration
| Input | Description | Default (Bootcamp) | Default (Live) |
| :--- | :--- | :--- | :--- |
| `InpRiskPercent` | Risk per trade (% Balance) | 2.0 | 2.5 |
| `InpMaxDrawdownPct` | Max Drawdown Limit | 4.9 | 15.0 |
| `InpKeltnerPeriod` | Keltner MA/ATR Period | 12 | 12 |
| `InpKeltnerMult` | Channel Width Multiplier | 1.4 | 1.4 |
| `InpDailyEmaPeriod` | Trend Filter Period | 200 | 200 |
| `InpSL_ATR_Mult` | Stop Loss Distance (ATR) | 2.0 | 2.0 |

## Testing Checklist
- [ ] **Compliance**: Verify no grid/martingale behavior. SL/TP must be set on entry.
- [ ] **Risk**: Ensure position size respects `InpRiskPercent`.
- [ ] **Drawdown**: Test that `InpMaxDrawdownPct` stops trading when hit.
- [ ] **Filters**: Verify no trades during `InpRolloverHourStart` to `InpRolloverHourEnd`.
- [ ] **Breakout**: Visually confirm entries occur only when Close > UpperBand (Buy) or Close < LowerBand (Sell).
