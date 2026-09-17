import SwiftUI

/// The visual language for Call Recorder.
///
/// Every spacing value, corner radius, font, and status colour comes from here. A redesign that
/// scatters raw numbers through the views cannot be adjusted afterwards, so the tokens are the
/// one place to change how the app looks.
enum CR {
    /// A 4-point scale. A view picks the step that matches the grouping it expresses, not the
    /// number that looks close enough.
    ///
    /// The steps are roles, and the same relationship has to come out the same wherever it is
    /// drawn. A heading with a caption under it was laid out at one point in a callout, two in a
    /// settings row, three in two list rows, four under a window title, and six under the
    /// speaker-review title: five surfaces, one relationship, five answers. Nothing was wrong in
    /// any one of them, and the app read as slightly unsettled in all of them. The roles are
    /// named here so the choice is a lookup rather than a nudge:
    ///
    /// - hairline: a label and the line under it, inside one row or list item.
    /// - tight: a window title and the sentence under it, or two parts of one heading.
    /// - snug: a control and its neighbour inside one group.
    /// - inner: two controls on one line, or a container and what it holds.
    /// - item: two rows of one list, or a card's own inner margin.
    /// - section: two groups on one surface, and a card's gutter.
    /// - screen: a surface and the window edge.
    enum Space {
        /// A label and the line under it, inside one row or list item.
        static let hairline: CGFloat = 2
        /// A window title and the sentence under it, or two parts of one heading.
        static let tight: CGFloat = 4
        /// A control and its neighbour inside one group.
        static let snug: CGFloat = 6
        /// Two controls on one line, or a container and what it holds.
        static let inner: CGFloat = 8
        /// Two rows of one list, or a card's own inner margin.
        static let item: CGFloat = 12
        /// Two groups on one surface, and a card's gutter.
        static let section: CGFloat = 16
        /// A surface and the window edge.
        static let screen: CGFloat = 20
        /// The room a list leaves above the bar of controls under it.
        ///
        /// A list that runs to its footer reads as one crowded block, and the last row looks like
        /// part of the buttons. The gap was the item step of 12, which is the space between two
        /// rows; the space between a list and the controls that finish it is a section of its own,
        /// so it is the same 20 the bars keep at their own edges.
        static let bar: CGFloat = 20
        /// The widest a column of settings text should get. Past this a label and its control
        /// sit a screen apart, so every settings pane is capped to this measure.
        static let measure: CGFloat = 600
    }

    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
    }

    /// The controls that sit in a row.
    ///
    /// A card's rows only read as one list when every control in them is the same height. A
    /// switch and a pop-up menu draw at 22 points, a button at 30, so a card holding one of each
    /// changed step halfway down and the dividers no longer lined up. One height, one slot, and
    /// one label inset fix that at the source instead of per row.
    enum Control {
        /// The height of a button, a search field, and the slot a row gives any control.
        static let height: CGFloat = 30
        /// The inset a button keeps between its edge and its label.
        static let insetX: CGFloat = 14
    }

    /// A status chip's own metrics.
    ///
    /// A chip is the one control whose letters are smaller than its neighbours', so it cannot
    /// take the button height or the button inset and still sit in a row without pushing it. The
    /// numbers are named here for the same reason the button's are: a chip is drawn on seven
    /// surfaces, and each of them can otherwise grow its own dot gap.
    enum Chip {
        /// Between the status dot and the word it colours.
        static let dotGap: CGFloat = 4
        /// Between a chip's edge and its contents.
        static let insetX: CGFloat = 8
        static let insetY: CGFloat = 3
        /// The dot in a chip, which is smaller than the header's live dot.
        static let dot: CGFloat = 6
        /// What a compact chip keeps of each.
        static let compactInsetX: CGFloat = 6
        static let compactInsetY: CGFloat = 2
    }
    /// An icon on its own, as a control.
    ///
    /// The circle is the click target, and it is larger than the glyph so a 12-point symbol is not
    /// a 12-point target. The slack that leaves around the glyph is the distance a row has to pull
    /// the circle out by to put the glyph on the surface's gutter, so it is named once here and
    /// used by both sides.
    enum Icon {
        /// The diameter of an icon button's click target.
        static let circle: CGFloat = 26
        /// Half the slack around a glyph in its circle: (26 - 12) / 2.
        static let glyphInset: CGFloat = (circle - 12) / 2
        /// The square a status mark is drawn in, whether it is a symbol or a live dot.
        static let statusSlot: CGFloat = 18
        /// The width a glyph in a note row keeps, so two notes' text begins at one column.
        static let symbolSlot: CGFloat = 14
        /// The column a sidebar row keeps for its glyph, so five labels begin on one line.
        static let sidebarSlot: CGFloat = 20
        /// The diameter of the live dot's core.
        static let statusDot: CGFloat = 8
        /// How far an SF Symbol's ink sits inside the status slot, measured on the header glyphs.
        static let symbolInkInset: CGFloat = 1.5
    }

    /// How strongly a piece of text is drawn.
    ///
    /// The app used the system's `.tertiary` for the small explanatory text: section labels,
    /// footnotes, email addresses, the message under an empty list. Measured against the surface
    /// behind it, that style draws at 2.27:1. Small text needs 4.5:1, so the quietest text in the
    /// app was the one that could not be read, and there was a lot of it.
    ///
    /// There are two levels because there are two jobs. A footnote, a section label, and an email
    /// address are read, so they get ``readable``. A hairline, a chevron, or a separator is a
    /// shape, so it keeps the third level and stays quiet.
    enum Ink {
        /// Text a person reads: 5.9:1 on the dark window, 5.3:1 on a white one.
        ///
        /// This is the level for anything a person has to read: a subtitle, a row's detail, a
        /// footnote, a section label, an email address, the message under an empty list. The
        /// system's own secondary style is not usable for it. It measures 5.9:1 in the dark
        /// appearance, which is where the app was first checked, and 3.9:1 in the light one, where
        /// it misses the 4.5:1 floor. The two appearances need different greys, so this picks one
        /// for each rather than taking the system's for both.
        ///
        /// The readable level is drawn in the light appearance in a grey of the app's own rather
        /// than in the system's secondary label. That label resolves to #808080 on a white window
        /// and to #7B7B7B on a card, which is 3.9:1 and 4.2:1 against the 4.5:1 small text needs.
        /// It is the same shortfall as the tertiary level this replaced, in the other appearance,
        /// and it covered the same text: every subtitle, footnote, section label, and row detail
        /// on a light window.
        static let readable = AnyShapeStyle(Color(nsColor: readableColor))

        /// The readable colour itself, so the test that measures it can read it back. A `Color`
        /// built from a dynamic colour cannot be unwrapped again, so the two are kept together.
        static let readableColor = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? .secondaryLabelColor : readableLabel
        }

        /// The grey the readable level is drawn in on a light window.
        ///
        /// #6C6C6C. Chosen against a card rather than against the window, because most of this
        /// text sits on one and a card is the lighter of the two surfaces in that appearance: the
        /// value clears 4.5:1 on both. #707070 is the lightest grey that clears a card, so this
        /// keeps four levels of margin for a display that renders it a little differently.
        private static let readableLabel = NSColor(
            srgbRed: 108 / 255,
            green: 108 / 255,
            blue: 108 / 255,
            alpha: 1
        )

        /// A shape rather than a word: a divider, an icon, a chevron.
        static let shape = AnyShapeStyle(HierarchicalShapeStyle.tertiary)
        /// Text that repeats something already on screen, such as a unit after a number.
        static let duplicated = AnyShapeStyle(HierarchicalShapeStyle.tertiary)
        /// A glyph that carries meaning: a chevron that promises the row leads somewhere, the
        /// symbol over an empty list. A mark needs 3:1, not 4.5:1, and the third level draws at
        /// 2.3:1 in the dark appearance and 1.9:1 in the light one, under both.
        static let mark = AnyShapeStyle(Color(nsColor: markColor))

        /// The mark colour itself, so the test that measures it can read it back.
        ///
        /// Both values clear the text floor as well as the mark floor. A chevron only has to be
        /// seen, but a measurement of a surface cannot tell a glyph from a word, and a token that
        /// passes both thresholds is one that never has to be argued about.
        static let markColor = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? NSColor(white: 0.66, alpha: 1) : NSColor(white: 0.40, alpha: 1)
        }

        /// Text drawn in the accent colour: a link that opens something.
        ///
        /// The accent itself is #007AFF, which is 4.0:1 on a white window and 4.2:1 on a dark
        /// one, under the 4.5:1 small text needs in both. A filled control keeps the system
        /// accent, because the user chose it and it is read as a shape; words take the same hue
        /// far enough from the surface to be read, which is what this is.
        static let action = AnyShapeStyle(Color(nsColor: actionColor))

        /// The action colour itself, so the test that measures it can read it back.
        static let actionColor = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark
                ? NSColor(srgbRed: 0, green: 144 / 255, blue: 1, alpha: 1)
                : NSColor(srgbRed: 10 / 255, green: 99 / 255, blue: 214 / 255, alpha: 1)
        }
    }

    /// A short type ramp. Three sizes plus a timer cover the whole app, which keeps the
    /// hierarchy readable instead of letting every label pick its own size.
    enum Font {
        static let title = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let headline = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13)
        static let callout = SwiftUI.Font.system(size: 12)
        static let caption = SwiftUI.Font.system(size: 11)
        static let button = SwiftUI.Font.system(size: 13, weight: .medium)
        static let timer = SwiftUI.Font
            .system(size: 30, weight: .medium, design: .rounded)
            .monospacedDigit()

        /// The line box a one-line label at this size occupies, in points.
        ///
        /// A glyph has no line of its own. An icon set beside text has to be given the height of
        /// the text's line, or it centres on its own smaller box and rides low against the
        /// sentence it labels. SwiftUI sizes a system font's line box at roughly 1.2 times its
        /// size, and this app draws body text at 13.
        static let bodyLineHeight: CGFloat = 16
    }

    /// The shape a surface is drawn in. A capsule reads as a control; a rounded rectangle reads
    /// as a container.
    enum Shape {
        case capsule
        case rounded(CGFloat)

        var any: AnyShape {
            switch self {
            case .capsule: AnyShape(Capsule(style: .continuous))
            case .rounded(let radius): AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            }
        }
    }

    /// What the colour says before the word is read.
    enum Tone {
        /// The microphone is on.
        case live
        /// Paused, or waiting for a person to make a choice.
        case waiting
        /// The machine is busy and the user can only wait.
        case working
        /// Finished and usable.
        case ready
        /// Something broke.
        case failed
        /// Nothing is happening.
        case muted

        var color: Color {
            switch self {
            case .live: .red
            case .waiting: .orange
            case .working: .blue
            case .ready: .green
            case .failed: .red
            case .muted: Color.secondary
            }
        }

        /// The tone as text and as a small glyph.
        ///
        /// `color` is chosen to be *seen*: a dot in a list, a fill behind a row, a border. It is
        /// not chosen to be *read*, and on a light window it is not readable. The chip label
        /// measured 2.2:1 against its own pale fill in the light appearance, against the 4.5:1
        /// small text needs, and the same shortfall applies to every icon drawn in a tone colour.
        /// This is the same hue taken down far enough to read on a light surface, and left as the
        /// system's own colour on a dark one, where the vivid value already passes.
        var ink: Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return isDark ? self.darkInk : self.lightInk
            })
        }

        /// The tone in a dark appearance.
        ///
        /// A chip is a 14 % fill of its own hue, so the label is read against a surface that has
        /// been pulled toward the colour of the ink. On a dark window that costs more than it looks:
        /// the system red scored 4.2:1 and the system blue 4.3:1 against their own fills, under the
        /// 4.5:1 small text needs. Red and blue are lifted by the smallest factor that clears it;
        /// orange, green, and the muted grey already did. The test measures each of them.
        private var darkInk: NSColor {
            let (base, lift): (NSColor, CGFloat) = switch self {
            case .live, .failed: (.systemRed, 1.32)
            case .waiting: (.systemOrange, 1)
            case .working: (.systemBlue, 1.06)
            case .ready: (.systemGreen, 1)
            case .muted: (.secondaryLabelColor, 1)
            }
            guard lift != 1 else { return base }
            // Lifting each channel keeps the hue and only raises how bright it reads.
            let resolved = base.usingColorSpace(.sRGB) ?? base
            func raised(_ value: CGFloat) -> CGFloat { min(1, value * lift) }
            return NSColor(
                srgbRed: raised(resolved.redComponent),
                green: raised(resolved.greenComponent),
                blue: raised(resolved.blueComponent),
                alpha: 1
            )
        }

        /// A darkened form of the same hue for a light appearance. Each value clears 4.5:1
        /// against the tone's own 14 % fill over both a white sheet and the window background,
        /// which are the two lightest surfaces the app draws text on.
        private var lightInk: NSColor {
            switch self {
            case .live, .failed:
                NSColor(srgbRed: 179 / 255, green: 27 / 255, blue: 27 / 255, alpha: 1)
            case .waiting:
                NSColor(srgbRed: 160 / 255, green: 74 / 255, blue: 0, alpha: 1)
            case .working:
                NSColor(srgbRed: 0, green: 80 / 255, blue: 190 / 255, alpha: 1)
            case .ready:
                NSColor(srgbRed: 15 / 255, green: 110 / 255, blue: 55 / 255, alpha: 1)
            case .muted:
                NSColor(srgbRed: 88 / 255, green: 88 / 255, blue: 88 / 255, alpha: 1)
            }
        }
    }
}

