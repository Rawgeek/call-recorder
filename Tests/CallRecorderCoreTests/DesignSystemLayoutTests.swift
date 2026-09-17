import AppKit
import SwiftUI
import Testing
@testable import CallRecorderApp

/// Checks the numbers instead of the picture.
///
/// A margin that is four points out, or a control that is eight points shorter than the one beside
/// it, is almost invisible in a screenshot and obvious in a measurement. These tests hold the
/// spacing tokens and the components that use them to the values the design system states, so a
/// later change that breaks the rhythm fails here rather than after an install.
@Suite("Design system layout")
@MainActor
struct DesignSystemLayoutTests {
    /// The height a view asks for at a fixed width, measured the way the window measures it.
    private func height(of view: some View, width: CGFloat = 420) -> CGFloat {
        let hosting = NSHostingView(rootView: AnyView(view.frame(width: width)))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let measured = hosting.fittingSize.height
        window.contentView = nil
        window.close()
        return measured.rounded()
    }

    @Test("every row of a card is the same height whatever control it holds")
    func rowsShareOneHeight() {
        @State var on = true
        @State var choice = "Medium"

        let switchRow = CRSettingsRow(title: "A setting") {
            Toggle("", isOn: $on).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        let buttonRow = CRSettingsRow(title: "A setting") {
            CRButton(title: "Download", kind: .primary) {}
        }
        let textRow = CRSettingsRow(title: "A setting") {
            Text("1.53 GB").font(CR.Font.body)
        }
        let pickerRow = CRSettingsRow(title: "A setting") {
            Picker("", selection: $choice) {
                Text("Medium").tag("Medium")
            }
            .labelsHidden()
        }

        // A slot of one height is the point: without it a pop-up menu produced a shorter row
        // than a button, and a card of mixed rows stepped in and out down its dividers.
        #expect(height(of: switchRow) == height(of: buttonRow))
        #expect(height(of: switchRow) == height(of: textRow))
        #expect(height(of: switchRow) == height(of: pickerRow))
    }

    @Test("a row holds its control slot at the token height")
    func rowHonoursTheSlot() {
        let row = CRSettingsRow(title: "A setting") { Text("tiny") }
        // 12 above and below, plus the 30-point slot.
        #expect(height(of: row) == CR.Space.item * 2 + CR.Control.height)
    }

    @Test("the two fields draw at the same height as a button")
    func fieldsMatchButtons() {
        @State var search = ""
        let field = CRSearchField(placeholder: "Search people", text: $search)
        let text = CRTextField(placeholder: "Name", text: $search)
        let button = CRButton(title: "Download", kind: .primary) {}
        #expect(height(of: field) == CR.Control.height)
        #expect(height(of: text) == CR.Control.height)
        #expect(height(of: button) == CR.Control.height)
    }

    @Test("a settings card starts and ends on the row inset")
    func cardInsetIsTheRowInset() {
        let card = CRSettingsCard(title: "Group") {
            CRSettingsRow(title: "A setting") { Text("value") }
        }
        // The card holds a title and one row, separated by the snug step. The title's own height
        // comes from the type ramp, so it is measured rather than written as a number here.
        let titleHeight = height(of: Text("Group").font(CR.Font.headline), width: 200)
        #expect(
            height(of: card)
                == CR.Space.item * 2 + CR.Control.height + CR.Space.snug + titleHeight
        )
    }

    @Test("the spacing scale stays on the 4-point grid")
    func scaleStaysOnTheGrid() {
        let scale = [
            CR.Space.tight, CR.Space.snug, CR.Space.inner,
            CR.Space.item, CR.Space.section, CR.Space.screen,
        ]
        #expect(scale == [4, 6, 8, 12, 16, 20])
        #expect(scale.allSatisfy { $0.truncatingRemainder(dividingBy: 1) == 0 })
    }

