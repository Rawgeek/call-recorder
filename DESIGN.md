# Call Recorder Design Contract

## 0. Research log

- Apple macOS HIG: native menus, familiar keyboard behavior, system materials, compact information density.
- Apple Settings HIG: standard Settings scene, stable panes, Command-Comma, few durable preferences.
- Apple Accessibility HIG: system colors, non-color state cues, VoiceOver labels, keyboard access, minimum control sizing.
- Product brief: operational menu-bar utility; recording state and recovery outrank decoration.
- ChatGPT macOS menu reference: quiet section labels, full-width text rows, thin dividers, compact secondary metadata, and no nested cards.

## 1. Principles

- Native first: standard SwiftUI controls, system typography, system materials, SF Symbols.
- State obvious: icon, label, and color communicate every recording state; never color alone.
- One primary action per state: Start, Pause, Resume, or Stop.
- Data safety visible: finalizing/transcribing/indexing states show progress and preserve Stop results.
- No decorative motion, gradients, custom chrome, or branded visual system.

## 2. Tokens

- Spacing: 2, 4, 6, 8, 12, 16, 20 points (`CR.Space`), plus a 600-point `CR.Space.measure` that
  caps how wide a settings column gets.
- Controls: one 30-point height and one 14-point label inset (`CR.Control`) for a button, a text
  field, a search field, and the slot a settings row gives whatever control it holds. A system
  switch or pop-up menu draws at 22 points; the row's slot is what keeps a card of mixed rows on
  one step, so a card never changes row height halfway down.
- Popover width: 360 points, with a 16-point gutter that the header, the section label, every row,
  and the footer all share. Settings window opens at 880x720 and is resizable; 860 points is the
  usable minimum, which is the sidebar, the readable measure, and its margins.
- Settings window height: 720 points, so no pane hides content below the fold on first open.
- Sheet sizes: participant editor 440x540, term editor 440x400. A sheet that is shorter than its
  own content is cut by its footer; both are sized so the last field is whole.
- A settings pane draws its own margins through `SettingsPane`; no pane adds padding itself, so
  no pane can drift from another.
- An icon-only control is a 26-point circle around a 12-point glyph, so the glyph sits 7 points
  inside the circle's edge (`CR.Icon`). A row that starts or ends with one sets
  `leadingAligned` or `trailingAligned`, which moves the circle by that half-difference and
  gives it back on the far side. Without it the glyph lands 7 points inside the gutter that the
  labels, fields, and buttons of the same surface align on, and a surface's two edges disagree
  about where its margin is.
- Typography: system `.headline`, `.body`, `.callout`, `.caption`, monospaced digits for elapsed time.
- Colors: `.primary`, `.accentColor`, `.red` for recording/error context, `.orange` for paused;
  always paired with icon and text.
- Ink: three levels, each chosen per appearance and measured rather than picked by eye.
  `CR.Ink.readable` is anything a person reads (a subtitle, a row's detail, a footnote, a section
  label), and clears 4.5:1 on the window and on a card in both appearances. `CR.Ink.mark` is a
  glyph that carries meaning (a chevron, the symbol over an empty list) and clears 3:1. `CR.Ink.action`
  is a word in the accent hue (a link) and clears 4.5:1. The system's own `.tertiary` is 2.27:1 and
  its `.secondary` is 3.95:1 in the light appearance, so neither is used for text. The vivid
  `CR.Tone.color` values stay for dots, fills, and borders; `CR.Tone.ink` is the same hue for the
  word beside them.
- The system accent is kept for filled controls, including the one place it measures 4.02:1
  (white on the default `#007AFF`), because the user chose it. See the audit for the number.
- Materials: system menu/popover/window backgrounds only.
- App icon: a white waveform of four rounded bars on a blue-to-indigo tile, with the red recording
  dot in the upper right. The source artwork is 1024 points
  (`Resources/AppIcon-source.png`) and every size in the set is derived from it by
  `scripts/make-icon.sh`, so the 16-point variant cannot drift from the large one. The bars and
  dot are large and few on purpose: the icon has to survive 16 points, where a thin or busy mark
  turns to mush. The menu bar keeps SF Symbols rather than this icon, because a coloured tile
  would compete with the system's own menu bar treatment.

