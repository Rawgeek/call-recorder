#!/usr/bin/env python3
"""Report the left and right ink edges of a horizontal band, and the card edges around it.

    scripts/scan-band.py render.png X Y W H

X/Y/W/H are in points, like the other scripts. The band is scanned in render pixels.
"""
import sys
from PIL import Image

def main():
    path = sys.argv[1]
    x, y, w, h = (int(a) for a in sys.argv[2:6])
    image = Image.open(path).convert("RGB")
    left = x * 2
    top = y * 2
    right = (x + w) * 2
    bottom = (y + h) * 2
    surface = image.getpixel((left + 2, top + 2))
    print(f"path={path} band=({x},{y},{w},{h}) surface={surface}")
    for row in range(top, bottom):
        runs = []
        start = None
        for col in range(left, right):
            pixel = image.getpixel((col, row))
            # Ink is anything that is not the surface and not a near neighbour of it.
            differs = sum(abs(a - b) for a, b in zip(pixel, surface)) > 12
            if differs and start is None:
                start = col
            elif not differs and start is not None:
                runs.append((start / 2, (col - 1) / 2))
                start = None
        if start is not None:
            runs.append((start / 2, (right - 1) / 2))
        if runs:
            first = runs[0][0]
            last = runs[-1][1]
            padded = " ".join(f"{a:.1f}-{b:.1f}" for a, b in runs[:6])
            print(f"  y={row / 2:7.1f}  first={first:7.1f} last={last:7.1f}  runs: {padded}")

main()