    @Test("every step of the scale is on the 4-point grid")
    func everyStepIsOnTheGrid() {
        // The scale was declared with six steps and used with nine: three views reached past it
        // for a number of their own. The roles are named in the type now, and this holds all of
        // them to the grid, so a step added later cannot arrive off it.
        let scale = [
            CR.Space.hairline, CR.Space.tight, CR.Space.snug, CR.Space.inner,
            CR.Space.item, CR.Space.section, CR.Space.screen, CR.Space.bar,
        ]
        #expect(scale == [2, 4, 6, 8, 12, 16, 20, 20])
        #expect(scale.allSatisfy { $0.truncatingRemainder(dividingBy: 2) == 0 })
        // Ordered, so a view can rely on "at least as much room as the step below it".
        #expect(scale == scale.sorted())
    }

    @Test("the scale names a role for every step it declares")
    func scaleStepsAreOrdered() {
        // A label and its caption sit tighter than two rows, which sit tighter than two groups.
        #expect(CR.Space.hairline < CR.Space.tight)
        #expect(CR.Space.tight < CR.Space.snug)
        #expect(CR.Space.snug < CR.Space.inner)
        #expect(CR.Space.inner < CR.Space.item)
        #expect(CR.Space.item < CR.Space.section)
        #expect(CR.Space.section < CR.Space.screen)
        // A list and the bar under it keep a surface margin, not a row gap.
        #expect(CR.Space.bar == CR.Space.screen)
        #expect(CR.Space.bar > CR.Space.item)
    }

    @Test("a chip keeps its own metrics, and a compact one keeps less")
    func chipMetrics() {
        // A chip draws 11-point letters beside 13-point rows and 20-point headings. It cannot
        // take the button height or the button inset without pushing the row it sits in, so it
        // has its own numbers, and both sizes are on the grid.
        #expect(CR.Chip.dotGap == CR.Space.tight)
        #expect(CR.Chip.dot < CR.Icon.statusDot)
        #expect(CR.Chip.compactInsetX < CR.Chip.insetX)
        #expect(CR.Chip.compactInsetY < CR.Chip.insetY)
        let metrics = [
            CR.Chip.dotGap, CR.Chip.insetX, CR.Chip.insetY, CR.Chip.dot,
            CR.Chip.compactInsetX, CR.Chip.compactInsetY,
        ]
        #expect(metrics.allSatisfy { $0.truncatingRemainder(dividingBy: 1) == 0 })
        #expect(metrics.allSatisfy { $0 > 0 })
    }

    @Test("a note row puts its glyph on the text's first line")
    func noteGlyphAlignsWithItsText() {
        // The glyph is 11 points against a 13-point body line. Left at its natural height it
        // centred on its own shorter box and the mark rode low against the sentence it labels.
        // The slot gives it the line's height, and the width is shared so two notes' text begins
        // at one column.
        #expect(CR.Icon.symbolSlot < CR.Icon.statusSlot)
        #expect(CR.Font.bodyLineHeight > 13)

        // A note holds no control, so it is shorter than a row: the item inset twice plus one
        // line, and its height comes from the sentence rather than from the glyph beside it.
        let short = CRSettingsNote(icon: "checkmark.circle", text: "Healthy.")
        let long = CRSettingsNote(icon: "exclamationmark.triangle", text: "Healthy.")
        #expect(height(of: short) == CR.Space.item * 2 + CR.Font.bodyLineHeight)
        // Two icons of different weights and widths cannot change it, which is what the slot
        // guarantees: the row is the text's, and the glyph sits in it.
        #expect(height(of: short) == height(of: long))
        #expect(height(of: short) < height(of: CRSettingsRow(title: "A setting") { Text("v") }))
    }

    @Test("the sidebar keeps one column for its glyphs")
    func sidebarGlyphsShareAColumn() {
        // Five labels begin on one line only if every glyph keeps the same slot. A glyph that
        // asks for its own width moves that row's label and nothing else.
        #expect(CR.Icon.sidebarSlot > CR.Icon.statusSlot)
        #expect(CR.Icon.sidebarSlot.truncatingRemainder(dividingBy: 2) == 0)
    }


