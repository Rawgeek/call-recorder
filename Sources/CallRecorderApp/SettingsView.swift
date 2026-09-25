import CallRecorderCore
import SwiftUI

/// The Settings window.
///
/// The sidebar is built from an explicit stack rather than `NavigationSplitView`. The split view
/// draws its own title-bar treatment, which cannot be rendered outside a real window, so every
/// design change needed a packaged, signed, installed build before it could be looked at. This
/// layout renders anywhere and gives the sidebar the same styling as the rest of the app.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var section: SettingsSection = SettingsView.initialSection

    /// Which pane to open on. The snapshot runner sets this so a render can show any pane.
    static var initialSection: SettingsSection {
        guard let raw = ProcessInfo.processInfo.environment["CALL_RECORDER_SETTINGS_PANE"],
              let section = SettingsSection(rawValue: raw)
        else { return .general }
        return section
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // The sidebar plus the widest a pane is allowed to draw, plus its margins. Narrower
        // than this and the readable measure is squeezed, which is the one thing the measure
        // exists to prevent.
        .frame(minWidth: 860, minHeight: 560)
        .background(background)
        .navigationTitle("Call Recorder Settings")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: CR.Space.hairline) {
                ForEach(SettingsSection.allCases) { item in
                    SidebarRow(
                        section: item,
                        isSelected: item == section
                    ) {
                        section = item
                    }
                }
            }
            .padding(CR.Space.inner)
            Spacer(minLength: 0)
        }
        .frame(width: 196)
        .frame(maxHeight: .infinity)
        .background(Color.primary.opacity(0.03))
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .general: GeneralSettingsView(model: model)
        case .models: ModelSettingsView(model: model)
        case .people: PeopleSettingsView(model: model)
        case .vocabulary: VocabularySettingsView(model: model)
        case .recovery: RecoverySettingsView(model: model)
        }
    }

    /// Lets the window follow the system appearance where the material is available, and falls
    /// back to the standard window colour where it is not.
    @ViewBuilder
    private var background: some View {
        if #available(macOS 26.0, *) {
            Color.clear
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }
}

/// One row in the settings sidebar.
private struct SidebarRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let select: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: CR.Space.inner) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: CR.Icon.sidebarSlot)
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                Text(section.title)
                    .font(CR.Font.body)
                    .fontWeight(isSelected ? .medium : .regular)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, CR.Space.item)
            .padding(.vertical, CR.Space.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CR.Radius.small, style: .continuous)
                    .fill(isSelected ? Color.accentColor : (hovering ? Color.primary.opacity(0.06) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The settings sections. One case per pane, so adding a pane is one entry plus one view.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case models
    case people
    case vocabulary
    case recovery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .models: "Models"
        case .people: "Participants"
        case .vocabulary: "Vocabulary"
        case .recovery: "Recovery"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .models: "arrow.down.circle"
        case .people: "person.2"
        case .vocabulary: "text.book.closed"
        case .recovery: "cross.case"
        }
    }
}


struct RecoverySettingsView: View {
    @Bindable var model: AppModel
    @State private var pendingPurge: RecoverableArtifact?
    @State private var pendingRemoval: ProcessingJob?
    /// The bulk answer for the orphaned list, kept beside the single one so both open the same
    /// wording and the same removal.
    @State private var pendingBulkRemoval = false
    @Environment(\.openWindow) private var openWindow

    private var activeJobs: [ProcessingJob] {
        model.processingJobs.filter { $0.executionState != .complete }
    }

    /// The jobs that still have files to work with, newest first.
    ///
    /// The list used to hold both kinds of unfinished call in the order the database returned
    /// them, so a row waiting on a retry sat between two rows whose files were already gone. The
    /// reader looking for what to do next had to check each row's control to tell them apart.
    private var workingJobs: [ProcessingJob] {
        activeJobs.filter { !isUnfinishable($0) }
    }

    /// The jobs whose audio and transcript are both gone, so no retry can finish them.
    ///
    /// They are not processing and never will be. They are here because the row outlived its
    /// files, and the only thing left to do with one is clear it.
    private var orphanedJobs: [ProcessingJob] {
        activeJobs.filter { isUnfinishable($0) }
    }

    /// The call a job belongs to, in the words the popover's Recent list uses: who was on it, or
    /// when it started when nobody is named yet.
    ///
    /// The time is part of the answer, not decoration. Four calls that all began on the same day
    /// were titled "Call from Jul 28" four times, each with its own destructive Remove button and
    /// nothing to choose between them. A day is not an identity when the list holds more than one
    /// call from that day; the moment it started is.
    private func callTitle(for job: ProcessingJob) -> String {
        guard let call = model.processingCallSummaries[job.callID] else {
            return job.stage.displayName
        }
        if !call.participantNames.isEmpty {
            return call.participantNames.joined(separator: ", ")
        }
        let age = Date.now.timeIntervalSince(call.startedAt)
        let clock = call.startedAt.formatted(.dateTime.hour().minute())
        if age < 86_400 { return "Today at " + clock }
        return "Call from "
            + call.startedAt.formatted(.dateTime.month(.abbreviated).day())
            + " at " + clock
    }

    /// True when nothing is left for the job to work on.
    private func isUnfinishable(_ job: ProcessingJob) -> Bool {
        model.unfinishableCallIDs.contains(job.callID)
    }

    /// Names a kept recording by who was on it.
    ///
    /// Every row in this list used to be titled with its kind alone, so five recordings read as
    /// three kinds of file and the person had no way to tell which call they were looking at. The
    /// people are the identity, the same way they are in the popover's Recent list, and the call
    /// table still knows them whether or not the call row itself survived.
    private func artifactTitle(_ item: RecoverableArtifact) -> String {
        let names = (model.callParticipants[item.callID] ?? []).map(\.name)
        guard names.isEmpty else { return names.joined(separator: ", ") }
        switch item.kind {
        case .discardedRecording: return "Discarded recording"
        case .interruptedRecording: return "Interrupted recording"
        case .completedCall: return "Completed call files"
        }
    }

    /// What the recording is and when it was made, in that order.
    ///
    /// The time is the recording's own, not the moment its audio was removed. Those are different
    /// facts, and the removal time answers a question nobody in this list is asking.
    private func artifactDetail(_ item: RecoverableArtifact) -> String {
        let kind = switch item.kind {
        case .discardedRecording: "Discarded audio"
        case .interruptedRecording: "Audio from an interrupted recording"
        case .completedCall: "Audio from a finished call"
        }
        guard let recordedAt = item.recordedAt else {
            return kind + " · removed "
                + item.deletedAt.formatted(date: .abbreviated, time: .shortened)
        }
        return kind + " · recorded "
            + recordedAt.formatted(date: .abbreviated, time: .shortened)
    }

