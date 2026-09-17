#!/usr/bin/env python3
"""Measure the layout grid of a rendered window.

A spacing problem is hard to argue about and hard to see: a row with 12 points of padding above
it and 20 below looks almost right in a picture. This reads a PNG written by scripts/preview.sh
and reports the numbers instead, so a padding change can be checked rather than eyeballed.

For each image it prints the panels (settings cards), the text and controls inside them, and the
space above and below each band. Values are points, not pixels, so they can be compared directly
with the numbers in DesignSystem.swift.

    scripts/measure-layout.py dist/preview/settings-general.png
    scripts/measure-layout.py dist/preview/*.png
"""

from __future__ import annotations

import os
import sys
from collections import Counter
from dataclasses import dataclass

from PIL import Image

# The contrast helpers live in a sibling script, and its name has a hyphen in it, so it is loaded
# by path rather than by name.
import importlib.util

_contrast_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "measure-contrast.py")
_contrast_spec = importlib.util.spec_from_file_location("measure_contrast", _contrast_path)
measure_contrast = importlib.util.module_from_spec(_contrast_spec)
_contrast_spec.loader.exec_module(measure_contrast)

MIN_PIXELS = measure_contrast.MIN_PIXELS
TEXT_THRESHOLD = measure_contrast.TEXT_THRESHOLD
contrast = measure_contrast.contrast
pixels = measure_contrast.pixels
relative_luminance = measure_contrast.relative_luminance
to_srgb = measure_contrast.to_srgb

# A row counts as holding something when a pixel rises this far above the surface behind it.
# Inside a card the bar is higher: the card's own border and its hairline dividers sit between the
# fill and the text, and neither is content. A control on a card is brighter than both.
TEXT_LIFT = 6
CARD_TEXT_LIFT = 25
PANEL_LIFT = 3
# A band this short is a hairline: a divider, or the edge of a control.
RULE_HEIGHT = 3
# A piece of a band whose ink is this close to its surface is a divider or a shadow edge rather
# than text. The value is the narrowest difference a divider is drawn with, with room to spare.
LINE_CONTRAST = 1.6
# Content closer than this to a divider is reported as tight. It is `CR.Space.inner`, the
# smallest gap the design uses between two things that are not the same object.
TIGHT_GAP = 8
# How far a run of content may stop short of the gutter before the report calls it out. It is
# under the 7 points an unaligned icon leaves and over the point of rounding a glyph's own
# bounding box adds, so the report names the real gap and not the noise around it.
EDGE_SLACK = 5
# How near the edge a run must end to be judged against it at all. A control sits at the gutter;
# a sentence ends wherever its last word did, and a paragraph that wraps early is not a margin
# fault. This window is what separates the two.
EDGE_WINDOW = 40
# The shortest band that can be a line of text. A hairline rule and a card's own border are bands
# too, and neither is content that a margin applies to.
EDGE_MIN_HEIGHT = 8
# The shortest run that can be a card. The column a card is found in crosses other things as
# well: a title sits on it, a list row sits on it, and a footer's hairline crosses it. Each makes
# a run of its own a few points tall, and a run that short is a line of content rather than a
# surface that content can be laid out on. A card in this app is at least a heading and a row.
MIN_CARD = 40
# How far the fill beside a run of text must differ from the surface before the text is read as
# sitting inside a filled control. A chip's tint is a fraction of a tone, not a stroke, so the bar
# is low: it only has to be distinguishable from the surface, not bright.
CONTROL_FILL_GAP = 2
# A filled button casts a soft shadow, which spreads a few points past the button in every
# direction and fades as it goes. The shadow rises above the bar a band is found with, so a band
# whose leading edge is a shadow measures the halo instead of the control and reports the row as
# having been drawn past its own margin.
#
# Strength alone cannot tell the two apart. A shadow is drawn as a tint of the button, so how far
# it lifts a pixel depends on the appearance: measured beside the same row, it reaches 11 levels
# on a dark window and 15 on a light one, and on that light window a chip's own fill is only 13.
# No single bar separates a shadow from a fill in both appearances. Shape does, in both.
#
# A shadow is a ramp: each pixel is a level or two further from the window than the one outside it,
# and never more. A control and a letter both begin with a step. So the edge of a band is the first
# column whose level jumps from the column outside it. Measured on the popover's transport row,
# the shadow climbs by 0 to 2 levels a column and the capsule behind it jumps 84 in one; on the
# same row in the light appearance the figures are the same shape, 1 to 2 against 58.
MARK_LIFT = 6
# The rise that makes a column an edge. It is over the drift inside a shadow and under the
# lightest edge the app draws, which is a chip's fill stepping 13 levels off its window.
STEP_LIFT = 8
# How far a column has to stand out before it is content on its own account, whatever the columns
# inside it do. A shadow never reaches this: measured at its brightest beside a filled button, it
# holds 11 levels on a dark window and 15 on a light one. Antialiasing at the start of a letter
# passes it: a glyph's outer column is a faint step, and the column after it is the glyph.
#
# The bar is what keeps the halo trim from eating a letter. A shadow is left to the step rule,
# which finds the control behind it, and a letter is taken where it starts, however gradually it
# fades in. Reading the two the same way walked six points into a label, because a round letter
# has no step in its outer column to find.
MARK_STRONG = 16
# A menu draws its indicator glyph inside its own frame, a few points in from the edge, and the
# app cannot move it: the glyph is the control's chrome, and the frame is what sits on the gutter.
# The glyph is told apart from content by the surface between them. A glyph set apart by a real
# gap is the control's own indicator; text that simply stops short of the gutter has no gap before
# it, which is the fault this check exists to find.
INDICATOR_GAP = 5
# The widest a control's indicator can be. A chevron is a few points across; a label is not, so a
# group of words separated by a gap is not mistaken for one.
INDICATOR_MAX = 14
# The tallest an indicator can be. A chevron is short and wide; a control's own glyph is a shape
# with a full icon's height, and a button that misses its gutter has to keep being reported. The
# two are measured at 4.5 and 10.5 points, so the line between them is easy to place.
INDICATOR_HEIGHT = 7
# The inset every modal in the app keeps around its footer row, and the most a footer may sit
# closer to one end of the window than the other. The same padding modifier draws all four sides,
# so the two vertical insets are the same number by construction; a view that hand-rolls one of
# them drifts by more than the point of rounding a button's own box adds.
# The two insets the app uses around a window's own content: the popover keeps the section one
# and every other window keeps the screen one. The gap between one band and the next is the item
# one.
SCREEN = 20
SECTION = 16
ITEM = 12
# How close two insets have to be to count as the same measurement, once the ink inside a
# control's own box has cancelled out of the comparison.
FOOTER_TOLERANCE = 1.0
# The app composes a footer row in one of two ways, and each declares its own pair of insets. A
# modal pads a row of buttons by SCREEN on every side, so the space above the row and the space
# below it are the same number. A filled button drops its shadow two points further below itself
# than it reaches above itself, which shifts the band the eye sees by twice that, so a padded row
# is allowed to lean towards the window edge by this much.
FOOTER_SHADOW_BIAS = 4
# The popover stacks its toolbar as one more band of the popover, so the row keeps the item
# spacing above it and the window padding below it. Whatever the row draws inside its own box
# cancels out of the difference between the two insets, which leaves exactly the two tokens.
FOOTER_STACK_GAP = SECTION - ITEM
# A footer is a short block against the bottom edge. Content that fills the window is a scrolling
# pane, and the rows of the last card in it are not a footer however they end.
FOOTER_MAX = 0.3
# Points are what DesignSystem.swift uses. A preview is a retina bitmap, so it is twice as large.
# Set PREVIEW_SCALE when a preview was rendered at another scale.
SCALE = int(os.environ.get("PREVIEW_SCALE", "2"))


