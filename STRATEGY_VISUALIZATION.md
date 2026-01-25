# Expert Advisor Strategy Visualization

This document provides a visual representation of the logic used in the MT5 Expert Advisors (`ADXLiveEA`, `LiveEA`, `BootcampEA`).

## Core Strategy: Keltner Channel Breakout

All EAs share the same core logic based on Keltner Channel breakouts aligned with the daily trend. The main difference lies in the **ADX Filter** used in `ADXLiveEA` for higher quality setups.

```mermaid
flowchart TD
    Start([New Candle on H1]) --> PreChecks
    
    subgraph PreChecks ["Safety & Environment Checks"]
        Check1{"Spread < Max?"}
        Check2{"Time in Session?"}
        Check3{"Not in Rollover?"}
        Check4{"Risk Limits OK?"}
        Check5{"Not in Cooldown?"}
        
        Check1 -- No --> Wait["Wait for next Tick"]
        Check2 -- No --> Wait
        Check3 -- No --> Wait
        Check4 -- No --> Wait
        Check5 -- No --> Wait
    end
    
    PreChecks --> TrendFilter
    
    subgraph TrendFilter ["Daily Trend Direction"]
        D1_EMA{"Price > Daily EMA 200?"}
        D1_EMA -- Yes --> Bullish["Bullish Bias"]
        D1_EMA -- No --> Bearish["Bearish Bias"]
    end
    
    Bullish --> SignalCheckBuy
    Bearish --> SignalCheckSell
    
    subgraph SignalCheckBuy ["Buy Signal Logic"]
        KeltnerBuy{"Close > Upper Band\nAND\nPrev Close < Upper Band?"}
    end
    
    subgraph SignalCheckSell ["Sell Signal Logic"]
        KeltnerSell{"Close < Lower Band\nAND\nPrev Close > Lower Band?"}
    end
    
    SignalCheckBuy -- Yes --> ADXCheck{"ADX Filter?"}
    SignalCheckSell -- Yes --> ADXCheck
    
    SignalCheckBuy -- No --> Wait
    SignalCheckSell -- No --> Wait
    
    subgraph ADXCheck ["ADX Filter (ADXLiveEA Only)"]
        IsADXEA{"Is ADXLiveEA?"}
        IsADXEA -- Yes --> CheckADX{"ADX > Threshold (25)?"}
        IsADXEA -- No --> CalculateRisk
        CheckADX -- Yes --> CalculateRisk
        CheckADX -- No --> Wait
    end
    
    subgraph CalculateRisk ["Position Sizing"]
        CalcSL["Calculate SL Distance (ATR * Mult)"]
        CalcTP["Calculate TP Distance (SL * RR)"]
        CalcLots["Calculate Lot Size based on Risk %"]
    end
    
    CalculateRisk --> Execution
    
    subgraph Execution ["Trade Execution"]
        SendOrder["Send Buy/Sell Order"]
    end
    
    Execution --> Management
    
    subgraph Management ["Trade Management (OnTick)"]
        TrailSL{"Price moved X ATR?"}
        TrailSL -- Yes --> MoveSL["Move SL to Lock Profit"]
        
        BreakEven{"Price > Trigger Distance?"}
        BreakEven -- Yes --> MoveBE["Move SL to Breakeven"]
        
        TimeExit{"Friday Close / Session End?"}
        TimeExit -- Yes --> ClosePos["Close All Positions"]
    end
```

## Key Parameters

| Parameter | Description | Typical Value |
|-----------|-------------|---------------|
| **Timeframe** | Entry Chart Timeframe | H1 |
| **Daily EMA** | Trend Filter Period | 200 |
| **Keltner Period** | Channel Period | 12 |
| **Keltner Mult** | Channel Width Multiplier | 1.0 - 1.4 |
| **ATR Period** | Volatility Measure | 14 |
| **Risk %** | Risk per trade | 2.0% - 2.5% |
| **ADX Threshold** | Trend Strength (ADXLiveEA only) | 25 |

## Logic Summary

1.  **Trend Filter**: We only trade in the direction of the long-term trend (Daily EMA 200).
2.  **Entry Signal**: We enter when price "explodes" out of the Keltner Channel (Breakout).
3.  **Validation**:
    *   **LiveEA / BootcampEA**: Takes the trade immediately if safety checks pass.
    *   **ADXLiveEA**: Waits for ADX > 25 to confirm a strong trend before entering.
4.  **Exit**:
    *   **Stop Loss**: Dynamic based on ATR (Volatility).
    *   **Take Profit**: Fixed Risk:Reward ratio (e.g., 1:2).
    *   **Trailing Stop**: Locks in profits as price moves in our favor.
