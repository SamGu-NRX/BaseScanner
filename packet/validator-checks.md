# Three arrival checks for the capture packet validator

The server's validator (`packet/packetgen/validate.py` and `server/contracts` in
`huntertcarver/house-scanning-server`) already checks the schema, every file's size and SHA-256,
rigid poses, plausible intrinsics, epochs, depth and confidence byte counts, and tap replay. These
three checks catch mistakes those do not. Each ran in the packet 1.1 validator (`t3/packet`
`d5439cf`, `packet/validate.py`) with a test that breaks it on purpose. Whether they reach the
server as a pull request or stay a proposal is Sam's and Hunter's call.

## 1. Keyframes lie on the pose stream

For each keyframe, find the `arkitPoses` row of the same epoch nearest its `timestamp`. It must be
within one frame of the stream's rate (1/60 s at 60 Hz), and its position within 1 cm of the
keyframe pose's translation.

**What it catches.** Keyframes and the pose stream written in different frames, or on different
clocks: for example, keyframe poses converted to another frame while the stream stays raw, or
timestamps taken from `Date` on one side and uptime on the other. Every other check passes such a
packet, because each part is valid on its own.

**Evidence.** On the ADVIO sample, 79 keyframes matched their stream rows exactly. Moving one
keyframe 10 cm, or its timestamp past the stream's end, fails the check (1.1 tests
`test_a_photo_off_its_trajectory` and `test_a_photo_between_trajectory_samples`).

## 2. Depth is aligned to its keyframe

A depth map covers its keyframe's field of view at lower resolution:
- its `w / h` equals the image's within 1%, and it is no larger than the image;
- values are finite and non-negative, with 0 for no measurement, and at least 1% are measured;
- confidence values are at most 2.

**What it catches.** A depth map from another orientation or crop (for example a portrait-rotated
map with a landscape image), which the byte-count check passes because `w × h` is unchanged. It
also catches NaN written for "no reading", and an all-zero map.

**Evidence.** On ETH3D electro with laser-rendered depth, ETH3D's own 3-D points reprojected
through the packet's poses to a median 0.65 to 1.01 px, and the depth agreed with them to a median
0.2 to 0.6%. The aspect, NaN and confidence tests in 1.1's `tests/test_packet.py` each fail their
case.

## 3. The mesh file is what the manifest says

`geometry/mesh.ply` is a binary little-endian PLY. 0.4 does not fix its index and count types, so
this check proposes one layout as well:
- `float x, y, z` per vertex, and per face a `uchar` count followed by that many `int` indices,
  then an optional `uchar classification`;
- the body length equals exactly what the vertex and face counts imply;
- every face is a triangle, and every index is below the vertex count;
- classification values are 0 to 7 (`ARMeshClassification`), and all 0 when `mesh.classified` is
  false.

**What it catches.** A truncated upload that still hashes as sent, an index past the vertex list
(which crashes or corrupts a reconstruction reader), `double` coordinates or `uint` counts from a
different exporter, and classes written when classification was off, which cannot be told from
ARKit's own 0 ("none").

**Evidence.** 1.1's `tests/test_checks.py` breaks each of these in turn (index out of range,
class 8, a truncated body, a changed property type). The ARKit mesh has not yet been exercised
from a device.
