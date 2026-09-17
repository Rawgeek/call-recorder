import CallRecorderCore
import SwiftUI

/// A participant chooser that is typed into rather than scrolled.
///
/// The pop-up menu it replaces listed everyone ever met in name order, and a library of a few
/// hundred people turned that list into something to read through while the call is still running.
/// This opens into a search field, leads with the people who were on this call, and ends with the
/// one row that makes somebody new — so choosing an existing person and adding a new one are the
/// same two keystrokes. The return key takes the first match, or the new name when there is none.
struct ParticipantPicker<Label: View>: View {
    /// Everyone who may be chosen, already in the order that should break ties.
    let participants: [Participant]
    /// Called with the person the user chose, or the one just added.
    let onSelect: (Participant) -> Void
    /// Creates a person from a typed name. Nil where adding is not offered.
    var create: ((String) async -> Participant?)?
    /// What a row says beside a name, such as which people are on this call.
    var note: (Participant) -> String? = { _ in nil }
    @ViewBuilder var label: () -> Label

    @State private var isPresented = false
    @State private var query = ""

    var body: some View {
        Button {
            isPresented = true
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ParticipantPickerList(
                participants: participants,
                query: $query,
                onSelect: { participant in
                    onSelect(participant)
                    close()
                },
                create: create,
                note: note,
                onAdded: close
            )
        }
        .accessibilityLabel("Choose a participant")
    }

    private func close() {
        isPresented = false
        query = ""
    }
}

/// What a picker opens into.
///
/// Apart from the button because a popover does not draw off screen, and this list is the part a
/// person has to read: a render of the window shows the control, never what it opens onto.
struct ParticipantPickerList: View {
    let participants: [Participant]
    @Binding var query: String
    let onSelect: (Participant) -> Void
    var create: ((String) async -> Participant?)?
    var note: (Participant) -> String? = { _ in nil }
    /// Run once a person was added, so the surface that owns the popover can put it away.
    var onAdded: () -> Void = {}

    @State private var isCreating = false

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matches: [Participant] {
        SpeakerReviewCandidates.matching(participants, query: query)
    }

    /// The name to offer as a new person: what was typed, when it is nobody yet.
    private var nameToAdd: String? {
        guard create != nil, !trimmedQuery.isEmpty else { return nil }
        guard SpeakerReviewCandidates.exactMatch(participants, query: trimmedQuery) == nil else {
            return nil
        }
        return trimmedQuery
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CRSearchField(
                placeholder: "Search or add a name",
                text: $query,
                focusOnAppear: true,
                onSubmit: chooseFirst
            )
            .padding(CR.Space.item)
            CRDivider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(matches.prefix(60)) { participant in
                        row(participant)
                    }
                    if matches.isEmpty {
                        Text(
                            trimmedQuery.isEmpty
                                ? "Nobody has been saved yet."
                                : "Nobody matches \u{201C}\(trimmedQuery)\u{201D}."
                        )
                        .font(CR.Font.caption)
                        .foregroundStyle(CR.Ink.readable)
                        .padding(CR.Space.item)
                    }
                }
            }
            .frame(maxHeight: 260)
            if let nameToAdd {
                CRDivider()
                addRow(nameToAdd)
            }
        }
        .frame(width: 320)
    }

    private func row(_ participant: Participant) -> some View {
        Button {
            onSelect(participant)
        } label: {
            VStack(alignment: .leading, spacing: CR.Space.hairline) {
                Text(participant.name)
                    .font(CR.Font.body)
                    .foregroundStyle(CR.Ink.readable)
                if let detail = detailLine(participant) {
                    Text(detail)
                        .font(CR.Font.caption)
                        .foregroundStyle(CR.Ink.readable)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CR.Space.item)
            .padding(.vertical, CR.Space.snug)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func detailLine(_ participant: Participant) -> String? {
        var parts: [String] = []
        if let note = note(participant), !note.isEmpty { parts.append(note) }
        if let company = participant.company, !company.isEmpty { parts.append(company) }
        if let email = participant.email, !email.isEmpty, parts.count < 2 { parts.append(email) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The row that makes somebody new, offered only for a name nobody has.
    private func addRow(_ name: String) -> some View {
        Button {
            Task { await add(name) }
        } label: {
            HStack(spacing: CR.Space.snug) {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 12, weight: .medium))
                Text(isCreating ? "Adding…" : "Add \u{201C}\(name)\u{201D}")
                    .font(CR.Font.button)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(CR.Ink.readable)
            .padding(.horizontal, CR.Space.item)
            .frame(height: CR.Control.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isCreating)
        .help("Save this person and name the voice with them")
    }

    private func add(_ name: String) async {
        guard let create else { return }
        isCreating = true
        defer { isCreating = false }
        guard let created = await create(name) else { return }
        onSelect(created)
        onAdded()
    }

    /// Return takes the first match, or adds the typed name when nothing matches it.
    private func chooseFirst() {
        guard let first = matches.first else {
            if let nameToAdd { Task { await add(nameToAdd) } }
            return
        }
        onSelect(first)
    }
}
