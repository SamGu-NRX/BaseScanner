#!/bin/sh
# Copies the synthetic replay fixtures from the guided-capture branch (PR #10) into Fixtures/,
# without adding ios/ to a sparse checkout. Fixtures/ is git-ignored.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(git -C "$here" rev-parse --show-toplevel)"
git -C "$root" fetch --quiet origin t3/ios-mvf
rm -rf "$here/Fixtures"
# ios/HouseScanUITests/Fixtures/<name>/... becomes Fixtures/<name>/...
git -C "$root" archive origin/t3/ios-mvf ios/HouseScanUITests/Fixtures | tar -x -C "$here" --strip-components=2
ls "$here/Fixtures"