// MARK: - Surfaces

/// Glass on macOS 26, a material before it.
///
/// macOS 26 ships Liquid Glass as a system material, so the app asks for it by name and keeps the
/// material path for macOS 15. Both branches share one call site, so no view has to know which
/// system it is running on.
struct CRSurface: ViewModifier {
    var shape: CR.Shape = .rounded(CR.Radius.medium)
    var tint: Color?
    var interactive = false
    var stroked = true

    func body(content: Content) -> some View {
        let resolved = shape.any
        if #available(macOS 26.0, *) {
            content.glassEffect(glass, in: resolved)
        } else {
            content
                .background(fallback, in: resolved)
                .overlay(
                    resolved.stroke(
                        Color.primary.opacity(stroked ? 0.08 : 0),
                        lineWidth: 0.5
                    )
                )
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        var value: Glass = .regular
        if let tint { value = value.tint(tint) }
        if interactive { value = value.interactive() }
        return value
    }

    private var fallback: AnyShapeStyle {
        if let tint { return AnyShapeStyle(tint.opacity(0.16)) }
        return AnyShapeStyle(Material.regularMaterial)
    }
}

extension View {
    func crSurface(
        _ shape: CR.Shape = .rounded(CR.Radius.medium),
        tint: Color? = nil,
        interactive: Bool = false,
        stroked: Bool = true
    ) -> some View {
        modifier(CRSurface(shape: shape, tint: tint, interactive: interactive, stroked: stroked))
    }
}

