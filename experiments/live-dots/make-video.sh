#!/bin/bash
# Renders the replay in both modes at 1170 x 2532, 30 fps, and each dot scheme in LiDAR mode,
# and encodes each to H.264.
# LiveDots streams raw BGRA frames into ffmpeg, so no frame folder is written: as PNGs the
# ~320 frames of one mode take about 500 MB.
# Usage: ./make-video.sh [output folder]
set -euo pipefail
cd "$(dirname "$0")"
out="${1:-$HOME/house-scanning-data/reports/experience/prototype}"
mkdir -p "$out"
swift build -c release
render() {
    .build/release/LiveDots --export - "$@" |
        ffmpeg -y -loglevel error -f rawvideo -pix_fmt bgra -s 1170x2532 -r 30 -i - \
            -c:v libx264 -crf 23 -pix_fmt yuv420p "$file"
    echo "wrote $file"
}
for mode in lidar nolidar; do
    file="$out/live-dots-$mode.mp4" render --mode "$mode"
done
for scheme in a-hologram b-constellation c-ember; do
    file="$out/scheme-$scheme.mp4" render --mode lidar --scheme "${scheme#?-}"
done
