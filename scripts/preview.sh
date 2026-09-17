#!/bin/zsh
#
# Render the app's windows to PNG files, without packaging, signing, or installing.
#
# Reviewing a design used to mean: build, package, sign (which needs an unlocked keychain and a
# password), install, relaunch, find the window, screenshot it. This does it in one command, in
# about six seconds, and never asks for a password.
#
#   scripts/preview.sh              render every window into dist/preview
#   scripts/preview.sh /tmp/out     render into another directory
#
# The renderer reads the real database, so the pictures show real data, but it never records,
# never starts a capture, never writes to the database, and never reads the keychain.
#
set -euo pipefail

root="${0:A:h:h}"
out="${1:-$root/dist/preview}"

cd "$root"
mkdir -p "$out"

# A debug build is enough and is much faster than a release build.
swift build >/dev/null

CALL_RECORDER_PREVIEW=1 \
CALL_RECORDER_SNAPSHOT="$out" \
    "$root/.build/debug/CallRecorder"

print ""
print "Wrote $(ls -1 "$out"/*.png 2>/dev/null | wc -l | tr -d ' ') images to $out"
print "Open them with: open $out"

