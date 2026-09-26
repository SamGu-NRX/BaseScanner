"""Choices fixed before any scored run. Changing one after scoring means rerunning every candidate.

Committed together with the pass criteria in README.md, before the first scored run.
"""

# Operating threshold: chosen per model and class on the OI tune set (150 images, disjoint from
# eval), then applied unchanged to OI eval and CMP. Rule: the lowest score at which precision is
# at least MIN_PRECISION, which gives the most recall that still meets the precision bar; when no
# score reaches it, the score with the best F1. See oieval.choose_threshold.
MIN_PRECISION = 0.60
MIN_RECALL = 0.80
IOU = 0.5

# Diagnostic only, not a pass criterion: at 1 to 3 m an iPhone frame holds a window or door at
# roughly 15% or more of the frame's width. Boxes smaller than this fraction of the image in
# either dimension are treated as "difficult" (detections on them ignored, not counted as missed)
# in the "near-sized" tables.
NEAR_MIN_SIDE = 0.10

# OWLv2 text queries, one per wall object. Scored classes are window and door; the others are in
# the query list so a door competes with "garage door" the way it would in the app. Each box
# takes the query with the highest score.
OWL_QUERIES = {
    "window": "a photo of a window",
    "door": "a photo of a door",
    "garage_door": "a photo of a garage door",
    "ac": "a photo of an air conditioner",
    "gas_meter": "a photo of a gas meter",
    "elec_box": "a photo of an electrical box",
    "battery": "a photo of a home battery",
}
# Grounding DINO takes one caption with the same objects, each phrase ending in " .".
GDINO_PHRASES = {
    "window": "window",
    "door": "door",
    "garage_door": "garage door",
    "ac": "air conditioner",
    "gas_meter": "gas meter",
    "elec_box": "electrical box",
    "battery": "home battery",
}

# Post-processing for the open-vocabulary models: per-class NMS at this IoU, then the top
# MAX_DETS boxes above MIN_SCORE per image. The low floor keeps the tail needed for AP.
NMS_IOU = 0.5
MAX_DETS = 100
MIN_SCORE = 0.01

# Apple Vision VNDetectRectanglesRequest. Defaults would return one rectangle at least 20% of the
# image; these allow many small ones. Aspect ratio is short side over long side, so 0.2 admits a
# door (about 0.4). Quadrature tolerance stays at Apple's default, 30 degrees.
VISION_RECTS = {
    "maximumObservations": 0,  # 0 = no limit
    "minimumAspectRatio": 0.2,
    "maximumAspectRatio": 1.0,
    "minimumSize": 0.03,
    "quadratureTolerance": 30.0,
    "minimumConfidence": 0.0,
}

# Create ML student: transfer learning on Apple's object feature print, trained on the OI train
# subset (window and door). Core ML confidence floor for scoring, and the NMS IoU in its pipeline.
STUDENT_CONFIDENCE_FLOOR = 0.01
STUDENT_NMS_IOU = 0.45

# Speed classes from Mac timings (M4 Pro); an iPhone is slower, so these are optimistic.
LIVE_MS = 100
KEYFRAME_MS = 1000

# 3D extent: an edge lifted to the wall replaces a tap when its p90 error is at most this.
EXTENT_P90_FT = 0.5