/// A hairline that matches the rest of the chrome. The stock Divider draws edge to edge, which
/// makes a narrow popover look cut in half.
struct CRDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }
}

// MARK: - Buttons

/// The app's button. One type keeps height, radius, icon weight, and press feedback identical
/// everywhere, which is most of the difference between a designed app and a stack of system
/// controls.
struct CRButton: View {
    enum Kind {
        /// The one action the user came for.
        case primary
        case secondary
        case destructive
    }

    let title: String
    var icon: String?
    var kind: Kind = .secondary
    var fullWidth = false
    var help: String?
    let action: () -> Void

    var body: some View {
        switch kind {
        case .primary: base.buttonStyle(CRProminentButtonStyle())
        case .secondary: base.buttonStyle(CRSecondaryButtonStyle())
        case .destructive: base.buttonStyle(CRDestructiveButtonStyle())
        }
    }

    private var base: some View {
        Button(action: action) {
            HStack(spacing: CR.Space.snug) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(CR.Font.button)
                    .lineLimit(1)
            }
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, fullWidth ? CR.Space.item : CR.Control.insetX)
            .frame(height: CR.Control.height)
        }
        .help(help ?? title)
    }
}

/// The box a text input is typed into.
///
/// Inputs used to be the stock system control, which draws at 22 points. Beside the app's
/// 30-point buttons that put two heights in one row, and inside the editors the fields sat in
/// cards of 30-point controls looking undersized. This draws the box at the app's control height
/// with the app's own edges, and it is drawn the same way on every macOS version, so what a
/// preview shows is what the window shows.
struct CRFieldBox<Content: View>: View {
    /// Draws the accent edge while the field holds the keyboard focus. Without it a plain field
    /// shows nothing at all about where typing will land.
    var focused = false
    var shape: CR.Shape = .rounded(CR.Radius.small)
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, CR.Space.item)
            .frame(height: CR.Control.height)
            .background(shape.any.fill(Color.primary.opacity(0.06)))
            .overlay(
                shape.any.stroke(
                    focused ? Color.accentColor : Color.primary.opacity(0.12),
                    lineWidth: focused ? 1.2 : 0.5
                )
            )
    }
}

