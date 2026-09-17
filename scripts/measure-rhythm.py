#!/usr/bin/env python3
"""List the vertical bands of content down the pane, so the rhythm can be read as numbers.

    scripts/measure-rhythm.py render.png [x0 x1]

Only columns between x0 and x1 are considered, so the sidebar can be left out. Each band is a
run of rows holding ink, with its height and the gap above it. Text lines, rules, and controls
all appear; what matters is the step from one to the next.
"""
import sys
from PIL import Image

def main():
    path = sys.argv[1]
    image = Image.open(path).convert("RGB")
    width, height = image.size
    x0 = int(float(sys.argv[2]) * 2) if len(sys.argv) > 2 else 0
    x1 = int(float(sys.argv[3]) * 2) if len(sys.argv) > 3 else width

    def surface():
        votes = {}
        for x, y in ((width - 3, 2), (width - 3, height - 3)):
            pixel = image.getpixel((x, y))
            votes[pixel] = votes.get(pixel, 0) + 1
        return max(votes, key=votes.get)

    base = surface()
    rows = []
    for y in range(height):
        ink = any(
            sum(abs(a - b) for a, b in zip(image.getpixel((x, y)), base)) > 10
            for x in range(x0, x1, 2)
        )
        rows.append(ink)

    bands = []
    start = None
    for y, ink in enumerate(rows):
        if ink and start is None:
            start = y
        elif not ink and start is not None:
            bands.append((start, y - 1))
            start = None
    if start is not None:
        bands.append((start, height - 1))

    print(f"{path}  {width // 2}x{height // 2} pt   columns {x0 // 2}..{x1 // 2} pt")
    previous_end = None
    for start, end in bands:
        gap = "" if previous_end is None else f"  gap {start / 2 - previous_end / 2:5.1f}"
        print(f"  y {start / 2:7.1f}..{(end + 1) / 2:7.1f}  h {(end + 1 - start) / 2:5.1f}{gap}")
        previous_end = end + 1

main()