    /// One sentence saying whether the automatic repair ran, and what it decided.
    ///
    /// "It ran and left everything alone" is the answer someone needs when a call still shows one
    /// person on several voices: it means those voices were measured against that person's profile
    /// and matched, so the split is the transcription's, not a wrong name. Saying nothing left that
    /// indistinguishable from the repair never having run.
    private func reconcileSummaryText(_ summary: SpeakerReconcileSummary) -> String {
        if let failure = summary.failure {
            return "The last repair could not run: " + failure
        }
        let when = summary.finishedAt.formatted(date: .omitted, time: .shortened)
        if summary.callsExamined == 0 {
            return "Last repair ran at " + when
                + ". No call has one name on more than one voice."
        }
        let voices = "\(summary.voicesExamined) voice"
            + (summary.voicesExamined == 1 ? "" : "s")
        if summary.returnedToReview == 0 {
            var text = "Last repair ran at " + when + ". It compared " + voices
                + " across \(summary.callsExamined) call"
                + (summary.callsExamined == 1 ? "" : "s")
                + ", and every voice matched the name it carried."
            if let closest = summary.closestKeptSimilarity {
                text += String(format: " Closest kept match %.2f.", closest)
            }
            return text
        }
        return "Last repair ran at " + when + ". It compared " + voices
            + " and returned \(summary.returnedToReview) to review."
    }

    /// One line per problem, so the tab opens on what needs a decision instead of four
    /// reassuring rows. Empty means nothing is wrong and the tools below are optional.
    private var healthIssues: [String] {
        var issues: [String] = []
        let failedSaves = model.backgroundFailures.count
        if failedSaves > 0 {
            issues.append(
                "\(failedSaves) recording\(failedSaves == 1 ? "" : "s") failed to save"
            )
        }
        // A failed job is not waiting; it stopped and needs a retry. Saying "still waiting to
        // finish" about it hid the one action that would clear it.
        let failed = activeJobs.filter { $0.executionState == .failed }.count
        // Only the ones with something left to work on can be retried.
        let retryable = activeJobs.filter { $0.executionState == .failed && !isUnfinishable($0) }.count
        if retryable > 0 {
            issues.append("\(retryable) call\(retryable == 1 ? "" : "s") stopped part way and can be retried")
        }
        let orphans = failed - retryable
        if orphans > 0 {
            issues.append(
                orphans == 1
                    ? "1 unfinished call lost its audio and can be cleared"
                    : "\(orphans) unfinished calls lost their audio and can be cleared"
            )
        }
        let waiting = activeJobs.count - failed
        if waiting > 0 {
            issues.append("\(waiting) call\(waiting == 1 ? "" : "s") still processing")
        }
        if model.voiceIdentityState == .waitingForPermission {
            issues.append("The voice-profile key is waiting for a keychain permission answer")
        } else if model.voiceIdentityState == .unavailable {
            issues.append("Voice identity cannot read its key from the login keychain")
        }
        // A row can outlive its file: the working folder a call was transcribed into is removed
        // once the transcript is promoted, and a row that was not repointed first goes on naming
        // it. That row still offers Open, and Open then did nothing at all, which reads as a
        // broken button rather than a missing file.
        let missingFiles = model.missingTranscriptFileCount
        if missingFiles > 0 {
            let opening = missingFiles == 1 ? "saved transcript names" : "saved transcripts name"
            issues.append(String(missingFiles) + " " + opening + " a file that is gone")
        }

        let recoverable = model.recoverableArtifacts.count
        if recoverable > 0 {
            // Not every kept recording was deleted on purpose: an interrupted one is here too, and
            // calling it deleted sent people looking for a mistake they never made.
            issues.append(
                "\(recoverable) recording\(recoverable == 1 ? "" : "s") kept for 24 hours can still be restored"
            )
        }
        return issues
    }