## 3. Status language and symbols

| State | Symbol | Label | Primary action |
|---|---|---|---|
| Idle | `waveform` | Ready | Start Recording |
| Recording | `record.circle.fill` | Recording | Pause |
| Paused | `pause.circle.fill` | Paused | Resume |
| Finalizing | `waveform.badge.checkmark` | Saving Audio | Disabled |
| Participants | `person.2` | Add Participants | Continue |
| Transcribing | `text.bubble` | Transcribing | Disabled |
| Indexing | `magnifyingglass` | Indexing | Disabled |
| Error | `exclamationmark.triangle.fill` | Actionable error | Retry |

## 4. Menu-bar popover

- Header: state icon, state label, elapsed time when applicable.
- Controls: one prominent state action; Stop remains available while recording/paused.
- Secondary rows: pending transcription count, Open Recordings Folder, Settings, Quit.
- Recent section: five newest calls, participant title, compact date/status metadata. A completed transcript row copies the transcript and confirms the action inline.
- Match the ChatGPT reference rhythm with quiet section labels, edge-aligned rows, and dividers; keep native Call Recorder actions and state colors.
- Manual Stop/ Pause explains automatic detection suppression in accessible help text.

## 5. Primitives and windows

- `MenuSection`: secondary section label plus compact full-width rows; states are default, focus, disabled, and copied.
- `SpeakerEvidenceRow`: primary speaker label with duration and suggestion, a two-line selectable excerpt derived from preserved normalized transcript metadata (never persisted, no audio clip), Play Sample / Stop Sample controls or an explicit "Audio sample unavailable" state, then a labeled participant picker, Confirm, and Keep Unknown. States: excerpt available, playing, stopped, unavailable; each row carries play/stop/picker/confirm/keep-unknown accessibility labels, and state is never color-only.
- `ParticipantRow`: name, optional role/company, optional email, selection state, and Edit action.
- `ParticipantEditor`: native form for name, role, company, and email; Cancel and Save states; name is required.
- Participant window: search, selected people, inline Edit, add-new field, Save Without Participants, Continue.
- Settings panes: General, Models, Participants, Vocabulary, Recovery. Restore last pane.
- `SettingsPane`, `CRSettingsCard`, `CRSettingsRow`, `CRSettingsNote`, `CRSettingsField`,
  `CRSettingsList`, `CRSettingsDivider`: one frame, one card, and one row shape shared by every
  pane and by the two editors. A pane that needs a new shape adds a component here rather than
  its own spacing.
- Recovery lists failed jobs and 24-hour Recently Deleted items with Restore and confirmed Delete Now actions.
- Model rows: name, purpose, installed/download state, size, progress, Download/Delete.
- Empty/loading/error states use text plus relevant symbol and recovery control.

## 6. Interaction

- A failed call is not a waiting call. "Needs attention" is the status word; the reason appears
  once, in the callout under it, never twice on the same screen.
- Every row that a person must act on names the call it belongs to: who was on it, or the day it
  started. A row titled with a stage name repeats the same words down the card and identifies
  nothing.
- A state that has not been checked yet reads as unchecked, not as broken. The speaker-runtime
  chip waits for the check to finish before it reports anything.

- Standard Command-Comma opens Settings.
- Return activates safe primary actions; Escape closes non-destructive prompts without losing finalized audio.
- Full Keyboard Access reaches every control in visual order.
- Activating a recent call with an available transcript copies its complete Markdown transcript; unavailable transcripts remain visibly disabled.
- Speaker review plays a single active sample at a time, seeking to the excerpt start and stopping at the excerpt end; switching rows or stopping cancels the pending stop.
- Rows sort newest call first, then speaker index ascending; review evidence stays available after source audio expires because it is read from preserved transcript metadata.
- Destructive deletes require confirmation; recording Stop does not.
- Respect Reduce Motion, Increase Contrast, light/dark appearance, and system accent color.

