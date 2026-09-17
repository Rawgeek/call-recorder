#!/usr/bin/env python3
"""Check a rendered window against the spacing the design system declares.

The layout script reports where things are. This one says whether the numbers are right.

Every card in the app is drawn by CRSettingsCard and every row by CRSettingsRow, so every card
owes the same four insets: CR.Space.section of gutter on the left and right, and CR.Space.item
above its first row and below its last. A view that hand-rolls its own padding drifts by a few
points, which is invisible in a picture and obvious in a column of numbers.

Finding the card is the whole difficulty. A card is a rounded rectangle with a half-point stroke,
so the outermost pixel of the fill is not the card's edge, and a row just inside the top is
narrower than the card because of the corner. Measuring either one reports every inset a few
points small, or reports the stroke itself as content and every inset as zero.

So the card is found by flooding its fill from the middle. The flood reaches exactly the pixels
that are card and nothing else: the stroke is a different colour, so it bounds the region, and
the corners bound it too. Whatever the flood cannot reach, and that is not the window's own
surface, is content.

    scripts/measure-spacing.py dist/preview/settings-general.png
    scripts/measure-spacing.py dist/preview/*.png
"""

from __future__ import annotations

import os
import sys
from collections import Counter, deque

from PIL import Image

# Previews are retina bitmaps, so a point is two pixels. Set PREVIEW_SCALE when a preview was
# rendered at another scale.
SCALE = int(os.environ.get("PREVIEW_SCALE", "2"))

# A card's fill is a faint step off the window behind it. This is the smallest difference that
# counts as the card rather than the window.
CARD_LIFT = 2
# A window's own material is not one flat colour: the popover's background drifts by about eight
# as it falls away from the menu bar. That drift is not a surface, and a run scan that treated it
# as one merged the button, the gap below it, and the row under that into a single 97-point
# surface. The faintest real surface is a card, which sits about 27 above the window, so the bar
# for deciding that a column holds something sits between them.
RUN_LIFT = 12
# How far a run's own fill has to sit from the window before the run is a filled control rather
# than a surface. A card is a 4.5 % white fill, which measures about 27 on a dark window; a button
# is a solid accent or grey, which measures about 320. Anything between is a control.
FILL_STRENGTH = 120
# Text and controls stand far out of the card fill. This separates content from the fill.
#
# A filled button casts a soft shadow, which spreads a faint halo seven points past the button in
# every direction. The halo is part of the drawing, but it is not the control, and counting it
# would report every card that holds a filled button as having a top padding of nine and a bottom
# one of eight. The two are far apart, so the line between them is easy to place: measured on the
# storage card, whose only content is one row of buttons, the brightest shadow lifts the fill by
# 66 and the dimmest real mark by about 130. Every control and every piece of text is far above
# this number, and no shadow reaches it.
CONTENT_LIFT = 80
# The declared inset of a card's content, which is what the report checks against.
GUTTER = 16
ROW = 12
# A card nested inside another card keeps the tighter inset, so that the pair reads as one thing
# inside another rather than as two cards at the same level. The speaker review window draws each
# transcript sample this way.
NESTED = 8
# A strip is a row that is its own surface: a disclosure row in the popover, a person in the picker.
# It is narrower than a card, so it keeps a tighter gutter, and it holds a single line of content
# rather than a list, so its row padding is smaller too. Its text ink measures about two points
# below the top of its line box.
STRIP = 12
STRIP_ROW = 8
# How much a strip's horizontal inset may measure short when the thing on that edge is a glyph.
#
# A strip's leading and trailing content is a control, and in the participant picker both are SF
# Symbols: a selection circle on the left and a pencil on the right. A glyph's ink does not fill
# its frame, so the ink measures inside the padding the row actually declares. On the picker's
# 599.5-point rows the circle's ink begins 13.5 points from the pill's left edge and the pencil's
# ends 13.0 from its right one, against a declared 12 in both cases. Text and buttons do not have
# this slack, which is why it is allowed here and not for a card.
#
# The allowance is 2.5 points, and it is bounded on purpose: a strip that really kept 8 instead of
# 12 misses by 4 and is still named. The value was checked that way, by re-rendering the picker
# with the row at `CR.Space.snug` and confirming the report called it out.
GLYPH_SLACK = 2.5
# A difference this small is the antialiasing on a glyph's own bounding box, not a layout fault.
TOLERANCE = 1.0
# A card's vertical padding is 12 points, but what the eye measures is the ink inside the row, and
# every control sits centred in a 30-point slot. Text ink starts about two and a half points below
# the top of its line box, and a small switch is twenty-two points tall, so it floats four points
# inside the slot. A row can therefore measure anywhere between 12 and 19 from the card's edge
# depending only on which control it holds, and all of those are the same padding. The horizontal
# gutters have no such slack, so those are held to the exact number.
ROW_MIN = ROW - TOLERANCE
ROW_MAX = ROW + 2.5 + 4
# A card shorter than this is a heading or a hairline rather than a card.
MIN_CARD = 40


