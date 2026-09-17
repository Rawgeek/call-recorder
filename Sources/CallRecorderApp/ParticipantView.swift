import CallRecorderCore
import SwiftUI

/// A name waiting to be added, so the add sheet has something to present on.
///
/// The window opens that sheet from two places and one of them carries a name. A bare string has
/// no identity for the item-based sheet presentation to read, and a fresh identity per request is
/// also what makes adding the same name twice reopen the sheet rather than doing nothing.
struct PendingParticipantName: Identifiable {
    let id = UUID()
    let name: String

    /// The request that the row under the list can make: the name it holds, tidied.
    ///
    /// A blank field has nothing to add, so it makes no request at all. Naming this rule here
    /// rather than inside the button keeps it checkable without a window.
    static func typedName(_ raw: String) -> PendingParticipantName? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return PendingParticipantName(name: trimmed)
    }
}

/// The checklist of who was on a call.
///
/// The list is the control, so a row is one target: clicking anywhere on it selects or clears the
/// person. The previous layout put a checkbox at the start of each row, which left most of the row
/// inert and gave no confirmation that a click had landed.
struct ParticipantView: View {
    @Bindable var model: AppModel
    var callID: CallID?
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var newName = ""
    @State private var editingParticipant: Participant?
    /// The name to open the add sheet with, or nil when that sheet is closed.
    ///
    /// A pending name rather than a flag, because the row above the footer can carry a name into
    /// the sheet. Presenting on the value is what makes it arrive before the sheet is built; a flag
    /// plus a separate name is two pieces of state that can disagree.
    @State private var addingParticipantName: PendingParticipantName?
    @State private var saveError: String?
    @State private var isSaving = false
    /// Clearing a finished call's list is the one destructive action in this window, so it asks
    /// first. Every other destructive action in the app already does.
    @State private var confirmingRemoveAll = false

    /// The people who were already on this call when the window opened.
    ///
    /// Editing a finished call means confirming a handful of people out of everyone ever met: the
    /// three who were there were scattered through a list of forty-seven in name order, and finding
    /// them meant reading every row. They lead the list while it is open.
    ///
    /// This is a snapshot rather than the live selection, because a list that reordered as rows are
    /// clicked would move the next row out from under the pointer. The order stays still for as
    /// long as the window is open, and every row keeps the checkbox that says whether it is on.
    @State private var leadingParticipants: Set<ParticipantID> = []

    /// The call this window writes to: the call the user picked, or the call opened from Recent.
    private var editedCallID: CallID? { callID ?? model.participantEditingCallID }

    private var isEditingFinishedCall: Bool { editedCallID != nil }

    private var filteredParticipants: [Participant] {
        let matching = search.isEmpty
            ? model.participants
            : model.participants.filter { participant in
                participant.name.localizedCaseInsensitiveContains(search)
                    || (participant.company?.localizedCaseInsensitiveContains(search) ?? false)
                    || (participant.email?.localizedCaseInsensitiveContains(search) ?? false)
            }
        // A person who was already on the call is the likeliest reason the window was opened, so
        // those rows come first and the rest keep their name order underneath.
        return SpeakerReviewCandidates.ordered(
            participants: matching,
            leading: leadingParticipants
        )
    }

