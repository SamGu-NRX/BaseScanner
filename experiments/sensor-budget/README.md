# Sensor budget

## Question

Some candidate signals can't be tested on data we have: dual-camera disparity, focus distance, barometer, ultra-wideband ranging to a second phone, known-size objects (meter cover, brick courses, siding, a Letter sheet), measuring both ends of a span in one photo, and the 4032 × 3024 still. What error does physics allow each one at the range it would be used? Each gets a formula, parameters at the optimistic and conservative ends of published values, and a Monte Carlo where the parts combine non-linearly.

## Pass criteria, fixed before the run

- **Worth a device test:** with conservative parameters, p90 error at the operating range is at most 2 in for a position or length, or at most 1% for a scale.
- **Drop:** even optimistic parameters exceed 4 in, or 3% for a scale.
- **In between:** listed with the parameter that decides it.

## Result

Not run yet.
