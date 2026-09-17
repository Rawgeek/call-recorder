#!/usr/bin/env python3
"""Enlarge part of a rendered window, so padding is judged on pixels and not on impression.

    scripts/zoom.py dist/preview/settings-general.png /tmp/out.png X Y W H SCALE

X, Y, W, and H are in points, like the other scripts; the render is 2 points to the pixel. SCALE
is how many times to enlarge the crop, one to eight. Pixels are copied rather than interpolated,
because a soft edge is exactly what a padding fault looks like.

This is the companion to the measuring scripts, not a replacement for them. They report a number
and cannot say what the number is; this shows what the number is and cannot report it.
"""
import sys
from PIL import Image


def main():
    if len(sys.argv) != 8:
        raise SystemExit(__doc__)
    source, out = sys.argv[1], sys.argv[2]
    x, y, w, h, scale = (int(a) for a in sys.argv[3:8])
    if not 1 <= scale <= 8:
        raise SystemExit("scale must be 1 to 8")
    image = Image.open(source)
    crop = image.crop((x * 2, y * 2, (x + w) * 2, (y + h) * 2)).convert("RGB")
    crop = crop.resize((crop.width * scale, crop.height * scale), Image.NEAREST)
    crop.save(out)
    print(f"{out}  {crop.size[0]}x{crop.size[1]} px  from ({x}, {y}) at {scale}x")


main()