def difference(left: tuple, right: tuple) -> int:
    return sum(abs(a - b) for a, b in zip(left, right))


def card_runs(image, column: int, surface: tuple) -> list:
    """The vertical runs of a column that are not the window's own surface."""
    runs = []
    start = None
    for y in range(image.size[1]):
        on_card = difference(image.getpixel((column, y)), surface) > RUN_LIFT
        if on_card and start is None:
            start = y
        elif not on_card and start is not None:
            runs.append((start, y - 1))
            start = None
    if start is not None:
        runs.append((start, image.size[1] - 1))
    return runs


def interior_of(image, column: int, top: int, bottom: int, fill: tuple) -> set:
    """Every pixel reachable from the card's middle that is drawn in the card's own fill."""
    width, height = image.size

    # The first pixel down the column that matches the fill. A tall card can have a row divider
    # where this starts looking, and a button's shadow can bridge one surface to the next, so the
    # fill is chosen before this point rather than read from a single pixel.
    start = None
    for y in range(top + 1, bottom):
        if difference(image.getpixel((column, y)), fill) <= CARD_LIFT:
            start = (column, y)
            break
    if start is None:
        return set()

    seen = {start}
    queue = deque([start])
    while queue:
        x, y = queue.popleft()
        for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
            if not (0 <= nx < width and 0 <= ny < height):
                continue
            if (nx, ny) in seen:
                continue
            if difference(image.getpixel((nx, ny)), fill) > CARD_LIFT:
                continue
            seen.add((nx, ny))
            queue.append((nx, ny))
    return seen