## 7. Accessibility

- Every icon-only status item and button has an explicit accessibility label and state/value.
- Recording, paused, processing, and error states differ by symbol and text, not color alone.
- Progress announces model-download and processing changes without repeated noisy updates.
- Controls use native sizes at least 20x20 points; primary controls target 28x28 points or larger.
- Focus moves to participant search when its window opens and to the recovery action after errors.

## 8. Reviewing a layout without installing

`scripts/preview.sh` renders the menu bar, all five settings panes, the speaker review window, the
participant picker, both editors, and the component sheet to PNG files in about twenty seconds. It
needs no packaging, no signing, and no
password. Set `CALL_RECORDER_SNAPSHOT_SIZE=1600x820` to render the panes at another window size,
which is how a centred column and its margins are checked at more than one width.

The menu bar renders once per recorder state: idle, recording, paused, add participants,
transcribing, indexing, and failed. Each state is produced by replaying the app's own reducer, so a
picture always shows a state the app can actually be in. The popover is measured before it is
drawn, because the system sizes it to its content and a fixed height would add empty space the real
popover does not have.

Previews read the preferences of the installed app, so a settings pane shows the real settings. The
renderer refuses every preference write, so a review can never change them.

`scripts/measure-layout.py dist/preview/settings-general.png` reads one of those images and prints
the numbers: the pane margin, every card with its left and right margin, the space above each card,
the first and last content inset, and the gap between every band of content. Use it before and
after a change instead of comparing two pictures. It reports points, and takes `PREVIEW_SCALE` when
a preview was rendered at a scale other than two.

`scripts/measure-layout.py --gaps dist/preview/*.png` prints the space on each side of every divider
and ends with the count of dividers that sit closer than eight points to the content they separate.
A row that starts on its divider looks deliberate in a picture and reads as a fault in a number, so
this is the check for the padding nobody notices. Every surface should end at zero.

`scripts/measure-layout.py --contrast dist/preview/*.png` prints every band of text with its
contrast ratio and ends with the worst one, the number of bands, and how many are under 4.5:1. It
skips dividers and the soft edge of a shadow, and it splits a band wherever the surface behind it
changes, so a filled button under a line of text is measured against its own fill rather than
against the window. A region that is off by one file's coordinates reports that instead of a
number.

`scripts/measure-layout.py --edges dist/preview/*.png` prints where the content of each surface
ends, in columns, and calls out any run that stops more than five points inside the gutter its
neighbours share. This is the check for a control that draws without the alignment its surface
uses: an icon-only button holds a 12-point glyph in a 26-point circle, so its ink sits seven points
inside the circle's edge, and four surfaces had exactly that fault in a margin nobody could see.
Only runs that end within forty points of the edge are judged, because a sentence ends wherever its
last word did; text written inside a filled control is measured against that control, not against
the card behind it.

A run that ends inside a filled control is taken out to that control's own edge before it is
measured, because the control's edge is what the row is saying about the gutter. A menu picker
draws a capsule that stops on the gutter with its title and its chevron set well inside it, so
measuring the ink would report the picker's own padding as a margin fault. A control with no fill,
such as an icon-only button, is unaffected: there is no fill to walk through, so its glyph keeps
standing on the gutter and a glyph that misses it is still reported.

Validate the tool before trusting a clean report. Revert the alignment flag for one row, render,
and confirm the report names that row; a detector that never fires is not evidence. Adding
`trailingAligned: false` to the vocabulary rows prints "7 run(s) of content stop 7.5 pt inside
that gutter", which is the fault and its size.

`scripts/measure-spacing.py dist/preview/settings-*.png` checks the four insets of every card
against the numbers `CRSettingsCard` and `CRSettingsRow` declare: sixteen points of gutter on
the left and right, twelve above the first row and below the last. The layout script says where a
card is; this one says whether the padding inside it is right, which is the difference between a
pane where every card agrees and one where each pane was written by hand.

