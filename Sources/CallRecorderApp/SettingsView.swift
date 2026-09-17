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
                    // on screen to say so. Naming the wait is what lets the user look for it.
                    CRSettingsRow(
                        title: "Waiting for keychain permission",
                        detail: "macOS is waiting for an answer to a dialog asking whether Call Recorder "
                            + "may read its key. Look for it on screen; it can open behind another "
                            + "window. Answering once allows every later read.",
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
                    title: "Keep a name when the fragments are one voice",
                    detail: "Returns the rest of the fragments to review."
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
                // footnote. A recording where nobody spoke comes back from Whisper holding a
                // phrase it learned from video credits -- "Thank you for watching." -- attributed
                // to a real person on the call, and a file like that claims a meeting happened.
                CRSettingsRow(
                    title: "Remove files for calls where nobody spoke",
                    detail: model.noSpeechTranscriptCount == 0
                        ? "Whisper answers silence with text it learned from video credits, which "
                            + "would read as a real transcript. There is nothing of that kind here."
                        : "\(model.noSpeechTranscriptCount) transcript "
                            + (model.noSpeechTranscriptCount == 1 ? "file holds" : "files hold")
                            + " nothing but words Whisper wrote over silence. Each is copied into "
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
                // The same pass does both jobs, and the second button previews it. Whisper repeating
                // itself is the fault a user cannot see for themselves in a long transcript, so the
                // count is offered before the rewrite rather than after it.
                CRSettingsRow(
                    title: "Remove lines nobody said",
                    detail: "Whisper repeats itself when it loses the audio, and it writes the "
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
    @State private var pendingDeletion: WhisperModel?

    var body: some View {
        SettingsPane(
            title: "Models",
            subtitle: "The transcription model, the silence filter, and the search embeddings."
        ) {
            CRSettingsCard(
                title: "Transcription model",
                footnote: "A new recording waits for the selected model. The download happens once."
            ) {
                CRSettingsRow(
                    title: "Model",
                    detail: "Larger models transcribe more accurately and take longer to run."
                ) {
                    Picker("", selection: $model.settings.selectedWhisperModelID) {
                        // Two groups, because the choice between them is the one a reader has to
                        // make first: the English-only files cannot transcribe anything else.
                        Section("Multilingual") {
                            ForEach(multilingualModels) { whisperModel in
                                Text(whisperModel.displayName).tag(whisperModel.id)
                            }
                        }
                        Section("English only") {
                            ForEach(englishOnlyModels) { whisperModel in
                                Text(whisperModel.displayName).tag(whisperModel.id)
                            }
                        }
                    }
                    .labelsHidden()
                    // A capped width keeps a long model name from pushing the label aside, but the
                    // menu that SwiftUI draws inside it is only as wide as its own title. Centring
                    // that in the cap left it floating seventy points short of the gutter that the
                    // switches and pop-up menus of every other row end on. Trailing alignment puts
                    // it back on the row's edge.
                    .frame(maxWidth: 220, alignment: .trailing)
                }
                if let selected = selectedModel {
                    CRSettingsDivider()
                    selectedModelStatus(selected)
                }
            }

            guidanceCard

            CRSettingsCard(
                title: "Whisper models",
                footnote: "Downloaded once and kept in Application Support."
            ) {
                ForEach(Array(model.modelManager.models.enumerated()), id: \.element.id) { index, whisperModel in
                    if index > 0 { CRSettingsDivider() }
                    modelRow(whisperModel)
                }
                if model.modelManager.installedBytes > 0 {
                    CRSettingsDivider()
                    CRSettingsRow(
                        title: "On disk",
                        detail: "Total size of the models installed on this Mac."
                    ) {
                        Text(ModelSizeLabel.file(bytes: model.modelManager.installedBytes))
                        .font(CR.Font.body)
                        .foregroundStyle(CR.Ink.readable)
                        .monospacedDigit()
                    }
                }
            }

            updateSection

            // Both of these used to be their own one-row section with a different treatment.
            // They are the same kind of thing as a Whisper model — a file the app needs — so they
            // are listed the same way, with a status that says whether it is ready.
            CRSettingsCard(title: "Other components") {
                CRSettingsRow(
                    title: "Silero VAD v6.2.0",
                    detail: "Filters silence on long calls so transcription restarts cleanly."
                ) {
                    CRStatusChip(tone: .ready, text: "Bundled")
                }
                CRSettingsDivider()
                CRSettingsRow(
                    title: "EmbeddingGemma 300M",
                    detail: model.embeddingModelIsInstalled
                        ? "Powers meaning-based search across every transcript."
                        : "Downloads on first use. Keyword search works without it."
                ) {
                    if model.embeddingModelIsInstalled {
                        CRStatusChip(tone: .ready, text: "Downloaded")
                    } else {
                        CRStatusChip(tone: .muted, text: "Not downloaded")
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete this model?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { whisperModel in
            Button("Delete \(whisperModel.displayName)", role: .destructive) {
                try? model.modelManager.delete(whisperModel)
                pendingDeletion = nil
            }
        }
    }

    /// The model the picker points at, when it names one this build knows about.
    private var selectedModel: WhisperModel? {
        model.modelManager.models.first { $0.id == model.settings.selectedWhisperModelID }
    }

    @ViewBuilder
    private func selectedModelStatus(_ whisperModel: WhisperModel) -> some View {
        // Said before the download and before the next recording, because a model that does not
        // fit shows up as a transcription that crawls or fails, not as a message of its own.
        if !whisperModel.fits(inMemoryOf: physicalMemoryBytes) {
            CRSettingsNote(
                icon: "exclamationmark.triangle",
                text: "\(whisperModel.displayName) asks for about \(ModelSizeLabel.memory(bytes: whisperModel.recommendedMemoryBytes)) of memory with the app's headroom, and this Mac has \(ModelSizeLabel.memory(bytes: physicalMemoryBytes)). Transcription can slow down sharply or fail; a smaller model is the safe choice.",
                tone: .waiting
            )
            CRSettingsDivider()
        }
        switch model.modelManager.state(for: whisperModel) {
        case .installed:
            CRSettingsNote(
                icon: "checkmark.circle",
                text: "\(whisperModel.displayName) is ready for new recordings.",
                tone: .ready
            )
        case .downloading:
            CRSettingsRow(
                title: "Downloading",
                detail: "New recordings wait until \(whisperModel.displayName) is on disk."
            ) {
                CRButton(title: "Cancel") { model.modelManager.cancel(whisperModel) }
            }
        case .notInstalled:
            CRSettingsRow(
                title: "Selected model is not downloaded",
                detail: "New recordings cannot be transcribed until it is downloaded.",
                warning: true
            ) {
                CRButton(title: "Download Now", kind: .primary) {
                    model.modelManager.download(whisperModel)
                }
            }
        case let .failed(message):
            CRSettingsRow(
                title: "Selected model download failed",
                detail: message,
                warning: true
            ) {
                CRButton(title: "Retry") { model.modelManager.download(whisperModel) }
            }
        }
    }

    /// Automatic model updates, and what the last check found.
    ///
    /// The caption states the two things a person would otherwise have to guess: that a download
    /// is only accepted when its published hash matches, and that the previous copy is kept.
    @ViewBuilder
    private var updateSection: some View {
        CRSettingsCard(
            title: "Updates",
            footnote: "A download is installed only when its published hash matches, the swap is instant, and the previous copy is kept."
        ) {
            CRSettingsRow(
                title: "Update models automatically",
                detail: "Call Recorder checks the model host after launch and every few hours. Nothing changes while a call is recorded or transcribed."
            ) {
                Toggle("", isOn: $model.settings.automaticModelUpdatesEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            CRSettingsDivider()
            CRSettingsRow(
                // The row is named for what it does, like the switch row above it. It used to be
                // titled with its own status, so one card held a feature on its first row and a
                // read-out on its second, and the two did not read as the same kind of thing.
                title: "Check for updates",
                detail: updateDetail,
                warning: model.isModelInUse
            ) {
                HStack(spacing: CR.Space.inner) {
                    if model.modelManager.checking {
                        ProgressView().controlSize(.small)
                    }
                    CRButton(title: "Check Now") {
                        Task { await model.modelManager.performAutomaticPass() }
                    }
                    .disabled(model.modelManager.checking)
                }
            }
            ForEach(pendingUpdates) { whisperModel in
                CRSettingsDivider()
                CRSettingsRow(
                    title: "\(whisperModel.displayName) has a newer copy",
                    detail: "The model host publishes a different file than the one installed.",
                    warning: model.isModelInUse
                ) {
                    CRButton(title: "Update") {
                        model.modelManager.applyUpdate(whisperModel)
                    }
                    .disabled(model.isModelInUse)
                }
            }
            ForEach(unverifiableModels) { whisperModel in
                CRSettingsDivider()
                CRSettingsNote(
                    icon: "questionmark.circle",
                    text: "\(whisperModel.displayName): \(unverifiableReason(whisperModel))"
                )
            }
            if let failure = model.modelManager.failingModels.values.first {
                CRSettingsDivider()
                CRSettingsNote(icon: "exclamationmark.triangle", text: failure, tone: .failed)
            }
        }
    }

    /// What the check row says under its title: the last result, then the reason updates are
    /// paused when a call is running.
    private var updateDetail: String {
        var lines: [String] = []
        lines.append(checkSummary)
        if let message = model.modelManager.statusMessage { lines.append(message) }
        if model.isModelInUse { lines.append("A call is in progress, so updates are paused.") }
        if lines.isEmpty { lines.append("Checks run in the background and never interrupt a call.") }
        return lines.joined(separator: " ")
    }


    private var checkSummary: String {
        guard let last = model.modelManager.lastCheckedAt else {
            return "Not checked yet."
        }
        return "Last checked \(last.formatted(date: .abbreviated, time: .shortened))."
    }

    private var pendingUpdates: [WhisperModel] {
        model.modelManager.models.filter { model.modelManager.decision(for: $0)?.isUpdateAvailable == true }
    }

    private var unverifiableModels: [WhisperModel] {
        model.modelManager.models.filter {
            model.modelManager.state(for: $0).isInstalled
                && model.modelManager.decision(for: $0)?.hasVerdict == false
        }
    }

    private func unverifiableReason(_ whisperModel: WhisperModel) -> String {
        guard case .cannotVerify(let reason) = model.modelManager.decision(for: whisperModel) else {
            return ""
        }
        return reason
    }

    @ViewBuilder
    private func modelRow(_ whisperModel: WhisperModel) -> some View {
        CRSettingsRow(
            title: whisperModel.displayName,
            detail: specLine(whisperModel),
            warning: !whisperModel.fits(inMemoryOf: physicalMemoryBytes)
        ) {
            switch model.modelManager.state(for: whisperModel) {
            case .notInstalled:
                CRButton(title: "Download", kind: .primary) {
                    model.modelManager.download(whisperModel)
                }
            case .downloading:
                HStack(spacing: CR.Space.inner) {
                    ProgressView().controlSize(.small)
                    CRButton(title: "Cancel") { model.modelManager.cancel(whisperModel) }
                }
            case .installed:
                HStack(spacing: CR.Space.inner) {
                    CRStatusChip(tone: .ready, text: "Installed")
                    // Only offered once an update has replaced something, because that is the
                    // only time an earlier copy exists to go back to.
                    if model.modelManager.canRevert(whisperModel) {
                        CRButton(title: "Revert") {
                            try? model.modelManager.revert(whisperModel)
                        }
                        .help("Restore the copy from before the last update")
                    }
                    CRButton(title: "Delete", kind: .destructive) {
                        pendingDeletion = whisperModel
                    }
                }
            case let .failed(message):
                HStack(spacing: CR.Space.inner) {
                    Text(message)
                        .font(CR.Font.caption)
                        .foregroundStyle(CR.Tone.failed.ink)
                        .lineLimit(2)
                    CRButton(title: "Retry") { model.modelManager.download(whisperModel) }
                }
            }
        }
    }


    // MARK: - Model guidance

    /// The Mac's memory, which is what the fit warning compares a model against.
    private var physicalMemoryBytes: Int64 {
        // A design preview can stand in for a smaller Mac, because the warning it draws is the one
        // thing about this pane a large machine never shows. The app itself never sets this.
        if
            let raw = ProcessInfo.processInfo.environment["CALL_RECORDER_PREVIEW_MEMORY_GB"],
            let gigabytes = Int64(raw), gigabytes > 0
        {
            return gigabytes * 1_000_000_000
        }
        return Int64(ProcessInfo.processInfo.physicalMemory)
    }

    private var multilingualModels: [WhisperModel] {
        model.modelManager.models.filter { !$0.englishOnly }
    }

    private var englishOnlyModels: [WhisperModel] {
        model.modelManager.models.filter(\.englishOnly)
    }

    /// Models this Mac cannot hold with the headroom the app keeps in reserve.
    private var modelsThatDoNotFit: [WhisperModel] {
        model.modelManager.models.filter { !$0.fits(inMemoryOf: physicalMemoryBytes) }
    }

    /// One row's figures, in the order a person chooses by: what it is for, then what it costs.
    private func specLine(_ whisperModel: WhisperModel) -> String {
        var parts = [
            whisperModel.detail,
            "\(whisperModel.parameters) params",
            "\(ModelSizeLabel.file(bytes: whisperModel.expectedBytes)) download",
            "\(ModelSizeLabel.memory(bytes: whisperModel.memoryBytes)) RAM",
            "\(whisperModel.speed) vs Large",
        ]
        if let english = whisperModel.englishWordErrorRate {
            parts.append("English WER \(english)")
        }
        if let multilingual = whisperModel.multilingualWordErrorRate {
            parts.append("other languages \(multilingual)")
        }
        if !whisperModel.fits(inMemoryOf: physicalMemoryBytes) {
            parts.append("needs more memory than this Mac has with headroom")
        }
        return parts.joined(separator: " · ")
    }

    /// The model table, so the choice is made from numbers rather than from a hunch.
    ///
    /// The columns are the ones the model vendor publishes: parameters, the working memory
    /// whisper.cpp needs, the VRAM a GPU build asks for, speed relative to Large, and word error
    /// rate on read speech. A model this Mac cannot hold with the app's headroom is marked, which
    /// is the warning worth having before a three-gigabyte download.
    private var guidanceCard: some View {
        CRSettingsCard(
            title: "Which model should I choose?",
            footnote: "Word error rate is measured on read speech; lower is better. Speed is relative to Large v3. Memory is whisper.cpp's working set, and Call Recorder keeps thirty percent in reserve before it warns."
        ) {
            VStack(alignment: .leading, spacing: CR.Space.item) {
                CRSettingsNote(
                    icon: "checkmark.seal",
                    text: "Small is the pick for everyday calls: the best balance of speed and accuracy."
                )
                CRSettingsNote(
                    icon: "hare",
                    text: "Large v3 Turbo is nearly as accurate as Large v3 and about eight times faster."
                )
                CRSettingsNote(
                    icon: modelsThatDoNotFit.isEmpty ? "memorychip" : "exclamationmark.triangle",
                    text: memorySummary,
                    tone: modelsThatDoNotFit.isEmpty ? .muted : .waiting
                )
                comparisonTable
                    .padding(.horizontal, CR.Space.section)
            }
            .padding(.vertical, CR.Space.tight)
        }
    }

    private var memorySummary: String {
        let memory = ModelSizeLabel.memory(bytes: physicalMemoryBytes)
        guard !modelsThatDoNotFit.isEmpty else {
            return "This Mac has \(memory) of memory, which fits every model here with headroom to spare."
        }
        return "This Mac has \(memory) of memory. \(names(of: modelsThatDoNotFit)) need more than that with headroom and will swap heavily."
    }

    private func names(of models: [WhisperModel]) -> String {
        let names = models.map(\.displayName)
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    private var comparisonTable: some View {
        Grid(alignment: .leading, horizontalSpacing: CR.Space.item, verticalSpacing: CR.Space.snug) {
            GridRow {
                tableCell("Model", header: true, alignment: .leading)
                tableCell("Params", header: true)
                tableCell("Download", header: true)
                tableCell("RAM", header: true)
                tableCell("VRAM", header: true)
                tableCell("Speed", header: true)
                tableCell("English WER", header: true)
                tableCell("Multilingual WER", header: true)
            }
            ForEach(model.modelManager.models) { whisperModel in
                GridRow {
                    HStack(spacing: CR.Space.tight) {
                        if !whisperModel.fits(inMemoryOf: physicalMemoryBytes) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(CR.Tone.waiting.ink)
                                .help("Needs more memory than this Mac has with headroom")
                        }
                        Text(whisperModel.displayName)
                            .font(CR.Font.caption)
                    }
                    .gridColumnAlignment(.leading)
                    tableCell(whisperModel.parameters)
                    tableCell(ModelSizeLabel.file(bytes: whisperModel.expectedBytes))
                    tableCell(ModelSizeLabel.memory(bytes: whisperModel.memoryBytes))
                    tableCell(whisperModel.requiredVRAM)
                    tableCell(whisperModel.speed)
                    tableCell(whisperModel.englishWordErrorRate ?? "—")
                    tableCell(whisperModel.multilingualWordErrorRate ?? "—")
                }
            }
        }
    }

    private func tableCell(
        _ text: String,
        header: Bool = false,
        alignment: HorizontalAlignment = .trailing
    ) -> some View {
        Text(text)
            .font(header ? CR.Font.caption.weight(.semibold) : CR.Font.caption)
            .foregroundStyle(CR.Ink.readable)
            .monospacedDigit()
            .gridColumnAlignment(alignment)
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
    /// Only the terms inside the prompt budget reach the model. Showing which ones are in force
    /// answers the question the list could not: is the term I added actually being used?
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
            CRSettingsCard(title: "How this reaches Whisper") {
                VStack(alignment: .leading, spacing: CR.Space.inner) {
                    Text(
                        "Whisper accepts a limited amount of context per recording, so Call Recorder "
                            + "sends your participants' names first, then the terms you use most. "
                            + "Terms outside that budget stay saved and are still matched when a "
                            + "transcript is corrected, but they are not sent to the model."
                    )
                    .font(CR.Font.caption)
                    .foregroundStyle(CR.Ink.readable)
                    .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: CR.Space.inner) {
                        CRStatusChip(
                            tone: promptTermIDs.isEmpty ? .muted : .ready,
                            text: "\(promptTermIDs.count) of \(model.glossary.count) in the prompt"
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
                footnote: "Most used first. Terms without a checkmark are saved but outside the prompt."
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
                                    .accessibilityLabel("\(term.preferred) is in the prompt")
                            } else {
                                Image(systemName: "clock")
                                    .font(.system(size: 11))
                                    // The difference between a term that reaches the model and one
                                    // that does not is this glyph, and nothing else on the row.
                                    .foregroundStyle(CR.Ink.readable)
                                    .help(
                                        "Saved, but outside the prompt budget. It will be applied "
                                            + "when a transcript is corrected, not sent to the model."
                                    )
                                    .accessibilityLabel("\(term.preferred) is outside the prompt")
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
            ? "Spell the term the way it should appear. Alternatives catch the ways Whisper mishears it."
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
