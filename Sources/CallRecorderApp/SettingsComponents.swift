import SwiftUI

/// The frame every settings pane sits in.
///
/// Each pane used to render its own `Form` straight into the window, so the content started at
/// the top edge with no margin and every row stretched the full width of a large window. A
/// shared frame gives every pane the same readable measure, a title that says where you are, and
/// room to breathe. It also separates the panes from the sidebar instead of letting them float.
struct SettingsPane<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CR.Space.section) {
                VStack(alignment: .leading, spacing: CR.Space.tight) {
                    Text(title)
                        .font(.system(size: 20, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(CR.Font.body)
                            .foregroundStyle(CR.Ink.readable)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                content()
            }
            // A settings row that spans 1200 points is unreadable: the label and its control end
            // up a screen apart. Capping the measure keeps them together, and the margin keeps
            // the pane off the sidebar and off the window edge. Both live here so every pane gets
            // the same frame; leaving it to each pane is what let four of them drift.
            .frame(maxWidth: CR.Space.measure, alignment: .leading)
            .padding(.horizontal, CR.Space.screen)
            .padding(.vertical, CR.Space.screen)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

/// A titled group of settings rows.
///
/// This replaces `Section` inside a `Form`. The previous treatment drew each group as a
/// full-bleed band that ran the width of the window, which is what made the pane read as a
/// table of raw rows. A card has a visible edge, sits on the pane background, and groups its
/// rows the way the rest of the app groups things.
struct CRSettingsCard<Content: View>: View {
    var title: String?
    var footnote: String?
    /// A sentence the card owes the reader, carried by an icon rather than by a line of text.
    var info: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: CR.Space.snug) {
            if let title {
                HStack(spacing: CR.Space.tight) {
                    Text(title)
                        .font(CR.Font.headline)
                        .foregroundStyle(CR.Ink.readable)
                    if let info { CRInfoIcon(text: info) }
                }
            } else if let info {
                CRInfoIcon(text: info)
            }
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: CR.Radius.large, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: CR.Radius.large, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            if let footnote {
                Text(footnote)
                    .font(CR.Font.caption)
                    // A footnote explains what the card does. It is read, so it is drawn to be.
                    .foregroundStyle(CR.Ink.readable)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One row inside a settings card: a label on the left, its control on the right.
///
/// A row is separated by a hairline rather than each row drawing its own background, which keeps
/// a card reading as one object with divisions instead of a stack of unrelated strips.
///
/// The control sits on the label's centre line, not on its baseline. Baseline alignment made the
/// height of a row depend on which control it held: a pop-up menu hangs lower than a switch, so a
/// row with a pop-up started seven points below the top of the card while a row with a switch
/// started twelve, and a card of mixed rows had no rhythm at all. Centring every control gives
/// every row the same inset and the same height.
struct CRSettingsRow<Content: View>: View {
    let title: String
    var detail: String?
    /// What the row would otherwise spend a second line saying, kept for the pointer.
    var info: String?
    var warning: Bool = false
    @ViewBuilder var control: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: CR.Space.item) {
            VStack(alignment: .leading, spacing: CR.Space.hairline) {
                HStack(spacing: CR.Space.tight) {
                    Text(title)
                        .font(CR.Font.body)
                    if let info { CRInfoIcon(text: info) }
                }
                if let detail {
                    Text(detail)
                        .font(CR.Font.caption)
                        .foregroundStyle(warning ? AnyShapeStyle(CR.Tone.waiting.ink) : CR.Ink.readable)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: CR.Space.item)
            // Every control draws in the same slot, so two rows that say the same amount of
            // text come out the same height whether they hold a switch, a pop-up menu, or a
            // button. Without the slot a card of mixed controls had two different row steps.
            control()
                .frame(minHeight: CR.Control.height)
        }
        .padding(.horizontal, CR.Space.section)
        .padding(.vertical, CR.Space.item)
        .accessibilityElement(children: .contain)
    }
}

/// A glyph that carries a sentence on the pointer.
///
/// Settings rows used to explain themselves in the row. A card of six rows then held six
/// paragraphs for facts a person needs once, and the numbers that decide a choice were buried in
/// the prose. The sentences are the same sentences; they now cost a glyph's width, and the row
/// says only what is not already known.
struct CRInfoIcon: View {
    let text: String
    var tone: CR.Tone = .muted

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tone.ink)
            .help(text)
            .accessibilityLabel(text)
    }
}

/// The hairline between two settings rows.
struct CRSettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
            .padding(.leading, CR.Space.section)
    }
}

/// A list of rows inside a settings pane.
///
/// `List` cannot size itself inside a `ScrollView`: it is itself a scroll container, so it asks
/// for no height and collapses to nothing. These panes scroll as a whole, so the rows are stacked
/// in the pane and the pane supplies the scrolling.
struct CRSettingsList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder var row: (Item) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { CRSettingsDivider() }
                row(item)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: CR.Radius.large, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CR.Radius.large, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

/// A status line inside a settings card: an icon and a sentence, with no control.
///
/// Some rows report rather than ask. Drawing them with the same margins as a control row keeps a
/// card aligned, which is what made the previous form look like two different lists stacked.
struct CRSettingsNote: View {
    let icon: String
    let text: String
    var tone: CR.Tone = .muted

    var body: some View {
        // Measured by its top edge rather than by its first baseline, and with the glyph in a box
        // the height of one line of text. Baseline alignment reads the glyph frame's bottom as its
        // baseline, so a wide symbol and a round one push the row to different heights: the same
        // note measured 41 points with a checkmark and 42 with a triangle. Tops and one line of
        // height make the row the text's height exactly, and put the mark on the first line of a
        // note that wraps.
        HStack(alignment: .top, spacing: CR.Space.item) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tone.ink)
                // The width is shared so two notes' text begins at one column, and the height is
                // one line so the mark sits on the first line rather than beside the block.
                .frame(width: CR.Icon.symbolSlot, height: CR.Font.bodyLineHeight)
            Text(text)
                .font(CR.Font.body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, CR.Space.section)
        .padding(.vertical, CR.Space.item)
        .accessibilityElement(children: .combine)
    }
}

/// A labelled control stacked vertically.
///
/// A label beside a text field squeezes the field in a narrow editor, so the editors stack the
/// pair instead. The margins match a control row, which keeps an editor aligned with the pane
/// under it.
struct CRSettingsField<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: CR.Space.snug) {
            Text(title)
                .font(CR.Font.callout)
                .foregroundStyle(CR.Ink.readable)
            content()
        }
        .padding(.horizontal, CR.Space.section)
        .padding(.vertical, CR.Space.item)
        .accessibilityElement(children: .contain)
    }
}