The card is found by flooding its fill from the middle. A card is a rounded rectangle with a
half-point stroke, so its outermost pixel is not its edge and a row just inside the top is narrower
than the card: measuring either reports every inset a few points small, or reports the stroke as
content and every inset as zero. The flood reaches exactly the pixels that are the card, and
whatever it cannot reach is content. A filled button casts a faint shadow a few points past itself,
so the threshold that counts a mark as content sits above the brightest shadow and below the
quietest text drawn on a card.

Three kinds of surface are drawn, and each keeps its own inset. A card holds a list and keeps
sixteen points of gutter with twelve above its first row and below its last. A nested card sits
inside another card and keeps eight on all four sides, so the pair reads as one thing inside
another rather than as two cards at the same level. A strip is a row that is its own surface, such
as the disclosure row in the popover, and keeps twelve across with eight down. The report names the
one it matched, because failing a strip against a card's numbers would be wrong and unreadable.

Three things are not surfaces and are reported rather than judged. A filled control can stand as
tall as a short card, and is told apart from one by how far its fill sits from the window: a surface
is a faint step off the window, a control's fill is a strong one. A surface whose content does not
reach its gutter, such as a callout that ends in a content-sized button, has no control on the
gutter to measure, so it is named as content-sized and left to the edge report, which is the tool
for that half of the question. And a card that runs off the top or bottom of a scrolling pane owes
an inset that cannot be seen, so the edge it is cut off at is marked with an asterisk and skipped.

The vertical insets are checked as a range in every case and the horizontal ones as exact numbers.
A row's padding is twelve points, but what is measured is the ink inside it, and every control is
centred in a thirty-point slot: text ink starts two and a half points below the top of its line box
and a small switch floats four points inside the slot, so a row measures anywhere from twelve to
eighteen depending only on which control it holds. All of those are the same padding. A gutter has
no such slack.

Both reading tools work in the light appearance and the Increase Contrast appearance:

    CALL_RECORDER_APPEARANCE=light scripts/preview.sh dist/preview-light
    CALL_RECORDER_APPEARANCE=light CALL_RECORDER_CONTRAST=high scripts/preview.sh dist/preview-contrast
    scripts/measure-layout.py --contrast dist/preview-light/*.png

The light appearance is not a mirror of the dark one. The system's secondary label measures 5.9:1
against a dark window and 3.95:1 against a white one, so a colour that passes in one appearance can
fail in the other, and the ink tokens resolve separately for that reason. Measure both before
changing a colour token.

`dist/preview/design-system.png` renders `DesignSystemSheet`: every button, field, chip, message,
and row type at its real size on one page. The rows at the bottom of that page say the same amount
of text while holding a different control, so a row that is taller than its neighbours is visible
as a difference in the picture rather than as a feeling about a pane. Reference a component here
before changing its spacing.

`Tests/CallRecorderCoreTests/DesignSystemLayoutTests.swift` measures the same components and fails
when a row of one control stops matching a row of another, or when the spacing scale leaves the
4-point grid. It also measures the ink tokens: `readable` against a white window, a dark window,
a light card, and a dark card; `mark` against both windows and both cards; `action` likewise; and
each tone's ink against its own 14 % fill. A colour that fails its floor fails here rather than in
a review. Run it after any change to a component or a colour, before rendering.

The renderer draws each surface at the size its own body declares: the settings panes at the size
passed in `CALL_RECORDER_SNAPSHOT_SIZE`, the participant picker at the size its window opens with,
and both editors at the size their frames declare. A render at any other size adds a margin that the
layout does not have, and that margin will read as a spacing mistake in the measurement.

`scripts/preview.sh` and this script only read the database. Both work with the app closed, and
neither writes a recording, a transcript, or a database row.

## 9. Accepted debt

- No animations beyond native progress indicators.
- No responsive iOS layout; macOS 15+ only.