/// The search field.
///
/// Three surfaces each drew their own: two used a stock rounded text field and one a capsule on
/// the app's own surface. The same control came out two different heights, and only one of them
/// lined up with the button beside it. One field keeps the row flat and the height predictable.
struct CRSearchField: View {
    let placeholder: String
    @Binding var text: String
    /// Set by a surface that opens ready to type, so the field asks for focus itself.
    var focusOnAppear = false

    @FocusState private var focused: Bool

    var body: some View {
        CRFieldBox(focused: focused, shape: .capsule) {
            HStack(spacing: CR.Space.snug) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CR.Ink.mark)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(CR.Font.body)
                    .focused($focused)
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            // A control, not a decoration: at the third level it was a faint smudge
                            // that looked like part of the field rather than something to press.
                            .foregroundStyle(CR.Ink.readable)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
        }
        .onAppear {
            if focusOnAppear { focused = true }
        }
    }
}

/// A text input, in the same box as the search field and at the same height as a button.
struct CRTextField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    @FocusState private var focused: Bool

    var body: some View {
        CRFieldBox(focused: focused) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(CR.Font.body)
                .focused($focused)
                .onSubmit(onSubmit)
        }
    }
}

/// How much of its strength a control keeps while it cannot be used.
///
/// SwiftUI dims its own button styles when a control is disabled and leaves a custom style at full
/// strength, so a disabled button drawn by this app measured the same accent fill as an enabled
/// one: the two were the same colour to the pixel. The user pressed Confirm with no participant
/// chosen, nothing happened, and the honest reading of that screen was that the app was broken.
/// The state has to be visible before the press, not after it.
enum CRDisabled {
    /// The share of a fill that survives.
    static let fill: Double = 0.32
    /// The share of a label's ink that survives.
    static let ink: Double = 0.45
}