@dataclass
class Band:
    """A run of rows that hold something brighter than the surface behind it."""

    top: int
    bottom: int
    left: int
    right: int


class Shot:
    def __init__(self, path: str) -> None:
        image = Image.open(path).convert("L")
        self.path = path
        self.pixels = image.load()
        self.width, self.height = image.size
        # A settings window is 900 points wide and renders at 2x; a menu bar popover renders at
        # 2x as well. Anything narrower is a point-for-point render.
        self.scale = SCALE
        self.background, self.left = self.surface()
        # Text and a card are on the far side of the window colour from it: brighter on a dark
        # window and darker on a light one. Every threshold below is a distance away from the
        # surface in that direction, so one reading of the picture serves both appearances instead
        # of the light one reporting an empty pane.
        self.ink_direction = self.read_ink_direction()
        # The band scan starts at the pane edge. A card's border is dimmer than the text on it, so
        # the higher bar used inside a card keeps the border out of the picture.
        self.scan_left = self.left
        self.panel_rows, self.panel_background = self.panels()
        self.tight_gap = TIGHT_GAP
        self._panel_fill: int | None = None
        self._row_context: dict[int, tuple[int, int, int] | None] | None = None

    # MARK: - Reading the surfaces

    def read_ink_direction(self) -> int:
        """Which way ink lies from the window colour: +1 if it is brighter, -1 if it is darker.

        The picture is not self-describing about this. A dark window draws its text brighter than
        itself and a light window draws it darker, and the same is true of a card's fill, so one
        sample of the extremes settles it for every surface in the same render.
        """

        darkest, lightest = 255, 0
        for y in range(0, self.height, 2):
            for x in range(0, self.width, 2):
                value = self.pixels[x, y]
                darkest = min(darkest, value)
                lightest = max(lightest, value)
        return 1 if lightest - self.background >= self.background - darkest else -1

    def lift(self, value: int, reference: int) -> int:
        """How far a pixel lies from the surface behind it, in the direction ink lies."""

        return (value - reference) * self.ink_direction

    def surface(self) -> tuple[int, int]:
        """The pane background and the column where the pane starts."""

        samples = [self.pixels[self.width - 3, self.height // 2], self.pixels[self.width - 3, self.height // 4]]
        background = max(set(samples), key=samples.count)
        limit = int(self.height * 0.985)
        left = 0
        while left < self.width:
            matching = sum(1 for y in range(self.height) if self.pixels[left, y] == background)
            if matching >= limit:
                break
            left += 1
        return background, left

    def panels(self) -> tuple[list[tuple[int, int]], int]:
        """Vertical runs of a card, read at the column that stays inside a card the longest.

        A card is a rounded rectangle of a lighter fill with a hairline border. The border runs
        the whole height of the card, corners included, so the column with the longest unbroken
        run is a border column, and its runs are exactly the cards.
        """

        column, rows = self.left, []
        best = 0
        for x in range(self.left, self.width, max(1, self.scale // 2)):
            candidate = [
                y
                for y in range(self.height)
                if self.lift(self.pixels[x, y], self.background) > PANEL_LIFT
            ]
            if not candidate:
                continue
            # The longest unbroken run in this column, ignoring gaps of a row or two.
            run = longest = 1
            for previous, current in zip(candidate, candidate[1:]):
                run = run + 1 if current - previous <= 2 else 1
                longest = max(longest, run)
            if longest > best:
                best, column, rows = longest, x, candidate
        if not rows:
            return [], self.background
        card = max(set(self.pixels[column, y] for y in rows), key=lambda v: sum(1 for y in rows if self.pixels[column, y] == v))

        runs: list[tuple[int, int]] = []
        # Anything shorter than a card is the text, the control, or the hairline that happens to
        # cross the same column. Reading one of those as a card gives every row near it the wrong
        # surface to be measured against, which is worse than the row having none.
        floor = MIN_CARD * self.scale
        start = rows[0]
        previous = rows[0]
        for y in rows[1:]:
            if y - previous > 3:
                if previous - start > floor:
                    runs.append((start, previous))
                start = y
            previous = y
        if previous - start > floor:
            runs.append((start, previous))
        return runs, card

    def inside_panel(self, y: int) -> bool:
        return any(top <= y <= bottom for top, bottom in self.panel_rows)

    def inside_control(self, band: Band, fill: int) -> bool:
        """Whether a band of text is written inside a filled control rather than on the surface.

        A chip, a button, and a field all draw their own fill, and each of them pads its label away
        from its own edge by design. Measured against the card's gutter, that padding reads as a
        margin fault when it is the control working correctly. The fill immediately left of the
        text is the test: text written on the surface has the surface beside it.
        """

        beside = [
            self.pixels[x, y]
            for y in range(band.top, band.bottom + 1)
            for x in range(max(self.left, band.left - 6), band.left)
        ]
        if not beside:
            return False
        middle = sorted(beside)[len(beside) // 2]
        return abs(middle - fill) > CONTROL_FILL_GAP

    def content_extent(self, band: Band) -> Band | None:
        """A band with the halo around its controls left out.

        A band is found at a low bar, because the faintest text still has to be found. A filled
        control casts a shadow past its own edge, and the shadow is above that bar, so a band that
        holds a filled control starts where the shadow fades in rather than where the control
        does. Measured against the window, the transport row of the popover begins at 13 points
        when its Resume capsule begins at 16: three points of nothing, reported as though the row
        were drawn past its own margin.

        Each row is read on its own, from the outside in, and its edge is the first column that
        steps off the column outside it rather than the first column that holds anything. A row
        whose leading edge is a shadow therefore reports where the control it belongs to begins,
        and a row of plain text reports the same edge it always did: the ink at the start of a
        glyph steps straight from the surface to the glyph, and the run that follows it is the
        glyph.

        A row that never steps, such as one crossing the shadow before a control on its rounded
        corner, falls back to its first marked column, so nothing that used to be measured stops
        being measured.
        """

        leading: list[int] = []
        trailing: list[int] = []
        stepped: list[int] = []
        for row in range(band.top, band.bottom + 1):
            reference, _ = self.reference(row)
            if self.row_has_step(row, reference, band.left, band.right):
                stepped.append(row)
            edge = self.row_edge(row, reference, band.left, band.right, 1)
            if edge is not None:
                leading.append(edge)
            edge = self.row_edge(row, reference, band.right, band.left, -1)
            if edge is not None:
                trailing.append(edge)
        if not leading or not trailing:
            return None
        # The halo is above and below the control as well as beside it, so the rows that hold
        # nothing but the halo are dropped from the top and the bottom. A row without a step
        # anywhere is a row of the ramp the shadow makes, or a blank row inside a card, and
        # neither is where the row being measured begins or ends.
        top = stepped[0] if stepped else band.top
        bottom = stepped[-1] if stepped else band.bottom
        return Band(top, bottom, min(leading), max(trailing))

    def row_has_step(self, y: int, reference: int, left: int, right: int) -> bool:
        """Whether a row holds an edge anywhere along it."""

        for x in range(left + 1, right + 1):
            rise = self.lift(self.pixels[x, y], reference) - self.lift(
                self.pixels[x - 1, y], reference
            )
            if abs(rise) >= STEP_LIFT:
                return True
        return False

    def row_edge(self, y: int, reference: int, start: int, stop: int, direction: int) -> int | None:
        """Where a row's content begins, reading in from the surface on one side.

        The mark comes first, because a letter starts where its ink starts. The step is what is
        read when the mark is too faint to be content, which is the halo a filled button casts on
        the surface beside it.
        """

        mark = self.first_mark(y, reference, start, stop, direction)
        if mark is not None and self.lift(self.pixels[mark, y], reference) > MARK_STRONG:
            return mark
        step = self.step_edge(y, reference, start, stop, direction)
        return step if step is not None else mark

    def first_mark(self, y: int, reference: int, start: int, stop: int, direction: int) -> int | None:
        """The first column along a row that stands out from the surface at all."""

        x = start
        while x != stop + direction:
            if 0 <= x < self.width and self.lift(self.pixels[x, y], reference) > MARK_LIFT:
                return x
            x += direction
        return None

    def step_edge(self, y: int, reference: int, start: int, stop: int, direction: int) -> int | None:
        """The first column along a row whose level jumps from the column outside it.

        The column outside is the one the scan came from, so an edge is found walking in from the
        surface whichever direction the row is read in. The first column of the scan has nothing
        outside it, so the scan starts one column in.
        """

        x = start + direction
        while x != stop + direction:
            outside = x - direction
            if 0 <= x < self.width and 0 <= outside < self.width:
                rise = self.lift(self.pixels[x, y], reference) - self.lift(
                    self.pixels[outside, y], reference
                )
                if rise >= STEP_LIFT:
                    return x
            x += direction
        return None

    def holds_ink(self, band: Band, x: int) -> bool:
        """Whether any row of a band draws something at this column above the halo bar."""

        for row in range(band.top, band.bottom + 1):
            if self.holds_ink_at(row, x):
                return True
        return False

    def holds_ink_at(self, y: int, x: int) -> bool:
        """Whether one pixel is above the halo bar, read against the surface behind it."""

        reference, _ = self.reference(y)
        return self.lift(self.pixels[x, y], reference) > MARK_LIFT

    def drop_indicator(self, band: Band) -> Band:
        """A band with the control's own indicator glyph left out.

        A menu draws its indicator inside its frame, a few points in from the edge. The frame is
        what sits on the gutter, so the glyph is chrome rather than content: measured, it reads as
        a run that stops six points short of a gutter it was never asked to meet. The rest of the
        run sits far inside the edge and is not judged either way.

        The glyph is separated from what precedes it by a real gap and is only a few points wide.
        Text that merely stops short of the gutter has no such gap, so it keeps being reported,
        which is the whole point of the check.
        """

        columns = [x for x in range(band.left, band.right + 1) if self.holds_ink(band, x)]
        if len(columns) < 2:
            return band
        gap = INDICATOR_GAP * self.scale
        split = None
        for position in range(len(columns) - 1, 0, -1):
            if columns[position] - columns[position - 1] >= gap:
                split = position
                break
        if split is None:
            return band
        width = columns[-1] - columns[split] + 1
        if width > INDICATOR_MAX * self.scale:
            return band
        trailing = columns[split:]
        rows = [
            y
            for y in range(band.top, band.bottom + 1)
            if any(self.holds_ink_at(y, x) for x in trailing)
        ]
        if not rows or rows[-1] - rows[0] + 1 > INDICATOR_HEIGHT * self.scale:
            return band
        return Band(band.top, band.bottom, columns[0], columns[split - 1])

    def extend_to_control(self, band: Band, fill: int, left: int, right: int) -> Band:
        """A band taken out to the edge of the control it ends in.

        A row draws its label on the surface and its control on the right, and the band holds both.
        The control paints its own fill and pads its own label inside that fill, so the row's
        rightmost ink is the label's last letter and not the edge of the thing being looked at:
        a menu picker draws a capsule that stops on the gutter, with its title and its chevron set
        well inside it. What the row is saying about the gutter is where the capsule ends, so the
        run is taken out to that edge before it is measured.

        The far side is extended the same way, so a row whose control leads it is measured from the
        control's leading edge. A control with no fill, such as an icon-only button, is unaffected:
        there is no fill beside the run to walk through, so its glyph keeps standing on the gutter
        it is drawn on and a glyph that misses it is still reported.
        """

        def filled(x: int, y: int) -> bool:
            return abs(self.pixels[x, y] - fill) > CONTROL_FILL_GAP

        rows = range(band.top, band.bottom + 1)
        start, stop = band.left, band.right
        # A control is bounded: this walks through a filled run and stops at the first column that
        # is not part of it, so a card's own surface ends the walk as surely as its edge does.
        limit = 40
        while start > left and limit and all(filled(start - 1, y) for y in rows):
            start -= 1
            limit -= 1
        limit = 40
        while stop < right and limit and all(filled(stop + 1, y) for y in rows):
            stop += 1
            limit -= 1
        return Band(top=band.top, bottom=band.bottom, left=start, right=stop)

    def owning_panel(self, band: Band) -> tuple[int, int] | None:
        """The innermost panel a band sits on, or None when it sits on the window itself.

        The innermost one, because a control inside a card is inset from the card, not from the
        window behind it. A band that starts on a panel edge is left on the window: a card's own
        border is the outermost row of the card, and reading it as content would measure the
        border against the border.
        """

        middle = (band.top + band.bottom) // 2
        owners = [
            (top, bottom)
            for top, bottom in self.panel_rows
            if top < band.top and band.bottom < bottom
        ]
        if not owners:
            return None
        _ = middle
        return min(owners, key=lambda pair: pair[1] - pair[0])

    def panel_extent(self, top: int, bottom: int) -> tuple[int, int]:
        """The horizontal extent of a panel, read along its border."""

        # The top and bottom rows curve away at the corners, so they understate the width. Read
        # the sides a little inside each end instead.
        inset = 6 * self.scale
        left, right = self.width, 0
        for y in (top + inset, bottom - inset, (top + bottom) // 2):
            if y <= top or y >= bottom:
                continue
            for x in range(self.left, self.width):
                if self.lift(self.pixels[x, y], self.background) > PANEL_LIFT:
                    left = min(left, x)
                    right = max(right, x)
        return left, right

    def reference(self, y: int) -> tuple[int, int]:
        """What counts as empty at this row, and how far above it something must rise."""

        if self.inside_panel(y):
            return self.panel_background, CARD_TEXT_LIFT
        return self.background, TEXT_LIFT

    # MARK: - Finding content

    def bands(self) -> list[Band]:
        bright = []
        for y in range(self.height):
            reference, lift = self.reference(y)
            found = None
            for x in range(self.scan_left, self.width):
                if self.lift(self.pixels[x, y], reference) > lift:
                    found = x
                    break
            bright.append(found)

        bands: list[Band] = []
        y = 0
        while y < self.height:
            if bright[y] is None:
                y += 1
                continue
            top = y
            while y < self.height and bright[y] is not None:
                y += 1
            bottom = y - 1
            if bottom - top < 2:
                continue
            left_edge, right_edge = self.width, 0
            for row in range(top, bottom + 1):
                reference, lift = self.reference(row)
                for x in range(self.scan_left, self.width):
                    if self.lift(self.pixels[x, row], reference) > lift:
                        left_edge = min(left_edge, x)
                        right_edge = max(right_edge, x)
            bands.append(Band(top, bottom, left_edge, right_edge))
        return bands

    def row_mode(self, y: int, left: int = 0, right: int | None = None) -> tuple[int, int]:
        """The colour most of a row holds, and how many pixels hold something else.

        A row of text is mostly its surface: the ink covers a fraction of the line. A row of
        surface holds one colour and nothing else. Reading a row this way tells the two apart
        without being told what the surface is, so the same reading works inside a card, on a
        window background, and in either appearance. The window is what the row is compared over:
        the whole width for a divider that crosses the surface, and one card for a divider that
        divides that card.
        """

        right = self.width - 1 if right is None else right
        counted = Counter(self.pixels[x, y] for x in range(left, right + 1))
        mode, count = counted.most_common(1)[0]
        return mode, right - left + 1 - count

    def panel_fill(self) -> int:
        """The colour the inside of a card is drawn in, which is not its border colour."""

        if self._panel_fill is not None:
            return self._panel_fill
        counted: Counter[int] = Counter()
        for top, bottom in self.panel_rows:
            left, right = self.panel_extent(top, bottom)
            for y in range(top + 4, bottom - 3, 2):
                for x in range(left + 6, right - 5, 2):
                    counted[self.pixels[x, y]] += 1
        self._panel_fill = counted.most_common(1)[0][0] if counted else self.panel_background
        return self._panel_fill

    def row_context(self, y: int) -> tuple[int, int, int] | None:
        """What a row is drawn on: the columns it spans, and the surface behind it.

        A row inside a card is compared with the card, so the card's own fill is not read as
        content and its dividers are read against the fill rather than against the window. A row
        on the window is compared with the window. The card's own edge rows answer nothing: the
        border is the card, so it is neither content nor a divider.
        """

        if self._row_context is None:
            contexts: dict[int, tuple[int, int, int] | None] = {
                y: (0, self.width - 1, self.background) for y in range(self.height)
            }
            fill = self.panel_fill() if self.panel_rows else self.background
            for top, bottom in self.panel_rows:
                left, right = self.panel_extent(top, bottom)
                # Two points inside the card's own edge: the border is one colour and the fill is
                # another, and counting the border as content would put a mark on every row.
                inner_left, inner_right = left + 4, right - 4
                for y in range(top, bottom + 1):
                    contexts[y] = (
                        None
                        if y <= top + 1 or y >= bottom - 1
                        else (inner_left, inner_right, fill)
                    )
            self._row_context = contexts
        return self._row_context[y]

    @staticmethod
    def surface_behind(band: Band, colours: Image.Image) -> tuple[int, int, int]:
        """The colour a band of text starts on.

        A band can hold more than one surface: a right-aligned control puts its own fill in the
        same rows as the sentence beside it, so the row's most common colour can be the control
        rather than the card the sentence is written on. Reading the surface from the band's own
        leading columns takes the surface the text starts on, which is the one it is measured
        against.
        """

        pixels = colours.load()
        counted: Counter[tuple[int, int, int]] = Counter()
        width = max(1, min(4, band.right - band.left + 1))
        for y in range(band.top, band.bottom + 1):
            for x in range(band.left, band.left + width):
                counted[pixels[x, y]] += 1
        return counted.most_common(1)[0][0] if counted else (0, 0, 0)

    def rules(self) -> list[tuple[int, int]]:
        """Every full-width hairline that separates two runs of one surface.

        A divider is a thin line of one colour over a surface of another, so it is found by
        thickness rather than by what is next to it. A row counts as part of a line when it holds
        one colour across the whole width, that colour is not the window behind it, and the run of
        rows holding it is no taller than four.

        Only the lines that cross the surface are read here: the one under a header, the one over
        a footer. A line inside a card is a different measurement and is already printed by the
        geometry report, which shows the space above and below every band in a card. Keeping the
        two apart also keeps this list free of controls: a control is never as wide as the window,
        so a control's edge can never be mistaken for one of these.
        """

        rows: list[tuple[int, int, int]] = []
        for y in range(self.height):
            context = self.row_context(y)
            if context is None:
                continue
            left, right, surface = context
            mode, others = self.row_mode(y, left, right)
            # A line is drawn near the width of the surface it sits on: the popover divides its
            # content at its own gutter, which is nine per cent of the surface, and a card divides
            # itself at its own inset. Twelve per cent of slack covers the widest gutter and still
            # keeps a card's fill out, which leaves ten per cent as a margin.
            if others > (right - left + 1) * 0.12 or abs(mode - surface) <= 2:
                continue
            # A run of rows holding one colour with only a slow change between them is a surface
            # with a shadow on it, not a line: the line and the fill under a card are one shade
            # apart, and a card's fill drifts by a level or two from row to row.
            if rows and abs(rows[-1][2] - mode) <= 2 and rows[-1][1] == y - 1:
                rows[-1] = (rows[-1][0], y, mode)
            else:
                rows.append((y, y, mode))

        # A line is a step up from the surface, so at least one of the rows a few points above it
        # and a few points below it holds the surface colour. Nothing else on a surface does that.
        # The fill of a button is not the surface it sits on, so the rows inside a button never
        # qualify, and the shading of a capsule's halo changes with every row, so neither does its
        # edge.
        #
        # One side is enough because the other side may hold the content the line separates, and a
        # line sitting against its content is a finding rather than a reason to look away. The gap
        # report prints how close it is.
        def neighbour(y: int) -> int | None:
            context = self.row_context(y)
            if context is None:
                return None
            left, right, _ = context
            mode, _ = self.row_mode(y, left, right)
            return mode

        found: list[tuple[int, int]] = []
        for top, bottom, _ in rows:
            if bottom - top + 1 > 4:
                continue
            context = self.row_context(top)
            if context is None:
                continue
            surface = context[2]
            above, below = neighbour(top - 3), neighbour(bottom + 3)
            if above is None or below is None:
                continue
            if abs(above - surface) > 2 or abs(below - surface) > 2:
                continue
            found.append((top, bottom))
        return found

    def gap_report(self) -> None:
        """The space a divider leaves above and below the content it separates.

        A margin problem hides between two surfaces: content sitting on a line looks deliberate in
        a picture until the number is printed. Every full-width divider on the surface is listed
        with the gap on each side, and the ones under the smallest design gap are called out,
        because a control that touches its divider reads as a rendering mistake rather than a
        tight layout.

        The bands are the ones the geometry report already finds, so a gap is measured against the
        same objects the picture was laid out from. A gap of zero where a list is cut off is a
        scroll view clipping its content at its own edge, not a padding mistake: the number is
        printed either way, and a surface that scrolls is read with that in mind.
        """

        scale = self.scale
        lines = self.rules()
        if not lines:
            print("  no dividers")
            return
        bands = [band for band in self.bands() if band.bottom - band.top + 1 > RULE_HEIGHT]
        if not bands:
            print("  no content found")
            return
        tight = 0
        for top, bottom in lines:
            above = [band for band in bands if band.bottom < top]
            below = [band for band in bands if band.top > bottom]
            gap_above = (top - above[-1].bottom - 1) / scale if above else None
            gap_below = (below[0].top - bottom - 1) / scale if below else None
            note = ""
            if gap_above is not None and gap_below is not None:
                if min(gap_above, gap_below) < self.tight_gap:
                    note = "   <- tight"
                    tight += 1
            shown_above = "-" if gap_above is None else f"{gap_above:.1f}"
            shown_below = "-" if gap_below is None else f"{gap_below:.1f}"
            print(
                f"  rule y {top / scale:7.1f}-{bottom / scale:7.1f}"
                f"   above {shown_above:>6}   below {shown_below:>6}{note}"
            )
        print(f"  {len(lines)} dividers, {tight} closer than {self.tight_gap:g} pt to content")

    def edge_report(self) -> None:
        """Where the content of a surface ends, read as columns rather than looked at as margins.

        Two things on one surface are meant to end on one line: a card's buttons, fields, and
        glyphs all stop at the same gutter, because that is what makes a margin read as a margin.
        A column that stops short of it by a few points still looks deliberate in a picture, which
        is how an icon-only button holding a 12-point glyph in a 26-point circle kept its ink seven
        points inside the gutter the buttons above it used.

        Each run of content is measured against the edge of the surface it actually sits on: the
        window or pane for a heading or a row that spans the surface, and the panel's own edge for
        anything inside a card or a filled control. Measuring the inside of a chip against the
        window's gutter would report the chip's own padding as a fault, because a chip is inset by
        design.

        One cluster inside a group is a surface whose content agrees with itself. Two clusters a
        few points apart are the fault: the nearer one is the gutter, and the further one is
        whatever draws without it. A wrapped paragraph legitimately ends short of the gutter, so
        the count is what is read here, not any single row.
        """

        bands = [
            band
            for band in self.bands()
            if band.bottom - band.top + 1 > EDGE_MIN_HEIGHT * self.scale
        ]
        if not bands:
            print("  no content found")
            return
        scale = self.scale
        groups: dict[str, tuple[list[Band], int, int]] = {}
        for band in bands:
            owner = self.owning_panel(band)
            if owner is None:
                left, right = self.left, self.width - 1
                name, fill = "window", self.background
            else:
                left, right = self.panel_extent(*owner)
                name = f"panel y {owner[0] / scale:g}-{owner[1] / scale:g}"
                fill = self.panel_fill()
            # A control pads its own label, so the label is not a statement about this gutter.
            # This is read from the band as it was found. The control's own fill is what the test
            # needs to see, and taking the halo off the band first would leave the test looking at
            # the fill and calling the row it belongs to a label inside a control.
            if self.inside_control(band, fill):
                continue
            trimmed = self.content_extent(band)
            if trimmed is None:
                continue
            band = self.drop_indicator(trimmed)
            # A row draws its label on the surface and its control on the right. The control paints
            # its own fill and pads its own label inside that fill, so the row's rightmost ink is
            # the label's last letter and not the edge of the thing being looked at. What the row
            # is saying about the gutter is where the control ends, so the run is taken out to the
            # control's own edge before it is measured. A picker whose capsule stops on the gutter
            # reads as 16 either way; a control that ends short of it still reads as the fault.
            band = self.extend_to_control(band, fill, left, right)
            groups.setdefault(name, ([], left, right))[0].append(band)

        flagged = 0
        for name, (members, left, right) in groups.items():
            if len(members) < 3:
                # One run on its own surface has nothing to disagree with. A chip holding one
                # label is not a margin problem.
                continue
            trailing: Counter[float] = Counter()
            leading: Counter[float] = Counter()
            for band in members:
                trailing[round((right - band.right) / scale * 2) / 2] += 1
                leading[round((band.left - left) / scale * 2) / 2] += 1
            for direction, counted, caption in (
                ("trailing", trailing, "the right edge"),
                ("leading", leading, "the left edge"),
            ):
                columns = sorted(counted)
                # Only runs that end near the edge are judged. A sentence ends where its last word
                # did; a control sits at the gutter, and only the second one is a margin.
                near = [column for column in columns if column <= EDGE_WINDOW]
                if not near:
                    continue
                gutter = near[0]
                near = [column for column in near if column - gutter <= EDGE_SLACK * 2]
                counted = Counter({column: counted[column] for column in near})
                short = [column for column in near if column - gutter > EDGE_SLACK]
                shown = "  ".join(f"{column:g} pt x{counted[column]}" for column in near)
                print(f"  {name}: {direction} in {caption} {gutter:g} pt: {shown}")
                if short:
                    flagged += 1
                    print(
                        f"    <- {sum(counted[column] for column in short)} run(s) of content stop"
                        f" {', '.join(f'{column - gutter:g}' for column in short)}"
                        f" pt inside that gutter"
                    )
        print(f"  {len(groups)} surface(s), {flagged} edge(s) with content off the gutter")

    def footer_report(self) -> None:
        """Check the row of controls along the bottom of a window.

        Every modal in the app ends the same way: a hairline, one row of buttons, then the window
        edge. That row is padded on all four sides by one value, so the space above it and the
        space below it are the same number. Symmetry is the whole check. It needs no knowledge of
        which button is which, and a footer that hand-rolls its own padding drifts a few points
        and breaks it.

        A filled button draws a soft shadow several points past its own edge. The shadow is drawn
        on both sides of the row, so it moves both numbers by the same amount and the comparison
        between them still holds. The row of a footer is also short: content that carries on to
        the window edge is a scrolling pane, and the last card of a pane is not a footer however
        it ends. Only a short block sitting against the bottom edge is read.
        """

        scale = self.scale
        rules = self.window_rules()
        if not rules:
            print("  no divider, so this surface has no footer")
            return
        divider = rules[-1][1]
        bands = [
            band
            for band in self.bands()
            if band.top > divider and band.bottom - band.top + 1 > RULE_HEIGHT
        ]
        if not bands:
            print(f"  divider y {divider / scale:7.1f}  holds nothing below it")
            return
        # A footer can hold more than one band when it puts a note over its buttons. The block
        # ends at the first real break, and a break is anything wider than the screen inset.
        row = [bands[0]]
        for band in bands[1:]:
            if (band.top - row[-1].bottom) / scale > SCREEN:
                break
            row.append(band)
        # A filled button casts a shadow several points past its own box, and the shadow is part of
        # the drawing rather than of the control. Reading the box keeps the inset the row was laid
        # out with; reading the shadow reports the button as sitting nearer the window edge than
        # it does, and on a footer of one filled button that is the whole measurement.
        boxes = [self.content_extent(band) for band in row]
        boxes = [box for box in boxes if box is not None]
        if not boxes:
            print(f"  divider y {divider / scale:7.1f}  holds nothing below it")
            return
        top, bottom = boxes[0].top, boxes[-1].bottom
        above = (top - divider - 1) / scale
        below = (self.height - 1 - bottom) / scale
        if below > SCREEN + 12 or bottom - top + 1 > self.height * FOOTER_MAX:
            print(
                f"  divider y {divider / scale:7.1f}  what follows it runs on,"
                f" so that is a pane and not a footer"
            )
            return
        trailing = (self.width - 1 - max(box.right for box in boxes)) / scale
        lead = above - below
        if -FOOTER_TOLERANCE <= lead <= FOOTER_SHADOW_BIAS + FOOTER_TOLERANCE:
            shape = "padded row"
            gutter = SCREEN
        elif abs(lead + FOOTER_STACK_GAP) <= FOOTER_TOLERANCE:
            shape = "stacked band"
            gutter = SECTION
        else:
            shape = "no shape the app composes"
            # The shape is what says which gutter the row keeps, so a row that matches no shape
            # is not judged against one either. Guessing here would report the guess.
            gutter = None
        problems: list[str] = []
        if shape.startswith("no shape"):
            nearer = "the divider" if above < below else "the window edge"
            problems.append(f"the row sits {abs(lead):.1f} pt closer to {nearer}")
        # A filled button draws a soft shadow six points past its own edge, so the band it makes
        # reaches past the gutter and is measured a few points inside it. The gutter is what the
        # button's own box keeps. A band that ends outside the gutter is the fault; one that ends
        # inside it by no more than the shadow reaches is that shadow.
        if gutter is not None:
            if trailing > gutter + FOOTER_TOLERANCE:
                problems.append(
                    f"the row ends {trailing - gutter:.1f} pt past the {gutter:g}-point gutter"
                )
            elif trailing < gutter - FOOTER_SHADOW_BIAS - 3:
                problems.append(
                    f"the row ends {gutter - trailing:.1f} pt inside the {gutter:g}-point gutter,"
                    f" which is more than a shadow reaches"
                )
        verdict = "OFF " if problems else "ok  "
        shown = "-" if gutter is None else f"{gutter:g}"
        print(
            f"  {verdict}footer y {top / scale:7.1f}..{bottom / scale:7.1f}"
            f"   {shape}: above {above:5.1f}  below {below:5.1f}"
            f"  trailing {trailing:5.1f} from {shown}"
        )
        for problem in problems:
            print(f"       <- {problem}")

    def window_rules(self) -> list[tuple[int, int]]:
        """The dividers that cross a window, rather than the ones a card draws between its rows.

        A card divides itself with the same hairline and is nearly as wide as the window it sits
        in, so the width of the line does not tell the two apart. The surface the line is drawn on
        does: a window divider lies on the window, and a card's lies on the card. Only the first
        kind can be followed by the window's own bottom edge, which is what a footer sits on.
        """

        found: list[tuple[int, int]] = []
        for top, bottom in self.rules():
            context = self.row_context(top)
            if context is not None and context[2] == self.background:
                found.append((top, bottom))
        return found

    def contrast_report(self) -> None:
        """The contrast of every band of text the surface draws.

        The bands are the ones the geometry report already finds, so a check on the colours and a
        check on the spacing look at the same objects. A band is a run of rows that hold something
        brighter than the surface behind it, which is what a line of text is: the surface inside the
        band is the background, and the repeated colour furthest from it is the ink.

        A band is split wherever the surface under it changes, because two things on two surfaces
        are two readings. A filled button sitting under a line of text is one band in the geometry
        report and two surfaces here: the white on the button's fill, and the text on the card.
        Measured as one, the button's fill becomes the background and the card behind the text
        becomes the ink, which reports a colour pair that nothing on the surface is drawn in.
        """
        colours = to_srgb(Image.open(self.path))
        rows: list[tuple[float, Band]] = []
        skipped = 0
        for band in self.bands():
            # A hairline is a divider, not text. Its contrast against the card is a deliberate
            # 8 % and measuring it against the text threshold reports a failure that nobody
            # claimed: a divider is meant to be barely there.
            if band.bottom - band.top + 1 <= RULE_HEIGHT * 2:
                skipped += 1
                continue
            box = (band.left, band.top, band.right + 1, band.bottom + 1)
            if box[2] <= box[0] or box[3] <= box[1]:
                continue
            counted = Counter(pixels(colours.crop(box)))
            if not counted:
                continue
            # The surface is read from the band's leading columns and the ink is the repeated
            # colour furthest from it, so a band that holds a control and a sentence in the same
            # rows is measured as the sentence.
            background = self.surface_behind(band, colours)
            repeated = [colour for colour, count in counted.items() if count >= MIN_PIXELS]
            if not repeated:
                continue
            ink = max(
                repeated,
                key=lambda colour: abs(
                    relative_luminance(colour) - relative_luminance(background)
                ),
            )
            # A band that differs from its surface by less than this is a divider or the soft edge
            # of a shadow, not ink. Nothing readable is drawn in a shade that close to the surface
            # under it: a divider is meant to be barely there, and a tool that reports one as a
            # failure is reporting its own threshold rather than the picture.
            if contrast(background, ink) < LINE_CONTRAST:
                skipped += 1
                continue
            rows.append((contrast(background, ink), band))

        if not rows:
            print("  no text bands found")
            return
        scale = self.scale
        for ratio, band in rows:
            verdict = "ok " if ratio >= TEXT_THRESHOLD else "LOW"
            print(
                f"  {verdict} y {band.top / scale:7.1f}-{band.bottom / scale:7.1f}"
                f"  x {band.left / scale:6.1f}..{band.right / scale:6.1f}  {ratio:5.2f}:1"
            )
        worst = min(rows, key=lambda row: row[0])
        below = [row for row in rows if row[0] < TEXT_THRESHOLD]
        note = f", {skipped} divider{'s' if skipped != 1 else ''} skipped" if skipped else ""
        print(
            f"  worst {worst[0]:.2f}:1 at y {worst[1].top / scale:.1f}"
            f"  ·  {len(rows)} bands, {len(below)} below {TEXT_THRESHOLD}:1{note}"
        )

    def describe(self) -> None:
        scale = self.scale
        bands = self.bands()
        print(f"\n{self.path}  {self.width // scale}x{self.height // scale} pt"
              f"  pane from {self.left / scale:.1f} pt")

        in_panel = [b for b in bands if self.inside_panel(b.top)]
        if in_panel:
            first = min(b.left for b in in_panel)
            last = max(b.right for b in in_panel)
            print(f"  card contents span x {first / scale:.1f} .. {last / scale:.1f} pt")

        for index, (top, bottom) in enumerate(self.panel_rows):
            gap = "" if index == 0 else f"   gap above {(top - self.panel_rows[index - 1][1]) / scale:.1f}"
            left_edge, right_edge = self.panel_extent(top, bottom)
            print(f"  panel {top / scale:7.1f} .. {bottom / scale:7.1f}  h {(bottom - top + 1) / scale:6.1f}"
                  f"  x {left_edge / scale:6.1f}..{right_edge / scale:6.1f}"
                  f"  margins {(left_edge - self.left) / scale:.1f} / {(self.width - 1 - right_edge) / scale:.1f}{gap}")
            inside = [b for b in bands if top <= b.top and b.bottom <= bottom]
            if not inside:
                continue
            print(f"       inset from top {(inside[0].top - top) / scale:.1f}"
                  f", from bottom {(bottom - inside[-1].bottom) / scale:.1f}")
            for position, band in enumerate(inside):
                above = inside[position - 1] if position else None
                lead = "" if above is None else f"  +{(band.top - above.bottom) / scale:5.1f}"
                height = band.bottom - band.top + 1
                kind = "  rule" if height <= RULE_HEIGHT else "  band"
                print(f"      {kind} y {band.top / scale:7.1f}-{band.bottom / scale:7.1f}  h {height / scale:5.1f}"
                      f"  x {band.left / scale:6.1f}..{band.right / scale:6.1f}{lead}")

        outside = [b for b in bands if not self.inside_panel(b.top)]
        if outside:
            print("  between panels")
            for position, band in enumerate(outside):
                above = outside[position - 1] if position else None
                lead = "" if above is None else f"  +{(band.top - above.bottom) / scale:5.1f}"
                height = band.bottom - band.top + 1
                kind = "  rule" if height <= RULE_HEIGHT else "  band"
                print(f"      {kind} y {band.top / scale:7.1f}-{band.bottom / scale:7.1f}  h {height / scale:5.1f}"
                      f"  x {band.left / scale:6.1f}..{band.right / scale:6.1f}{lead}")


def main() -> None:
    arguments = sys.argv[1:]
    with_contrast = "--contrast" in arguments
    with_gaps = "--gaps" in arguments
    with_edges = "--edges" in arguments
    with_footer = "--footer" in arguments
    paths = [argument for argument in arguments if not argument.startswith("--")]
    for path in paths:
        try:
            shot = Shot(path)
            if with_gaps:
                print(f"\n{path}  {shot.width // shot.scale}x{shot.height // shot.scale} pt")
                shot.gap_report()
            elif with_footer:
                print(f"\n{path}  {shot.width // shot.scale}x{shot.height // shot.scale} pt")
                shot.footer_report()
            elif with_edges:
                print(f"\n{path}  {shot.width // shot.scale}x{shot.height // shot.scale} pt")
                shot.edge_report()
            elif with_contrast:
                print(f"\n{path}  {shot.width // shot.scale}x{shot.height // shot.scale} pt")
                shot.contrast_report()
            else:
                shot.describe()
        except Exception as error:  # one unreadable file must not stop a batch
            print(f"{path}: {error}")


if __name__ == "__main__":
    main()
