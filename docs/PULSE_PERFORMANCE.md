# Pulse iPhone performance review

The reviewed UI checkpoint is `cd7ef00d` on `main`. Performance changes are isolated on
`pulse/performance` for simulator validation. This pass preserves the score formulas, stored
data, Bluetooth behavior, and approved screen designs.

## Selected improvements

| Area | Avoidable work | Change |
| --- | --- | --- |
| Home day navigation | Optional hosted Sleep and stress cards load even on historical days, where those cards are hidden. | Restrict their work to Today. |
| Home synthesis | Calibration explanations and stale-night checks map history during view updates. | Resolve them alongside the existing day caches. |
| Sleep and Trends | An eager section stack sits inside the scaffold's lazy stack, constructing offscreen cards. | Make the actual section stacks lazy. |
| Trends weekly recap | The full-history digest is rebuilt on unrelated view updates. | Memoize it with its repository generation, week, and display-scale inputs. |
| Live heart-rate line | A 60 Hz animation rebuilds the same domain and curve between incoming samples. | Prepare geometry when data or size changes; animate only the glint and endpoint pulse. |
| Animated workout bar | Each animation frame resolves the same tint and fill gradient. | Prepare the material outside the animation clock. |
| Ring material | Each gradient resolves the same tint five times. | Resolve its components once for all five stops. |

## Follow-up candidates

- Metric Explorer reads values and provenance through separate repository paths before showing a
  generic metric. Combining those reads could reduce opening latency, but requires fixtures for source
  precedence, deduplication, and fallback behavior before changing the repository API.
- The small connection and battery controls observe all of `LiveState`, including unrelated HR/RR
  updates. Narrow subscriptions could reduce those controls' redraws; the main dashboard already
  isolates live observations into small leaves.
- Sleep can rebuild its model provisionally and again after its complete session data arrives. A
  shared immutable snapshot could reduce the work further, but needs careful refresh and night-edit
  invalidation checks.

## Validation and measurement

Simulator builds and tests validate compilation and behavior. A shorter call path or fewer repeated
operations does not establish an FPS or battery improvement. Simulator timings also do not predict
physical-iPhone performance, especially during real Bluetooth sync or on a large imported library.

Before a phone update, review the simulator's Home day navigation, Sleep stage selection, Trends range
and week controls, long scrolling, and metric navigation. A physical-device trace with the owner's
explicit feedback remains the next step for frame-time, CPU, and energy measurements.

Completed validation for this pass:

- iPhone simulator app build; 584 Python tests and 135 StrandDesign tests passed.
- An extracted Swift fixture compared the old and prepared heart-rate geometry across 24 combinations
  of empty, singleton, flat, varying, gapped, and mismatched-segment input at three viewport sizes.
  Every path element and endpoint matched exactly.
- The material fixture compared all five stops for 36 tints, including alpha handling; outputs matched.
- Cache checks covered repeat reads and invalidation after repository, refresh, week, scale, and locale
  changes. Simulator range and week navigation also updated the displayed summaries correctly.
- A synthetic 6,000-frame workload with 1 Hz input reduced geometry builds from 6,000 to 100. This
  measures only prepared geometry reuse, excluding drawing and layout; it is not an app speedup claim.