def measure(path: str) -> None:
    image = Image.open(path).convert("RGB")
    width, height = image.size
    # The window's own surface, which a card is drawn on top of. Every window in the app keeps its
    # bottom right corner clear, so that pixel is the surface whatever the window holds.
    surface = image.getpixel((width - 4, height - 4))
    column = int(width * 0.75)

    cards = [
        (top, bottom)
        for top, bottom in card_runs(image, column, surface)
        if bottom - top > MIN_CARD * SCALE
    ]

    print()
    print(f"{path}  {width // SCALE}x{height // SCALE} pt  {len(cards)} card(s)")
    if not cards:
        print("  no cards on this surface")
        return

    worst = 0.0
    for top, bottom in cards:
        # The run is read from its own left margin rather than from a fixed column. A column chosen
        # by width alone lands inside whatever control the card happens to end with, and a filled
        # button is grey where a card is nearly the window's colour, so the sample came back as the
        # button. The run's leftmost column is its edge, and a few points inside that is the card's
        # own padding, which nothing else is ever drawn in.
        rows_of_run = range(top, bottom + 1)

        def is_surface_column(x: int) -> bool:
            return all(
                difference(image.getpixel((x, y)), surface) <= RUN_LIFT for y in rows_of_run
            )

        leftmost = column
        while leftmost > 0 and not is_surface_column(leftmost - 1):
            leftmost -= 1
        # Far enough in to clear the card's rounded corner, then read down the whole run and take
        # the colour it holds most of. Any single row can be wrong: a tall card can have a divider
        # or a line of text across it, and a button's run starts on the shadow above it. Over the
        # whole run the fill is the majority for both, because a surface and a control are each
        # mostly their own fill.
        probe = min(leftmost + 40, width - 1)
        middle = (top + bottom) // 2
        sampled = Counter(image.getpixel((probe, y)) for y in range(top, bottom + 1))
        fill = sampled.most_common(1)[0][0]
        if difference(fill, surface) <= CARD_LIFT:
            # A card whose fill is its window's colour has no visible edge to find. The first pixel
            # across from the run's own left edge still finds whatever it is drawn on.
            for x in range(leftmost, width):
                candidate = image.getpixel((x, middle))
                if difference(candidate, surface) > CARD_LIFT:
                    fill = candidate
                    probe = x
                    break
        # A run can be a filled control rather than a surface: a full-width button has a fill of its
        # own and stands about as tall as a short card. The two are told apart by how far their fill
        # sits from the window. A surface is drawn as a faint step off the window, which is what
        # makes it read as glass rather than as a shape; a control's fill is a strong step, because
        # a control has to look pressable. This tool measures surfaces, so a run that is a control
        # is not one of its subjects.
        if difference(fill, surface) > FILL_STRENGTH:
            continue
        interior = interior_of(image, probe, top, bottom, fill)
        if not interior:
            print(f"  card y {top / SCALE:7.1f}..{bottom / SCALE:7.1f}  could not be read")
            continue

        # The flood stops one pixel short of the card's stroke on every side, so the card's true
        # edge is one pixel further out than the region it reached.
        left = min(x for x, _ in interior) - 1
        right = max(x for x, _ in interior) + 1
        card_top = min(y for _, y in interior)
        card_bottom = max(y for _, y in interior)

        # Reading one pixel at a time is a call into C for every pixel of every card, which turns a
        # window of five cards into a minute of work. The card is read once into a flat list of
        # differences from its own fill, and everything after this indexes that list.
        box = (left, card_top, right + 1, card_bottom + 1)
        box_width = right + 1 - left
        flat = list(image.crop(box).getdata())
        lift = [difference(pixel, fill) for pixel in flat]
        del flat

        # The flood does not reach into the rounded corners, so on the rows near a card's ends its
        # span is narrower than the card. Scanning a whole row would then read the window surface
        # that shows outside the corner as a mark on the card. Each row and column is scanned only
        # where the flood actually reached, which is the card itself.
        span_by_row = {}
        span_by_column = {}
        for x, y in interior:
            low, high = span_by_row.get(y, (x, x))
            span_by_row[y] = (min(low, x), max(high, x))
            low, high = span_by_column.get(x, (y, y))
            span_by_column[x] = (min(low, y), max(high, y))

        # A mark counts as content only when it is thicker than a line on both axes. A card's
        # dividers are one pixel tall and a control's own edge is one pixel wide; neither is a row
        # of text, and counting either would report the inset of a line instead of the inset of the
        # thing the line separates. A pixel also has to sit inside the flood's span with both of
        # its neighbours, or the card's own stroke would count as the mark beside the edge.
        def is_content(x: int, y: int, lift_limit: int = CONTENT_LIFT) -> bool:
            row_low, row_high = span_by_row[y]
            column_low, column_high = span_by_column[x]
            if not row_low < x < row_high or not column_low < y < column_high:
                return False
            index = (y - card_top) * box_width + (x - left)
            if lift[index] <= lift_limit:
                return False
            vertical = (
                y - 1 > column_low and lift[index - box_width] > lift_limit
            ) or (
                y + 1 < column_high and lift[index + box_width] > lift_limit
            )
            horizontal = (
                x - 1 > row_low and lift[index - 1] > lift_limit
            ) or (
                x + 1 < row_high and lift[index + 1] > lift_limit
            )
            return vertical and horizontal

        rows = [
            y
            for y in sorted(span_by_row)
            if any(
                is_content(x, y)
                for x in range(span_by_row[y][0] + 1, span_by_row[y][1] - 1)
            )
        ]
        if not rows:
            print(f"  card y {top / SCALE:7.1f}..{bottom / SCALE:7.1f}  empty")
            continue

        # Every column the flood reached is tested between the first and last row that holds
        # content. is_content already refuses a pixel that is not strictly inside its own row and
        # column spans, so nothing here has to know where the content stops along the column.
        columns = [
            x
            for x in sorted(span_by_column)
            if any(is_content(x, y) for y in range(rows[0], rows[-1] + 1))
        ]
        if not columns:
            print(f"  card y {top / SCALE:7.1f}..{bottom / SCALE:7.1f}  empty")
            continue

        inset = {
            "top": (rows[0] - card_top) / SCALE,
            "bottom": (card_bottom - rows[-1]) / SCALE,
            "left": (columns[0] - left) / SCALE,
            "right": (right - columns[-1]) / SCALE,
        }
        # A card inside a scrolling pane runs off the top or the bottom of the window, so the inset
        # it owes that edge cannot be seen. Only the edges that are on screen are checked. The
        # flood's own bounds are the test, not the run's: a run can start on the surface above.
        clipped = {
            "top" if card_top < 2 else None,
            "bottom" if card_bottom > image.size[1] - 3 else None,
        } - {None}

        # The app draws three kinds of surface, and each keeps its own inset. Naming the one a
        # surface matched is what makes a report readable: a strip that keeps 12 and 8 is right,
        # and saying so is more useful than failing it against a card's 16 and 12.
        spread = max(inset.values()) - min(inset.values())
        if spread <= 2.5 and abs(inset["left"] - NESTED) <= TOLERANCE:
            print(
                f"  ok  card y {top / SCALE:7.1f}..{bottom / SCALE:7.1f}"
                f"  nested, inset {inset['left']:5.1f} (want {NESTED})"
            )
            continue
        if spread > 2.5 and abs(inset["left"] - STRIP) <= TOLERANCE:
            strip_ok = (
                STRIP_ROW - 0.5 <= inset["top"] <= STRIP_ROW + 4
                and STRIP_ROW - 0.5 <= inset["bottom"] <= STRIP_ROW + 4
                and abs(inset["right"] - STRIP) <= TOLERANCE
            )
            print(
                f"  {'ok ' if strip_ok else 'OFF'} card y {top / SCALE:7.1f}..{bottom / SCALE:7.1f}"
                f"  strip, inset l/r {inset['left']:5.1f}/{inset['right']:.1f} (want {STRIP})"
                f" t/b {inset['top']:5.1f}/{inset['bottom']:.1f} (want {STRIP_ROW})"
            )
            if not strip_ok:
                worst = max(worst, 1.0)
            continue
        if (
            spread > 2.5
            and STRIP - TOLERANCE <= inset["left"] <= STRIP + GLYPH_SLACK
            and STRIP - TOLERANCE <= inset["right"] <= STRIP + GLYPH_SLACK
        ):
            strip_ok = (
                STRIP_ROW - 0.5 <= inset["top"] <= STRIP_ROW + 4
                and STRIP_ROW - 0.5 <= inset["bottom"] <= STRIP_ROW + 4
            )
            print(
                f"  {'ok ' if strip_ok else 'OFF'} card y {top / SCALE:7.1f}..{bottom / SCALE:7.1f}"
                f"  strip, glyph edges {inset['left']:5.1f}/{inset['right']:.1f} (want {STRIP})"
                f" t/b {inset['top']:5.1f}/{inset['bottom']:.1f} (want {STRIP_ROW})"
            )
            if not strip_ok:
                worst = max(worst, 1.0)
            continue

        faults = {}

        # Text ink starts inside its line box, so the leading edge of a card measures a little
        # deeper than its padding when the first thing in the row is a word or a glyph. The
        # trailing edge is a control's own edge, which sits on the gutter exactly.
        #
        # A callout whose leading glyph lands within a point of 12 is read as a strip instead, and
        # reported against the strip's own trailing gutter. That reads as a fault on a card that is
        # placed correctly: the popover's two permission cards measure 13.5 and 13.0 because their
        # SF Symbols have different ink, and the half point decides which kind of surface the row
        # is taken to be. The ambiguity was left in place rather than traded away. Letting a row
        # leave the strip branch when its trailing inset is far from 12 also silences a real fault,
        # which `scripts/make-strip-fixtures.py` draws and the checker names; the fixture pair is
        # kept so that trade can be seen before anyone makes it.
        leading_floor = GUTTER - 2.5

        # Some surfaces hold content that does not span them: a callout's last item is a
        # content-sized button, and a specimen sheet centres what it shows. A surface like that has
        # no control sitting on its gutter to measure, so its horizontal insets say nothing about
        # its padding. Saying so is honest; failing it against a card would be wrong. The layout
        # script is the tool for the other half of this: it names any run of content that stops
        # short of the gutter its neighbours share.
        if inset["right"] >= GUTTER + TOLERANCE and inset["left"] >= leading_floor:
            print(
                f"  --  card y {top / SCALE:7.1f}..{bottom / SCALE:7.1f}"
                f"  content-sized, no control on the gutter"
                f" (insets {inset['left']:5.1f}/{inset['right']:5.1f})"
            )
            continue

        for key, value in inset.items():
            if key in clipped:
                continue
            if key in ("top", "bottom"):
                if not ROW_MIN <= value <= ROW_MAX:
                    faults[key] = value - ROW
            elif key == "left":
                if not leading_floor <= value <= GUTTER + TOLERANCE:
                    faults[key] = value - GUTTER
            elif abs(value - GUTTER) > TOLERANCE:
                faults[key] = value - GUTTER

        want = {
            "top": f"{ROW_MIN}-{ROW_MAX}",
            "bottom": f"{ROW_MIN}-{ROW_MAX}",
            "left": f"{leading_floor}-{GUTTER + TOLERANCE}",
            "right": str(GUTTER),
        }
        worst = max([worst] + [abs(value) for value in faults.values()])
        verdict = "ok " if not faults else "OFF"
        detail = " ".join(
            f"{key} {value:5.1f}/{want[key]}{'*' if key in clipped else ''}"
            for key, value in inset.items()
        )
        print(f"  {verdict} card y {top / SCALE:7.1f}..{bottom / SCALE:7.1f}  {detail}")

    print(f"  worst departure: {worst:.1f} pt   (* marks an edge the window clips)")


def main() -> None:
    paths = [argument for argument in sys.argv[1:] if not argument.startswith("--")]
    if not paths:
        print(__doc__)
        return
    for path in paths:
        try:
            measure(path)
        except Exception as error:  # one unreadable file must not stop a batch
            print(f"{path}: {error}")


if __name__ == "__main__":
    main()
