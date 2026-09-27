#!/bin/bash
# Renders the replay in both modes at 1170 x 2532, 30 fps, and encodes each to H.264.
# LiveDots streams raw BGRA frames into ffmpeg, so no frame folder is written: as PNGs the
# ~320 frames of one mode take about 500 MB.
# Usage: ./make-video.sh [output folder]
set -euo pipefail
cd "$(dirname "$0")"
out="${1:-$HOME/house-scanning-data/reports/experience/prototype}"
mkdir -p "$out"
swift build -c release
for mode in lidar nolidar; do
    .build/release/LiveDots --export - --mode "$mode" |
        ffmpeg -y -loglevel error -f rawvideo -pix_fmt bgra -s 1170x2532 -r 30 -i - \
            -c:v libx264 -crf 23 -pix_fmt yuv420p "$out/live-dots-$mode.mp4"
    echo "wrote $out/live-dots-$mode.mp4"
done