/// Reads the enabled state a button style cannot see.
///
/// `ButtonStyle.makeBody` receives a configuration holding `isPressed` and nothing else, so a
/// style that paints its own fill never learns that its control is off. The environment still
/// carries it, and only a real view can read the environment, so each style hands its label to
/// one of these and draws from what it finds.
private struct CRButtonState<Content: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    let isPressed: Bool
    @ViewBuilder let content: (_ isEnabled: Bool, _ isPressed: Bool) -> Content

    var body: some View {
        content(isEnabled, isPressed)
    }
}

struct CRProminentButtonStyle: ButtonStyle {
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        CRButtonState(isPressed: configuration.isPressed) { isEnabled, isPressed in
            let shape = Capsule(style: .continuous)
            configuration.label
                .foregroundStyle(.white.opacity(isEnabled ? 1 : CRDisabled.ink))
                .background(
                    tint.opacity(
                        isEnabled ? (isPressed ? 0.82 : 1) : CRDisabled.fill
                    ),
                    in: shape
                )
                .overlay(shape.strokeBorder(.white.opacity(isEnabled ? 0.18 : 0.08), lineWidth: 0.5))
                // The shadow is what makes a filled button read as raised and pressable, so it
                // goes with the fill rather than staying under a control that cannot be pressed.
                .shadow(color: tint.opacity(isEnabled ? 0.30 : 0), radius: 6, y: 2)
                .scaleEffect(isPressed ? 0.98 : 1)
                .animation(.snappy(duration: 0.15), value: isPressed)
        }
    }
}

