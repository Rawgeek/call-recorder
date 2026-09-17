import CallRecorderCore
import SwiftUI

/// Every component on one page.
///
/// A spacing problem is hard to check one screen at a time: a button that is two points taller
/// than the row beside it reads as a feeling about that screen, not as a number. The sheet puts
/// the buttons, the fields, the chips, the cards, and the rows at their real size in one picture,
/// so a difference between two of them is visible as a difference.
///
/// The snapshot runner renders it. The running app never shows it.
struct DesignSystemSheet: View {
    @State private var searchText = ""
    @State private var filledSearch = "Acme"
    @State private var typedText = ""
    @State private var toggleA = true
    @State private var toggleB = false
    @State private var pickerValue = "Medium"
    @State private var stepper = 2.0

    var body: some View {
        VStack(alignment: .leading, spacing: CR.Space.section) {
            VStack(alignment: .leading, spacing: CR.Space.tight) {
                Text("Call Recorder design system")
                    .font(.system(size: 20, weight: .semibold))
                Text("One height for a control, one margin for a card, one gutter for a surface.")
                    .font(CR.Font.body)
                    .foregroundStyle(CR.Ink.readable)
            }

            HStack(alignment: .top, spacing: CR.Space.section) {
                VStack(alignment: .leading, spacing: CR.Space.section) {
                    buttons
                    iconButtons
                    chips
                }
                .frame(width: 400, alignment: .leading)

                VStack(alignment: .leading, spacing: CR.Space.section) {
                    fields
                    messages
                    rows
                }
                .frame(width: 480, alignment: .leading)
            }
        }
        // 900 plus the two 20-point margins is the width the renderer is given, so the sheet has
        // no slack to centre itself in and no slack to clip against.
        .frame(width: 900, alignment: .leading)
        .padding(CR.Space.screen)
    }

    // MARK: - Bands

    private var buttons: some View {
        group("Buttons · \(Int(CR.Control.height)) pt") {
            VStack(alignment: .leading, spacing: CR.Space.item) {
                HStack(spacing: CR.Space.item) {
                    CRButton(title: "Start Recording", icon: "record.circle", kind: .primary) {}
                    CRButton(title: "Pause", icon: "pause.fill") {}
                    CRButton(title: "Delete", icon: "trash", kind: .destructive) {}
                }
                HStack(spacing: CR.Space.item) {
                    CRButton(title: "Reveal", icon: "folder") {}
                    CRButton(title: "Choose…", kind: .primary) {}
                    CRButton(title: "Retry") {}
                }
                // The popover's width, so a full-width button is drawn at the size it is used at.
                CRButton(title: "Start Recording", icon: "record.circle", kind: .primary, fullWidth: true) {}
                    .frame(width: 328)
            }
        }
    }

