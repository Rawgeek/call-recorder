#!/usr/bin/env python3
"""Report the last and first rows of ink in a window, against the window's own edges.

    scripts/measure-margins.py render.png

Prints, in points: the distance from the window's top/left/right/bottom edge to the nearest
content, and a note when the content is a control rather than text.

The measurement is a coarse one: it finds rows and columns holding any pixel that differs from
the corner pixel, which stands in for the window's own surface. It is enough to catch a control
that sits on the window edge, which is what a missing margin looks like.
"""
import sys
from PIL import Image

def corner_surface(image):
    width, height = image.size
    votes = {}
    for x, y in ((2, 2), (width - 3, 2), (2, height - 3), (width - 3, height - 3)):
        pixel = image.getpixel((x, y))
        votes[pixel] = votes.get(pixel, 0) + 1
    return max(votes, key=votes.get)

def main():
    for path in sys.argv[1:]:
        image = Image.open(path).convert("RGB")
        width, height = image.size
        surface = corner_surface(image)
        threshold = 10

        def differs(pixel):
            return sum(abs(a - b) for a, b in zip(pixel, surface)) > threshold

        rows = [y for y in range(height) if any(differs(image.getpixel((x, y))) for x in range(0, width, 3))]
        cols = [x for x in range(width) if any(differs(image.getpixel((x, y))) for y in range(0, height, 3))]
        if not rows or not cols:
            print(f"{path}: no content")
            continue
        print(
            f"{path}  {width // 2}x{height // 2} pt"
            f"  top {rows[0] / 2:.1f}  bottom {(height - 1 - rows[-1]) / 2:.1f}"
            f"  left {cols[0] / 2:.1f}  right {(width - 1 - cols[-1]) / 2:.1f}"
        )

main()

