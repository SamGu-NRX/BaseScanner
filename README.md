# House scanning

We're exploring a simpler way to survey a home for a Base Power battery. A homeowner records the area around their electric meter with a phone. The goal is a 3D view that helps a reviewer assess whether a battery can fit and where it could go.

Success means one capture session gives Base enough information for a decision, without follow-up photos. A human can review the result.

The first experiment will test whether an existing video-to-3D tool can produce a useful model from an ordinary phone recording.

## Start with one wall

The first prototype will cover a meter wall, the ground beside it, and a nearby corner:

1. Record a short phone video and reconstruct it with [OOOSplat](https://github.com/ooolabdev/ooosplat).
2. Set the model's scale using a known distance visible in the capture. A house plan may supply that distance if we can identify the same endpoints.
3. Mark the meter and obstacles by hand, then position a box with the battery's dimensions.
4. Compare a different distance in the model with a real measurement to check whether the scale holds up.

Keep the original images beside the model. A convincing 3D view can still miss an obstacle or get a distance wrong. Approving an installation also requires electrical checks and confirmed placement rules.

## Learn from the first attempt

Start with the complete attempt, inspect what falls short, and change the part responsible. Blurry footage, distorted geometry, and an unreadable meter label need different fixes.

We'll record capture effort, processing time, measurement errors, and what the reviewer still needs. We'll also compare the model plus images with the images alone. Reconstruction needs to make the survey more useful to justify the extra work.

If people miss important areas, we can try live guidance or a progress view that shows what's left to capture. One good scan gives us a starting point. Repeated captures on different phones tell us whether it works reliably.

## Build on existing work

- [OOOSplat](https://github.com/ooolabdev/ooosplat) is the first reconstruction candidate. It accepts video and image sequences and provides a desktop pipeline and viewer. Its application code is Apache-2.0. Bundled engines have separate licenses.
- [Rumi](https://github.com/IBS27/rumi) is a useful reference for capture feedback and working with dimensioned objects. Its current capture requires LiDAR. We found no declared repository license, so we'll clarify permission before copying its code.

Neither has been tested on this project's exterior footage yet. The [earlier AR proposal](docs/00-overview.md) describes another approach to evaluate.

Before making installation decisions, we need to confirm the battery model and placement rules, acceptable measurement error, and how to rank suitable locations.