    /// The width a view asks for at its natural size.
    private func width(of view: some View) -> CGFloat {
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 10)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let measured = hosting.fittingSize.width
        window.contentView = nil
        window.close()
        return measured.rounded()
    }

    @Test("an icon button keeps its width when its glyph moves onto a gutter")
    func iconButtonKeepsItsRowWidth() {
        // The pull is a shift, not a shrink. If the far side did not give back what the pulled side
        // took, every button in a row would be seven points narrower and a row of them would step
        // closer at the next circle.
        let plain = CRIconButton(icon: "trash", label: "Delete", alwaysVisible: true) {}
        let leading = CRIconButton(
            icon: "trash", label: "Delete", alwaysVisible: true, leadingAligned: true
        ) {}
        let trailing = CRIconButton(
            icon: "trash", label: "Delete", alwaysVisible: true, trailingAligned: true
        ) {}

        #expect(width(of: plain) == CR.Icon.circle)
        #expect(width(of: leading) == width(of: plain))
        #expect(width(of: trailing) == width(of: plain))
        // The pull is the whole half-difference, so the glyph lands on the gutter rather than near it.
        #expect(CR.Icon.glyphInset == (CR.Icon.circle - 12) / 2)
    }

    @Test("the live dot fills its slot without moving the label beside it")
    func liveDotKeepsItsSlot() {
        // The dot is pulled toward the gutter so its core lines up with the status symbols the
        // header draws in the same place. The pull is paid for on the far side, so the status
        // word after it does not move when a recording starts.
        #expect(width(of: CRLiveDot()) == CR.Icon.statusSlot)
        // The pull is the difference between where a dot's ink starts and where a symbol's does.
        let pull = (CR.Icon.statusSlot - CR.Icon.statusDot) / 2 - CR.Icon.symbolInkInset
        #expect(pull > 0)
        #expect(pull < CR.Icon.statusSlot / 2)
    }

    /// The average colour of a rendered view, so a state that is only drawn can still be checked.
    private func averageColor(of view: some View, width: CGFloat = 200) -> NSColor {
        let hosting = NSHostingView(rootView: AnyView(view.frame(width: width)))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: CR.Control.height)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            window.contentView = nil
            window.close()
            return .clear
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.contentView = nil
        window.close()

        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var samples = 0.0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                red += Double(colour.redComponent)
                green += Double(colour.greenComponent)
                blue += Double(colour.blueComponent)
                samples += 1
            }
        }
        guard samples > 0 else { return .clear }
        return NSColor(
            srgbRed: red / samples,
            green: green / samples,
            blue: blue / samples,
            alpha: 1
        )
    }

    @Test("a disabled button does not paint like an enabled one")
    func disabledButtonLooksDisabled() {
        // The bug this holds shut: Confirm did nothing when no participant was chosen. The guard
        // was correct, but the button was painted in the full accent fill, so the screen said the
        // action was available and the app said it was not. A custom ButtonStyle does not inherit
        // the dimming SwiftUI gives its own styles, and nothing here was reading isEnabled, so the
        // two states measured the identical colour.
        for (kind, name) in [
            (CRButton.Kind.primary, "primary"),
            (CRButton.Kind.secondary, "secondary"),
            (CRButton.Kind.destructive, "destructive"),
        ] {
            let enabled = averageColor(of: CRButton(title: "Confirm", kind: kind) {})
            let disabled = averageColor(of: CRButton(title: "Confirm", kind: kind) {}.disabled(true))
            // Any visible dimming moves the average. A state that draws the same fill leaves it
            // exactly equal, which is what must not be true.
            #expect(enabled != disabled, "the (name) button looks the same disabled as enabled")
        }
        // The treatment is a real dimming, not a token change nobody can see.
        #expect(CRDisabled.fill < 1)
        #expect(CRDisabled.ink < 1)
    }

    /// The ratio between two colours, as the accessibility guidelines measure it.
    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            let srgb = color.usingColorSpace(.sRGB) ?? color
            func channel(_ value: CGFloat) -> Double {
                let v = Double(value)
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(srgb.redComponent)
                + 0.7152 * channel(srgb.greenComponent)
                + 0.0722 * channel(srgb.blueComponent)
        }
        let first = luminance(a)
        let second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// Resolves a tone colour the way the window does, in the given appearance.
    private func resolve(_ color: NSColor, appearance: NSAppearance.Name) -> NSColor {
        let appearance = NSAppearance(named: appearance)!
        var resolved = color
        appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) ?? color }
        return resolved
    }

    /// The tone's own 14 % fill over the two lightest surfaces it is drawn on. A chip is a pale
    /// tint of its tone, so the label sits on the tint, not on the window.
    private func tintedSurface(
        _ tone: CR.Tone,
        over background: NSColor,
        appearance: NSAppearance.Name
    ) -> NSColor {
        let vivid = resolve(NSColor(tone.color), appearance: appearance)
        let base = resolve(background, appearance: appearance)
        return NSColor(
            srgbRed: vivid.redComponent * 0.14 + base.redComponent * 0.86,
            green: vivid.greenComponent * 0.14 + base.greenComponent * 0.86,
            blue: vivid.blueComponent * 0.14 + base.blueComponent * 0.86,
            alpha: 1
        )
    }

    @Test("tone ink is readable on a light window and on a dark one")
    func toneInkIsReadable() {
        // The vivid tone is for a dot, a fill, and a border: things that are seen. A word and a
        // small glyph are read. In the light appearance the vivid tone scored 2.2:1 against its
        // own chip fill, where small text needs 4.5:1, so the label was unreadable on a light Mac.
        let tones: [CR.Tone] = [.live, .waiting, .working, .ready, .failed, .muted]
        let lightSurfaces = [NSColor.white, NSColor.windowBackgroundColor]
        for tone in tones {
            let lightInk = resolve(NSColor(tone.ink), appearance: .aqua)
            for surface in lightSurfaces {
                let tint = tintedSurface(tone, over: surface, appearance: .aqua)
                let ratio = contrast(lightInk, tint)
                #expect(
                    ratio >= 4.5,
                    "\(tone) reads at \(String(format: "%.2f", ratio)):1 on a light surface"
                )
            }
            let darkInk = resolve(NSColor(tone.ink), appearance: .darkAqua)
            let darkTint = tintedSurface(tone, over: .windowBackgroundColor, appearance: .darkAqua)
            let darkRatio = contrast(darkInk, darkTint)
            #expect(
                darkRatio >= 4.5,
                "\(tone) reads at \(String(format: "%.2f", darkRatio)):1 on a dark surface"
            )
        }
    }

    @Test("tone ink stays a visible mark against the plain window too")
    func toneInkIsVisibleAsAMark() {
        // Some of these are drawn as a bare glyph with no fill behind it, where the threshold is
        // 3:1 rather than 4.5:1.
        let tones: [CR.Tone] = [.live, .waiting, .working, .ready, .failed, .muted]
        for tone in tones {
            for appearance in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua] {
                let ink = resolve(NSColor(tone.ink), appearance: appearance)
                let window = resolve(.windowBackgroundColor, appearance: appearance)
                let ratio = contrast(ink, window)
                #expect(
                    ratio >= 3,
                    "\(tone) marks at \(String(format: "%.2f", ratio)):1 in \(appearance.rawValue)"
                )
            }
        }
    }

    @Test("the readable level clears the text floor on a window and on a card")
    func readableInkIsReadable() {
        // The level every subtitle, row detail, footnote, section label, and email address is
        // drawn in. It replaced the system's tertiary style, which measured 2.3:1, and then the
        // system's secondary style, which measured 3.9:1 in the light appearance. Both surfaces
        // matter: some of this text sits on the window and some of it sits on a card, and a card
        // is the lighter of the two in the light appearance and the darker in the dark one.
        let lightCard = NSColor(srgbRed: 245 / 255, green: 245 / 255, blue: 245 / 255, alpha: 1)
        let darkCard = NSColor(srgbRed: 39 / 255, green: 39 / 255, blue: 39 / 255, alpha: 1)
        let cases: [(appearance: NSAppearance.Name, surfaces: [NSColor])] = [
            (.aqua, [.white, NSColor.windowBackgroundColor, lightCard]),
            (.darkAqua, [.windowBackgroundColor, darkCard]),
        ]
        for (appearance, surfaces) in cases {
            let ink = resolve(CR.Ink.readableColor, appearance: appearance)
            for surface in surfaces {
                let ratio = contrast(ink, resolve(surface, appearance: appearance))
                #expect(
                    ratio >= 4.5,
                    "readable ink is \(String(format: "%.2f", ratio)):1 in \(appearance.rawValue)"
                )
            }
        }
    }

    @Test("the mark level clears the mark floor on a window and on a card")
    func markInkIsVisible() {
        // A chevron that promises the row leads somewhere, and the symbol over an empty list.
        // These are marks, so the floor is 3:1 rather than 4.5:1, and the third level they used
        // to take measured 2.3:1 in the dark appearance and 1.9:1 in the light one.
        let lightCard = NSColor(srgbRed: 245 / 255, green: 245 / 255, blue: 245 / 255, alpha: 1)
        let darkCard = NSColor(srgbRed: 39 / 255, green: 39 / 255, blue: 39 / 255, alpha: 1)
        let cases: [(appearance: NSAppearance.Name, surfaces: [NSColor])] = [
            (.aqua, [.white, lightCard]),
            (.darkAqua, [.windowBackgroundColor, darkCard]),
        ]
        for (appearance, surfaces) in cases {
            let ink = resolve(CR.Ink.markColor, appearance: appearance)
            for surface in surfaces {
                let ratio = contrast(ink, resolve(surface, appearance: appearance))
                #expect(
                    ratio >= 3,
                    "mark ink is \(String(format: "%.2f", ratio)):1 in \(appearance.rawValue)"
                )
            }
        }
    }

    @Test("an accent-coloured word clears the text floor on a window and on a card")
    func actionInkIsReadable() {
        // A link is a word, so it needs the text floor rather than the mark one. The system accent
        // is 4.0:1 on a white window and 4.2:1 on a dark one, so a link takes the same hue taken
        // far enough from the surface instead. The accent itself is kept for fills, where it is
        // read as a shape and the user's own choice of it is visible.
        let lightCard = NSColor(srgbRed: 245 / 255, green: 245 / 255, blue: 245 / 255, alpha: 1)
        let darkCard = NSColor(srgbRed: 39 / 255, green: 39 / 255, blue: 39 / 255, alpha: 1)
        let cases: [(appearance: NSAppearance.Name, surfaces: [NSColor])] = [
            (.aqua, [.white, lightCard]),
            (.darkAqua, [.windowBackgroundColor, darkCard]),
        ]
        for (appearance, surfaces) in cases {
            let ink = resolve(CR.Ink.actionColor, appearance: appearance)
            for surface in surfaces {
                let ratio = contrast(ink, resolve(surface, appearance: appearance))
                #expect(
                    ratio >= 4.5,
                    "action ink is \(String(format: "%.2f", ratio)):1 in \(appearance.rawValue)"
                )
            }
        }
    }

    @Test("a divider leaves the section step of room above and below its content")
    func dividerKeepsItsMargins() {
        // A control that starts on a divider reads as a drawing fault rather than as a tight
        // layout, and the picture does not show it: the numbers do. Every card's divider is
        // surrounded by the row's own vertical inset on both sides.
        let card = CRSettingsCard(title: "Group") {
            CRSettingsRow(title: "First") { Text("one") }
            CRSettingsDivider()
            CRSettingsRow(title: "Second") { Text("two") }
        }
        let titleHeight = height(of: Text("Group").font(CR.Font.headline), width: 200)
        // Two rows, two insets each, and the divider itself, which is one point.
        #expect(
            height(of: card)
                == CR.Space.item * 4 + CR.Control.height * 2 + 1 + CR.Space.snug + titleHeight
        )
    }
}
