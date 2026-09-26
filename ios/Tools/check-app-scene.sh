#!/bin/sh
# Validates the scene.json inside a scan bundle the app wrote against the server's schema.
# The engine logs each bundle's path ("bundle <path>/scan.zip ..." under category "engine").
#   ios/Tools/check-app-scene.sh <path to scan.zip>
set -eu
zip="${1:?usage: check-app-scene.sh <scan.zip>}"
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
/usr/bin/unzip -t -q "$zip"
/usr/bin/unzip -q -o "$zip" scene.json -d "$work"
HOUSESCAN_SCENE_JSON="$work/scene.json" swift test --package-path "$here/../HouseScanKit" --filter AppSceneFileTests