struct CRSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CRButtonState(isPressed: configuration.isPressed) { isEnabled, isPressed in
            let shape = Capsule(style: .continuous)
            if #available(macOS 26.0, *) {
                configuration.label
                    .foregroundStyle(.primary.opacity(isEnabled ? 1 : CRDisabled.ink))
                    // Glass supplies the surface, but it is translucent and it needs a window to
                    // composite against. A faint fill and edge underneath give the button a shape
                    // that survives both, so the button can be measured in a render and does not
                    // vanish over a busy background.
                    .background(.quaternary.opacity(isPressed ? 0.85 : 0.45), in: shape)
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                    .glassEffect(
                        isPressed
                            ? .regular.tint(.white.opacity(0.10))
                            : .regular.interactive(),
                        in: shape
                    )
                    .scaleEffect(isPressed ? 0.98 : 1)
                    .animation(.snappy(duration: 0.15), value: isPressed)
            } else {
                configuration.label
                    .foregroundStyle(.primary.opacity(isEnabled ? 1 : CRDisabled.ink))
                    .background(.quaternary.opacity(isPressed ? 1 : 0.6), in: shape)
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                    .scaleEffect(isPressed ? 0.98 : 1)
                    .animation(.snappy(duration: 0.15), value: isPressed)
            }
        }
    }
}

struct CRDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CRButtonState(isPressed: configuration.isPressed) { isEnabled, isPressed in
            let shape = Capsule(style: .continuous)
            configuration.label
                // The vivid red is chosen to be seen, not to be read. On a light window it draws
                // the label at 3.1:1 against the button's own pale red fill, which is under the
                // 4.5:1 small text needs; the tone's ink is the same hue taken dark enough to
                // read.
                .foregroundStyle(CR.Tone.failed.ink.opacity(isEnabled ? 1 : CRDisabled.ink))
                .background(
                    Color.red.opacity(
                        isEnabled ? (isPressed ? 0.22 : 0.12) : CRDisabled.fill
                    ),
                    in: shape
                )
                .overlay(shape.strokeBorder(Color.red.opacity(isEnabled ? 0.22 : 0.10), lineWidth: 0.5))
                .scaleEffect(isPressed ? 0.98 : 1)
                .animation(.snappy(duration: 0.15), value: isPressed)
        }
    }
}

/// An icon-only control that stays invisible until the pointer is over it.
///
/// Row actions used to sit on screen at full strength for every call, so a list of five calls
/// showed ten identical glyphs and the titles competed with them.
struct CRIconButton: View {
    let icon: String
    let label: String
    var tone: CR.Tone = .muted
    var alwaysVisible = false
    /// When set, the caller decides visibility. Otherwise the button reveals itself on hover.
    var revealed: Bool?
    /// Set on a button that leads a row.
    ///
    /// The glyph is centred in a 26-point circle so the click target is big enough, which put the
    /// circle's glyph seven points inside the surface's gutter: a footer icon sat right of the
    /// text above it. Pulling the circle out by that half-difference puts the glyph on the gutter
    /// and leaves the circle's edge in the surface's margin, which is where a hover disc belongs.
    var leadingAligned = false
    /// Set on a button that ends a row.
    ///
    /// The same half-difference as the leading pull, on the other side. A row that ends in an
    /// icon had its glyph seven points inside the gutter that the labels, fields, and buttons of
    /// the same surface line up on, so the two edges of a surface disagreed about where the margin
    /// is: a card of text rows ended sixteen points in and the icon column above it ended
    /// twenty-three. When both are set, the leading pull wins.
    var trailingAligned = false
    let action: () -> Void