    private var iconButtons: some View {
        group("Icon buttons · 26 pt") {
            HStack(spacing: CR.Space.tight) {
                CRIconButton(icon: "folder", label: "Open folder", alwaysVisible: true) {}
                CRIconButton(icon: "gearshape", label: "Settings", alwaysVisible: true) {}
                CRIconButton(icon: "person.2", label: "Participants", alwaysVisible: true) {}
                CRIconButton(icon: "power", label: "Quit", tone: .failed, alwaysVisible: true) {}
                CRIconButton(icon: "doc.on.doc", label: "Copy", revealed: false) {}
                CRIconButton(icon: "trash", label: "Delete", tone: .failed, revealed: false) {}
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var chips: some View {
        group("Status chips") {
            VStack(alignment: .leading, spacing: CR.Space.inner) {
                HStack(spacing: CR.Space.inner) {
                    CRStatusChip(tone: .ready, text: "Ready")
                    CRStatusChip(tone: .waiting, text: "Waiting")
                    CRStatusChip(tone: .working, text: "Transcribing")
                    Spacer(minLength: 0)
                }
                HStack(spacing: CR.Space.inner) {
                    CRStatusChip(tone: .failed, text: "Needs attention")
                    CRStatusChip(tone: .live, text: "Recording")
                    CRStatusChip(tone: .muted, text: "Not set")
                    Spacer(minLength: 0)
                }
                HStack(spacing: CR.Space.inner) {
                    CRStatusChip(tone: .ready, text: "Ready", compact: true)
                    CRStatusChip(tone: .waiting, text: "1 to review", compact: true)
                    CRLiveDot()
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var fields: some View {
        group("Fields · \(Int(CR.Control.height)) pt") {
            VStack(alignment: .leading, spacing: CR.Space.item) {
                CRSearchField(placeholder: "Search people", text: $searchText)
                CRSearchField(placeholder: "Search people", text: $filledSearch)
                CRTextField(placeholder: "Add someone new by name", text: $typedText)
                HStack(spacing: CR.Space.inner) {
                    CRSearchField(placeholder: "Search terms", text: $searchText)
                    CRButton(title: "Add Term", icon: "plus", kind: .primary) {}
                }
                HStack(spacing: CR.Space.inner) {
                    CRTextField(placeholder: "Add someone new by name", text: $typedText)
                        .frame(maxWidth: 260)
                    CRButton(title: "Add", icon: "plus") {}
                }
            }
        }
    }

    private var messages: some View {
        group("Messages") {
            VStack(alignment: .leading, spacing: CR.Space.item) {
                CRCallout(
                    icon: "exclamationmark.triangle.fill",
                    title: "The recording could not be saved.",
                    tone: .failed
                ) {
                    CRButton(title: "Copy Error Details", icon: "doc.on.doc") {}
                }
                CRDisclosureRow(
                    icon: "person.crop.circle.badge.questionmark",
                    title: "Speaker labels missing",
                    detail: "34 past calls without voices",
                    tone: .muted
                ) {}
                CREmptyState(
                    icon: "waveform",
                    title: "Nothing to review",
                    message: "After the next call, its voices appear here."
                )
                .background(
                    RoundedRectangle(cornerRadius: CR.Radius.medium, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                )
            }
        }
    }

    /// One card holding every kind of row, which is where a row height that does not match shows
    /// up first: the dividers step in and out down the card.
    private var rows: some View {
        group("Rows: same text, same height") {
            CRSettingsCard(
                title: "Every control draws in a 30-point slot",
                footnote: "A switch, a pop-up menu, a field, and a button now produce the same row."
            ) {
                CRSettingsRow(title: "Switch, one line") {
                    Toggle("", isOn: $toggleA).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                CRSettingsDivider()
                CRSettingsRow(title: "Switch, with detail", detail: "A second line of text.") {
                    Toggle("", isOn: $toggleB).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                CRSettingsDivider()
                CRSettingsRow(title: "Menu, one line") {
                    Picker("", selection: $pickerValue) {
                        Text("Medium").tag("Medium")
                        Text("Small").tag("Small")
                    }
                    .labelsHidden()
                    // The specimen shows the rule, so it follows it: a capped control is aligned to
                    // the row's trailing gutter rather than centred in its cap.
                    .frame(maxWidth: 160, alignment: .trailing)
                }
                CRSettingsDivider()
                CRSettingsRow(title: "Button, one line") {
                    CRButton(title: "Download", kind: .primary) {}
                }
                CRSettingsDivider()
                CRSettingsRow(title: "Text, one line", detail: "A read-only value") {
                    Text("1.53 GB").font(CR.Font.body).foregroundStyle(CR.Ink.readable)
                }
                CRSettingsDivider()
                CRSettingsRow(title: "Stepper, with detail", detail: "Extra time after a call.") {
                    Stepper(value: $stepper, in: 0...10) {
                        Text("\(stepper, specifier: "%.0f") s").monospacedDigit()
                    }
                    .fixedSize()
                }
                CRSettingsDivider()
                CRSettingsNote(icon: "checkmark.circle", text: "A note keeps the same margins.", tone: .ready)
            }
        }
    }

    // MARK: - Parts

    private func group<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: CR.Space.snug) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(CR.Ink.readable)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
