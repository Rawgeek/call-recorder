#!/usr/bin/env python3
"""Measure the contrast of the text and marks in a rendered window.

Accessibility guidance sets a numeric floor: 4.5:1 for small text, 3:1 for a mark such as an icon
or a chart line. A colour picked by eye cannot be checked against a number, and a picture cannot
be checked by eye either, because the numbers behind it are not visible in it.

This reads a PNG written by scripts/preview.sh and reports, for each region it is given, the
contrast between the region's background and the text drawn on it. Regions are named on the
command line so the same check can be repeated after a change.

The render carries a Display P3 profile, so a colour read out of the file as if it were sRGB is
not the colour on screen: the red of a recording header measures 4.3:1 that way and 4.7:1 once
the profile is applied. Every value here is converted to sRGB first, which is the space the
guidance is written for.

    scripts/measure-contrast.py dist/preview/menu-bar-recording.png header=12,20,420,58
    scripts/measure-contrast.py dist/preview/design-system.png chip=30,600,460,640

A region is `name=x,y,width,height` in the image's own pixels. Without a region the whole image is
measured, which is only useful for telling a dark render from a light one.
"""

from __future__ import annotations

import io
import os
import sys
from collections import Counter

from PIL import Image, ImageCms


def pixels(image: Image.Image):
    """Every pixel of the image as tuples.

    `getdata` is deprecated in Pillow 14 and its replacement is not in Pillow 12, so the newer
    name is used when it exists and the older one otherwise.
    """
    reader = getattr(image, "get_flattened_data", None) or image.getdata
    return reader()

# The two thresholds the guidance uses. Small text needs the higher one; a mark that carries
# meaning needs the lower one.
TEXT_THRESHOLD = 4.5
MARK_THRESHOLD = 3.0
# A colour has to appear this many times in a region to count as a colour of the drawing rather
# than as anti-aliasing between two of them.
MIN_PIXELS = 8


def to_srgb(image: Image.Image) -> Image.Image:
    """The image in sRGB, whatever space it was drawn in."""
    profile = image.info.get("icc_profile")
    if not profile:
        return image.convert("RGB")
    source = ImageCms.ImageCmsProfile(io.BytesIO(profile))
    return ImageCms.profileToProfile(
        image.convert("RGB"),
        source,
        ImageCms.createProfile("sRGB"),
    )


def relative_luminance(colour: tuple[int, int, int]) -> float:
    def channel(value: int) -> float:
        srgb = value / 255
        return srgb / 12.92 if srgb <= 0.03928 else ((srgb + 0.055) / 1.055) ** 2.4

    red, green, blue = (channel(value) for value in colour)
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue


def contrast(first: tuple[int, int, int], second: tuple[int, int, int]) -> float:
    a, b = relative_luminance(first), relative_luminance(second)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)


def measure(image: Image.Image, box: tuple[int, int, int, int]) -> tuple[float, tuple, tuple]:
    """The contrast inside one region, with the two colours it was taken from.

    The background is the colour the region is mostly made of. The foreground is the repeated
    colour furthest from it in luminance, which is the text or the glyph: anti-aliased pixels sit
    between the two and are ignored because each of them is rare.
    """
    counts = Counter(pixels(image.crop(box)))
    if not counts:
        raise ValueError(f"region {box} is empty")
    background = counts.most_common(1)[0][0]
    candidates = [colour for colour, count in counts.items() if count >= MIN_PIXELS]
    if not candidates:
        raise ValueError(f"region {box} has no repeated colour")
    foreground = max(
        candidates,
        key=lambda colour: abs(relative_luminance(colour) - relative_luminance(background)),
    )
    return contrast(background, foreground), background, foreground


def parse_region(value: str) -> tuple[str, tuple[int, int, int, int]]:
    name, _, geometry = value.partition("=")
    parts = [int(part) for part in geometry.split(",")] if geometry else []
    if len(parts) != 4:
        raise ValueError(f"{value!r} is not name=x,y,width,height")
    x, y, width, height = parts
    return name, (x, y, x + width, y + height)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    path = argv[1]
    if not os.path.exists(path):
        print(f"no such file: {path}")
        return 1
    image = to_srgb(Image.open(path))
    regions = argv[2:]
    if not regions:
        overall = measure(image, (0, 0, image.width, image.height))
        print(f"{path}  whole image {overall[0]:.2f}:1  background {overall[1]}")
        return 0

    failures = 0
    unwarned = True
    print(f"{os.path.basename(path)}  {image.width}x{image.height} px, sRGB")
    for value in regions:
        try:
            name, box = parse_region(value)
            # A region that runs past the picture is a mistake in the caller's coordinates, not a
            # contrast result. Saying so beats reporting the black that the empty part becomes.
            if box[2] > image.width or box[3] > image.height:
                raise ValueError(
                    f"region runs past the picture ({image.width}x{image.height}): "
                    f"{box[0]},{box[1]},{box[2]},{box[3]}"
                )
            ratio, background, foreground = measure(image, box)
        except ValueError as error:
            print(f"  {value}: {error}")
            failures += 1
            continue
        verdict = "ok " if ratio >= TEXT_THRESHOLD else "LOW"
        if ratio < TEXT_THRESHOLD:
            failures += 1
        note = "" if ratio >= TEXT_THRESHOLD else f"  (a mark needs {MARK_THRESHOLD}:1, text {TEXT_THRESHOLD}:1)"
        print(
            f"  {verdict} {name:34s} {ratio:5.2f}:1"
            f"  on {background} drawn in {foreground}{note}"
        )
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