    @State private var hovering = false

    private var isVisible: Bool { alwaysVisible || (revealed ?? hovering) }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                // An icon-only control is a control, not a decoration: it is the only thing on the
                // row that says what the row does. The system's secondary colour draws it at
                // 3.9:1 on a light window, which is under the floor for a mark that carries
                // meaning, so it is drawn at the readable level like the label it stands for.
                .foregroundStyle(hovering ? AnyShapeStyle(tone.ink) : CR.Ink.readable)
                .frame(width: CR.Icon.circle, height: CR.Icon.circle)
                .background(
                    Circle().fill(hovering ? Color.primary.opacity(0.10) : .clear)
                )
                .contentShape(Circle())
        }
        // The pull is given back on the far side, so a row of these buttons keeps the spacing it
        // had and only the glyph moves: without it, each button would step seven points closer to
        // the next and the circles would overlap.
        .padding(.leading, leadingPull)
        .padding(.trailing, trailingPull)
        .buttonStyle(.plain)
        .opacity(isVisible ? 1 : 0)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
        .allowsHitTesting(isVisible)
    }

    /// How far the circle moves to put its glyph on the surface's gutter. The side that is pulled
    /// is paid for by the other, so the button keeps the width it takes in its row.
    private var leadingPull: CGFloat {
        if leadingAligned { return -CR.Icon.glyphInset }
        return trailingAligned ? CR.Icon.glyphInset : 0
    }

    private var trailingPull: CGFloat {
        if trailingAligned { return -CR.Icon.glyphInset }
        return leadingAligned ? CR.Icon.glyphInset : 0
    }
}

// MARK: - Small parts

/// A coloured dot and a word. The dot answers "is this fine" before the word is read, which
/// matters in a list where four different states used to look identical.
struct CRStatusChip: View {
    let tone: CR.Tone
    let text: String
    var compact = false

    var body: some View {
        HStack(spacing: CR.Chip.dotGap) {
            Circle()
                .fill(tone.color)
                .frame(width: CR.Chip.dot, height: CR.Chip.dot)
            Text(text)
                .font(CR.Font.caption)
                .fontWeight(.medium)
                .lineLimit(1)
        }
        // The words take the ink and the dot keeps the vivid tone: the mark stays loud, and the
        // label stays readable on whichever appearance the window is in.
        .foregroundStyle(tone.ink)
        .padding(.horizontal, compact ? CR.Chip.compactInsetX : CR.Chip.insetX)
        .padding(.vertical, compact ? CR.Chip.compactInsetY : CR.Chip.insetY)
        .background(tone.color.opacity(0.14), in: Capsule(style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A pulsing dot used while the microphone is live.
struct CRLiveDot: View {
    var color: Color = .red
    @State private var expanded = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.28))
                .frame(width: CR.Icon.statusSlot, height: CR.Icon.statusSlot)
                .scaleEffect(expanded ? 1 : 0.55)
                .opacity(expanded ? 0 : 0.9)
            Circle()
                .fill(color)
                .frame(width: CR.Icon.statusDot, height: CR.Icon.statusDot)
        }
        .frame(width: CR.Icon.statusSlot, height: CR.Icon.statusSlot)
        // The header draws an SF Symbol in this slot in every state but this one. A symbol's ink
        // starts about a point and a half inside the slot, and a dot centred in the same slot
        // starts five, so the mark jumped nearly four points right the moment a recording began
        // and jumped back when it stopped. The dot is pulled by that difference and the far side
        // is given back, so the header's leading edge stays on one line and the pulse stays
        // concentric with the core.
        .padding(.leading, -(CR.Icon.statusSlot - CR.Icon.statusDot) / 2 + CR.Icon.symbolInkInset)
        .padding(.trailing, (CR.Icon.statusSlot - CR.Icon.statusDot) / 2 - CR.Icon.symbolInkInset)
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                expanded = true
            }
        }
        .accessibilityHidden(true)
    }
}