    var body: some View {
        SettingsPane(
            title: "Recovery",
            subtitle: "Check the database, restore working files, and retry anything that failed."
        ) {
            CRSettingsCard(
                title: "Status",
                footnote: healthIssues.isEmpty
                    ? nil
                    : "Recover below, or open the recordings folder to look at the files."
            ) {
                if healthIssues.isEmpty {
                    CRSettingsNote(
                        icon: "checkmark.circle",
                        text: "Everything is healthy.",
                        tone: .ready
                    )
                } else {
                    ForEach(Array(healthIssues.enumerated()), id: \.offset) { index, issue in
                        if index > 0 { CRSettingsDivider() }
                        CRSettingsNote(
                            icon: "exclamationmark.triangle",
                            text: issue,
                            tone: .waiting
                        )
                    }
                }
                CRSettingsDivider()
                CRSettingsRow(
                    title: "Check again",
                    detail: "Re-read the database and the recordings folder."
                ) {
                    CRButton(title: "Refresh", icon: "arrow.clockwise") {
                        Task { await model.refreshMetadata() }
                    }
                }
            }

            // Empty sections were four rows of reassurance to read past. A card now appears
            // only when it holds something the user can act on.
            if model.backgroundSavingCount > 0 || !model.backgroundFailures.isEmpty {
                CRSettingsCard(title: "Background Saves") {
                    if model.backgroundSavingCount > 0 {
                        CRSettingsNote(
                            icon: "arrow.down.circle",
                            text: "\(model.backgroundSavingCount) "
                                + "recording\(model.backgroundSavingCount == 1 ? "" : "s") "
                                + "saving in the background."
                        )
                    }
                    ForEach(Array(model.backgroundFailures.enumerated()), id: \.element.job.callID) { index, failure in
                        if index > 0 || model.backgroundSavingCount > 0 { CRSettingsDivider() }
                        CRSettingsRow(
                            title: "Save failed",
                            detail: failure.job.endedAt.formatted(date: .abbreviated, time: .shortened)
                                + " · " + failure.message
                        ) {
                            HStack(spacing: CR.Space.inner) {
                                CRButton(title: "Retry") {
                                    model.retryBackgroundSave(for: failure.job.callID)
                                }
                                CRButton(title: "Copy Error") {
                                    model.copyBackgroundSaveError(for: failure.job.callID)
                                }
                            }
                        }
                    }
                }
            }

            if !workingJobs.isEmpty {
                CRSettingsCard(title: "Calls Still Processing") {
                    ForEach(Array(workingJobs.enumerated()), id: \.element.callID) { index, job in
                        if index > 0 { CRSettingsDivider() }
                        CRSettingsRow(
                            title: callTitle(for: job),
                            detail: job.executionState == .failed
                                ? "Failed while \(job.stage.failureName)"
                                : job.stage.displayDetail
                        ) {
                            if job.executionState == .failed {
                                CRButton(title: "Retry") {
                                    Task { await model.retryProcessing(job) }
                                }
                            }
                        }
                    }
                }
            }

            // A call that lost both its audio and its transcript cannot be retried. Those rows
            // used to sit inside the list above, under a title that said they were processing.
            if !orphanedJobs.isEmpty {
                CRSettingsCard(
                    title: "Calls With No Files Left",
                    footnote: "Nothing can be recovered from these. Removing a row deletes its "
                        + "record and nothing else."
                ) {
                    // Six rows, one decision. The count rides on the row so the answer is the same
                    // whichever row a person reads, and the row only appears when there is more
                    // than one row to collapse.
                    if orphanedJobs.count > 1 {
                        CRSettingsRow(
                            title: "Remove all \(orphanedJobs.count) unfinished calls",
                            detail: "The same removal as each row below, applied to all of them."
                        ) {
                            CRButton(title: "Remove All", kind: .destructive) {
                                pendingBulkRemoval = true
                            }
                        }
                        CRSettingsDivider()
                    }
                    ForEach(Array(orphanedJobs.enumerated()), id: \.element.callID) { index, job in
                        if index > 0 { CRSettingsDivider() }
                        CRSettingsRow(
                            title: callTitle(for: job),
                            detail: "Its audio and transcript are gone, so a retry cannot finish it"
                        ) {
                            CRButton(title: "Remove", kind: .destructive) {
                                pendingRemoval = job
                            }
                        }
                    }
                }
                // The same confirmation the single Remove uses, said once for the whole list, so
                // six identical rows do not need six trips through the same dialog.
                .confirmationDialog(
                    "Remove all \(orphanedJobs.count) unfinished calls?",
                    isPresented: $pendingBulkRemoval,
                    titleVisibility: .visible
                ) {
                    Button("Remove All", role: .destructive) {
                        let callIDs = orphanedJobs.map(\.callID)
                        Task { await model.removeUnfinishableCalls(callIDs) }
                    }
                    Button("Keep", role: .cancel) {}
                } message: {
                    Text(
                        "Their audio and transcripts are already gone, so removing deletes only "
                            + "their records."
                    )
                }
            }

            CRSettingsCard(
                title: "Speakers",
                footnote: "Repairs are safe to repeat. Both act on saved data and can be undone by naming speakers again."
            ) {
                // The review window is the place where names are set, so it is the primary
                // action here rather than a link buried in a settings row.
                CRSettingsRow(
                    title: "Review speakers",
                    detail: "Listen to each voice, then name it. The transcript and the voice profile update together."
                ) {
                    CRButton(title: "Review Speakers…", icon: "person.crop.circle.badge.questionmark", kind: .primary) {
                        WindowPresentation.present(open: { openWindow(id: "speaker-review") })
                    }
                }
                CRSettingsDivider()
                switch model.voiceIdentityState {
                case .available:
                    CRSettingsNote(
                        icon: "lock.shield",
                        text: "Encrypted voice-profile storage is available.",
                        tone: .ready
                    )
                case .checking:
                    CRSettingsNote(
                        icon: "lock.shield",
                        text: "Reading the voice-profile key…",
                        tone: .muted
                    )
                case .waitingForPermission:
                    // A keychain dialog does not expire, and the read waits behind it with nothing
                    // on screen to say so. Naming the wait is what lets the user look for it. An
                    // answer that was cancelled leaves the same state, because the key still needs
                    // permission, so the sentence says what is true of both: no answer yet.
                    CRSettingsRow(
                        title: "Waiting for keychain permission",
                        detail: "macOS asked whether Call Recorder may read its key and has no answer "
                            + "yet. Look for the dialog on screen; it can open behind another window. "
                            + "Answering once allows every later read.",
                        warning: true
                    ) {
                        CRButton(title: "Try Again") {
                            model.retryVoiceIdentity()
                        }
                    }
                case .unavailable:
                    CRSettingsRow(
                        title: "Login keychain unavailable",
                        detail: "The login keychain locks with the screen. Unlock the Mac; Call Recorder "
                            + "retries by itself, and macOS may ask once to allow access."
                            + keychainDetailSuffix,
                        warning: true
                    ) {
                        CRButton(title: "Retry") {
                            model.retryVoiceIdentity()
                        }
                    }
                }
                CRSettingsDivider()
                CRSettingsRow(
                    title: "Check every name against its voice",
                    detail: "A fragment that does not sound like the person returns to review once."
                ) {
                    CRButton(title: "Fix Speaker Names", icon: "person.wave.2") {
                        model.reconcileSharedSpeakers()
                    }
                }
                if let summary = model.lastSpeakerReconcile {
                    CRSettingsDivider()
                    CRSettingsNote(
                        icon: summary.failure == nil
                            ? "checkmark.circle"
                            : "exclamationmark.triangle",
                        text: reconcileSummaryText(summary),
                        tone: summary.failure == nil ? .muted : .failed
                    )
                }
                CRSettingsDivider()
                CRSettingsRow(
                    title: "Update saved transcript headers",
                    detail: "Rewrites the participant line when it no longer matches the participant list."
                ) {
                    CRButton(title: "Fix Transcript Names", icon: "doc.badge.gearshape") {
                        model.refreshStaleTranscriptHeaders()
                    }
                }
                CRSettingsDivider()
                CRSettingsRow(
                    title: "Write back missing transcript files",
                    detail: "A call can still name the working file that cleanup removed. The "
                        + "saved text is written out again under the call's own name."
                ) {
                    CRButton(title: "Restore Files", icon: "doc.badge.plus") {
                        model.restoreMissingTranscriptFiles()
                    }
                }
                CRSettingsDivider()
                // The one repair that removes a file, so it says so in the row rather than in a
                // footnote. A recording where nobody spoke comes back from the transcriber holding a
                // phrase it learned from video credits -- "Thank you for watching." -- attributed
                // to a real person on the call, and a file like that claims a meeting happened.
                CRSettingsRow(
                    title: "Remove files for calls where nobody spoke",
                    detail: model.noSpeechTranscriptCount == 0
                        ? "The transcriber answers silence with text it learned from video credits, which "
                            + "would read as a real transcript. There is nothing of that kind here."
                        : "\(model.noSpeechTranscriptCount) transcript "
                            + (model.noSpeechTranscriptCount == 1 ? "file holds" : "files hold")
                            + " nothing but words the transcriber wrote over silence. Each is copied into "
                            + "the Backups folder before it is removed.",
                    warning: model.noSpeechTranscriptCount > 0
                ) {
                    CRButton(title: "Remove", icon: "trash") {
                        Task { await model.confirmRemoveEmptyTranscripts() }
                    }
                    .disabled(model.noSpeechTranscriptCount == 0)
                }

            }

            if !model.recoverableArtifacts.isEmpty {
                CRSettingsCard(
                    title: "Recently Deleted",
                    footnote: "These are removed for good 24 hours after deletion."
                ) {
                    ForEach(Array(model.recoverableArtifacts.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { CRSettingsDivider() }
                        CRSettingsRow(
                            title: artifactTitle(item),
                            detail: artifactDetail(item)
                        ) {
                            HStack(spacing: CR.Space.inner) {
                                CRButton(title: "Restore") {
                                    Task { await model.restoreArtifact(item) }
                                }
                                CRButton(title: "Delete Now", kind: .destructive) {
                                    pendingPurge = item
                                }
                            }
                        }
                    }
                }
            }

            CRSettingsCard(
                title: "Maintenance",
                footnote: "A backup is a verified copy of the database, kept in the Backups folder."
            ) {
                CRSettingsRow(
                    title: "Run database check",
                    detail: "Looks for damaged pages and missing files."
                ) {
                    CRButton(title: "Run Check", icon: "checkmark.shield") {
                        Task { await model.runDatabaseCheck() }
                    }
                }
                CRSettingsDivider()
                CRSettingsRow(
                    title: "Create verified backup",
                    detail: "Writes a copy that can replace the database if it is ever damaged."
                ) {
                    CRButton(title: "Back Up", icon: "externaldrive.badge.plus") {
                        Task { await model.createDatabaseBackup() }
                    }
                }
                CRSettingsDivider()
                CRSettingsRow(title: "Backups folder") {
                    CRButton(title: "Open", icon: "folder") {
                        model.openBackupsFolder()
                    }
                }
            }

            CRSettingsCard(
                title: "Transcript text",
                footnote: "One pass does both jobs and runs by itself when the glossary or the rules change. Only the spoken text changes, the header keeps each term beside the alternatives it was misheard as, every original is copied into the Backups folder first, and the search index is rebuilt from the corrected text."
            ) {
                CRSettingsRow(
                    title: "Re-apply the glossary to saved transcripts",
                    detail: "Corrects names and terms in transcripts recorded before you added them. Safe to run again."
                ) {
                    CRButton(title: "Re-apply", icon: "text.badge.checkmark") {
                        Task { await model.reapplyGlossaryToSavedTranscripts() }
                    }
                    .disabled(model.glossary.isEmpty)
                }
                CRSettingsDivider()
                // The same pass does both jobs, and the second button previews it. A reader repeating
                // itself is the fault a user cannot see for themselves in a long transcript, so the
                // count is offered before the rewrite rather than after it.
                CRSettingsRow(
                    title: "Remove lines nobody said",
                    detail: "The transcriber repeats itself when it loses the audio, and it writes the "
                        + "glossary into the transcript as if it had been spoken. The same pass "
                        + "removes those, keeps the first copy of a repeated sentence, and runs "
                        + "by itself when the rules change."
                ) {
                    CRButton(title: "Preview", icon: "doc.text.magnifyingglass") {
                        Task { await model.previewTranscriptCleanup() }
                    }
                }
            }

            CRSettingsCard(
                title: "Diagnostics",
                footnote: model.recoveryMessage
            ) {
                CRSettingsRow(
                    title: "Export diagnostics",
                    detail: "Writes a report with the logs a person needs to find the cause."
                ) {
                    CRButton(title: "Export", icon: "square.and.arrow.up") {
                        Task { await model.exportDiagnostics() }
                    }
                }
                CRSettingsDivider()
                CRSettingsRow(
                    title: "Copy latest error",
                    detail: model.errorDetails == nil
                        ? "No error has been recorded in this session."
                        : "Puts the full traceback on the clipboard."
                ) {
                    CRButton(title: "Copy", icon: "doc.on.doc") {
                        model.copyErrorDetails()
                    }
                    .disabled(model.errorDetails == nil)
                }
            }
        }
        .task {
            await model.refreshMetadata()
            // The count is read by a row in this pane, and it is the one repair that removes a
            // file. Reading it here means the row says what is there now rather than what was
            // there at the last launch.
            await model.refreshNoSpeechTranscriptCount()
        }
        .confirmationDialog(
            "Permanently delete these working files?",
            isPresented: Binding(
                get: { pendingPurge != nil },
                set: { if !$0 { pendingPurge = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingPurge
        ) { item in
            Button("Delete Now", role: .destructive) {
                Task { await model.purgeArtifact(item) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(
                item.kind == .discardedRecording
                    ? "The accidental recording and its pending call entry cannot be recovered after this action."
                    : "The transcript and search index stay available. Audio and temporary files cannot be recovered after this action."
            )
        }
        .confirmationDialog(
            "Remove this unfinished call?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { job in
            Button("Remove", role: .destructive) {
                let callID = job.callID
                Task { await model.removeUnfinishableCall(callID) }
            }
            Button("Keep", role: .cancel) {}
        } message: { _ in
            Text("Its audio and transcript are already gone, so the row is all that is left.")
        }
    }

    /// The keychain message from the last failed read, when there is one. The row already says
    /// what to do, so this is kept short and reads as the reason rather than the instruction.
    private var keychainDetailSuffix: String {
        guard let message = model.voiceIdentityError else { return "" }
        return " Reported: " + message
    }
}


struct ModelSettingsView: View {
    @Bindable var model: AppModel
    @State private var pendingComponentDeletion: SupportingModel?

    /// A language a call is likely to be in, in the order the menu shows them.
    ///
    /// The list is the languages the people on these calls actually speak rather than every
    /// language the model knows: a menu of ninety-nine entries is a worse answer than one of
    /// twelve, and the one that matters most is first.
    private struct SpokenLanguage: Identifiable {
        let code: String
        let name: String
        var id: String { code }
    }

    private static let spokenLanguages: [SpokenLanguage] = [
        SpokenLanguage(code: "en", name: "English"),
        SpokenLanguage(code: "ru", name: "Russian"),
        SpokenLanguage(code: "uk", name: "Ukrainian"),
        SpokenLanguage(code: "de", name: "German"),
        SpokenLanguage(code: "es", name: "Spanish"),
        SpokenLanguage(code: "fr", name: "French"),
        SpokenLanguage(code: "it", name: "Italian"),
        SpokenLanguage(code: "pt", name: "Portuguese"),
        SpokenLanguage(code: "pl", name: "Polish"),
        SpokenLanguage(code: "nl", name: "Dutch"),
        SpokenLanguage(code: "tr", name: "Turkish"),
        SpokenLanguage(code: "cs", name: "Czech"),
    ]

    var body: some View {
        SettingsPane(
            title: "Models",
            subtitle: "The model that reads a call, the runtime it runs in, and the models search reads."
        ) {
            // Reading is one decision with two halves: the weights, and the environment that runs
            // them. They are one card, because a Mac missing either cannot transcribe, and the
            // reader should see both halves of that answer together.
            CRSettingsCard(
                title: "Speech",
                info: "Qwen3-ASR reads a recording into words in Russian and English, including a "
                    + "call that mixes them, and names the language it found. The weights are "
                    + "published for MLX, a Python library, so the app keeps a Python environment "
                    + "beside its models and runs the model in it. Both halves are checked against "
                    + "the publisher's hashes before anything uses them."
            ) {
                if let transcription = model.transcriptionModel {
                    componentRow(transcription)
                    componentNotes(transcription)
                    CRSettingsDivider()
                }
                speechRuntimeRow
                CRSettingsDivider()
                CRSettingsRow(
                    title: "Spoken language",
                    info: "The model decides the language of each recording unless it is told one. "
                        + "Naming the language holds it to that language's script when two readings "
                        + "are close, so a call that is in one language is read better when the "
                        + "language is named here."
                ) {
                    Picker("", selection: $model.settings.transcriptionLanguage) {
                        Text("Detect automatically").tag("auto")
                        ForEach(Self.spokenLanguages) { language in
                            Text(language.name).tag(language.code)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220, alignment: .trailing)
                }
                CRSettingsDivider()
                CRSettingsRow(
                    title: "Print the time of each turn",
                    info: "Every turn in a saved transcript opens with its time, which is what a "
                        + "reader needs to jump into the recording. Off by default: without it the "
                        + "file reads as spoken text."
                ) {
                    Toggle("", isOn: $model.settings.transcriptTimestamps)
                        .labelsHidden()
                }
            }

            CRSettingsCard(
                title: "Components",
                info: "The models the app keeps beside the transcription model: the one that turns "
                    + "text into vectors for search, and the runtime the indexer and the MCP server "
                    + "run on. A download is accepted only when its published hash matches the "
                    + "publisher's."
            ) {
                if let component = embeddingComponent {
                    componentRow(component)
                    componentNotes(component)
                }
                CRSettingsDivider()
                indexerRuntimeRow
            }
        }
        .task {
            // Both are read from this Mac rather than from the network: the hashes of a model that
            // was installed before Call Recorder recorded them, and whether the environment can
            // import the two modules the transcription script needs.
            await model.supportingManager.bootstrapManifest()
            model.speechRuntime.refresh()
        }
        .confirmationDialog(
            "Delete this model?",
            isPresented: Binding(
                get: { pendingComponentDeletion != nil },
                set: { if !$0 { pendingComponentDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingComponentDeletion
        ) { component in
            Button("Delete \(component.displayName)", role: .destructive) {
                try? model.supportingManager.delete(component)
                pendingComponentDeletion = nil
            }
        } message: { component in
            Text(
                "It is downloaded again the next time something needs it, and it is about "
                    + ModelSizeLabel.file(bytes: component.totalBytes) + ". "
                    + component.displayName + " works offline until then."
            )
        }
    }

    // MARK: - The speech runtime

    /// The Python environment the model runs in.
    ///
    /// It earns a row for the same reason the indexer runtime does: it is a few hundred megabytes
    /// the app fetches rather than carries, and a Mac that cannot transcribe is owed the reason in
    /// a sentence rather than behind an information glyph.
    @ViewBuilder
    private var speechRuntimeRow: some View {
        let runtime = model.speechRuntime
        CRSettingsRow(
            title: "Speech runtime",
            detail: speechRuntimeDetail,
            info: "The transcription model is published for MLX, which is a Python library. The app "
                + "installs mlx and mlx-audio into a Python environment beside its models, and runs "
                + "the model in it. Speaker analysis runs in the same environment.",
            warning: speechRuntimeNeedsAttention
        ) {
            switch runtime.state {
            case .ready:
                CRStatusChip(tone: .ready, text: "Ready")
            case .noPython:
                if runtime.canBuildEnvironment {
                    CRButton(title: "Set Up", kind: .primary) { runtime.install() }
                } else {
                    CRStatusChip(tone: .failed, text: "No Python")
                }
            case .missingModules:
                CRButton(title: "Install", kind: .primary) { runtime.install() }
            case .otherVersions:
                CRStatusChip(tone: .waiting, text: "Other versions")
                CRButton(title: "Reinstall") { runtime.install() }
            case .installing:
                HStack(spacing: CR.Space.inner) {
                    ProgressView().controlSize(.small)
                    Text(runtime.progress?.formatted(
                        .percent.precision(.fractionLength(0))
                    ) ?? "Working")
                        .font(CR.Font.caption)
                        .monospacedDigit()
                        .foregroundStyle(CR.Ink.readable)
                }
            case .failed:
                CRStatusChip(tone: .failed, text: "Failed")
                CRButton(title: "Retry") { runtime.install() }
            }
        }
    }

    private var speechRuntimeDetail: String? {
        let runtime = model.speechRuntime
        switch runtime.state {
        case .ready:
            return nil
        case .noPython:
            return model.speechRuntime.canBuildEnvironment
                ? "The app reads calls in a Python environment of its own, beside its models, and "
                    + "it is not here yet. Setting it up uses the Python on this Mac and fetches "
                    + "the two packages the model runs on, about a gigabyte."
                : "The Python environment chosen in Speaker setup is not there. Choose another in "
                    + "Review Speakers, Speaker setup."
        case .missingModules:
            return "Python is here; the two modules the model runs on are not."
        case .otherVersions(let installed):
            let found = installed.sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }
                .joined(separator: ", ")
            return "\(found) is installed, and this build reads calls with "
                + SpeechRuntimeRequirement.packages.joined(separator: " and ")
                + ". Reinstall puts the tested versions back."
        case .installing:
            return runtime.status
        case .failed(let message):
            return message
        }
    }

    private var speechRuntimeNeedsAttention: Bool {
        switch model.speechRuntime.state {
        case .failed, .noPython, .otherVersions:
            return true
        case .ready, .installing, .missingModules:
            return false
        }
    }

    // MARK: - Components

    private var embeddingComponent: SupportingModel? {
        model.supportingManager.models.first { $0.id == SupportingModel.embeddingGemmaID }
    }

    /// The JavaScript runtime the indexer and the MCP server both run on.
    ///
    /// It is not a model anyone chooses between. It earns a row because it is the one thing the
    /// app fetches that a person can watch arrive, and because a Mac with no network is owed the
    /// reason search is waiting. The failure is drawn as a sentence in the row rather than behind
    /// the information glyph: a fault that only appears on hover is a fault nobody reads.
    @ViewBuilder
    private var indexerRuntimeRow: some View {
        let installer = model.indexerRuntime
        CRSettingsRow(
            title: "Transcript indexer runtime",
            detail: indexerRuntimeDetail,
            info: "Transcript search and the MCP server both run on a JavaScript runtime of about "
                + "36 MB. It is fetched once instead of travelling inside the app, which is what "
                + "keeps the download of the app small. The archive is kept beside the unpacked "
                + "copy, so a Mac that has it once can rebuild the runtime without the network.",
            warning: installer.state.failure != nil
        ) {
            switch installer.state {
            case .ready:
                CRStatusChip(tone: .ready, text: "Ready")
            case .missing:
                CRButton(title: "Download", kind: .primary) { installer.install() }
            case .downloading:
                downloadRow(progress: installer.progress) { installer.cancel() }
            case .failed:
                CRStatusChip(tone: .failed, text: "Failed")
                CRButton(title: "Retry") { installer.install() }
            }
        }
    }

    private var indexerRuntimeDetail: String? {
        switch model.indexerRuntime.state {
        case .ready:
            return nil
        case .missing:
            return "Search waits for this. It is fetched once."
        case .downloading:
            return nil
        case .failed(let message):
            return message
        }
    }

    @ViewBuilder
    private func componentRow(_ component: SupportingModel) -> some View {
        CRSettingsRow(
            title: component.displayName,
            detail: componentRowDetail(component),
            info: componentSummary(component),
            warning: model.supportingManager.failure(for: component) != nil
        ) {
            switch model.supportingManager.state(for: component) {
            case .notInstalled:
                CRButton(
                    title: "Download " + ModelSizeLabel.file(bytes: component.totalBytes),
                    kind: .primary
                ) {
                    model.supportingManager.download(component)
                }
            case .downloading:
                downloadRow(progress: model.supportingManager.progress(for: component)) {
                    model.supportingManager.cancel(component)
                }
            case .installed:
                HStack(spacing: CR.Space.inner) {
                    CRStatusChip(tone: .ready, text: "Ready")
                    if model.supportingManager.canRevert(component) {
                        CRButton(title: "Go Back") {
                            try? model.supportingManager.revert(component)
                        }
                        .help("Use the revision the last update replaced")
                    }
                    CRButton(title: "Delete", kind: .destructive) {
                        pendingComponentDeletion = component
                    }
                }
            case .failed(let message):
                CRStatusChip(tone: .failed, text: "Failed").help(message)
                CRButton(title: "Retry") { model.supportingManager.download(component) }
            }
        }
    }

    /// The one line a component row says out loud, and only when something needs doing.
    ///
    /// The model's own version leads it. Which copy of a model is on disk — a size, and the
    /// quantisation that decides how much memory it needs — was only ever written in the catalog,
    /// so the row could not be read to tell one download from another.
    private func componentRowDetail(_ component: SupportingModel) -> String? {
        switch model.supportingManager.state(for: component) {
        case .failed:
            return component.versionLabel + ". The download did not finish."
        case .notInstalled:
            let waiting = component.id == SupportingModel.qwen3ASRID
                ? "Calls wait for this."
                : "Search finds passages by keyword until this is downloaded."
            return component.versionLabel + ". " + waiting
        case .installed, .downloading:
            return component.versionLabel
        }
    }

    /// What the row would otherwise spend a paragraph on.
    private func componentSummary(_ component: SupportingModel) -> String {
        let manager = model.supportingManager
        switch manager.state(for: component) {
        case .installed:
            let size = ModelSizeLabel.file(bytes: manager.installedBytes(for: component))
            guard let record = manager.record(for: component) else {
                return component.detail + " " + size + " on disk."
            }
            return "Verified at revision " + String(record.revision.prefix(7)) + ", " + size
                + " on disk. " + component.detail
        case .downloading:
            return "Downloading " + ModelSizeLabel.file(bytes: component.totalBytes)
                + ". It is checked against the publisher's hashes before anything uses it."
        case .notInstalled:
            return component.detail
        case .failed:
            return "The download did not finish. Retry starts it again."
        }
    }

    /// What the last check found, when it found something to say.
    @ViewBuilder
    private func componentNotes(_ component: SupportingModel) -> some View {
        let manager = model.supportingManager
        if case .updateAvailable(let update)? = manager.decision(for: component) {
            CRSettingsDivider()
                CRSettingsRow(
                    title: "A newer copy is published",
                    detail: "It is " + ModelSizeLabel.file(bytes: update.totalBytes)
                        + ". Downloading it keeps the present copy so the change can be undone.",
                    warning: model.isModelInUse
            ) {
                CRButton(title: "Update") { manager.applyUpdate(component) }
                    .disabled(model.isModelInUse)
            }
        }
        if case .cannotVerify(let reason)? = manager.decision(for: component) {
            CRSettingsDivider()
            CRSettingsNote(icon: "questionmark.circle", text: reason)
        }
        if let failure = manager.failure(for: component) {
            CRSettingsDivider()
            CRSettingsNote(icon: "exclamationmark.triangle", text: failure, tone: .failed)
        }
        if manager.reclaimableBytes(for: component) > 0 {
            CRSettingsDivider()
            CRSettingsRow(
                title: "A duplicate copy is taking up space",
                detail: "An earlier build cached a second copy of this model that nothing reads. "
                    + "Moving it to the Trash frees "
                    + ModelSizeLabel.file(bytes: manager.reclaimableBytes(for: component)) + ".",
                warning: true
            ) {
                CRButton(title: "Move to Trash") { manager.reclaimDuplicates(of: component) }
            }
        }
    }

    /// A download in flight: a ring that fills, the share it has reached, and the way to stop it.
    ///
    /// The share is a number beside the ring rather than a word under the row. Its column is
    /// fixed, so the Cancel button next to it does not step sideways as the digits change, and
    /// the ring is the part that moves.
    private func downloadRow(progress: Double?, cancel: @escaping () -> Void) -> some View {
        HStack(spacing: CR.Space.inner) {
            CRProgressRing(progress: progress)
            if let progress {
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(CR.Font.caption)
                    .monospacedDigit()
                    .foregroundStyle(CR.Ink.readable)
                    .frame(width: 30, alignment: .trailing)
            }
            CRButton(title: "Cancel", action: cancel)
        }
    }
}

struct PeopleSettingsView: View {
    @Bindable var model: AppModel
    @State private var search = ""
    @State private var editingParticipant: Participant?
    @State private var creatingParticipant = false

    private var filteredParticipants: [Participant] {
        guard !search.isEmpty else { return model.participants }
        return model.participants.filter { participant in
            participant.name.localizedCaseInsensitiveContains(search)
                || (participant.company?.localizedCaseInsensitiveContains(search) ?? false)
                || (participant.email?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    private var withVoiceProfile: Int {
        model.participants.filter {
            (model.voiceProfileSummary(for: $0.id)?.confirmedSampleCount ?? 0) > 0
        }.count
    }

    var body: some View {
        SettingsPane(
            title: "Participants",
            subtitle: "Everyone you meet with. Names here are what transcripts use."
        ) {
            CRSettingsCard(
                title: "Your microphone",
                footnote: "Recordings made with the selected microphone are attributed to this person."
            ) {
                CRSettingsRow(title: "Assigned to the selected microphone") {
                    Picker("", selection: $model.settings.localParticipantID) {
                        Text("Not set").tag(nil as ParticipantID?)
                        ForEach(model.participants, id: \.id) { participant in
                            Text(participant.name).tag(Optional(participant.id))
                        }
                    }
                    .labelsHidden()
                    // Trailing, for the same reason as the model menu: the control SwiftUI draws
                    // is narrower than its cap, so centring it in the cap leaves it off the
                    // gutter the neighbouring rows end on.
                    .frame(maxWidth: 240, alignment: .trailing)
                    .disabled(model.participants.isEmpty)
                }
            }

            CRSettingsCard(
                title: "People",
                footnote: "\(filteredParticipants.count) of \(model.participants.count) shown · "
                    + "\(withVoiceProfile) with a learned voice."
            ) {
                HStack(spacing: CR.Space.inner) {
                    CRSearchField(
                        placeholder: "Search by name, company, or email",
                        text: $search
                    )
                    CRButton(title: "Add Person", icon: "plus", kind: .primary) {
                        creatingParticipant = true
                    }
                }
                .padding(.horizontal, CR.Space.section)
                .padding(.vertical, CR.Space.item)

                if model.participants.isEmpty {
                    CRSettingsDivider()
                    CREmptyState(
                        icon: "person.2",
                        title: "No people yet",
                        message: "Add people once and reuse them after future calls."
                    )
                } else if filteredParticipants.isEmpty {
                    CRSettingsDivider()
                    CREmptyState(
                        icon: "magnifyingglass",
                        title: "No matches",
                        message: "Try another name, company, or email."
                    )
                } else {
                    ForEach(filteredParticipants) { participant in
                        CRSettingsDivider()
                        Button {
                            editingParticipant = participant
                        } label: {
                            HStack(spacing: CR.Space.inner) {
                                ParticipantLabel(participant: participant)
                                Spacer(minLength: CR.Space.inner)
                                Image(systemName: "pencil")
                                    // The pencil is the only sign that the row opens an editor.
                                    .foregroundStyle(CR.Ink.readable)
                            }
                            .padding(.horizontal, CR.Space.section)
                            .padding(.vertical, CR.Space.item)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Edit \(participant.name)")
                    }
                }
            }
        }
        .sheet(item: $editingParticipant) { participant in
            ParticipantEditor(model: model, participant: participant)
        }
        .sheet(isPresented: $creatingParticipant) {
            ParticipantEditor(model: model, participant: nil)
        }
    }

}

struct VocabularySettingsView: View {
    @Bindable var model: AppModel
    @State private var search = ""
    @State private var editingTerm: GlossaryTerm?
    @State private var pendingDelete: GlossaryTerm?
    /// Only the terms inside the word limit reach the model. Showing which ones are in force answers
    /// the question the list could not: is the term I added actually being used?
    @State private var showingOnlyPromptTerms = false

    private var filteredTerms: [GlossaryTerm] {
        let ranked = GlossaryUsage.ranked(model.glossary, usageCounts: model.glossaryUsage)
        let scoped = showingOnlyPromptTerms
            ? ranked.filter { promptTermIDs.contains($0.id) }
            : ranked
        guard !search.isEmpty else { return scoped }
        return scoped.filter {
            $0.preferred.localizedCaseInsensitiveContains(search)
                || $0.aliases.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    /// The terms this build would send, previewed against the next likely call.
    ///
    /// A recording sends the names of the people who were on THAT call, so no list can predict
    /// the exact set in advance. Previewing every saved person instead would spend the whole
    /// prompt on names and report almost nothing as in force, which is what made this indicator
    /// read as "none of my terms are used". The owner of the Mac is on every one of their own
    /// calls, so their name is the one part that is always true.
    private var promptTermIDs: Set<GlossaryTermID> {
        let guaranteed = model.participants.filter {
            $0.id == model.settings.localParticipantID
        }
        return PromptBuilder.promptTermIDs(
            participants: guaranteed,
            glossary: model.glossary,
            usageCounts: model.glossaryUsage
        )
    }

    /// Shows how much a term has earned its place. "Used in recent calls" is written without a
    /// number because the count is a count of transcripts, not of spoken mentions.
    private func usageLabel(for term: GlossaryTerm) -> String {
        let count = model.glossaryUsage[term.preferred.lowercased()] ?? 0
        switch count {
        case 0: return "Not used yet"
        case 1: return "Used in 1 recent call"
        default: return "Used in \(count) recent calls"
        }
    }

    var body: some View {
        SettingsPane(
            title: "Vocabulary",
            subtitle: "Names and terms the transcriber should spell your way."
        ) {
            CRSettingsCard(title: "How this reaches the transcriber") {
                VStack(alignment: .leading, spacing: CR.Space.inner) {
                    Text(
                        "Call Recorder sends your participants' names first, then the terms you use "
                            + "most, up to 60 words for a recording. Terms past that stay saved and "
                            + "are still matched when a transcript is corrected, but they are not "
                            + "sent to the model."
                    )
                    .font(CR.Font.caption)
                    .foregroundStyle(CR.Ink.readable)
                    .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: CR.Space.inner) {
                        CRStatusChip(
                            tone: promptTermIDs.isEmpty ? .muted : .ready,
                            text: "\(promptTermIDs.count) of \(model.glossary.count) sent with the audio"
                        )
                        Toggle("Show only these terms", isOn: $showingOnlyPromptTerms)
                            .toggleStyle(.checkbox)
                            .font(CR.Font.caption)
                            .disabled(promptTermIDs.isEmpty)
                        Spacer(minLength: 0)
                    }

                    // The count is a preview, and saying so is the difference between a useful
                    // number and a wrong one: a busy call carries more names and therefore fewer
                    // terms.
                    Text(
                        "Counted with your own name first. A call with more people carries more "
                            + "names, so fewer terms fit. Ranked by how often each term already "
                            + "appears in your transcripts."
                    )
                    .font(CR.Font.caption)
                    .foregroundStyle(CR.Ink.readable)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, CR.Space.section)
                .padding(.vertical, CR.Space.item)
            }

            CRSettingsCard(
                title: "Terms",
                footnote: "Most used first. Terms without a checkmark are saved but not sent."
            ) {
                HStack(spacing: CR.Space.inner) {
                    CRSearchField(placeholder: "Search terms or alternatives", text: $search)
                    CRButton(title: "Add Term", icon: "plus", kind: .primary) {
                        editingTerm = GlossaryTerm(
                            id: GlossaryTermID(rawValue: UUID()),
                            preferred: "",
                            aliases: []
                        )
                    }
                }
                .padding(.horizontal, CR.Space.section)
                .padding(.vertical, CR.Space.item)

                if model.glossary.isEmpty {
                    CRSettingsDivider()
                    CREmptyState(
                        icon: "text.book.closed",
                        title: "No saved terms",
                        message: "Add company names, people names, and product terms so they transcribe correctly."
                    )
                } else if filteredTerms.isEmpty {
                    CRSettingsDivider()
                    CREmptyState(
                        icon: "magnifyingglass",
                        title: "No matches",
                        message: "Try another term or alternative spelling."
                    )
                } else {
                    ForEach(filteredTerms) { term in
                        CRSettingsDivider()
                        HStack(spacing: CR.Space.inner) {
                            VStack(alignment: .leading, spacing: CR.Space.hairline) {
                                Text(term.preferred)
                                if !term.aliases.isEmpty {
                                    Text(term.aliases.joined(separator: " · "))
                                        .font(CR.Font.caption)
                                        // The alternatives are the reason the term works. Reading
                                        // them is how someone checks a misheard spelling is here.
                                        .foregroundStyle(CR.Ink.readable)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: CR.Space.inner)
                            if promptTermIDs.contains(term.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(CR.Tone.ready.ink)
                                    .help("This term is sent to the transcriber.")
                                    .accessibilityLabel("\(term.preferred) is sent to the transcriber")
                            } else {
                                Image(systemName: "clock")
                                    .font(.system(size: 11))
                                    // The difference between a term that reaches the model and one
                                    // that does not is this glyph, and nothing else on the row.
                                    .foregroundStyle(CR.Ink.readable)
                                    .help(
                                        "Saved, but past the word limit. It will be applied when a "
                                            + "transcript is corrected, not sent to the model."
                                    )
                                    .accessibilityLabel("\(term.preferred) is not sent to the transcriber")
                            }
                            Text(usageLabel(for: term))
                                .font(CR.Font.caption)
                                .foregroundStyle(CR.Ink.readable)
                            CRIconButton(
                                icon: "pencil",
                                label: "Edit \(term.preferred)",
                                alwaysVisible: true,
                                trailingAligned: true
                            ) {
                                editingTerm = term
                            }
                            CRIconButton(
                                icon: "trash",
                                label: "Delete \(term.preferred)",
                                tone: .failed,
                                alwaysVisible: true,
                                trailingAligned: true
                            ) {
                                pendingDelete = term
                            }
                        }
                        .padding(.horizontal, CR.Space.section)
                        .padding(.vertical, CR.Space.item)
                    }
                }
            }
        }
        .task { await model.refreshMetadata() }
        .sheet(item: $editingTerm) { term in
            GlossaryTermEditor(model: model, term: term)
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.preferred ?? "term")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Term", role: .destructive) {
                if let term = pendingDelete {
                    Task { await model.deleteGlossaryTerm(term) }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Existing transcripts keep their wording. Future recordings stop using this term.")
        }
    }
}

struct GlossaryTermEditor: View {
    @Bindable var model: AppModel
    let term: GlossaryTerm
    @Environment(\.dismiss) private var dismiss
    @State private var preferred: String
    @State private var aliases: String

    init(model: AppModel, term: GlossaryTerm) {
        self.model = model
        self.term = term
        _preferred = State(initialValue: term.preferred)
        _aliases = State(initialValue: term.aliases.joined(separator: ", "))
    }

    private var isNew: Bool { term.preferred.isEmpty }

    /// What the sheet says the edit will do.
    ///
    /// The line used to promise that saved transcripts keep their wording. That stopped being true
    /// when the glossary repair was added: an alternative now corrects the files already written,
    /// on the next start or from the button in Recovery. A sheet that tells the reader the opposite
    /// of what the app does is worse than one that says nothing, because it is where the change is
    /// made and the reader has no reason to doubt it.
    ///
    /// Nonisolated so a test can read the words without a window.
    nonisolated static func subtitle(isNew: Bool) -> String {
        isNew
            ? "Spell the term the way it should appear. Alternatives catch the ways the transcriber mishears it."
            : "Alternatives also correct saved transcripts, at the next start or from Re-apply in Recovery."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: CR.Space.snug) {
                Text(isNew ? "Add Term" : "Edit Term")
                    .font(.system(size: 17, weight: .semibold))
                Text(GlossaryTermEditor.subtitle(isNew: isNew))
                .font(CR.Font.callout)
                .foregroundStyle(CR.Ink.readable)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(CR.Space.screen)

            CRDivider()

            CRSettingsCard(title: "Term") {
                CRSettingsField(title: "Preferred spelling") {
                    CRTextField(placeholder: "Acme Inc.", text: $preferred)
                }
                CRSettingsDivider()
                CRSettingsField(title: "Common alternatives, comma separated") {
                    CRTextField(
                        placeholder: "Acme, Acme Inc., Ac-me",
                        text: $aliases
                    )
                }
            }
            .padding(CR.Space.screen)

            Spacer(minLength: 0)

            CRDivider()

            HStack(spacing: CR.Space.item) {
                Spacer(minLength: 0)
                CRButton(title: "Cancel", kind: .secondary) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                CRButton(
                    title: isNew ? "Add Term" : "Save",
                    icon: "checkmark",
                    kind: .primary,
                    action: save
                )
                .disabled(preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(CR.Space.screen)
        }
        // The same width as the person editor, so the two sheets that edit a saved list are the
        // same object with different contents.
        .frame(width: 440, height: 400)
    }

    private func save() {
        let name = preferred
        let values = aliases.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        dismiss()
        Task { await model.addGlossaryTerm(preferred: name, aliases: values) }
    }
}
