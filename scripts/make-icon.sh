#!/bin/zsh
#
# Build the app icon set from the source artwork.
#
#   scripts/make-icon.sh                 rebuild Resources/AppIcon.icns from the source PNG
#   scripts/make-icon.sh path/to/art.png rebuild from another source
#
# The source is the 1024-point artwork; every size in the set is derived from it, so the small
# variants stay consistent with the large one instead of being drawn separately. macOS reads the
# .icns through Info.plist CFBundleIconFile, and the packaging script copies the result into the
# bundle Resources directory.
#
set -euo pipefail

root="${0:A:h:h}"
source_png="${1:-$root/Resources/AppIcon-source.png}"
output="$root/Resources/AppIcon.icns"

if [[ ! -f "$source_png" ]]; then
    print -u2 "no source artwork at $source_png"
    exit 1
fi

work=$(mktemp -d /tmp/call-recorder-icon.XXXXXX)
trap 'rm -rf "$work"' EXIT
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"

# The names and sizes an .iconset must contain. The @2x file is the retina pair of the size
# before it, so 32@2x is the same pixels as 64.
for size in 16 32 128 256 512; do
    sips -z $size $size "$source_png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$source_png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil --convert icns "$iconset" --output "$output"
print "Wrote $output"
print "  from $source_png"