struct CRSectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    /// Covers both a bare heading and a heading with a control on the right.
    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: CR.Space.inner) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                // A section label is read: it is how the eye finds the group it wants. At 2.27:1
                // it was the least readable word on the surface it named.
                .foregroundStyle(CR.Ink.readable)
            Spacer(minLength: CR.Space.inner)
            trailing()
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// Explains an empty list instead of leaving a blank panel.
struct CREmptyState: View {
    let icon: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: CR.Space.snug) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(CR.Ink.mark)
            Text(title)
                .font(CR.Font.headline)
                .foregroundStyle(CR.Ink.readable)
            if let message {
                Text(message)
                    .font(CR.Font.caption)
                    .foregroundStyle(CR.Ink.readable)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, CR.Space.section)
        .padding(.horizontal, CR.Space.item)
    }
}
/// A card that asks for a decision.
///
/// Wherever the app cannot finish on its own, the reason and the way out sit in one card.
/// Splitting them across a caption and a menu made the user connect the two themselves.
struct CRCallout<Actions: View>: View {
    let icon: String
    let title: String
    var message: String?
    var tone: CR.Tone = .waiting
    /// Set on a card that can be sent away.
    ///
    /// A card that stays until its condition clears is right for a permission that blocks
    /// recording, and wrong for a reminder: the automatic-recording card sat over the Recent list
    /// for as long as the setting stayed off, and there was nothing to press to put it down.
    var dismiss: (() -> Void)?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: CR.Space.inner) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                // A glyph is read the same way a word is: a warning triangle in the vivid tone is
                // 2.2:1 on a light card, below the 3:1 a non-text mark needs to be seen at all.
                .foregroundStyle(tone.ink)
                .frame(width: CR.Icon.statusSlot)
            VStack(alignment: .leading, spacing: CR.Space.snug) {
                Text(title)
                    .font(CR.Font.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(message)
                        .font(CR.Font.caption)
                        .foregroundStyle(CR.Ink.readable)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions()
            }
            Spacer(minLength: 0)
            if let dismiss {
                CRIconButton(
                    icon: "xmark",
                    label: "Dismiss",
                    alwaysVisible: true,
                    action: dismiss
                )
            }
        }
        .padding(CR.Space.item)
        .background(cardShape.fill(tone.color.opacity(0.10)))
        .overlay(cardShape.strokeBorder(tone.color.opacity(0.22), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: CR.Radius.medium, style: .continuous)
    }
}

/// A row that leads somewhere else. The chevron promises the navigation before the click, which
/// the plain buttons it replaces did not.
struct CRDisclosureRow: View {
    let icon: String
    let title: String
    var detail: String?
    var tone: CR.Tone = .waiting
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: CR.Space.inner) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tone.ink)
                    .frame(width: CR.Icon.statusSlot)
                VStack(alignment: .leading, spacing: CR.Space.hairline) {
                    Text(title)
                        .font(CR.Font.headline)
                    if let detail {
                        Text(detail)
                            .font(CR.Font.caption)
                            .foregroundStyle(CR.Ink.readable)
                    }
                }
                Spacer(minLength: CR.Space.inner)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CR.Ink.mark)
            }
            .padding(.horizontal, CR.Space.item)
            .padding(.vertical, CR.Space.inner)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardShape.fill(tone.color.opacity(hovering ? 0.18 : 0.10)))
            .overlay(cardShape.strokeBorder(tone.color.opacity(0.22), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(detail.map { title + ", " + $0 } ?? title)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: CR.Radius.medium, style: .continuous)
    }
}
