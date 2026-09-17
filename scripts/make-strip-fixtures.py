#!/usr/bin/env python3
"""Draw the two rows the spacing checker has to tell apart.

A row keeps 12 points on each side, and its right-hand content is a control that sits on that
gutter. A row whose right-hand content stops far short of it is a real fault, and the checker
exists to name it. These fixtures are that pair, drawn from the same numbers the app uses, so a
change to how the checker picks a row's kind can be tested against both before it is trusted.

The card holds three thin bands of content rather than one block. That is what makes it a card to
the checker and not a filled control: the checker reads the colour that fills most of the row, and
a single tall block of ink would be the majority instead of the surface behind it."""
import sys
from PIL import Image

SCALE = 2
SURFACE = (30, 30, 30)
CARD = (45, 45, 45)
INK = (200, 200, 200)

def draw(path, right_inset_pt, left_inset_pt=12, edge_inset_pt=8, width_pt=360, height_pt=100):
    image = Image.new('RGB', (width_pt * SCALE, height_pt * SCALE), SURFACE)
    card = (16 * SCALE, 10 * SCALE, (width_pt - 16) * SCALE, (height_pt - 10) * SCALE)
    for x in range(card[0], card[2]):
        for y in range(card[1], card[3]):
            image.putpixel((x, y), CARD)
    card_width = card[2] - card[0]
    band_pt = 4
    band = band_pt * SCALE
    # Three bands, the first and last sitting on the row's own edge inset, so the measured top
    # and bottom insets are the row's padding rather than a band's position.
    first = 10 + edge_inset_pt
    last = (height_pt - 10) - edge_inset_pt - band_pt
    for index, centre in enumerate((first, 50, last)):
        top = centre * SCALE
        # The shortest band stops at the row's trailing gutter; the others stop short of it.
        left = card[0] + left_inset_pt * SCALE
        right = card[2] - (right_inset_pt if index == 0 else right_inset_pt) * SCALE
        for x in range(left, right):
            for y in range(top, top + band):
                image.putpixel((x, y), INK)
    image.save(path)
    print(path, 'left inset', left_inset_pt, 'right inset', right_inset_pt, 'card', card)

if __name__ == '__main__':
    draw('/tmp/strip-good.png', right_inset_pt=12)
    draw('/tmp/strip-broken.png', right_inset_pt=40)
