# AMN Expansion Zones

This repository now includes a TradingView Pine Script v5 indicator in:

- `amn_expansion_zones.pine`

## What the script does

The indicator is built around the AMN-style sequence described in the task:

1. Determine higher timeframe external bias.
2. Wait for internal shift on the chart timeframe.
3. Start an expansion phase only after internal aligns with external.
4. Create zones only from confirmed valid lows / valid highs.
5. Keep multiple zones alive in sequence while they remain fresh.
6. Mark mitigation when price reaches the configured fib level.
7. Optionally show a simplified sweep + MSS entry confirmation.

## Block-by-block explanation

### 1) Inputs

The script exposes the requested controls:

- HTF timeframe
- HTF swing length
- local pivot length
- left scan bars
- internal shift lookback
- zone extend bars
- fib level
- show fib
- delete on mitigation
- show signals
- show debug

I also added:

- `showExtraFib` for optional 0.3 and 0.7 lines
- `sweepLookback` and `microLookback` for the optional entry confirmation logic

Note:

- `zoneExtendBars` is capped at `500` because TradingView drawing objects that use `xloc.bar_index` cannot be projected indefinitely into the future.

### 2) HTF bias engine

The script uses `request.security()` to pull:

- HTF close
- HTF pivot high
- HTF pivot low

It stores the most recent confirmed HTF swing high / low and sets:

- bullish bias if HTF close is above the last HTF swing high
- bearish bias if HTF close is below the last HTF swing low
- otherwise it keeps the previous bias

### 3) Local swing detection

The trading timeframe uses:

- `ta.pivotlow(low, localPivotLen, localPivotLen)`
- `ta.pivothigh(high, localPivotLen, localPivotLen)`

These local pivots are the anchors for valid low / valid high source discovery.

### 4) Valid low / valid high left-scan logic

This is implemented as an actual left scan from the swing anchor.

For a swing low:

- scan only older candles to the left
- among bearish candles, select the one with the lowest **close**
- a valid low is confirmed only when price closes above that candle's high
- the zone uses the full candle range

For a swing high:

- scan only older candles to the left
- among bullish candles, select the one with the highest **close**
- a valid high is confirmed only when price closes below that candle's low
- the zone uses the full candle range

Pending candidates are stored in arrays until confirmation happens.

### 5) Internal shift / expansion logic

The current timeframe expansion logic uses:

- bullish shift when `close > ta.highest(high[1], internalShiftLookback)`
- bearish shift when `close < ta.lowest(low[1], internalShiftLookback)`

That only triggers when the HTF external bias already points in the same direction.

When it happens, the script stores:

- `expansionDir`
- `expansionStartBar`

When HTF bias changes, pending valid-low and valid-high candidates are cleared so an old regime cannot confirm new zones after the directional framework has changed.

### 6) Expansion-only zone creation

A zone is created only when all of these are true:

- external bias matches the direction
- `expansionDir` matches the direction
- the valid low / valid high is confirmed
- the source candle and swing were formed after expansion started

This avoids creating pullback zones before the internal shift confirms expansion.

### 7) Multiple zone support

The script uses arrays to keep multiple zones:

- `array<box>` for boxes
- `array<line>` for fib lines
- float arrays for top / bottom / mid
- int arrays for direction / start bar / source bar
- bool array for active state

It also prevents duplicate zone creation from the same source candle.

### 8) Fibs and mitigation

Each zone stores:

- top
- bottom
- midpoint at the configurable fib level

Optional visual fib lines:

- 0.5
- 0.3
- 0.7

Mitigation rule:

- bullish zone is mitigated when a later bar trades to or below the midpoint
- bearish zone is mitigated when a later bar trades to or above the midpoint

If `deleteOnMitigation` is enabled, the objects are removed. Otherwise, they are kept but faded.

### 9) Optional sweep + MSS entry markers

This is intentionally a lightweight confirmation model:

Bullish:

- price taps bullish zone
- price sweeps a recent low
- candle closes back up
- later closes above a recent micro high
- BUY label prints

Bearish:

- price taps bearish zone
- price sweeps a recent high
- candle closes back down
- later closes below a recent micro low
- SELL label prints

### 10) Debug tools

When debug is enabled, the script shows:

- current HTF bias
- current expansion direction
- HTF swing values
- when expansion starts
- when valid lows / highs confirm
- which source candle was chosen
- when a zone is mitigated

## Assumptions and simplifications

This version is logically consistent with the requested structure model, but it still includes some practical simplifications:

1. **HTF bias uses pivot-based structure only**
   - No proprietary significance filter for swings.
   - No displacement, session, or volume conditions.

2. **Valid source scan is bounded by `leftScanBars`**
   - This is required for Pine performance.
   - If the real AMN model scans a wider or adaptive range, this version can differ.

3. **Expansion gating is strict**
   - I required both the source candle and its swing anchor to form after the internal shift.
   - This keeps the model aligned with the instruction to use only zones formed after expansion starts.

4. **Entry confirmation is simplified**
   - The sweep + MSS model is intentionally basic and optional.
   - It is not a full reconstruction of a proprietary execution model.

5. **No AMN 1-5 / 1-6 numbering labels**
   - I intentionally left this out rather than add fake or arbitrary numbering.

6. **No explicit external liquidity target / draw-on-liquidity termination**
   - Zones remain active until mitigation.
   - The script does not currently stop generating zones based on a detected higher-level target being reached.

7. **HTF close behavior follows `request.security()`**
   - This script does not attempt to reconstruct every realtime nuance of TradingView HTF bar confirmation behavior beyond standard `request.security()` usage.

## Where this may still differ from a real AMN proprietary indicator

Most likely differences are:

- how the proprietary model defines a "significant" HTF swing
- whether internal structure shift uses more nuanced market structure than a highest/lowest lookback break
- how the proprietary model chooses valid source candles when several competing candles exist
- how long a valid source remains eligible for confirmation
- whether zones are invalidated by context changes besides midpoint mitigation
- how sweep + MSS entry logic handles liquidity pools, inducement, and session timing
- whether there are extra narrative labels or state transitions between source, break, retest, and execution

## Usage notes

1. Open TradingView Pine Editor.
2. Copy `amn_expansion_zones.pine`.
3. Save and add it to a chart.
4. Start with:
   - HTF = `240`
   - HTF swing length = `3`
   - local pivot length = `3`
   - left scan bars = `20`
   - internal shift lookback = `10`
   - fib level = `0.5`
5. Turn on `Show debug helpers` first to validate the model state.