    /// Spells out what the save button will write, because an empty selection is a valid choice
    /// that removes every participant from the call.
    private var selectionSummary: String {
        let count = model.selectedParticipantIDs.count
        switch count {
        case 0: return "No one selected"
        case 1: return "1 person selected"
        default: return "\(count) people selected"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            CRDivider()
            toolbar
            list
            CRDivider()
            footer
        }
        .frame(minWidth: 520, minHeight: 520)
        .onAppear { leadingParticipants = model.selectedParticipantIDs }
        .sheet(item: $editingParticipant) { participant in
            ParticipantEditor(model: model, participant: participant)
        }
        // The pending name is the sheet's identity, so a new request is a new sheet and the editor
        // is built with the name already in it. An empty name is a real case and still opens it.
        .sheet(item: $addingParticipantName) { pending in
            ParticipantEditor(model: model, adding: pending.name)
        }
        .confirmationDialog(
            "Remove every participant from this call?",
            isPresented: $confirmingRemoveAll,
            titleVisibility: .visible
        ) {
            Button("Remove Participants", role: .destructive) {
                model.selectedParticipantIDs.removeAll()
                save()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The call keeps its recording and transcript. Its header, and any speaker named "
                    + "on it, go back to being unknown. Choosing people again puts them back."
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: CR.Space.snug) {
            HStack(alignment: .firstTextBaseline, spacing: CR.Space.inner) {
                Text("Who was on this call?")
                    .font(.system(size: 17, weight: .semibold))
                Spacer(minLength: CR.Space.item)
                CRStatusChip(
                    tone: model.selectedParticipantIDs.isEmpty ? .muted : .ready,
                    text: selectionSummary
                )
            }
            if let editedCallID {
                HStack(spacing: CR.Space.snug) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11))
                        .foregroundStyle(CR.Ink.mark)
                    Text(editingCallTitle(editedCallID))
                        .font(CR.Font.callout)
                        .foregroundStyle(CR.Ink.readable)
                    Text("· Saving updates this call's transcript")
                        .font(CR.Font.caption)
                        .foregroundStyle(CR.Ink.readable)
                }
            } else {
                Text("Saved people are reused for every call and match voices automatically.")
                    .font(CR.Font.callout)
                    .foregroundStyle(CR.Ink.readable)
            }
        }
        .padding(CR.Space.screen)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: CR.Space.inner) {
            // The same field as the settings panes, so the row is one height whether the search
            // box is beside a button here or there.
            CRSearchField(placeholder: "Search people", text: $search, focusOnAppear: true)

            CRButton(title: "Add Person", icon: "person.badge.plus", kind: .secondary) {
                addingParticipantName = PendingParticipantName(name: "")
            }
        }
        .padding(.horizontal, CR.Space.screen)
        // The toolbar sits under the header's divider. With only a bottom margin the search field
        // started on the line itself, which reads as a drawing fault rather than as a tight
        // layout: every other control on every other surface keeps the section gap from a divider.
        .padding(.top, CR.Space.item)
        .padding(.bottom, CR.Space.item)
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if filteredParticipants.isEmpty {
            ScrollView {
                CREmptyState(
                    icon: "person.crop.circle.badge.plus",
                    title: search.isEmpty ? "No saved people" : "No matches",
                    message: search.isEmpty
                        ? "Add someone and they become selectable on every call."
                        : "Try another search, or add this person."
                )
            }
        } else {
            ScrollView {
                LazyVStack(spacing: CR.Space.hairline) {
                    ForEach(filteredParticipants, id: \.id) { participant in
                        ParticipantRow(
                            participant: participant,
                            isSelected: model.selectedParticipantIDs.contains(participant.id),
                            voiceSummary: model.voiceProfileSummary(for: participant.id)
                        ) {
                            toggle(participant)
                        } edit: {
                            editingParticipant = participant
                        }
                    }
                }
                // The list shares the toolbar's margin, so a name starts under the search field
                // instead of a step to its left.
                .padding(.horizontal, CR.Space.screen)
                // The footer's divider is the list's floor. Stopping the rows 12 points above it
                // left the last name looking like the first thing in the footer, so the list
                // keeps the same gap the footer keeps from its own edges.
                .padding(.bottom, CR.Space.bar)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: CR.Space.item) {
            if let saveError {
                CRCallout(
                    icon: "exclamationmark.triangle.fill",
                    title: "Couldn't save",
                    message: saveError,
                    tone: .failed
                ) {}
            }
            // Adding someone and finishing the call are two different jobs. They shared a row,
            // which left the primary button about ninety points at the window's own size and
            // clipped its label to "Save Particip…".
            //
            // This row used to create the person itself, from the name alone, while the toolbar's
            // Add Person button opened the editor that collects a role, a company, and an address.
            // One job with two outcomes and nothing on the surface to say which one had been used:
            // a name typed here produced a person every later list showed with no way to tell them
            // from a colleague, and the fields it skipped were never offered again. The typed name
            // now opens the same editor, filled in, so the fast path stays fast and the record is
            // complete.
            HStack(spacing: CR.Space.snug) {
                CRTextField(
                    placeholder: "Add someone new by name",
                    text: $newName,
                    onSubmit: beginAddingParticipant
                )
                .frame(maxWidth: 320)
                CRButton(
                    title: "Add",
                    icon: "plus",
                    kind: .secondary,
                    action: beginAddingParticipant
                )
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer(minLength: 0)
            }

            HStack(spacing: CR.Space.item) {
                // Clearing the list is destructive, so it sits away from the default button at
                // the leading edge, where nobody reaches it on the way to Save.
                CRButton(
                    title: isEditingFinishedCall ? "Remove All" : "Skip",
                    kind: .secondary
                ) {
                    // Skipping a new recording is not destructive and does not ask. Clearing a
                    // finished call's list does, because it rewrites what the transcript says
                    // about who was there.
                    if isEditingFinishedCall {
                        confirmingRemoveAll = true
                    } else {
                        model.selectedParticipantIDs.removeAll()
                        save()
                    }
                }
                // Removing nothing is not a job, so the button is off when the list is already
                // empty. It used to open its confirmation for a call that had no participants and
                // then save the same empty list, which is a dialog and a write for no change.
                .disabled(isSaving || (isEditingFinishedCall && model.selectedParticipantIDs.isEmpty))
                .help(isEditingFinishedCall ? "Remove every participant from this call" : "Continue")

                Spacer(minLength: CR.Space.item)

                if isSaving {
                    ProgressView().controlSize(.small)
                }
                CRButton(
                    title: isEditingFinishedCall ? "Save Participants" : "Continue",
                    icon: "checkmark",
                    kind: .primary,
                    action: save
                )
                .disabled(isSaving)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(CR.Space.screen)
    }

    // MARK: - Actions

    private func toggle(_ participant: Participant) {
        if model.selectedParticipantIDs.contains(participant.id) {
            model.selectedParticipantIDs.remove(participant.id)
        } else {
            model.selectedParticipantIDs.insert(participant.id)
        }
    }

    /// Opens the add sheet with the typed name already in it.
    ///
    /// The field is cleared here rather than on save: the sheet owns the name from this point, so a
    /// cancelled add leaves the row empty and the sheet's own Cancel is the way to drop it.
    private func beginAddingParticipant() {
        guard let pending = PendingParticipantName.typedName(newName) else { return }
        newName = ""
        addingParticipantName = pending
    }

    /// Saves and closes. A failure keeps the window open with the reason, so the button never
    /// looks like it did nothing.
    private func save() {
        guard !isSaving else { return }
        isSaving = true
        saveError = nil
        Task {
            let failure = await model.saveParticipants()
            isSaving = false
            if let failure {
                saveError = failure
                return
            }
            model.finishEditingParticipants()
            dismiss()
        }
    }

    private func editingCallTitle(_ callID: CallID) -> String {
        guard let call = model.recentCalls.first(where: { $0.id == callID }) else {
            return "Participants for a saved call"
        }
        return "Participants for \(call.startedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// One selectable person.
private struct ParticipantRow: View {
    let participant: Participant
    let isSelected: Bool
    let voiceSummary: VoiceProfileSummary?
    let toggle: () -> Void
    let edit: () -> Void

    @State private var hovering = false

    private var hasLearnedVoice: Bool {
        (voiceSummary?.confirmedSampleCount ?? 0) > 0
    }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: CR.Space.item) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    // The empty circle is what says the row can be picked. At half the secondary
                    // colour it drew at 1.9:1 on a light window, which is under the 3:1 a mark
                    // that carries meaning needs, and it read as a smudge rather than a control.
                    .foregroundStyle(
                        isSelected ? Color.accentColor : Color(nsColor: CR.Ink.markColor)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: CR.Space.hairline) {
                    Text(participant.name)
                        .font(CR.Font.body)
                        .fontWeight(isSelected ? .medium : .regular)
                    if !roleAndCompany.isEmpty {
                        Text(roleAndCompany)
                            .font(CR.Font.caption)
                            .foregroundStyle(CR.Ink.readable)
                            .lineLimit(1)
                    }
                    if let email = participant.email {
                        Text(email)
                            .font(CR.Font.caption)
                            // An address is read to check who this is, and two people can share a
                            // name. At 2.27:1 it was the hardest line in the row to read.
                            .foregroundStyle(CR.Ink.readable)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: CR.Space.inner)

                if hasLearnedVoice {
                    Image(systemName: "waveform.badge.checkmark")
                        .font(.system(size: 12))
                        .foregroundStyle(CR.Tone.ready.ink)
                        .help("This person can be matched by voice after a call.")
                        .accessibilityLabel("\(participant.name) has a learned voice")
                } else {
                    Image(systemName: "waveform.badge.plus")
                        .font(.system(size: 12))
                        // This glyph says something the row does not: this person has no learned
                        // voice. It is read, so it has to be visible.
                        .foregroundStyle(CR.Ink.readable)
                        .help("Name this person on a voice and the app learns it.")
                        .accessibilityLabel("\(participant.name) has no learned voice yet")
                }

                CRIconButton(
                    icon: "pencil",
                    label: "Edit \(participant.name)",
                    // The pencil keeps its place in the row whether or not the pointer is over it.
                    // Revealing it on hover reserved the same 26-point circle either way, so the
                    // glyph beside it sat 48.5 points inside the row's right edge while the row's
                    // own content began 13.5 points inside its left one, and the widest margin on
                    // the surface was the one nothing was drawn in. The People pane shows its
                    // pencil on every row, so this is also the one treatment for both lists.
                    alwaysVisible: true,
                    trailingAligned: true,
                    action: edit
                )
            }
            // A row's own margin plus the list's margin is what puts the checkbox under the
            // search field above it.
            .padding(.horizontal, CR.Space.item)
            .padding(.vertical, CR.Space.inner)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CR.Radius.small, style: .continuous)
                    .fill(rowBackground)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(participant.name)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.14) }
        return hovering ? Color.primary.opacity(0.06) : .clear
    }

    private var roleAndCompany: String {
        [participant.role, participant.company]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

/// The compact person summary used where a row is not selectable.
struct ParticipantLabel: View {
    let participant: Participant

    var body: some View {
        VStack(alignment: .leading, spacing: CR.Space.hairline) {
            Text(participant.name)
            if !roleAndCompany.isEmpty {
                Text(roleAndCompany)
                    .font(.caption)
                    .foregroundStyle(CR.Ink.readable)
                    .lineLimit(1)
            }
            if let email = participant.email {
                Text(email)
                    .font(.caption)
                    .foregroundStyle(CR.Ink.readable)
                    .lineLimit(1)
            }
        }
    }

    private var roleAndCompany: String {
        [participant.role, participant.company]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

/// Adds or edits one person. The same sheet serves both, so adding someone collects every field
/// while the user still has the details in front of them.
struct ParticipantEditor: View {
    @Bindable var model: AppModel
    /// nil adds a new person, which is why the name and the profile fields start empty.
    let participant: Participant?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var role: String
    @State private var company: String
    @State private var email: String
    @State private var isSaving = false
    @State private var confirmProfileReset = false

    init(model: AppModel, participant: Participant?) {
        self.model = model
        self.participant = participant
        _name = State(initialValue: participant?.name ?? "")
        _role = State(initialValue: participant?.role ?? "")
        _company = State(initialValue: participant?.company ?? "")
        _email = State(initialValue: participant?.email ?? "")
    }

    /// Adds a person, with a name the caller already knows.
    ///
    /// This window has two ways to add someone: the toolbar button opens this sheet, and the row
    /// above the footer took a name and created the person straight away with no other fields. Two
    /// paths to the same job gave two different records for it — a name typed below the list
    /// produced a person with no address and no role, and there was nothing on the surface to say
    /// which one the user had just made. Both paths now open this sheet, and the name typed below
    /// the list arrives here already filled in, so filling the rest is the next thing rather than
    /// a step that was silently skipped.
    init(model: AppModel, adding name: String) {
        self.model = model
        self.participant = nil
        _name = State(initialValue: name)
        _role = State(initialValue: "")
        _company = State(initialValue: "")
        _email = State(initialValue: "")
    }

    private var isNew: Bool { participant == nil }

    /// What the sheet says the edit will do.
    ///
    /// This used to promise that saved transcripts keep their wording. They do not: the participant
    /// line of every saved transcript is rewritten when it no longer matches the list, at the next
    /// start or from Fix Transcript Names in Recovery. The sheet is where the edit is made, so the
    /// one place the reader would never doubt a wrong answer is here.
    nonisolated static func subtitle(isNew: Bool) -> String {
        isNew
            ? "The name is used in transcripts, so spell it the way the person writes it."
            : "A corrected name also reaches saved transcripts, at the next start or from Fix Transcript Names in Recovery."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: CR.Space.snug) {
                Text(isNew ? "Add Person" : "Edit Person")
                    .font(.system(size: 17, weight: .semibold))
                Text(ParticipantEditor.subtitle(isNew: isNew))
                .font(CR.Font.callout)
                .foregroundStyle(CR.Ink.readable)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(CR.Space.screen)

            CRDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: CR.Space.section) {
                    CRSettingsCard(title: "Details") {
                        CRSettingsField(title: "Name") {
                            CRTextField(placeholder: "Jordan Lee", text: $name)
                        }
                        CRSettingsDivider()
                        CRSettingsField(title: "Role") {
                            CRTextField(placeholder: "Product Manager", text: $role)
                        }
                        CRSettingsDivider()
                        CRSettingsField(title: "Company") {
                            CRTextField(placeholder: "Acme Inc.", text: $company)
                        }
                        CRSettingsDivider()
                        CRSettingsField(title: "Email") {
                            CRTextField(placeholder: "name@example.com", text: $email)
                        }
                    }

                    // Voice controls belong to an existing person, because a new one has no profile.
                    if let participant {
                        CRSettingsCard(
                            title: "Voice identification",
                            footnote: "A profile is learned from finished calls. It is stored encrypted and never leaves this Mac."
                        ) {
                            CRSettingsRow(title: "Status", detail: profileStatus) {
                                EmptyView()
                            }
                            if let summary = model.voiceProfileSummary(for: participant.id) {
                                if summary.confirmedSampleCount > 0 {
                                    CRSettingsDivider()
                                    CRSettingsRow(
                                        title: "Reset voice profile",
                                        detail: "Forgets the learned voice. Saved transcripts keep their names."
                                    ) {
                                        CRButton(title: "Reset", kind: .destructive) {
                                            confirmProfileReset = true
                                        }
                                    }
                                }
                                if summary.recoverableSampleCount > 0 {
                                    CRSettingsDivider()
                                    CRSettingsRow(
                                        title: "Restore voice profile",
                                        detail: "Brings back a profile that was reset or replaced."
                                    ) {
                                        CRButton(title: "Restore") {
                                            model.restoreVoiceProfile(for: participant.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(CR.Space.screen)
            }
            CRDivider()

            HStack(spacing: CR.Space.item) {
                Spacer(minLength: 0)
                if isSaving { ProgressView().controlSize(.small) }
                CRButton(title: "Cancel", kind: .secondary) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                CRButton(
                    title: isNew ? "Add Person" : "Save",
                    icon: "checkmark",
                    kind: .primary,
                    action: save
                )
                .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(CR.Space.screen)
        }
        // Tall enough that the four fields are whole at the size the sheet opens at: at 480 the
        // email field was cut in half by the footer.
        .frame(width: 440, height: 540)
        .confirmationDialog(
            "Reset \(participant?.name ?? "this person")'s voice profile?",
            isPresented: $confirmProfileReset,
            titleVisibility: .visible
        ) {
            Button("Reset Voice Profile", role: .destructive) {
                if let participant { model.resetVoiceProfile(for: participant.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Encrypted samples can be restored for 24 hours. Existing transcripts are unchanged.")
        }
    }

    private func save() {
        isSaving = true
        Task {
            let saved = if let participant {
                await model.updateParticipant(
                    participant, name: name, role: role, company: company, email: email
                )
            } else {
                await model.createParticipant(
                    name: name, role: role, company: company, email: email
                ) != nil
            }
            isSaving = false
            if saved { dismiss() }
        }
    }

    private var profileStatus: String {
        guard
            let participant,
            let summary = model.voiceProfileSummary(for: participant.id)
        else {
            return "No profile"
        }
        if summary.confirmedSampleCount >= 2 {
            return "Ready · \(summary.confirmedSampleCount) samples"
        }
        if summary.confirmedSampleCount == 1 {
            return "Learning · 1 sample"
        }
        return summary.recoverableSampleCount > 0 ? "Reset · restore available" : "No profile"
    }
}
