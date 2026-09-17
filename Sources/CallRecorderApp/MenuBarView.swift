import CallRecorderCore
import SwiftUI

/// The menu bar popover.
///
/// This is the surface the user opens many times a day, so it keeps three bands in a fixed
/// order: what is happening now, what needs a decision, and what happened recently. The bands
/// hold their position in every state, so the control the user wants is where they left it.
struct MenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var confirmingDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: CR.Space.item) {
            header
            transport
            outcome
            decision
            recent
            CRDivider()
            footer
        }
        .padding(CR.Space.section)
        .frame(width: 360)
    }

    // MARK: - Now

    /// What the last action did, for as long as it is still news.
    ///
    /// Discarding a recording, restoring one, and repairing speakers all happen from this popover,
    /// and all of them used to change the surface without a word. The row went away, or the count
    /// went down, and the sentence that said the recording was still recoverable for a day lived
    /// in Settings where nobody was looking. This says it where the action was taken.
    @ViewBuilder
    private var outcome: some View {
        if model.recoveryMessageAt != nil, let message = model.recoveryMessage {
            let problem = model.recoveryOutcome == .problem
            HStack(alignment: .firstTextBaseline, spacing: CR.Space.inner) {
                Image(systemName: problem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(problem ? CR.Tone.waiting.ink : CR.Tone.ready.ink)
                Text(RecoveryNotice(message: message, outcome: model.recoveryOutcome).reason)
                    .font(CR.Font.caption)
                    .foregroundStyle(CR.Ink.readable)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var header: some View {
        HStack(spacing: CR.Space.inner) {
            if model.recorderState.phase == .recording {
                CRLiveDot()
            } else {
                Image(systemName: model.menuBarSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(statusColor)
                    // Leading, so the status glyph sits on the popover's gutter with everything
                    // under it. Centring it in its frame indented it three points.
                    .frame(width: CR.Icon.statusSlot, alignment: .leading)
            }
            Text(model.statusLabel)
                .font(CR.Font.title)
                .foregroundStyle(statusColor)
                .lineLimit(1)
            Spacer(minLength: CR.Space.snug)
            if model.backgroundSavingCount > 0 {
                CRStatusChip(tone: .working, text: "Saving \(model.backgroundSavingCount)")
            } else if isWatching {
                // Detection works silently, so one chip answers "is it still watching?".
                CRStatusChip(tone: .ready, text: "Watching")
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var transport: some View {
        switch model.recorderState.phase {
        case .idle:
            CRButton(
                title: "Start Recording",
                icon: "record.circle",
                kind: .primary,
                fullWidth: true,
                action: model.start
            )

        case .recording, .paused:
            let isRecording = model.recorderState.phase == .recording
            VStack(alignment: .leading, spacing: CR.Space.item) {
                timer
                HStack(spacing: CR.Space.inner) {
                    CRButton(
                        title: isRecording ? "Pause" : "Resume",
                        icon: isRecording ? "pause.fill" : "play.fill",
                        kind: .primary,
                        fullWidth: true,
                        action: isRecording ? model.pause : model.resume
                    )
                    CRButton(title: "Stop", icon: "stop.fill", kind: .secondary, action: model.stop)
                    // An accidental recording has to be cancellable while it is still running,
                    // not only after it stops.
                    CRIconButton(
                        icon: "trash",
                        label: "Discard this recording",
                        tone: .failed,
                        alwaysVisible: true,
                        // The row ends on the popover's gutter: the Start Recording button, the
                        // Stop button beside it, and the status chip in the header all end there,
                        // and a glyph centred in its circle fell half an icon short of them.
                        trailingAligned: true
                    ) {
                        confirmingDiscard = true
                    }
                }
            }
            .confirmationDialog(
                "Discard this recording?",
                isPresented: $confirmingDiscard,
                titleVisibility: .visible
            ) {
                Button("Discard Recording", role: .destructive, action: model.discard)
                Button("Keep Recording", role: .cancel) {}
            } message: {
                Text("The audio is deleted and no transcript is written.")
            }

        case .awaitingParticipants:
            VStack(alignment: .leading, spacing: CR.Space.inner) {
                CRButton(
                    title: "Choose Participants",
                    icon: "person.2",
                    kind: .primary,
                    fullWidth: true
                ) {
                    // Clear any finished call left over from an earlier edit, so this save
                    // reaches the recording that is actually waiting.
                    model.finishEditingParticipants()
                    presentWindow("participants")
                }
                CRButton(title: "Discard", icon: "trash", kind: .destructive, action: model.discard)
            }

        case .finalizing, .transcribing, .indexing:
            HStack(spacing: CR.Space.inner) {
                ProgressView()
                    .controlSize(.small)
                // The header one line above already names the stage in the same words. Repeating
                // it beside the spinner put "Transcribing" on screen twice and made the body of
                // the popover say nothing about what is actually happening.
                Text(model.processingDetail)
                    .font(CR.Font.body)
                    .foregroundStyle(CR.Ink.readable)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

        case .failed:
            CRCallout(
                icon: "exclamationmark.triangle.fill",
                title: model.errorMessage ?? "Open Settings to resolve the problem.",
                tone: .failed
            ) {
                HStack(spacing: CR.Space.inner) {
                    if model.canRetryPendingCall {
                        CRButton(
                            title: "Retry Participant Selection",
                            kind: .primary,
                            action: model.retryPendingCall
                        )
                    }
                    if model.errorDetails != nil {
                        CRButton(
                            title: "Copy Error Details",
                            icon: "doc.on.doc",
                            action: model.copyErrorDetails
                        )
                    }
                }
                // A failure the audio did not survive had no way out: the retry above is refused
                // by its own guard, and nothing else in the popover leaves the failed state, so
                // the app could only record again after a trip through Settings. The button that
                // clears it is offered in both cases, and it keeps the audio when there is any.
                if model.canRetryPendingCall {
                    // The audio is still there, so the recording gets the same confirmed discard
                    // every other phase offers rather than a quiet delete.
                    CRButton(
                        title: "Discard This Recording",
                        icon: "trash",
                        kind: .destructive,
                        action: model.dismissFailure
                    )
                } else {
                    CRButton(
                        title: "Start Recording",
                        icon: "record.circle",
                        kind: .primary,
                        action: model.startOverFromFailure
                    )
                }
            }
        }
    }

    /// A recorder has to show how long it has been running. Without it the only way to check is
    /// to guess from the clock. The view ticks once a second and reads the start date.
    @ViewBuilder
    private var timer: some View {
        // Paused is a state the clock has to answer for. The timer used to count from the moment
        // recording began and never stopped, so a call paused for ten minutes read ten minutes
        // longer than the audio it produced: nothing is captured while paused, and the number a
        // person reads here is the length of the recording.
        if let anchor = model.recordingStartedAt ?? model.recordingPausedAt {
            TimelineView(.periodic(from: anchor, by: 1)) { context in
                Text(formattedDuration(elapsedSeconds(at: context.date)))
                    .font(CR.Font.timer)
                    .foregroundStyle(.primary)
                    .accessibilityLabel(
                        model.recorderState.phase == .paused
                            ? "Paused after \(spokenDuration(elapsedSeconds(at: context.date)))"
                            : "Recording for \(spokenDuration(elapsedSeconds(at: context.date)))"
                    )
            }
        }
    }

    private func elapsedSeconds(at now: Date) -> TimeInterval {
        AppModel.recordedSeconds(
            banked: model.recordedSecondsBeforePause,
            currentRunStartedAt: model.recordingStartedAt,
            paused: model.recorderState.phase == .paused,
            at: now
        )
    }

    // MARK: - Decisions

    @ViewBuilder
    private var decision: some View {
        // Automatic detection is the point of the app, so when it is off the popover offers the
        // fix instead of hiding it in Settings. The offer can also be sent away: it is a reminder
        // and not a fault, and it sat over the Recent list for as long as the setting stayed off.
        if Self.offersAutomaticRecordingReminder(
            enabled: model.settings.automaticDetectionEnabled,
            dismissed: model.settings.automaticDetectionNoticeDismissed
        ), model.recorderState.phase == .idle {
            CRCallout(
                icon: "bell.slash.fill",
                title: "Automatic recording is off",
                message: "Recordings only start when you press Start.",
                tone: .waiting,
                dismiss: { model.settings.automaticDetectionNoticeDismissed = true }
            ) {
                CRButton(title: "Turn On", icon: "bolt.fill", kind: .primary) {
                    model.settings.automaticDetectionEnabled = true
                }
            }
        }

        // The permission this app cannot work without, said before a call rather than after one.
        //
        // System audio is captured through ScreenCaptureKit, and macOS gates it behind Screen
        // Recording. Without the grant the capture throws, and what reached the surface was a
        // framework sentence naming no permission and no way to grant one, which reads as the app
        // being broken. The card names the permission, says what a recording without it actually
        // holds, and opens the pane that carries the switch.
        if let notice = ScreenRecordingPermission.notice(granted: model.screenRecordingGranted) {
            CRCallout(
                icon: "rectangle.on.rectangle.slash",
                title: notice.title,
                message: notice.message,
                tone: .failed
            ) {
                CRButton(title: "Open System Settings", icon: "gearshape", kind: .primary) {
                    model.openScreenRecordingSettings()
                }
            }
        }

        if !model.backgroundFailures.isEmpty {
            let count = model.backgroundFailures.count
            CRCallout(
                icon: "exclamationmark.triangle.fill",
                title: "\(count) background save\(count == 1 ? "" : "s") failed",
                message: "Open Settings to retry or copy the error.",
                tone: .failed
            ) {
                CRButton(title: "Review", kind: .primary, action: presentSettings)
            }
        }

        // A stopped stage is neither a failure nor finished, and the row only says the call is
        // waiting. This is the sentence that explains why nothing is happening, and the retry
        // that starts the work again, both on the surface where the stop was pressed.
        if let stoppedID = model.stoppedProcessingCallID ?? model.previewStoppedProcessingCallID {
            let name = model.recentCalls.first { $0.id == stoppedID }.map { Self.title(for: $0) }
            CRCallout(
                icon: "stop.circle",
                title: "Processing stopped",
                message: name.map { "\($0) is waiting in the queue. Retry starts the stage again." }
                    ?? "The call is waiting in the queue. Retry starts the stage again.",
                tone: .waiting,
                dismiss: { model.dismissStoppedProcessing() }
            ) {
                CRButton(title: "Retry", icon: "arrow.clockwise", kind: .primary) {
                    model.retryStoppedProcessing()
                }
            }
        }

        // Voice matching stops while the key that unlocks the voice profiles is unread, and that
        // read parks on a permission dialog macOS waits on forever. The popover is where the user
        // looks, and it said nothing: the row under this one offered a review of voices that could
        // not be matched, and a confirmation that would fail. The dialog can open behind another
        // window, which is the one case where this surface has to name something not on screen.
        if let notice = Self.voiceIdentityNotice(model.voiceIdentityState) {
            CRCallout(
                icon: "lock.trianglebadge.exclamationmark",
                title: notice.title,
                message: notice.message,
                tone: .waiting
            ) {
                CRButton(title: "Try Again", icon: "arrow.clockwise", kind: .primary) {
                    model.retryVoiceIdentity()
                }
            }
        }

        if !model.speakerReviews.isEmpty {
            CRDisclosureRow(
                icon: "person.crop.circle.badge.questionmark",
                title: "Review Speakers",
                detail: "\(model.speakerReviews.count) voice\(model.speakerReviews.count == 1 ? "" : "s") waiting to be named",
                tone: .waiting
            ) {
                presentWindow("speaker-review")
            }
        }
        // Calls where detection could not run at all are a second condition with a second action,
        // and they used to be invisible whenever any voice also needed a name: the branch below
        // was an else-if, and the count above folded these calls into a number labelled "voices".
        // A call with no detected voice is not a voice, and its remedy is a retry rather than a
        // name, so it is stated on its own row.
        //
        // Only the retryable ones are named. Most calls in this state are older than the feature:
        // their audio is gone, nothing can be done about them, and a row that counts them would
        // stand here permanently with no action behind it. The full list is in Recovery, where a
        // record of what cannot be fixed belongs.
        if retryableSpeakerIssues > 0 {
            CRDisclosureRow(
                icon: "arrow.clockwise.circle",
                title: "Speaker detection stopped",
                detail: retryableSpeakerIssues == 1
                    ? "1 call can be tried again"
                    : "\(retryableSpeakerIssues) calls can be tried again",
                tone: .waiting
            ) {
                presentWindow("speaker-review")
            }
        }
        if model.speakerReviews.isEmpty,
           model.speakerAnalysisIssues.isEmpty,
           !model.voiceProfileSummaries.isEmpty,
           model.voiceProfileSummaries.allSatisfy({ $0.confirmedSampleCount == 0 }) {
            CRDisclosureRow(
                icon: "waveform.badge.plus",
                title: "Teach Call Recorder your voices",
                detail: "Name one speaker and the app recognises them next time",
                tone: .muted
            ) {
                presentWindow("speaker-review")
            }
        }
    }

    // MARK: - Recent

    @ViewBuilder
    private var recent: some View {
        if model.recentCalls.isEmpty {
            CREmptyState(
                icon: "waveform",
                title: "No recordings yet",
                // The empty list is the whole first screen of a new install, and the sentence it
                // carried explained the list rather than the app: it said where calls would appear
                // and nothing about where they come from. The one thing a person needs to know at
                // that moment is whether this app is listening to them, and when, so the sentence
                // says the trigger. It follows the setting, because a message promising automatic
                // recording over a popover that has just said automatic recording is off would be
                // the app contradicting itself in two lines.
                message: model.settings.automaticDetectionEnabled
                    ? "This app starts recording when another app opens your microphone, and "
                        + "stops when it is released. Finished calls appear here."
                    : "Press Start Recording to capture a call. Finished calls appear here."
            )
        } else {
            VStack(alignment: .leading, spacing: CR.Space.snug) {
                CRSectionHeader("Recent")
                VStack(spacing: CR.Space.hairline) {
                    ForEach(model.recentCalls) { call in
                        RecentCallRow(
                            model: model,
                            call: call,
                            showsTime: needsTime.contains(call.id),
                            openWindow: presentWindow,
                            // The renderer cannot produce a hover: the pointer that triggers one
                            // is not there off screen, so the highlight had never been in a
                            // picture and its insets had never been looked at.
                            hoveringOverride: model.previewHoveredCallID == call.id ? true : nil
                        )
                    }
                }
            }
        }
    }

    /// The rows that would otherwise read the same as another row on screen.
    ///
    /// Two calls with the same people, on the same day, both older than a day, were drawn as the
    /// same two lines: the names, and "Sep 11". Nine such pairs sit in the most recent forty
    /// calls, and each pair holds two different transcripts, so neither row could be chosen by
    /// reading it. A row whose names and date both repeat gets its time back, which is the part
    /// that tells the two apart; a row that is already unique keeps the short label, because the
    /// wide one is what the short one was introduced to avoid.
    /// Nonisolated because it reads a list and formats dates: it touches no view state, and a
    /// test that reached it on the main actor would trap on the executor check instead of
    /// reporting what the rows say.
    nonisolated static func rowsNeedingTheTime(_ calls: [RecentCallSummary]) -> Set<CallID> {
        var seen: [String: [CallID]] = [:]
        for call in calls {
            let key = title(for: call) + "\u{1F}" + whenLabel(for: call)
            seen[key, default: []].append(call.id)
        }
        return Set(seen.values.filter { $0.count > 1 }.flatMap { $0 })
    }

    /// What the popover says about voice matching, or nothing when it works.
    ///
    /// Two waits look the same from the window and are not. A read that has just started finishes
    /// on its own within seconds, and a read parked on a permission dialog waits for a person.
    /// Only the second is worth a card, and it is the one that used to be silent here: the
    /// keychain was locked for a day, and the popover went on showing the same nine voices with no
    /// hint that nothing could match them.
    ///
    /// Nonisolated because it reads a state value and returns words: a test that reached it on the
    /// main actor would trap on the executor check instead of reporting what the card says.
    nonisolated static func voiceIdentityNotice(
        _ state: VoiceIdentityState
    ) -> (title: String, message: String)? {
        switch state {
        case .available, .checking:
            return nil
        case .waitingForPermission:
            return (
                "Voice matching is paused",
                "The keychain is waiting for an answer to a dialog. It can open behind another "
                    + "window or on another display, both of which hid it for a day on this Mac. "
                    + "Choose Always Allow: Allow answers once, and the question returns."
            )
        case .unavailable:
            return (
                "Voice matching is off",
                "The voice-profile key could not be read. Try again, or open Recovery for the error."
            )
        }
    }

    /// Whether the popover offers to switch automatic recording back on.
    ///
    /// Two flags and one answer, written out so the rule can be checked without a window: the
    /// reminder is due while detection is off and has not been dismissed. Nonisolated because it
    /// reads values and returns a flag, so a test does not have to reach the main actor.
    nonisolated static func offersAutomaticRecordingReminder(
        enabled: Bool,
        dismissed: Bool
    ) -> Bool {
        !enabled && !dismissed
    }

    /// What a row is named after. A call with nobody on it is named by its own date and time,
    /// which is the only thing it has.
    nonisolated static func title(for call: RecentCallSummary) -> String {
        call.participantNames.isEmpty
            ? call.startedAt.formatted(date: .abbreviated, time: .shortened)
            : call.participantNames.joined(separator: ", ")
    }

    /// An absolute date on every row cost more width than the words that identify the call, so a
    /// call from today says how long ago it was and an older one keeps the date.
    ///
    /// The time comes back for a row that would otherwise be one of two identical rows. Date and
    /// time together are the longest form, so they are kept for the rows that have nothing else to
    /// tell them apart.
    nonisolated static func whenLabel(
        for call: RecentCallSummary,
        withTime: Bool = false
    ) -> String {
        let age = Date.now.timeIntervalSince(call.startedAt)
        if withTime {
            return call.startedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
        if age < 60 { return "just now" }
        if age < 86_400 { return call.startedAt.formatted(.relative(presentation: .numeric)) }
        return call.startedAt.formatted(.dateTime.month(.abbreviated).day())
    }

    private var needsTime: Set<CallID> { Self.rowsNeedingTheTime(model.recentCalls) }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: CR.Space.tight) {
            CRIconButton(
                icon: "folder",
                label: "Open Recordings Folder",
                alwaysVisible: true,
                leadingAligned: true
            ) {
                model.openRecordingsFolder()
            }
            CRIconButton(
                icon: "gearshape",
                label: "Settings",
                alwaysVisible: true,
                leadingAligned: true,
                action: presentSettings
            )
            CRIconButton(
                icon: "person.2",
                label: "Participants",
                alwaysVisible: true,
                leadingAligned: true
            ) {
                presentWindow("participants")
            }
            Spacer(minLength: 0)
            // The footer's first icon is drawn on the popover's gutter, so the last one is too.
            CRIconButton(
                icon: "power",
                label: "Quit Call Recorder",
                tone: .failed,
                alwaysVisible: true,
                trailingAligned: true
            ) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    // MARK: - Helpers

    private var isWatching: Bool {
        model.settings.automaticDetectionEnabled && model.recorderState.phase == .idle
    }

    /// The calls whose detection failed and whose audio is still there to try again on.
    ///
    /// Separate from the voices waiting on a name: those calls produced no voice to name.
    private var retryableSpeakerIssues: Int {
        model.speakerAnalysisIssues.filter(\.canRetry).count
    }

    private var statusColor: Color {
        // The header is the line the eye lands on first, so it reads in ink rather than in the
        // vivid mark colour, which is only bright enough to be noticed and not dark enough to be
        // read on a light popover.
        switch model.recorderState.phase {
        case .idle: .primary
        case .recording, .failed: CR.Tone.live.ink
        case .paused, .awaitingParticipants: CR.Tone.waiting.ink
        case .finalizing, .transcribing, .indexing: CR.Tone.working.ink
        }
    }

    private func formattedElapsed(from start: Date, to now: Date) -> String {
        formattedDuration(now.timeIntervalSince(start))
    }

    /// A length of recording as a clock. Two steps and up is minutes and seconds, and an hour adds
    /// the third step rather than a fourth column of zeroes.
    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    private func spokenElapsed(from start: Date, to now: Date) -> String {
        spokenDuration(now.timeIntervalSince(start))
    }

    /// The same length read aloud, for the label a screen reader announces.
    private func spokenDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let minutes = total / 60
        let seconds = total % 60
        return minutes == 0 ? "\(seconds) seconds" : "\(minutes) minutes \(seconds) seconds"
    }

    private func presentWindow(_ id: String) {
        WindowPresentation.present(open: { openWindow(id: id) })
    }

    private func presentSettings() {
        WindowPresentation.present(open: { openSettings() })
    }
}

/// One call in the recent list.
///
/// The row owns its hover state so the actions appear only for the call under the pointer. Five
/// rows of always-visible glyphs competed with the names they sat next to.
// Not private: the two rules a finished row uses to decide whether it has anything to say are
// pure functions of the call, and a test reaches them through this type rather than through a
// window. Everything else in the row is still the view's own business.
struct RecentCallRow: View {
    let model: AppModel
    let call: RecentCallSummary
    /// True when another row on screen carries the same names and the same date.
    let showsTime: Bool
    let openWindow: (String) -> Void
    /// The row's highlight, forced on for a render. Nil in the running app, where a hover decides.
    var hoveringOverride: Bool?

    @State private var hovering = false

    private var isHighlighted: Bool { hoveringOverride ?? hovering }

    var body: some View {
        HStack(spacing: CR.Space.tight) {
            Button {
                model.copyTranscript(for: call)
            } label: {
                VStack(alignment: .leading, spacing: CR.Space.hairline) {
                    Text(title)
                        .font(CR.Font.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: CR.Space.snug) {
                        // The chip marks a call that is not in its normal finished state. On a list
                        // where every row has finished, five identical green pills are the loudest
                        // thing on the surface and the only thing that never changes, so the eye
                        // lands on them before the names that tell one row from another. Leaving the
                        // chip off the finished rows is what lets the one unfinished row stand out,
                        // which is the whole reason the chip is here.
                        if showsStatusChip {
                            CRStatusChip(tone: statusTone, text: statusText, compact: true)
                                // A chip is two words, and this one carries a fact the reader has
                                // to be able to act on, so the sentence lives in the tooltip.
                                .help(missingOtherSide ? Self.missingOtherSideHelp : "")
                        }
                        // When a call happened and how many voices are left are read, not glanced
                        // at: they are how two rows for the same people are told apart.
                        Text(whenLabel)
                            .font(CR.Font.caption)
                            .foregroundStyle(CR.Ink.readable)
                        // How long the call ran. It sits after the time it happened, which is the
                        // order the two are asked in, and monospaced digits keep a column of
                        // lengths lined up down the list.
                        if let length = call.lengthLabel {
                            Text(length)
                                .font(CR.Font.caption)
                                .monospacedDigit()
                                .foregroundStyle(CR.Ink.readable)
                        }
                        if call.unresolvedSpeakerCount > 0 {
                            Text("\(call.unresolvedSpeakerCount) to review")
                                .font(CR.Font.caption)
                                .foregroundStyle(CR.Ink.readable)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!transcriptReady)
            .help(transcriptReady ? "Copy transcript" : "Transcript is not ready")
            .accessibilityLabel(
                transcriptReady
                    ? "Copy transcript for \(title)"
                    : "Transcript for \(title) is not ready"
            )

            CRIconButton(
                icon: model.copiedTranscriptCallID == call.id ? "checkmark" : "doc.on.doc",
                label: "Copy transcript",
                tone: .ready,
                alwaysVisible: model.copiedTranscriptCallID == call.id,
                revealed: hovering,
                trailingAligned: true
            ) {
                model.copyTranscript(for: call)
            }
            .disabled(!transcriptReady)

            // Work that is running gets a way to end it. The row is where this call's state is
            // read, so the control that stops the work sits with the stage it names.
            if showsStopControl {
                CRIconButton(
                    icon: "stop.circle",
                    label: "Stop processing",
                    tone: .waiting,
                    alwaysVisible: true
                ) {
                    model.stopProcessing()
                }
            }

            if canEditParticipants {
                CRIconButton(
                    icon: "person.2.badge.plus",
                    label: "Edit participants",
                    revealed: hovering,
                    trailingAligned: true
                ) {
                    openWindow("participants")
                    model.editParticipants(for: call)
                }
            }
        }
        // No margin of its own: the row sits on the popover's 16-point gutter like the header,
        // the section label, and the footer, so the popover has one left edge instead of two.
        // The hover highlight still spans the full width of the content area.
        .padding(.vertical, CR.Space.snug)
        .background(
            RoundedRectangle(cornerRadius: CR.Radius.small, style: .continuous)
                .fill(isHighlighted ? Color.primary.opacity(0.06) : .clear)
                // The row draws on the popover's 16-point gutter, so a pill on the row's own
                // bounds put its left edge one point from the first glyph while the sidebar's row
                // keeps twelve, and a highlighted row read as cramped. The fill keeps the same
                // room on its sides as it has above and below and takes that room from the gutter;
                // the negative padding gives the gutter back, so the names still line up with the
                // header above them and nothing moves when the pointer arrives.
                .padding(.horizontal, -CR.Space.snug)
        )
        .onHover { hovering = $0 }
        .contextMenu { menu }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Copy Transcript", systemImage: "doc.on.doc") {
            model.copyTranscript(for: call)
        }
        .disabled(!transcriptReady)

        Button("Open Transcript", systemImage: "doc.text") {
            model.openTranscript(for: call.id)
        }
        .disabled(!transcriptReady)

        if canEditParticipants {
            Button("Edit Participants…", systemImage: "person.2.badge.plus") {
                openWindow("participants")
                model.editParticipants(for: call)
            }
        }

        if call.unresolvedSpeakerCount > 0 {
            Button("Review Speakers…", systemImage: "person.crop.circle.badge.questionmark") {
                openWindow("speaker-review")
            }
        }
    }

    private var transcriptReady: Bool { call.hasTranscript }

    /// Whether this row is the one whose stage the app can end right now.
    private var showsStopControl: Bool {
        model.stoppableCallID == call.id || model.previewStoppableCallID == call.id
    }

    /// Whether this call lost the other side of its conversation.
    ///
    /// The preview can name a row because the state it draws needs a call that lost a track, and
    /// no render may write one into the library to get it.
    private var missingOtherSide: Bool {
        call.systemAudio == .missing || model.previewSystemAudioCallID == call.id
    }

    /// Whether this row still needs to say something. A finished call says nothing: its time and
    /// its review count are the rest of the line, and the row is already legible without a label
    /// that only ever repeats the state of every other row. A copy confirmation and a speaker
    /// problem are both news, so both keep their chip.
    private var showsStatusChip: Bool {
        Self.rowNeedsStatusChip(
            for: call,
            copied: model.copiedTranscriptCallID == call.id,
            hasSpeakerIssue: speakerIssue != nil
        ) || missingOtherSide
    }

    /// Whether a recent row has anything to say beyond its name and its time.
    ///
    /// A finished call normally says nothing: its time and its review count fill the line, and a
    /// chip that repeated the state of every other row would be noise. Three things are still news.
    /// A copy confirmation. A speaker problem. And a call whose transcript holds no speech, which
    /// is the one that was being thrown away: the label was computed for it while the chip was
    /// hidden for every finished call, so the row drew a time and nothing else over a recording of
    /// an empty room. Written as a function of the row rather than of the view so a test can ask
    /// the question the view asks.
    ///
    /// Nonisolated because it reads a value and returns a flag: a test that reached it on the main
    /// actor would trap on the executor check instead of reporting the answer.
    nonisolated static func rowNeedsStatusChip(
        for call: RecentCallSummary,
        copied: Bool,
        hasSpeakerIssue: Bool
    ) -> Bool {
        if copied || hasSpeakerIssue { return true }
        if call.systemAudio == .missing { return true }
        if !call.hasTranscript { return true }
        return speaksAsNoSpeech(call)
    }

    /// The sentence behind the warning chip on a call that lost one side.
    static let missingOtherSideHelp =
        "The other side of this call was not recorded, so the transcript holds your microphone "
        + "only. Check Screen Recording permission in Settings before the next call."

    /// Whether this call is a finished recording with no words in it.
    ///
    /// While a call is still being processed the row is about the work rather than the audio, and
    /// saying the recording is empty before the transcriber has answered would be a guess.
    nonisolated static func speaksAsNoSpeech(_ call: RecentCallSummary) -> Bool {
        call.hasTranscript && call.status == .ready && !call.hasSpeech
    }

    private var title: String { MenuBarView.title(for: call) }

    private var whenLabel: String {
        MenuBarView.whenLabel(for: call, withTime: showsTime)
    }

    private var statusText: String {
        if model.copiedTranscriptCallID == call.id { return "Copied" }
        if let issue = speakerIssue {
            return issue.canRetry ? "Retry speakers" : "Text saved"
        }
        // Before the no-speech chip: a call whose other side was never captured says why it may
        // hold so little, which is the fact the reader can act on.
        // Short enough to fit beside the time and a review count: the longer sentence this used
        // to carry was cut to "Only your micro..." on the row, and a chip that truncates its own
        // warning says nothing. The tooltip holds the whole sentence.
        if missingOtherSide { return "One side only" }
        // A call nobody spoke on is not ready. The transcriber found nothing, so it wrote a file
        // with a heading and no words, and every question the row used to ask answered yes: the
        // transcript exists, the call finished, the pipeline is complete. The row therefore said
        // Ready, in the ready tone, over a recording of an empty room. Saying what the recording
        // held is the difference between a list that can be trusted and one that cannot.
        if Self.speaksAsNoSpeech(call) {
            return "No speech"
        }
        return call.hasTranscript && call.status == .ready
            ? "Ready"
            : Self.label(for: call.status)
    }

    private var statusTone: CR.Tone {
        if model.copiedTranscriptCallID == call.id { return .ready }
        // Red rather than muted: the recording is half of a conversation, and the audio is kept
        // for a day, which is the window in which the reader can still do something about it.
        if missingOtherSide { return .failed }
        if let issue = speakerIssue {
            return issue.canRetry ? .waiting : .muted
        }
        switch call.status {
        case .recording: return .live
        case .metadata: return .waiting
        case .transcribing, .indexing: return .working
        // Muted rather than failed: nothing went wrong, and the Recovery pane is where a file
        // like this is judged and cleared. A failure tone here would send the reader looking for
        // a fault that does not exist.
        case .ready:
            if Self.speaksAsNoSpeech(call) { return .muted }
            return call.hasTranscript ? .ready : .waiting
        case .failed: return .failed
        }
    }

    private var speakerIssue: SpeakerAnalysisIssue? {
        model.speakerAnalysisIssues.first { $0.callID == call.id }
    }

    /// A saved call with no transcript is normally waiting for its turn in the queue. Call
    /// Recorder no longer asks for participants before transcribing, so the old wording sent
    /// people looking for a step that does not exist.
    private static func label(for status: CallStatus) -> String {
        switch status {
        case .recording: "Recording"
        case .metadata: "Waiting to transcribe"
        case .transcribing: "Transcribing"
        case .indexing: "Indexing"
        case .ready: "Ready"
        case .failed: "Needs attention"
        }
    }

    private var canEditParticipants: Bool {
        switch call.status {
        case .metadata, .ready, .failed: true
        case .recording, .transcribing, .indexing: false
        }
    }
}
