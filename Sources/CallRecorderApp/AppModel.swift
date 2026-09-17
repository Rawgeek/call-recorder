import AppKit
import CallRecorderCore
import Foundation
import Observation
import ServiceManagement
import OSLog

struct SpeakerAnalysisIssue: Identifiable {
    let callID: CallID
    let startedAt: Date
    let canRetry: Bool
    let audioAvailable: Bool
    let message: String
    let details: String?
    var id: CallID { callID }
}

/// Something the app has just finished, or has just refused to do, and how to say it.
///
/// Discarding a recording, restoring one, and repairing speakers are all started from the popover,
/// and all of them used to change the surface without a word. This is what those actions leave
/// behind so the popover can say what happened, and it is kept apart from the model so the two
/// rules it owns can be checked without building a window: which half of a message a narrow
/// surface shows, and which actions are news rather than a permanent record.
struct RecoveryNotice: Equatable {
    /// Whether the action was carried out or refused.
    ///
    /// Kept as its own value rather than inferred from the wording. A sentence that says a repair
    /// failed and a sentence that says it worked are both prose, and the first time one is reworded
    /// a guess would put a green tick on a failure.
    enum Outcome: Equatable {
        case done
        case problem
    }

    let message: String
    let outcome: Outcome

    /// The part of the message a narrow surface shows.
    ///
    /// A refusal can carry a redacted technical detail after a blank line, which is what gets copied
    /// into a report. The popover is 360 points wide and shows the reason; the detail stays where it
    /// is complete, in the copied diagnostics and in the Recovery pane's own note.
    var reason: String {
        String(message.prefix(while: { !$0.isNewline }))
    }
}

/// What came of asking for a transcript file that the database says a call has.
///
/// Open used to do nothing at all for a call whose file was gone, because the button assumed the
/// file named by the row was there. These are the answers that let the two surfaces say which of
/// those two things happened instead of going quiet.
enum TranscriptFileOutcome: Equatable {
    /// A file already sat under the call's own name, and the row was pointed at it.
    case repointed(URL)
    /// The transcript was written again from the saved text.
    case writtenBack(URL)
    /// The call holds too little speech for a file, which would misrepresent it as transcribed.
    case noSpeech
    /// Nothing was written.
    case failed
}

@MainActor
@Observable
final class AppModel {
    private(set) var recorderState = RecordingState.idle
    private(set) var participants: [Participant] = []
    private(set) var glossary: [GlossaryTerm] = []
    /// How often each glossary term appears in the newest transcripts, keyed by the lowercased
    /// preferred spelling. The transcription prompt is much smaller than the glossary, so the
    /// Vocabulary tab shows these counts to explain which terms actually reach the model.
    private(set) var glossaryUsage: [String: Int] = [:]
    /// People already named on a call. The review window uses this to warn before the same
    /// person is given a second voice in the same call.
    private(set) var namedParticipants: [CallID: Set<ParticipantID>] = [:]

    /// Everyone recorded as being on each call, so a window that has to name a voice can offer the
    /// people who were actually there before the people who were not.
    private(set) var callParticipants: [CallID: [Participant]] = [:]
    private var sessionUnlockObserver: NSObjectProtocol?
    private(set) var recentCalls: [RecentCallSummary] = []
    /// True once the first read of the database has finished, successfully or not.
    ///
    /// The menu bar can look empty for two different reasons: there is nothing to show, or the
    /// read has not finished. A render and a person both need to tell those apart.
    private(set) var metadataIsLoaded = false
    private(set) var copiedTranscriptCallID: CallID?
    private(set) var processingJobs: [ProcessingJob] = []
    /// The calls behind the unfinished jobs, so the Recovery rows can name them. A job carries
    /// only a call id, and four rows reading "Transcribing audio" identify nothing.
    private(set) var processingCallSummaries: [CallID: RecentCallSummary] = [:]
    /// The call whose running stage the app can end right now, if any.
    ///
    /// A transcription that stopped making progress used to be stoppable only from outside the
    /// app: the row showed the stage, and no surface held a control that ended the work. This is
    /// the call whose row carries Stop, and it is nil whenever no stoppable stage is running.
    private(set) var stoppableCallID: CallID?
    /// The call the user stopped, kept until they retry it or put the notice away.
    private(set) var stoppedProcessingCallID: CallID?
    /// The flag the running stage polls, written when the user stops it.
    @ObservationIgnored private var stageCancellation: ProcessCancellation?
    /// For a render: the row that draws the Stop control. Nil in the running app.
    var previewStoppableCallID: CallID?
    /// For a render: the stopped notice the preview draws. Nil in the running app.
    var previewStoppedProcessingCallID: CallID?
    /// For a render: the row drawn as a call that lost the other side of its conversation.
    var previewSystemAudioCallID: CallID?
    /// Calls whose unfinished job has nothing left to work with. Retrying one cannot succeed, so
    /// the Recovery pane offers to remove the row instead of a button that fails again.
    private(set) var unfinishableCallIDs: Set<CallID> = []
    private(set) var speakerReviews: [SpeakerReviewItem] = []
    private(set) var speakerReviewEvidence: [SpeakerClusterID: SpeakerReviewPlayback.Evidence] = [:]
    private(set) var speakerReviewCallDates: [CallID: Date] = [:]
    private(set) var voiceProfileSummaries: [VoiceProfileSummary] = []
    private(set) var recoverableArtifacts: [RecoverableArtifact] = []
    private(set) var recoveryMessage: String? {
        didSet {
            // Writing the message is what stamps the clock, and it always resets the tone: a
            // sentence set here is the ordinary case, which is something having been done. The
            // failure paths go through announceProblem instead, so the tone can never disagree
            // with the text because the two were set in the wrong order.
            recoveryOutcome = .done
            stampRecoveryMessage()
        }
    }

    /// When the message above was written, or nil once it has been on screen long enough.
    ///
    /// The popover is where a recording is discarded and where a repair is started, and it used to
    /// say nothing when either worked: the state flipped, and the sentence explaining what had
    /// happened was only written into a Diagnostics footnote in Settings. Worse, the reassuring
    /// half of that sentence — that the recording is still recoverable for a day — was the half
    /// nobody saw.
    ///
    /// So the popover says it, and stops saying it on its own. This is a separate clock rather than
    /// a second copy of the text, because the two surfaces want different lifetimes: the popover
    /// reports what just happened, and Settings keeps the last result as a record. Clearing this
    /// one leaves the record alone.
    private(set) var recoveryMessageAt: Date?

    /// How the message above should read: something done, or something refused.
    private(set) var recoveryOutcome: RecoveryNotice.Outcome = .done

    /// What the last speaker repair did, kept so the Repair card can say it ran and what it found.
    ///
    /// The repair runs by itself at launch, and it acted silently whether it changed anything or
    /// not. Someone looking at a call that still shows one person on several voices could not tell
    /// whether the repair had run at all, or had run and decided those voices really are one
    /// person. Both are answers; only the second one means there is nothing left to fix.
    private(set) var lastSpeakerReconcile: SpeakerReconcileSummary?
    private(set) var voiceIdentityError: String?

    /// Whether the voice-profile key has been read, and what stopped it.
    ///
    /// The key lives in the login keychain, and reading it can wait on a permission dialog. A read
    /// that is still waiting and a read that has not been tried look the same from a bare optional,
    /// so a window that asked "is there an error" answered no and drew "Encrypted voice-profile
    /// storage is available" while the read was in fact parked on a dialog the user could not see.
    /// The state is explicit so the surface can say which of the three it is in.
    private(set) var voiceIdentityState: VoiceIdentityState = .checking

    /// Whether macOS has granted Screen Recording, which is what system audio needs.
    ///
    /// Checked at launch with `CGPreflightScreenCaptureAccess`, which reports the state without
    /// raising a dialog. Without the grant the capture does not fall back to the microphone: it
    /// throws, and the error that reached the surface named no permission and no way to grant one.
    /// The state is kept here so the popover can say what is wrong before a call is attempted,
    /// rather than after one has failed.
    private(set) var screenRecordingGranted = AppModel.previewScreenRecordingGranted

    /// Lets a render show the card a missing Screen Recording grant draws.
    ///
    ///     CALL_RECORDER_SCREEN_PERMISSION=denied scripts/preview.sh
    ///
    /// The grant is a system fact, and a render of the popover on a Mac that has it can never show
    /// what a person without it sees. The flag exists so the sentence and the button can be looked
    /// at, which is the only way to check that a failure this common says the right thing.
    static var previewScreenRecordingGranted: Bool {
        guard isPreviewMode,
              let raw = ProcessInfo.processInfo.environment["CALL_RECORDER_SCREEN_PERMISSION"]
        else { return true }
        return raw.lowercased() != "denied"
    }

    /// Records the key state outside the app whenever it changes.
    ///
    /// The state is the answer to "is the speaker feature usable, and if not why", and it is the
    /// one question that cannot be answered by looking at the window: a keychain read that is
    /// parked on a dialog draws a normal-looking window. Writing the state where it can be read
    /// while the app is closed turns that into a fact anyone can check.
    private static func recordVoiceIdentityState(_ state: VoiceIdentityState) {
        // A render reads the real preferences but is not the real app, and this key is meant to say
        // what the installed app found when it started. Letting a render write it would replace
        // that with the render's own answer.
        guard !isPreviewMode else { return }
        let word = switch state {
        case .checking: "checking"
        case .waitingForPermission: "waiting-for-keychain-permission"
        case .available: "available"
        case .unavailable: "unavailable"
        }
        preferences().set(
            ISO8601DateFormatter().string(from: Date.now) + " " + word,
            forKey: "last-voice-identity-state"
        )
    }
    private(set) var speakerRuntimeMessage = "Speaker setup has not been checked."
    private(set) var checkingSpeakerRuntime = false
    private(set) var speakerAnalysisIssues: [SpeakerAnalysisIssue] = []
    private(set) var reviewingSpeakerIDs: Set<SpeakerClusterID> = []
    /// The excerpts whose assignment is being written, so the control can say so.
    private(set) var movingLineRanges: Set<String> = []
    private(set) var speakerReviewFailure: String?
    var selectedParticipantIDs: Set<ParticipantID> = []
    /// The finished call whose participants the Participants window is editing, if any.
    private(set) var participantEditingCallID: CallID?
    /// When the current recording started, so the menu bar can show how long it has been running.
    private(set) var recordingStartedAt: Date?
    /// How much of this call was recorded before the current run of the recorder.
    ///
    /// The popover's timer used to count from the moment recording started and never stopped, so a
    /// call paused for ten minutes read ten minutes longer than it was. Nothing captures audio while
    /// paused, so the number was not the length of the recording: it was the length of the sitting.
    /// Every previous run of this call is added up here and the live run is measured from the start
    /// of the current one.
    private(set) var recordedSecondsBeforePause: TimeInterval = 0
    /// When the pause began, so the popover's clock has a time to anchor its tick to while the
    /// recorder is stopped. The number it draws does not change; a still clock still needs a pulse.
    private(set) var recordingPausedAt: Date?
    var settings: AppSettings {
        didSet {
            // A dismissed reminder belongs to the state it was dismissed in. Switching automatic
            // recording back on and off again is a new decision about it, so the reminder is due
            // again; without this the card could never return, and the one place that explains the
            // setting would stay silent for good.
            if settings.automaticDetectionEnabled, !oldValue.automaticDetectionEnabled {
                settings.automaticDetectionNoticeDismissed = false
            }
            saveSettings()
        }
    }
    var startAtLoginEnabled: Bool {
        didSet { updateStartAtLogin() }
    }
    var errorMessage: String?
    private(set) var errorDetails: String?

    let modelManager: ModelManager
    /// The models the app needs but does not ask anyone to choose between.
    let supportingManager: SupportingModelManager
    private let applicationDirectory: URL
    private let store: CallStore?
    private var speakerStore: SpeakerStore?

    private var diarizer: Diarizer? {
        guard let script = Self.diarizerScriptURL() else { return nil }
        let managedPython = applicationDirectory.appending(path: "python/bin/python3")
        let configuredPython = (defaults.string(forKey: "speaker-python")
            ?? ProcessInfo.processInfo.environment["CALL_RECORDER_PYTHON"])
            .map { URL(filePath: $0) }
        let python = configuredPython ?? managedPython
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return nil }
        return Diarizer(python: python, script: script)
    }

    /// The speaker-detection script.
    ///
    /// The installed app copies it into Contents/Resources, where the main bundle finds it. A
    /// bare build keeps it in a resource bundle beside the executable, which the main bundle does
    /// not look in: the preview renderer found nothing, so every render reported "Speaker
    /// detection needs setup" for a runtime that was working. The lookup is written out rather
    /// than using the generated accessor, which would stop the process instead of returning nil.
    private static func diarizerScriptURL() -> URL? {
        if let url = Bundle.main.url(forResource: "diarize", withExtension: "py") { return url }
        // The executable's own directory, with symlinks resolved: SwiftPM points .build/debug at
        // the real build directory, and listing through the link fails.
        guard let directory = Bundle.main.executableURL?
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        else { return nil }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for entry in entries where entry.pathExtension == "bundle" {
            if let bundle = Bundle(url: entry),
               let url = bundle.url(forResource: "diarize", withExtension: "py") {
                return url
            }
        }
        return nil
    }

    private let pipeline: CallPipeline?
    private let indexer: IndexerClient?
    @ObservationIgnored private lazy var processor: MeetingProcessor? = {
        guard let store else { return nil }
        return MeetingProcessor(store: store, runStage: { [weak self] job in
            guard let self else { throw BackgroundProcessingError.appUnavailable }
            return try await self.runProcessingStage(job)
        }, onChange: { [weak self] in
            await self?.refreshMetadataFromProcessor()
        }, onStageCancelled: { [weak self] callID in
            await self?.processingStageWasCancelled(callID)
        })
    }()
    private let activityMonitor = AudioActivityMonitor()
    /// True when the app was started only to look at its windows.
    ///
    /// Reviewing a layout change should not require packaging, signing, and installing the app,
    /// and it must not start a recording. In preview mode the model reads the real database and
    /// renders the real windows, but nothing watches the microphone, nothing is processed, and
    /// nothing is written.
    static let isPreviewMode = ProcessInfo.processInfo.environment["CALL_RECORDER_PREVIEW"] == "1"

    /// Renders the popover as a new install sees it: no calls, no voices, no glossary usage.
    ///
    /// The first screen of a new install is the one surface that could not be reviewed at all.
    /// Every render reads the real library, so the empty state was reachable only by deleting that
    /// library. It matters more than the others for two reasons: it is the first thing a person
    /// sees after installing, and it is the only state in which the popover has nothing to say
    /// about a call. The flag hides the library from the render and changes nothing else.
    static let isEmptyLibraryPreview =
        isPreviewMode && ProcessInfo.processInfo.environment["CALL_RECORDER_EMPTY_LIBRARY"] == "1"

    /// The recent row drawn in its hovered state, for a render.
    ///
    /// A hover comes from a pointer, and an off-screen render has none, so the row's highlight had
    /// never been in a picture and its insets had never been looked at. Only the renderer sets
    /// this, and only in preview mode.
    var previewHoveredCallID: CallID?

    /// Set by the renderer once it has put a review card in place, so the window's own refresh
    /// does not clear it. Only the renderer sets this.
    private(set) var previewSeededReviewCard = false
    private let captureSession = AudioCaptureSession()
    private var captureOperationInFlight = false
    private var activeSessionDirectory: URL?
    private var capturedSegments: [CaptureSegment] = []
    private var nextSegmentIndex = 1
    private var activeCallID: CallID?
    private var finalizedAudioURL: URL?
    private let backgroundFinalization: BackgroundAudioFinalization
    private(set) var backgroundState = BackgroundFinalizationState()
    private var backgroundCompletedCallIDs: Set<CallID> = []
    private var backgroundDiagnosedFailures: Set<CallID> = []
    private var launchStartConsumed = false
    private var stopGraceTask: Task<Void, Never>?
    private var modelMaintenanceTask: Task<Void, Never>?
    private var speakerReviewRequestTask: Task<Void, Never>?
    private var captureQueue = CaptureCommandQueue()
    private static let settingsKey = "app-settings"
    private static let startAtLoginKey = "start-at-login"

    /// Where saved preferences are read and written.
    ///
    /// The app uses the standard domain. A build started from the command line has no bundle
    /// identifier, so `UserDefaults.standard` there is a different, empty domain: a layout render
    /// then drew every settings-dependent pane with default values, and the Models pane claimed
    /// the selected model was not downloaded while the installed one was. A render that shows the
    /// wrong settings cannot be used to review the pane, and reporting a fault from it would be
    /// reporting a fault that does not exist.
    private static func preferences() -> UserDefaults {
        guard isPreviewMode else { return .standard }
        // A sandboxed render must not read or write the real preferences either, or taking a
        // picture would change the settings the installed app uses.
        if previewHomeDirectory() != nil,
           let suite = UserDefaults(suiteName: previewDefaultsIdentifier)
        {
            return suite
        }
        guard let suite = UserDefaults(suiteName: productionIdentifier) else { return .standard }
        return suite
    }

    /// The UserDefaults domain a sandboxed preview home reads and writes.
    private static let previewDefaultsIdentifier = "local.callrecorder.app.preview"

    /// An isolated home directory for a layout render, when the environment names one.
    ///
    /// A render normally reads the real library, which is what makes the picture worth taking.
    /// A picture published in the repository must not carry somebody's call history or their
    /// colleagues' names, so `CALL_RECORDER_PREVIEW_HOME` points the model at a throwaway
    /// directory instead. It is honored only in preview mode, so a normal launch cannot be
    /// redirected by the variable.
    private static func previewHomeDirectory() -> URL? {
        guard isPreviewMode,
              let path = ProcessInfo.processInfo.environment["CALL_RECORDER_PREVIEW_HOME"],
              !path.isEmpty
        else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    /// The identifier the installed app writes under, so a render can find it without a bundle.
    private static let productionIdentifier = "local.callrecorder.app"
    private let defaults = preferences()

    private var artifactRecovery: ArtifactRecovery {
        ArtifactRecovery(
            directory: applicationDirectory.appending(
                path: "Recently Deleted",
                directoryHint: .isDirectory
            ),
            recordingsRoot: URL(filePath: settings.outputDirectory, directoryHint: .isDirectory),
            retention: 24 * 60 * 60
        )
    }

    private var transcriptRevisionManager: TranscriptRevisionManager {
        TranscriptRevisionManager(
            root: applicationDirectory.appending(
                path: "Transcript Revisions",
                directoryHint: .isDirectory
            )
        )
    }

    init() {
        let applicationDirectory = Self.previewHomeDirectory()
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/CallRecorder", directoryHint: .isDirectory)
        self.applicationDirectory = applicationDirectory
        modelManager = ModelManager(
            directory: applicationDirectory.appending(path: "models/whisper"),
            // Whisper models keep one record of what has been verified.
            manifestURL: applicationDirectory.appending(path: "models/manifest.json")
        )
        // The components beside them keep another: a model that is one file and a model that is
        // five are not the same shape, and a shared record would have to describe both.
        supportingManager = SupportingModelManager(applicationDirectory: applicationDirectory)
        // Watch every window, so windows opened from menus or the Window menu also come forward.
        WindowPresentation.startObservingWindows()
        if
            let data = defaults.data(forKey: Self.settingsKey),
            let stored = try? JSONDecoder().decode(AppSettings.self, from: data)
        {
            settings = stored
        } else {
            settings = .default
        }
        startAtLoginEnabled = defaults.object(
            forKey: Self.startAtLoginKey
        ) as? Bool ?? true
        errorDetails = defaults.string(forKey: "last-error")
        whisperVersion = defaults.string(forKey: Self.whisperVersionKey)
        let localStore = try? CallStore(path: applicationDirectory.appending(path: "calls.db").path)
        let tools = ToolLocator.standard
        store = localStore
        if
            let localStore,
            let ffmpeg = tools.locate("ffmpeg"),
            let ffprobe = tools.locate("ffprobe")
        {
            pipeline = CallPipeline(
                store: localStore,
                finalizer: MediaFinalizer(ffmpeg: ffmpeg, ffprobe: ffprobe)
            )
        } else {
            pipeline = nil
        }
        indexer = IndexerClient.standard(applicationDirectory: applicationDirectory)
        let backgroundFinalization = BackgroundAudioFinalization(
            store: localStore,
            pipeline: pipeline
        )
        self.backgroundFinalization = backgroundFinalization
        Task {
            await backgroundFinalization.setOnChange { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleBackgroundStateChange(state)
                }
            }
        }
        updateStartAtLogin()
        Task {
            await loadMetadata()
            // Preview mode stops here. Everything below either watches the microphone, writes
            // to the database, or talks to the network, and a layout review needs none of it.
            if Self.isPreviewMode { return }
            await processor?.start()
            startSpeakerReviewRequestPolling()
            observeSessionUnlock()
            // Two repairs run here, and this is the order they have to run in.
            //
            // Cleanup removes a call's working folder once its transcript is promoted. Where the
            // row was not repointed at the promoted file first, it went on naming the removed
            // folder and Open on that row did nothing. The file is written back from the saved
            // text, which is also what gives the second repair a file to read: a merge or an edit
            // made outside the app can leave a transcript naming someone who is no longer a
            // separate person, and that line cannot be corrected in a file that is not there.
            await restoreMissingTranscriptFilesNow(announceWhenClean: false)
            await refreshStaleTranscriptHeadersNow(announceWhenClean: false)
            // Fourth, and last of the housekeeping, because it is the only one that removes rather
            // than writes. It runs after the restore above so a call whose file was just written
            // back is judged once, and it does nothing at all when every file holds speech, which
            // is the ordinary case: the test reads the text the row already carries.
            _ = await removeTranscriptsWithNoSpeech()
            // Last of the three, and after both, because a transcript with no file on disk cannot
            // show a correction and a header written before a name changed is a separate fault.
            // This one rewrites files that already exist, so it runs only when the glossary it
            // was written under has changed since the library was last repaired.
            await reapplyTranscriptRulesIfNeeded()
            // Fifth: close the queue rows that no longer owe anything.
            //
            // It runs after the repairs above, because those are what leave a row behind when they
            // index a call themselves, and it must run after the pipeline started so it cannot
            // close a job the processor is working on.
            await settleCompletedIndexingJobsNow()
            activityMonitor.start { [weak self] isActive in
                self?.microphoneActivityChanged(isActive)
            }
            // These used to run from the menu bar label's onAppear, which macOS does not
            // call until the menu is first drawn. Automatic model updates waited for a click
            // that might never come, so they start here instead.
            startFromLaunchArgumentIfNeeded()
            startModelMaintenance()
            Logger(subsystem: "local.callrecorder.app", category: "models")
                .notice("launch setup reached the model maintenance step")
        }
    }

    var menuBarSymbol: String {
        switch recorderState.phase {
        case .idle: "waveform"
        case .recording: "record.circle.fill"
        case .paused: "pause.circle.fill"
        case .finalizing: "waveform.badge.checkmark"
        case .awaitingParticipants: "person.2"
        case .transcribing: "text.bubble"
        case .indexing: "magnifyingglass"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var statusLabel: String {
        switch recorderState.phase {
        case .idle: "Ready"
        case .recording: "Recording"
        case .paused: "Paused"
        case .finalizing: "Saving Audio"
        case .awaitingParticipants: "Add Participants"
        case .transcribing: "Transcribing"
        case .indexing: "Indexing"
        // A short state word, not the sentence. The popover draws this on the status line and
        // then repeats the reason in the card under it, so returning the message here printed
        // the same sentence twice in the space a user reads first.
        case .failed: "Needs attention"
        }
    }

    /// What the current stage is doing, for the line under the header while a call is processed.
    ///
    /// The stage comes from the job itself, so the popover says "Detecting speakers" rather than
    /// the phase name it already shows in the header. When the job is not readable the phase's
    /// own wording is the honest fallback.
    var processingDetail: String {
        guard let activeCallID,
              let stage = processingJobs.first(where: { $0.callID == activeCallID })?.stage
        else {
            switch recorderState.phase {
            case .finalizing: return "Writing the audio file"
            case .transcribing: return ProcessingStage.transcribing.displayDetail
            case .indexing: return ProcessingStage.indexing.displayDetail
            default: return "Working"
            }
        }
        return stage.displayDetail
    }

    var availableMicrophones: [AudioInputDevice] {
        AudioCaptureSession.availableMicrophones()
    }

    var selectedMicrophoneID: String {
        get {
            AudioCaptureSession.resolvedMicrophoneID(
                availableIDs: availableMicrophones.map(\.id),
                selectedID: settings.selectedMicrophoneID
            ) ?? ""
        }
        set { settings.selectedMicrophoneID = newValue.isEmpty ? nil : newValue }
    }

    var canRetryPendingCall: Bool {
        recorderState.phase == .failed && activeCallID != nil && finalizedAudioURL != nil
    }

    var backgroundSavingCount: Int {
        backgroundState.pendingCalls.count
    }

    var backgroundFailures: [BackgroundFinalizationFailure] {
        backgroundState.failures
    }

    func start() {
        Task { await beginRecording(automatic: false) }
    }

    func startFromLaunchArgumentIfNeeded() {
        guard
            !launchStartConsumed,
            ProcessInfo.processInfo.arguments.contains("--start-recording")
        else { return }
        launchStartConsumed = true
        start()
    }

    func pause() {
        captureQueue.enqueue { [weak self] in await self?.pauseRecording() }
    }

    func resume() {
        captureQueue.enqueue { [weak self] in await self?.resumeRecording() }
    }

    func stop() {
        captureQueue.enqueue { [weak self] in await self?.stopRecording(automatic: false) }
    }

    /// Saves the participants shown in the Participants window and says what happened.
    /// A finished call is updated in place; a call that is still waiting for participants is
    /// queued for processing. A save with nowhere to go returns a message instead of doing
    /// nothing, because a button that silently does nothing reads as broken.
    @discardableResult
    func saveParticipants() async -> String? {
        if let callID = participantEditingCallID {
            return await saveParticipants(for: callID)
        }
        guard recorderState.phase == .awaitingParticipants else {
            return "This recording is no longer waiting for participants."
                + " Pick the call under Recent, then edit its participants."
        }
        errorMessage = nil
        await queueCurrentCall()
        return errorMessage
    }

    func saveParticipantSelection() {
        Task { _ = await saveParticipants() }
    }

    /// Remembers which call the Participants window edits, so saving reaches that call.
    func editParticipants(for call: RecentCallSummary) {
        participantEditingCallID = call.id
        Task {
            guard let store else { return }
            let existing = (try? await store.participants(for: call.id)) ?? []
            selectedParticipantIDs = Set(existing.map(\.id))
        }
    }

    /// Clears the edited call so a later save cannot write to the wrong call.
    func finishEditingParticipants() {
        participantEditingCallID = nil
    }

    func saveParticipantSelection(for callID: CallID) {
        Task { _ = await saveParticipants(for: callID) }
    }

    /// Updates one finished call: participants, transcript header, and the participant list.
    @discardableResult
    func saveParticipants(for callID: CallID) async -> String? {
        guard let store else { return "The local database could not be opened." }
        var priorParticipantIDs: [ParticipantID]?
        var revision: TranscriptRevision?
        do {
            priorParticipantIDs = try await store.participants(for: callID).map(\.id)
            try await store.setParticipants(Array(selectedParticipantIDs), for: callID)
            revision = try await refreshTranscriptParticipants(
                callID: callID,
                store: store,
                revisionManager: transcriptRevisionManager
            )
            try await refreshMetadata(from: store)
            return nil
        } catch {
            if let revision { try? transcriptRevisionManager.restore(revision) }
            if let priorParticipantIDs {
                try? await store.setParticipants(priorParticipantIDs, for: callID)
            }
            report(error, context: "Save Call Participants")
            return errorMessage ?? "The participants could not be saved."
        }
    }

    func retryPendingCall() {
        guard recorderState.phase == .failed, let activeCallID else { return }
        captureQueue.enqueue { [weak self] in
            guard let self else { return }
            apply(.recover)
            apply(.restorePendingSession(sessionID: SessionID(rawValue: activeCallID.rawValue)))
            await queueCurrentCall()
        }
    }

    /// Leaves the failed recording and returns the app to idle.
    ///
    /// The popover offers a retry only when the audio survived. Every other failure — a missing
    /// encoder, an unwritable folder — left the app in a state whose only button was a retry its
    /// own guard refuses, so the way to record again was to open Settings and find Recovery.
    ///
    /// When any part of the call survived, this is the same discard the other phases offer: the
    /// audio and its working files move to Recently Deleted for 24 hours instead of being
    /// destroyed. When nothing survived — the failure happened before a call existed — there is
    /// no file to keep and the state is simply cleared, which the reducer has always allowed and
    /// no screen ever asked for.
    func dismissFailure() {
        Task { await dismissFailureNow() }
    }

    private func dismissFailureNow() async {
        guard recorderState.phase == .failed else { return }
        if activeCallID != nil, activeSessionDirectory != nil || finalizedAudioURL != nil {
            await discardCurrentCall()
        } else {
            clearRecordingContext()
            apply(.discard)
        }
        errorMessage = nil
        errorDetails = nil
    }

    /// Clears a failure the audio did not survive and starts a new recording.
    ///
    /// The user is on the popover because a call went wrong while they were working, so the useful
    /// answer is the record button rather than a message about the button. If the cause is still
    /// there the new attempt fails the same way and says the same thing, which costs one line on
    /// screen and saves the trip through Settings either way.
    func startOverFromFailure() {
        Task {
            await dismissFailureNow()
            guard recorderState.phase == .idle else { return }
            await beginRecording(automatic: false)
        }
    }

    /// The per-recording state that belongs to the call now on screen.
    private func clearRecordingContext() {
        activeCallID = nil
        finalizedAudioURL = nil
        activeSessionDirectory = nil
        capturedSegments = []
        nextSegmentIndex = 1
        selectedParticipantIDs.removeAll()
        recordingStartedAt = nil
        recordedSecondsBeforePause = 0
        recordingPausedAt = nil
    }

    func discard() {
        Task { await discardCurrentCall() }
    }

    /// Starts the popover's clock on the message just written, and stops it again on its own.
    ///
    /// The delay is long enough to read the sentence and finish looking at the row it is about, and
    /// short enough that a message cannot be mistaken for something that is still true an hour
    /// later. A second message replaces the first and restarts the clock.
    private func stampRecoveryMessage() {
        guard recoveryMessage != nil else {
            recoveryMessageAt = nil
            return
        }
        let stamp = Date()
        recoveryMessageAt = stamp
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            // Only the clock is cleared, and only if nothing newer has taken its place, so a
            // message written while this one was showing keeps its own full time on screen.
            if recoveryMessageAt == stamp { recoveryMessageAt = nil }
        }
    }

    /// Records that something was refused, and says why.
    ///
    /// The sentence may carry a redacted technical detail after a blank line, which is what a
    /// person copies into a report. The popover shows only the reason; the whole text is what
    /// Settings keeps.
    private func announceProblem(_ message: String) {
        recoveryMessage = message
        recoveryOutcome = .problem
    }

    func copyErrorDetails() {
        guard let errorDetails else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(errorDetails, forType: .string)
    }

    func retryBackgroundSave(for callID: CallID) {
        Task { await backgroundFinalization.retryFailed(callID) }
    }

    func copyBackgroundSaveError(for callID: CallID) {
        guard let failure = backgroundFailures.first(where: { $0.job.callID == callID }) else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(failure.message, forType: .string)
    }

    func confirmSpeaker(_ review: SpeakerReviewItem, participantID: ParticipantID) {
        Task {
            if let failure = await confirmSpeakerReview(review, participantID: participantID) {
                speakerReviewFailure = failure
            }
        }
    }

    func keepSpeakerUnknown(_ review: SpeakerReviewItem) {
        Task {
            if let failure = await keepSpeakerReviewUnknown(review) {
                speakerReviewFailure = failure
            }
        }
    }

    /// Moves the lines of one excerpt onto a person, whatever voice they were detected as.
    ///
    /// Detection returns whole voices, and a real call defeats it: two people on one headset come
    /// back as one voice and that voice is offered one name. The people who share it can be told
    /// apart by reading what they said, so this is the answer the window was missing.
    func assignSpeakerExcerpt(
        _ review: SpeakerReviewItem,
        excerpt: SpeakerReviewPlayback.Excerpt,
        participantID: ParticipantID
    ) {
        Task { await assignSpeakerExcerpt(review, excerpt: excerpt, participantID: participantID) }
    }

    func clearSpeakerExcerpt(_ review: SpeakerReviewItem, excerpt: SpeakerReviewPlayback.Excerpt) {
        Task { await clearSpeakerExcerpt(review, excerpt: excerpt) }
    }

    private func assignSpeakerExcerpt(
        _ review: SpeakerReviewItem,
        excerpt: SpeakerReviewPlayback.Excerpt,
        participantID: ParticipantID
    ) async {
        guard let store else { return }
        guard movingLineRanges.insert(excerpt.id).inserted else { return }
        defer { movingLineRanges.remove(excerpt.id) }
        do {
            try await store.saveSpeakerLineOverride(
                callID: review.callID,
                startMs: excerpt.startMs,
                endMs: excerpt.endMs,
                participantID: participantID
            )
            try await applyLineOverrides(callID: review.callID, store: store)
        } catch {
            report(error, context: "Speaker Line Assignment", category: .processing)
            speakerReviewFailure = Self.speakerReviewMessage(
                for: error,
                detail: DiagnosticsReporter.redacted(error: String(reflecting: error))
            )
        }
        await refreshSpeakerReviewEvidence()
    }

    private func clearSpeakerExcerpt(
        _ review: SpeakerReviewItem,
        excerpt: SpeakerReviewPlayback.Excerpt
    ) async {
        guard let store else { return }
        guard movingLineRanges.insert(excerpt.id).inserted else { return }
        defer { movingLineRanges.remove(excerpt.id) }
        do {
            try await store.removeSpeakerLineOverride(
                callID: review.callID,
                startMs: excerpt.startMs,
                endMs: excerpt.endMs
            )
            try await applyLineOverrides(callID: review.callID, store: store)
        } catch {
            report(error, context: "Speaker Line Assignment", category: .processing)
        }
        await refreshSpeakerReviewEvidence()
    }

    private func applyLineOverrides(callID: CallID, store: CallStore) async throws {
        _ = try await rewriteTranscript(
            callID: callID,
            store: store,
            renamingVoiceAt: nil,
            to: nil
        )
        try await refreshMetadata(from: store)
        await finalizeReviewedCallIfReady(callID, store: store)
    }

    /// The excerpts whose assignment is being written, so a second press cannot overlap the first.
    func isMovingSpeakerExcerpt(_ excerpt: SpeakerReviewPlayback.Excerpt) -> Bool {
        movingLineRanges.contains(excerpt.id)
    }

    func dismissSpeakerReviewFailure() {
        speakerReviewFailure = nil
    }

    func refreshSpeakerReviews() async {
        // A seeded card is put there by the renderer, and the window refreshes the list when it
        // appears, which would clear it and draw an empty queue over the state being reviewed.
        if previewSeededReviewCard { return }
        await refreshSpeakerAnalysisIssues()
        if speakerStore == nil {
            await retryVoiceIdentityNow()
        }
        guard let speakerStore else {
            speakerReviews = []
            return
        }
        do {
            speakerReviews = try await speakerStore.unresolvedReviews()
            await refreshSpeakerReviewEvidence()
        } catch {
            report(error, context: "Speaker Review Refresh", category: .database)
        }
    }

    func refreshSpeakerReviewEvidence() async {
        guard let store else {
            speakerReviewEvidence = [:]
            return
        }
        var evidence: [SpeakerClusterID: SpeakerReviewPlayback.Evidence] = [:]
        var dates: [CallID: Date] = [:]
        for (callID, reviews) in Dictionary(grouping: speakerReviews, by: \.callID) {
            do {
                guard
                    let call = try await store.call(id: callID),
                    let transcript = try await store.transcript(for: callID)
                else { continue }
                dates[callID] = call.startedAt
                let document = try JSONDecoder().decode(
                    NormalizedTranscript.self,
                    from: Data(contentsOf: URL(filePath: transcript.jsonPath))
                )
                let callDirectory = call.audioPath
                    .map { URL(filePath: $0).deletingLastPathComponent() }
                    ?? URL(filePath: transcript.jsonPath).deletingLastPathComponent()
                for review in reviews {
                    evidence[review.clusterID] = SpeakerReviewPlayback.evidence(
                        for: review,
                        transcript: document,
                        callDirectory: callDirectory,
                        recoverableArtifacts: recoverableArtifacts,
                        fileExists: { FileManager.default.fileExists(atPath: $0.path) }
                    )
                }
                let overrides = (try? await store.speakerLineOverrides(callID: callID)) ?? []
                for review in reviews {
                    evidence[review.clusterID]?.overrides = overrides
                }
            } catch {
                report(error, context: "Speaker Review Evidence", category: .processing)
            }
        }
        speakerReviewEvidence = evidence
        speakerReviewCallDates = dates
    }

    func voiceProfileSummary(for participantID: ParticipantID) -> VoiceProfileSummary? {
        voiceProfileSummaries.first { $0.participantID == participantID }
    }

    func resetVoiceProfile(for participantID: ParticipantID) {
        Task { await resetVoiceProfileNow(for: participantID) }
    }

    func restoreVoiceProfile(for participantID: ParticipantID) {
        Task { await restoreVoiceProfileNow(for: participantID) }
    }

    func retryVoiceIdentity() {
        Task { await retryVoiceIdentityNow() }
    }

    /// Re-reads the Screen Recording grant.
    ///
    /// macOS reads the grant when a process starts, so a permission turned on while the app is
    /// running does not take effect until it restarts. Re-reading is still worth doing, because it
    /// is what turns the card's own claim into a fact: the user who grants it and comes back sees
    /// whether the system has accepted it, instead of being told to restart with no way to check.
    func refreshScreenRecordingPermission() {
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    /// Opens the Screen Recording pane of System Settings.
    ///
    /// The card cannot grant the permission, and a sentence telling the user to find a pane by hand
    /// is a sentence that loses them. This lands on the exact pane.
    func openScreenRecordingSettings() {
        guard let url = URL(string: ScreenRecordingPermission.settingsURL) else { return }
        NSWorkspace.shared.open(url)
    }

    /// The login keychain locks with the screen, so reading the voiceprint key fails while the
    /// Mac is locked and works again after the user comes back. Retrying on unlock saves a manual
    /// click and heals a session that started before the first unlock.
    private func observeSessionUnlock() {
        guard sessionUnlockObserver == nil else { return }
        sessionUnlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.speakerStore == nil else { return }
                self.retryVoiceIdentity()
            }
        }
    }

    func checkSpeakerRuntime() async {
        guard !checkingSpeakerRuntime else { return }
        checkingSpeakerRuntime = true
        defer { checkingSpeakerRuntime = false }
        do {
            guard let diarizer else { throw DiarizerError.runtimeUnavailable }
            let check = Diarizer(python: diarizer.python, script: diarizer.script, timeout: 60)
            try await Task.detached { try check.check() }.value
            speakerRuntimeMessage = "Local speaker model is ready."
        } catch {
            speakerRuntimeMessage = error.localizedDescription
            report(error, context: "Speaker Runtime Check", category: .models)
        }
    }

    func chooseSpeakerPython() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Python executable with pyannote.audio installed"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        panel.prompt = "Use Environment"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !Self.isPreviewMode else { return }
        defaults.set(url.path, forKey: "speaker-python")
        Task { await checkSpeakerRuntime() }
    }

    func retrySpeakerAnalysis(for callID: CallID) async {
        guard let store else { return }
        do {
            if let item = try artifactRecovery.items().first(where: { $0.callID == callID }) {
                try artifactRecovery.restore(item.callID)
            }
            try await store.retrySpeakerAnalysis(callID: callID)
            try await refreshMetadata(from: store)
            await processor?.processNext()
        } catch {
            report(error, context: "Retry Speaker Detection", category: .processing)
        }
    }

    func openTranscript(for callID: CallID) {
        Task {
            guard let store else { return }
            do {
                guard let record = try await store.transcriptFileRecord(for: callID) else { return }
                let recorded = URL(filePath: record.markdownPath)
                if !record.markdownPath.isEmpty,
                    FileManager.default.fileExists(atPath: recorded.path) {
                    NSWorkspace.shared.open(recorded)
                    return
                }
                // The row outlived its file: cleanup removed the working folder the path named
                // and the row was never repointed at the promoted file. Writing the file back
                // is what makes Open do what the row says, and the saved text is enough to
                // rebuild it.
                switch await restoreTranscriptFile(for: record, store: store) {
                case let .writtenBack(url), let .repointed(url):
                    NSWorkspace.shared.open(url)
                case .noSpeech:
                    announceProblem(
                        "This call captured no speech, so there is no transcript file to open. "
                            + "The row stays, and Copy still takes the saved text."
                    )
                case .failed:
                    announceProblem(
                        "The transcript file for this call could not be written back. "
                            + "The detail is in the Recovery pane."
                    )
                }
            } catch { report(error, context: "Open Transcript") }
        }
    }

    private func refreshSpeakerAnalysisIssues() async {
        guard let store else { return }
        do {
            let jobs = try await store.processingJobs()
            let events = try await store.recentProcessingEvents(limit: 100)
            let recovery = try artifactRecovery.items()
            var issues: [SpeakerAnalysisIssue] = []
            for call in try await store.recentCalls(limit: 50) where call.hasTranscript {
                guard let record = try await store.transcript(for: call.id),
                      let storedCall = try await store.call(id: call.id) else { continue }
                let document = try JSONDecoder().decode(
                    NormalizedTranscript.self, from: Data(contentsOf: URL(filePath: record.jsonPath))
                )
                let job = jobs.first { $0.callID == call.id }
                guard document.needsSpeakerDetection || (job?.stage == .diarizing && job?.executionState == .failed) else { continue }
                let directory = storedCall.audioPath.map { URL(filePath: $0).deletingLastPathComponent() }
                let name = document.segments.contains { $0.source == .system } ? "system.m4a" : "call.m4a"
                let candidates = [directory?.appending(path: name),
                    recovery.first { $0.callID == call.id }?.payloadDirectory.appending(path: name)]
                let hasAudio = candidates.compactMap { $0 }.contains { FileManager.default.fileExists(atPath: $0.path) }
                let busy = job?.executionState == .pending || job?.executionState == .running
                let event = events.first { $0.callID == call.id && $0.stage == .diarizing }
                issues.append(SpeakerAnalysisIssue(
                    callID: call.id, startedAt: call.startedAt, canRetry: hasAudio && !busy,
                    audioAvailable: hasAudio,
                    message: busy ? "Detecting speakers…" : hasAudio
                        ? "Speaker detection failed. Audio and text are safe."
                        : "Speaker labels are missing. The original audio is no longer available.",
                    details: event?.details ?? event?.summary
                ))
            }
            speakerAnalysisIssues = issues
        } catch { report(error, context: "Speaker Analysis Status", category: .processing) }
    }

    func addParticipant(_ name: String) async {
        guard let store else { return }
        do {
            let participant = try await store.upsertParticipant(name: name)
            participants = try await store.listParticipants()
            selectedParticipantIDs.insert(participant.id)
        } catch {
            report(error, context: "Participant Add")
        }
    }

    /// Adds a person with the profile details in one step, so role, company, and email can be
    /// captured while the user still has them. Returns nil when the save failed.
    @discardableResult
    func createParticipant(
        name: String,
        role: String,
        company: String,
        email: String
    ) async -> Participant? {
        guard let store else { return nil }
        do {
            let created = try await store.upsertParticipant(name: name)
            let hasProfile = !role.isEmpty || !company.isEmpty || !email.isEmpty
            let participant = hasProfile
                ? try await store.updateParticipant(
                    id: created.id, name: name, role: role, company: company, email: email
                )
                : created
            participants = try await store.listParticipants()
            selectedParticipantIDs.insert(participant.id)
            return participant
        } catch {
            report(error, context: "Participant Add")
            return nil
        }
    }

    func updateParticipant(
        _ participant: Participant,
        name: String,
        role: String,
        company: String,
        email: String
    ) async -> Bool {
        guard let store else { return false }
        do {
            _ = try await store.updateParticipant(
                id: participant.id,
                name: name,
                role: role,
                company: company,
                email: email
            )
            participants = try await store.listParticipants()
            return true
        } catch {
            report(error, context: "Participant Update")
            return false
        }
    }

    func copyTranscript(for call: RecentCallSummary) {
        guard call.hasTranscript, let store else { return }
        Task {
            do {
                let record = try await store.transcript(for: call.id)
                let markdown = record.flatMap { record in
                    try? String(contentsOf: URL(filePath: record.markdownPath), encoding: .utf8)
                }
                let transcript: String?
                if let markdown {
                    transcript = markdown
                } else {
                    transcript = try await store.transcriptText(for: call.id)
                }
                guard let transcript else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(transcript, forType: .string)
                copiedTranscriptCallID = call.id
                try? await Task.sleep(for: .seconds(2))
                if copiedTranscriptCallID == call.id { copiedTranscriptCallID = nil }
            } catch {
                report(error, context: "Copy Transcript")
            }
        }
    }

    func addGlossaryTerm(preferred: String, aliases: [String]) async {
        guard let store else { return }
        do {
            _ = try await store.upsertGlossaryTerm(preferred: preferred, aliases: aliases)
            glossary = try await store.listGlossaryTerms()
        } catch {
            report(error, context: "Vocabulary Update")
        }
    }

    func deleteGlossaryTerm(_ term: GlossaryTerm) async {
        guard let store else { return }
        do {
            try await store.deleteGlossaryTerm(id: term.id)
            glossary = try await store.listGlossaryTerms()
        } catch {
            report(error, context: "Vocabulary Delete")
        }
    }

    /// Refreshes the model files on launch and then every few hours.
    ///
    /// A model file is only read while a call is being transcribed, so the pass stands aside
    /// whenever that is happening. The check costs a few short requests; a download only starts
    /// when a published hash differs from the hash recorded for the installed file.
    func startModelMaintenance() {
        Logger(subsystem: "local.callrecorder.app", category: "models")
            .notice("model maintenance requested")
        setModelManagerBusyGuard()
        guard modelMaintenanceTask == nil else { return }
        modelMaintenanceTask = Task { [weak self] in
            // Let the app finish starting up before touching the network.
            try? await Task.sleep(for: .seconds(90))
            while !Task.isCancelled {
                guard let self else { return }
                if self.settings.automaticModelUpdatesEnabled {
                    await self.modelManager.performAutomaticPass()
                    await self.supportingManager.performAutomaticPass()
                }
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    /// Tells the model manager when the app is using a model file.
    private func setModelManagerBusyGuard() {
        modelManager.isBusy = { [weak self] in
            guard let self else { return true }
            return self.isModelInUse
        }
        supportingManager.isBusy = { [weak self] in
            guard let self else { return true }
            return self.isModelInUse
        }
    }

    /// The folder holding the local embedding model that transcript search uses.
    var embeddingModelDirectory: URL {
        applicationDirectory.appending(path: "models/embeddinggemma")
    }

    /// Whether the embedding model is installed and complete.
    ///
    /// The manager answers from the files themselves. A folder that merely exists used to count as
    /// installed, so a download that stopped half way read as ready.
    var embeddingModelIsInstalled: Bool {
        guard let model = supportingManager.models.first else { return false }
        return supportingManager.state(for: model).isInstalled
    }

    /// The version of the whisper.cpp tool this Mac transcribes with.
    ///
    /// The tool comes from Homebrew rather than from the app, so this is the only place that says
    /// which engine is in use. It is read when the Models pane opens, because starting the tool
    /// loads a graphics back end that took fourteen seconds on this machine the first time.
    private(set) var whisperVersion: String?

    /// Where the last reading of that version is kept, so the row has an answer to show before
    /// the tool has been started again.
    private static let whisperVersionKey = "last-whisper-version"

    /// Where the tool was found, so the row can name the install rather than describe it.
    var whisperCLIPath: String? {
        ToolLocator.standard.locate("whisper-cli")?.path
    }

    func refreshWhisperVersion() async {
        guard let executable = ToolLocator.standard.locate("whisper-cli") else {
            whisperVersion = nil
            return
        }
        whisperVersion = await Task.detached { WhisperCLIVersion.read(from: executable) }.value
        // A render reads the real preferences but must not write to them, or taking a picture
        // would change the settings of the installed app.
        if let whisperVersion, !Self.isPreviewMode {
            defaults.set(whisperVersion, forKey: Self.whisperVersionKey)
        }
    }

    /// The version to show for the tool.
    ///
    /// What the tool answered when it was last asked, or, until then, the version written in the
    /// install path it was found at. The second is instant, so the row has an answer to show on a
    /// Mac that has never opened this pane before.
    var whisperVersionLabel: String? {
        whisperVersion
            ?? whisperCLIPath.flatMap { WhisperCLIVersion.fromInstallPath(URL(filePath: $0)) }
    }

    /// True while a recording is running or a transcript is being produced.
    ///
    /// These are the phases that read the model files or put a recording at risk. Waiting for a
    /// person to choose participants is not one of them: nothing is reading the models then.
    var isModelInUse: Bool {
        switch recorderState.phase {
        case .recording, .paused, .finalizing, .transcribing, .indexing: true
        case .idle, .awaitingParticipants, .failed: false
        }
    }

    func refreshMetadata() async {
        guard let store else {
            errorMessage = "The local database could not be opened."
            return
        }
        do {
            try await refreshMetadata(from: store)
        } catch {
            report(error, context: "Metadata Refresh", category: .database)
        }
    }

    /// Closes queued indexing jobs whose index has already been built.
    ///
    /// A repair that rewrites and re-indexes a saved transcript does the whole job the queue was
    /// waiting for, and used to leave the row behind. The queue then reported work that was
    /// finished, which is what put 47 calls in the Recovery pane as still processing, and draining
    /// that queue would have re-read every transcript only to fail on the stage after indexing for
    /// every call whose audio had already been cleaned up. The count is logged so the repair is
    /// visible from outside the app, and a failure here is reported rather than swallowed: it is
    /// housekeeping, not a reason to stop the launch.
    private func settleCompletedIndexingJobsNow() async {
        guard let store else { return }
        do {
            let settled = try await store.settleCompletedIndexingJobs()
            guard settled > 0 else { return }
            Logger(subsystem: "local.callrecorder.app", category: "recovery")
                .notice("closed \(settled, privacy: .public) indexing job(s) whose index was already built")
            processingJobs = try await store.processingJobs()
        } catch {
            report(error, context: "Settle Indexing Jobs", category: .recovery)
        }
    }

    func retryProcessing(_ job: ProcessingJob) async {
        guard let store else { return }
        do {
            try await store.retryProcessingJob(callID: job.callID)
            processingJobs = try await store.processingJobs()
            recoveryMessage = "Retry queued."
            await processor?.processNext()
        } catch {
            report(error, context: "Retry Processing", category: .recovery)
        }
    }

    /// Ends the stage that is running now.
    ///
    /// The stage ends its own process, and the job goes back to the queue with the audio and every
    /// finished stage intact. Nothing starts again on its own: a stage that was stopped for being
    /// stuck should not quietly begin again, so the popover carries the retry instead.
    func stopProcessing() {
        guard stoppableCallID != nil, let stageCancellation else { return }
        stageCancellation.cancel()
    }

    /// Starts the stopped call again, from the stage it was stopped at.
    func retryStoppedProcessing() {
        guard stoppedProcessingCallID != nil else { return }
        stoppedProcessingCallID = nil
        Task { await processor?.processNext() }
    }

    func dismissStoppedProcessing() {
        stoppedProcessingCallID = nil
    }

    /// Remembers a stage the user stopped, so the popover can offer the way back to it.
    private func processingStageWasCancelled(_ callID: CallID) async {
        stoppedProcessingCallID = callID
    }

    func runDatabaseCheck() async {
        guard let store else { return }
        do {
            let integrity = try await store.integrityReport()
            recoveryMessage = integrity.isHealthy
                ? "Database check passed."
                : "Database check found \(integrity.foreignKeyViolations.count) foreign-key issue(s)."
        } catch {
            report(error, context: "Database Check", category: .database)
        }
    }

    func createDatabaseBackup() async {
        guard let store else { return }
        do {
            let backup = try await store.createBackup(
                in: applicationDirectory.appending(path: "Backups", directoryHint: .isDirectory)
            )
            recoveryMessage = "Backup created: \(backup.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([backup])
        } catch {
            report(error, context: "Database Backup", category: .database)
        }
    }

    func exportDiagnostics() async {
        guard let store else { return }
        do {
            let directory = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Desktop/Call Recorder Diagnostics", directoryHint: .isDirectory)
            let version = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "development"
            let models = modelManager.models.compactMap { model in
                modelManager.state(for: model) == .installed ? model.id : nil
            }
            let archive = try await DiagnosticsReporter.exportBundle(
                store: store,
                appVersion: version,
                modelVersions: models,
                to: directory
            )
            recoveryMessage = "Diagnostics exported: \(archive.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([archive])
        } catch {
            report(error, context: "Diagnostics Export", category: .recovery)
        }
    }

    /// Waits until the first read of the database has finished, or the deadline passes.
    ///
    /// Anything that runs outside the app's own startup, such as a repair started from the
    /// terminal, has to wait for that read. Otherwise it works from an empty library and reports
    /// success for having changed nothing.
    func waitForMetadata(timeout: TimeInterval = 30) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !metadataIsLoaded, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// What one pass of the glossary repair did.
    ///
    /// Returned rather than written straight to the surface, because the pass now runs for two
    /// callers that want opposite things from it: a button, which must always say what happened,
    /// and a launch, which is housekeeping and must stay silent unless it changed something.
    struct GlossaryRepairOutcome {
        let callsVisited: Int
        let changedCalls: Int
        let corrections: Int
        let failures: Int
        /// Lines the pass removed because the model wrote them and nobody said them.
        let artifactsRemoved: Int
        /// Transcripts the pass rewrote only to drop the glossary line an earlier version wrote.
        let glossaryLinesRemoved: Int
        /// Printed time ranges taken off the front of transcript paragraphs.
        let timestampsStripped: Int
        /// Turns joined into the paragraph above them, which is layout and not speech.
        let foldedLines: Int
        /// Calls whose search index was rebuilt from the corrected text.
        let reindexed: Int

        var didChange: Bool { changedCalls > 0 }
    }

    /// Rewrites the saved transcripts when the glossary they were written under has changed.
    ///
    /// A term added through the Vocabulary pane or through MCP changes how future audio is
    /// decoded and nothing else, so every call already on disk keeps the spelling the model
    /// produced. A keyword search for the real name then returns nothing while reporting
    /// success. The repair existed but ran only when someone found the button, which meant a
    /// glossary could be improved and the library never learn about it.
    ///
    /// The rules that were applied are recorded, so the work is done once per change rather than
    /// on every start. This is the only repair here that rewrites files that already exist, and
    /// it is guarded against preview mode for that reason: a layout render reads the real
    /// library and must never write to it.
    /// Runs the pass when either rule set has moved: a glossary the library has not seen, or a
    /// not-speech rule it has not been cleaned with.
    ///
    /// One pass rather than two, because both rewrite the same files and both back them up first,
    /// so running them apart would write each transcript twice and leave two backup folders for one
    /// repair. Either rule moving is enough to make the pass worth walking the library for.
    private func reapplyTranscriptRulesIfNeeded() async {
        guard !Self.isPreviewMode, let store else { return }
        let fingerprint = GlossaryCorrector.fingerprint(of: glossary)
        let glossaryMoved = settings.appliedGlossaryFingerprint != fingerprint
        let artifactsMoved = settings.appliedArtifactRuleVersion != TranscriptArtifacts.ruleVersion
        guard glossaryMoved || artifactsMoved else { return }
        guard let outcome = await runTranscriptRepair(store: store) else { return }
        // Recorded even when nothing changed: the library and these rules now agree, and asking
        // again on the next launch would walk every transcript to learn the same thing.
        if glossaryMoved { settings.appliedGlossaryFingerprint = fingerprint }
        if artifactsMoved { settings.appliedArtifactRuleVersion = TranscriptArtifacts.ruleVersion }
        guard outcome.didChange || outcome.failures > 0 else { return }
        recoveryMessage = Self.glossaryRepairSummary(outcome)
    }

    /// What a repair changed, for the surface.
    static func glossaryRepairSummary(
        _ outcome: GlossaryRepairOutcome,
        dryRun: Bool = false
    ) -> String {
        // Nothing to do is a result, not a repair of nothing, and it is the answer most runs give.
        // Saying it in the same shape as a real repair would make every launch look like it had
        // found work to do.
        if outcome.changedCalls == 0, outcome.failures == 0 {
            return dryRun
                ? "Nothing to repair: every saved transcript already matches the glossary and the not-speech rules."
                : "Every saved transcript already matches the glossary and the not-speech rules."
        }
        let files = "transcript" + (outcome.changedCalls == 1 ? "" : "s")
        // Each count is one kind of work, and a pass can do any combination of them. Saying only
        // the first two would leave a pass that merely dropped a glossary line reporting that it
        // repaired files and changed nothing in them.
        var work: [String] = []
        if outcome.corrections > 0 {
            work.append(
                "\(outcome.corrections) spelling"
                    + (outcome.corrections == 1 ? "" : "s") + " fixed"
            )
        }
        if outcome.artifactsRemoved > 0 {
            // What a user has no other way to see. A line the model invented is invisible in a
            // long transcript, so reporting only the spellings would leave the larger half of the
            // repair unsaid.
            work.append(
                "\(outcome.artifactsRemoved) line"
                    + (outcome.artifactsRemoved == 1 ? "" : "s")
                    + " the model wrote but nobody said removed"
            )
        }
        if outcome.glossaryLinesRemoved > 0 {
            work.append(
                "the glossary line removed from \(outcome.glossaryLinesRemoved)"
                    + (outcome.glossaryLinesRemoved == 1 ? " file" : " files")
            )
        }
        if outcome.timestampsStripped > 0 {
            work.append(
                "\(outcome.timestampsStripped) printed timestamp"
                    + (outcome.timestampsStripped == 1 ? "" : "s") + " removed"
            )
        }
        if outcome.foldedLines > 0 {
            // Layout, not speech: the same words are in the file and it is shorter.
            work.append(
                "\(outcome.foldedLines) turn"
                    + (outcome.foldedLines == 1 ? "" : "s")
                    + " joined into the paragraph above"
            )
        }
        let result = work.isEmpty
            ? "no spellings and no invented lines"
            : Self.listed(work)
        let verb = dryRun ? "Would repair" : "Repaired"
        let head = "\(verb) \(outcome.changedCalls) \(files): \(result), and rebuilt the search index "
            + "for \(outcome.reindexed). "
        if dryRun {
            return head + "Nothing has been written."
        }
        return head + (outcome.failures == 0
            ? "Originals are in the Backups folder."
            : "\(outcome.failures) could not be repaired; see the repair report.")
    }

    /// Joins phrases the way a sentence reads: "a", "a and b", "a, b and c".
    private static func listed(_ phrases: [String]) -> String {
        guard let last = phrases.last else { return "" }
        guard phrases.count > 1 else { return last }
        return phrases.dropLast().joined(separator: ", ") + " and " + last
    }

    /// The line the repair report and the log carry, kept in one place so the two agree.
    static func glossaryRepairReport(
        visited: Int,
        changed: Int,
        failed: Int,
        corrections: Int,
        artifactsRemoved: Int = 0,
        glossaryLinesRemoved: Int = 0,
        timestampsStripped: Int = 0,
        foldedLines: Int = 0,
        reindexed: Int = 0
    ) -> String {
        "visited \(visited), changed \(changed), unchanged \(visited - changed - failed), "
            + "failed \(failed), corrections \(corrections), "
            + "notSpeechRemoved \(artifactsRemoved), glossaryLinesRemoved \(glossaryLinesRemoved), "
            + "timestampsStripped \(timestampsStripped), "
            + "speakerTurnsFolded \(foldedLines), "
            + "reindexed \(reindexed)"
    }

    /// Counts what a cleanup would remove without removing it.
    ///
    /// The pass behind this rewrites every file it touches, so the surface offers the count first.
    /// A repair that rewrites a whole library is not something a person should accept blind, and
    /// the count is also the answer to "is anything wrong with my transcripts at all".
    func previewTranscriptCleanup() async {
        guard let store else { return }
        recoveryMessage = "Checking every saved transcript…"
        guard let outcome = await runTranscriptRepair(store: store, dryRun: true) else { return }
        recoveryMessage = Self.glossaryRepairSummary(outcome, dryRun: true)
    }

    /// Counts the files a no-speech cleanup would remove, for the row that offers it.
    ///
    /// The row reads the count, so the count has to be current when the pane is looked at rather
    /// than only after a launch. This is the same dry run the command line uses and it writes
    /// nothing.
    func refreshNoSpeechTranscriptCount() async {
        _ = await removeTranscriptsWithNoSpeech(dryRun: true)
    }

    /// Removes the no-speech files, then says what went and where the copies are.
    func confirmRemoveEmptyTranscripts() async {
        guard let outcome = await removeTranscriptsWithNoSpeech() else { return }
        guard outcome.didChange || outcome.failed > 0 else {
            recoveryMessage = "No transcript file held only written-over silence, so nothing was removed."
            return
        }
        let files = "file" + (outcome.removed == 1 ? "" : "s")
        var message = "Removed \(outcome.removed) \(files) that held nothing but words Whisper "
            + "wrote over silence. Each was copied into the Backups folder first."
        if outcome.failed > 0 {
            message += " \(outcome.failed) could not be removed; see the empty-transcript report."
        }
        recoveryMessage = message
    }

    /// Rewrites saved transcripts with the glossary as it stands now, then re-indexes them.
    ///
    /// The glossary only ever reached the model, so text written before a term was added keeps
    /// the spelling the model produced. That is why a keyword search for a real name can return
    /// nothing: the company name is stored as the mishearing, in every chunk, from every call.
    /// Re-applying the glossary to the saved files is what makes the existing library searchable.
    ///
    /// Every file that changes is copied into the Backups folder first, so a repair can be undone
    /// by hand, and the pass is safe to run again: a transcript that already reads correctly is
    /// reported as unchanged and is not rewritten.
    /// - Parameter dryRun: Reports what the pass would change and writes nothing, including when
    ///   it is called from the Recovery button. The button never asks for one; the command line
    ///   does, so a repair over a whole library can be read before it is run.
    func reapplyGlossaryToSavedTranscripts(dryRun: Bool = false) async {
        guard let store else { return }
        guard let outcome = await runTranscriptRepair(store: store, dryRun: dryRun) else { return }
        guard !dryRun else {
            recoveryMessage = Self.glossaryRepairSummary(outcome, dryRun: true)
            return
        }
        // Both marks move with the button too. A user who repairs by hand has the library and the
        // rules in agreement, and the next launch has no reason to walk every file.
        settings.appliedGlossaryFingerprint = GlossaryCorrector.fingerprint(of: glossary)
        settings.appliedArtifactRuleVersion = TranscriptArtifacts.ruleVersion
        guard outcome.didChange || outcome.failures > 0 else {
            recoveryMessage = "Every saved transcript already matches the glossary and the not-speech rules."
            return
        }
        recoveryMessage = Self.glossaryRepairSummary(outcome)
    }

    /// One pass over the library, shared by the button and the launch check.
    ///
    /// Returns nil when the library could not be read at all, which is the one case where the
    /// caller must not record the repair as done.
    /// - Parameter dryRun: Counts what would change without copying or writing anything.
    private func runTranscriptRepair(
        store: CallStore,
        dryRun: Bool = false
    ) async -> GlossaryRepairOutcome? {
        do {
            let callIDs = try await store.callIDsWithTranscripts()
            // Prepared once for the whole library. Building it per segment cost more than the
            // correction itself and left the repair running for minutes on a warm CPU.
            let matcher = GlossaryCorrector.matcher(for: glossary)
            var changedCalls = 0
            var visitCount = 0
            var failedCalls = 0
            var artifactsRemoved = 0
            var glossaryLinesRemoved = 0
            var timestampsStripped = 0
            var foldedLines = 0
            var reindexed = 0
            var failures: [String] = []
            var changedIDs: [CallID] = []
            var backupDirectory: URL?
            for callID in callIDs {
                // One unreadable call must not stop a library-wide repair. A failure is recorded
                // and the pass continues, because the alternative is a repair that silently
                // stops partway and reports success for the part it reached.
                do {
                    guard let record = try await store.transcript(for: callID) else { continue }
                    let corrected = try correctedTranscript(record, matcher: matcher)
                    // A transcript is worth rewriting when the glossary fixed a spelling in it or
                    // when it held a line nobody said. Both counts feed the report, so a pass that
                    // only removed artefacts does not look like a pass that did nothing.
                    guard corrected.changed else { continue }
                    // A dry run stops here, before anything is copied or written, so the report can
                    // be read first. It is the difference between knowing what a repair will do and
                    // finding out after it has done it, and the pass over a full library is the one
                    // place where that matters.
                    guard !dryRun else {
                        changedCalls += 1
                        visitCount += corrected.replacements
                        artifactsRemoved += corrected.artifacts.removedLines
                        if corrected.glossaryLineRemoved { glossaryLinesRemoved += 1 }
                        timestampsStripped += corrected.timestampsStripped
                        foldedLines += corrected.foldedLines
                        continue
                    }
                    if backupDirectory == nil {
                        backupDirectory = try makeGlossaryRepairBackupDirectory()
                    }
                    guard let backupDirectory else { continue }
                    try copyIntoBackup(record, directory: backupDirectory, callID: callID)
                    try writeCorrectedTranscript(corrected, record: record)
                    try await store.saveTranscript(corrected.record, queueIndexing: true)
                    changedCalls += 1
                    visitCount += corrected.replacements
                    artifactsRemoved += corrected.artifacts.removedLines
                    if corrected.glossaryLineRemoved { glossaryLinesRemoved += 1 }
                    timestampsStripped += corrected.timestampsStripped
                    foldedLines += corrected.foldedLines
                    changedIDs.append(callID)
                } catch {
                    failedCalls += 1
                    failures.append("\(callID.rawValue.uuidString): \(error)")
                }
            }

            // Rebuild the search index now rather than only marking the calls as owing one.
            //
            // `saveTranscript` writes the corrected text and queues the work in two ways: it marks
            // the call in `index_jobs`, and it stages a processing job that the background pipeline
            // drains on the next launch. The second half is what normally does the indexing, and it
            // needs the app to run. This pass can be run from a command line with no window, and it
            // can also be the only thing that ever runs when a call was left owing a pass by an
            // earlier version and its processing job is gone. Indexing here makes the repair
            // complete on its own, so what the user searches is the text the repair wrote.
            //
            // Calls already marked as owing a pass are included, which is what brings a library
            // left behind by an earlier version back into step.
            if !dryRun, let indexer {
                var owed = Set(changedIDs)
                if let pending = try? await store.pendingIndexCallIDs() { owed.formUnion(pending) }
                for callID in owed.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
                    do {
                        try await indexer.index(callID: callID, store: store)
                        // The indexing the pipeline was queued for has just happened here, so the
                        // queue must not keep counting it as pending work. Without this the pane
                        // listed the whole repaired library as still processing, and a second
                        // pass re-read every file for work that was already done.
                        try? await store.settleIndexedProcessingJob(callID: callID)
                        reindexed += 1
                    } catch {
                        // A call whose file has gone cannot be indexed, and that is a separate
                        // fault with its own repair. It is named in the report and the pass goes
                        // on, because one missing file must not stop the rest of the library.
                        failures.append("index \(callID.rawValue.uuidString): \(error)")
                    }
                }
            }
            writeRepairReport(
                summary: Self.glossaryRepairReport(
                    visited: callIDs.count,
                    changed: changedCalls,
                    failed: failedCalls,
                corrections: visitCount,
                    artifactsRemoved: artifactsRemoved,
                    glossaryLinesRemoved: glossaryLinesRemoved,
                    timestampsStripped: timestampsStripped,
                    foldedLines: foldedLines,
                    reindexed: reindexed
                ),
                failures: failures,
                directory: backupDirectory
            )
            if changedCalls > 0 { await refreshMetadata() }
            return GlossaryRepairOutcome(
                callsVisited: callIDs.count,
                changedCalls: changedCalls,
                corrections: visitCount,
                failures: failedCalls,
                artifactsRemoved: artifactsRemoved,
                glossaryLinesRemoved: glossaryLinesRemoved,
                timestampsStripped: timestampsStripped,
                foldedLines: foldedLines,
                reindexed: reindexed
            )
        } catch {
            report(error, context: "Glossary Repair", category: .recovery)
            return nil
        }
    }

    /// Writes what a repair did beside the copies it made, and to the log.
    ///
    /// The command-line run has no window, and a repair that rewrites saved files should leave a
    /// record someone can read afterwards rather than a number that scrolled past.
    private func writeRepairReport(
        summary: String,
        failures: [String],
        directory: URL?
    ) {
        Logger(subsystem: "local.callrecorder.app", category: "recovery")
            .notice("transcript repair: \(summary, privacy: .public)")
        print("transcript repair: \(summary)")
        for failure in failures { print("  failed: \(failure)") }
        guard let directory else { return }
        let body = (["transcript repair", summary, ""] + failures.map { "failed: \($0)" })
            .joined(separator: "\n")
        try? Data(body.utf8).write(to: directory.appending(path: "repair-report.txt"))
    }

    /// One transcript with the glossary applied, and where the corrected files should go.
    private struct CorrectedTranscript {
        let record: TranscriptRecord
        let json: Data?
        let markdown: String?
        /// Spellings the glossary fixed, plus lines that were not speech.
        let replacements: Int
        let artifacts: TranscriptArtifacts.Outcome
        /// Whether the markdown lost the glossary line an earlier version wrote at the top.
        let glossaryLineRemoved: Bool
        /// Printed time ranges the pass took off the front of the markdown paragraphs.
        let timestampsStripped: Int
        /// Turns the pass joined into the paragraph above them, which is layout and not speech.
        let foldedLines: Int
        /// Whether any of the three files would differ. The markdown can need a rewrite when the
        /// stored text does not: the two hold the same speech in different shapes, and the blank
        /// lines a removed segment leaves behind are a markdown fault.
        let changed: Bool
    }

    /// Applies the glossary and the not-speech rules to a transcript's saved text. Nothing is
    /// written here.
    ///
    /// The two run in one pass because they rewrite the same three places -- the stored text, the
    /// JSON the index is built from, and the markdown body -- and doing them apart would walk the
    /// library twice and back the same file up twice for one repair.
    private func correctedTranscript(
        _ record: TranscriptRecord,
        matcher: GlossaryCorrector.Matcher
    ) throws -> CorrectedTranscript {
        // The stored text is the join of the segments, so correcting it once gives the count of
        // spellings fixed in this transcript.
        let correctedText = matcher.correct(record.text)
        let textArtifacts = TranscriptArtifacts.filter(correctedText.text)

        // The JSON carries the segment boundaries that the search index is built from, so it is
        // corrected too, and its result is what the indexer reads.
        var jsonData: Data?
        let jsonURL = URL(filePath: record.jsonPath)
        if let data = try? Data(contentsOf: jsonURL), !data.isEmpty {
            let decoder = JSONDecoder()
            if var document = try? decoder.decode(NormalizedTranscript.self, from: data) {
                let outcome = WhisperTranscript(language: document.language, segments: document.segments)
                    .applyingGlossary(matcher)
                let cleaned = TranscriptArtifacts.filter(segments: outcome.transcript.segments)
                if outcome.corrections > 0 || cleaned.outcome.didChange {
                    document = NormalizedTranscript(
                        callId: document.callId,
                        language: document.language,
                        model: document.model,
                        participants: document.participants,
                        glossary: document.glossary,
                        segments: cleaned.segments
                    )
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    jsonData = try encoder.encode(document)
                }
            }
        }

        // Only the spoken body is corrected. The header names the people on the call, and a rule
        // that reached into it could rewrite a name out of the one line that lists them. The
        // glossary line an earlier version wrote is dropped here as well, so a file whose wording
        // needed no correction is still tidied when the pass runs over it.
        var correctedMarkdown: String?
        var markdownChanged = false
        var glossaryLineRemoved = false
        var timestampsStripped = 0
        var foldedLines = 0
        let markdownURL = URL(filePath: record.markdownPath)
        if let markdown = try? String(contentsOf: markdownURL, encoding: .utf8) {
            let withoutGlossary = TranscriptRenderer.removingGlossaryLine(from: markdown) ?? markdown
            glossaryLineRemoved = withoutGlossary != markdown
            let body = TranscriptRenderer.body(of: withoutGlossary)
            let outcome = matcher.correct(body)
            let cleaned = TranscriptArtifacts.filter(outcome.text)
            timestampsStripped = cleaned.strippedTimestamps
            // Last, so a paragraph is built from lines that survived the rules above rather than
            // from lines that were about to be removed, and a folded paragraph is never rejoined
            // around a blank the cleaning was going to drop.
            let folded = TranscriptRenderer.foldingSpeakerTurns(cleaned.text)
            foldedLines = folded.foldedLines
            let rebuilt = TranscriptRenderer.replacingBody(
                of: withoutGlossary,
                with: folded.text
            )
            if rebuilt != markdown {
                correctedMarkdown = rebuilt
                markdownChanged = true
            }
        }

        return CorrectedTranscript(
            record: TranscriptRecord(
                callID: record.callID,
                language: record.language,
                model: record.model,
                text: textArtifacts.text,
                markdownPath: record.markdownPath,
                jsonPath: record.jsonPath
            ),
            json: jsonData,
            markdown: correctedMarkdown,
            replacements: correctedText.replacementCount,
            artifacts: textArtifacts,
            glossaryLineRemoved: glossaryLineRemoved,
            timestampsStripped: timestampsStripped,
            foldedLines: foldedLines,
            changed: correctedText.didChange
                || textArtifacts.didChange
                || markdownChanged
                || jsonData != nil
        )
    }

    /// Writes the corrected files beside the originals, which the caller has already backed up.
    private func writeCorrectedTranscript(
        _ corrected: CorrectedTranscript,
        record: TranscriptRecord
    ) throws {
        if let json = corrected.json {
            try json.write(to: URL(filePath: record.jsonPath), options: .atomic)
        }
        if let markdown = corrected.markdown {
            try Data(markdown.utf8).write(to: URL(filePath: record.markdownPath), options: .atomic)
        }
    }

    /// A dated folder for the pre-repair copies, created once per pass.
    private func makeGlossaryRepairBackupDirectory() throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let directory = applicationDirectory
            .appending(path: "Backups", directoryHint: .isDirectory)
            .appending(path: "Glossary repair \(stamp)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Copies a transcript's files aside before they are rewritten.
    private func copyIntoBackup(
        _ record: TranscriptRecord,
        directory: URL,
        callID: CallID
    ) throws {
        let target = directory.appending(path: callID.rawValue.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for path in [record.jsonPath, record.markdownPath] {
            let source = URL(filePath: path)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let destination = target.appending(path: source.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            try FileManager.default.copyItem(at: source, to: destination)
        }
        // The database text is not a file, so it is recorded so a hand repair can put it back.
        try Data(record.text.utf8).write(to: target.appending(path: "transcript-text.txt"))
    }

    func openBackupsFolder() {
        let directory = applicationDirectory.appending(path: "Backups", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    func restoreArtifact(_ item: RecoverableArtifact) async {
        do {
            try artifactRecovery.restore(item.callID)
            recoverableArtifacts = try artifactRecovery.items()
            recoveryMessage = "Working files restored."
            if
                item.kind == .discardedRecording,
                let store,
                let call = try await store.call(id: item.callID),
                recorderState.phase == .idle,
                let audioPath = call.audioPath,
                FileManager.default.fileExists(atPath: audioPath)
            {
                activeCallID = call.id
                finalizedAudioURL = URL(filePath: audioPath)
                activeSessionDirectory = item.originalDirectory
                apply(.restorePendingSession(sessionID: SessionID(rawValue: call.id.rawValue)))
                await captureQueue.enqueue { [weak self] in
                    await self?.queueCurrentCall()
                }
            }
        } catch {
            report(error, context: "Restore Working Files", category: .recovery)
        }
    }

    func purgeArtifact(_ item: RecoverableArtifact) async {
        do {
            try artifactRecovery.purge(item.callID)
            recoverableArtifacts = try artifactRecovery.items()
            if item.kind == .discardedRecording, let store {
                try await store.deleteCall(item.callID)
            }
            recoveryMessage = "Working files permanently deleted."
        } catch {
            report(error, context: "Delete Working Files", category: .recovery)
        }
    }

    func openRecordingsFolder() {
        let url = URL(filePath: settings.outputDirectory, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private func apply(_ event: RecorderEvent) {
        recorderState = RecorderReducer.reduce(state: recorderState, event: event)
    }

    /// Moves the recorder into a state for a layout render, and only for a layout render.
    ///
    /// The popover looks different in every phase, and the phases that matter most are the ones
    /// that are hard to reach on demand: a failed save, a call waiting for participants, a
    /// transcription in flight. The states are produced by the same reducer that drives a real
    /// recording, so a render shows the layout the app produces rather than one assembled for the
    /// picture. Outside preview mode this does nothing, which keeps a real recorder unreachable
    /// from it.
    func enterPreviewRecorderState(_ preview: PreviewRecorderState) {
        guard Self.isPreviewMode else { return }
        // Each state starts from idle. The reducer ignores an event that does not apply to the
        // current phase, so without this reset a state would silently render as the previous one.
        recorderState = .idle
        errorMessage = nil
        errorDetails = nil
        for event in preview.events {
            apply(event)
        }
        recordedSecondsBeforePause = 0
        recordingPausedAt = nil
        if preview.showsElapsedTime {
            // A paused call has already banked what it recorded, so the picture shows the clock the
            // way a paused call reaches it: a finished number and a stopped run.
            if recorderState.phase == .paused {
                recordedSecondsBeforePause = 754
                recordingPausedAt = Date()
                recordingStartedAt = nil
            } else {
                recordingStartedAt = Date().addingTimeInterval(-754)
            }
        } else {
            recordingStartedAt = nil
        }
        if let message = preview.failureMessage {
            errorMessage = message
            errorDetails = "ArtefactError: the working files for this call are no longer on disk.\n"
                + "Recorded at 10:41, last stage: finalizing artefacts."
        }
    }

    private func microphoneActivityChanged(_ isActive: Bool) {
        stopGraceTask?.cancel()
        if
            isActive,
            settings.automaticDetectionEnabled,
            recorderState.phase == .idle
        {
            captureQueue.enqueue { [weak self] in
                await self?.beginRecording(automatic: true)
            }
            return
        }
        apply(.externalMicrophoneChanged(isActive: isActive, newSessionID: nil))
        guard
            !isActive,
            recorderState.phase == .recording,
            !recorderState.automaticStartSuppressed
        else { return }
        let delay = settings.automaticStopGraceSeconds
        stopGraceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.captureQueue.enqueue {
                await self?.stopRecording(automatic: true)
            }
        }
    }

    private func beginRecording(automatic: Bool) async {
        guard recorderState.phase == .idle, !captureOperationInFlight else { return }
        guard let pipeline else {
            errorMessage = "ffmpeg and ffprobe are required to save recordings."
            apply(.fail(.storageUnavailable))
            return
        }
        captureOperationInFlight = true
        defer { captureOperationInFlight = false }
        let startedAt = Date()
        let sessionID = SessionID(rawValue: UUID())
        let callID = CallID(rawValue: sessionID.rawValue)
        let dirName = CallRecorderFolderNameFormatter.string(from: startedAt)
        let directory = URL(filePath: settings.outputDirectory, directoryHint: .isDirectory)
            .appending(path: dirName, directoryHint: .isDirectory)
        do {
            _ = try await captureSession.startSegment(
                directory: directory,
                index: 1,
                microphoneDeviceID: settings.selectedMicrophoneID
            )
            if automatic, !activityMonitor.externalMicrophoneActive {
                _ = try await captureSession.finishSegment()
                return
            }
            try await pipeline.start(callID: callID, startedAt: startedAt)
            activeSessionDirectory = directory
            activeCallID = callID
            finalizedAudioURL = nil
            capturedSegments = []
            nextSegmentIndex = 2
            recordingStartedAt = startedAt
            // A new call starts its own count, so nothing banked by the call before it is added on.
            recordedSecondsBeforePause = 0
            if automatic {
                apply(.externalMicrophoneChanged(isActive: true, newSessionID: sessionID))
            } else {
                apply(
                    .externalMicrophoneChanged(
                        isActive: activityMonitor.externalMicrophoneActive,
                        newSessionID: nil
                    )
                )
                apply(.manualStart(sessionID: sessionID))
            }
        } catch {
            report(error, context: "Capture Start", category: .capture)
            apply(.fail(.captureUnavailable))
        }
    }

    /// Adds the seconds recorded since the last start to the bank, and stops the live count.
    ///
    /// Called from the one place that ends a run of the recorder. It is written as a function of the
    /// dates rather than of a clock reading so a test can ask what it does at a chosen moment.
    private func bankRecordedSeconds(at now: Date = Date()) {
        guard let started = recordingStartedAt else { return }
        recordedSecondsBeforePause += max(0, now.timeIntervalSince(started))
        recordingStartedAt = nil
    }

    /// How much of this call has been recorded, in seconds, at a given moment.
    ///
    /// A paused call returns what was banked and does not grow, which is the whole point: no audio
    /// is captured while paused, so the number a person reads has to agree with the recording.
    nonisolated static func recordedSeconds(
        banked: TimeInterval,
        currentRunStartedAt: Date?,
        paused: Bool,
        at now: Date
    ) -> TimeInterval {
        guard !paused, let started = currentRunStartedAt else { return max(0, banked) }
        return max(0, banked) + max(0, now.timeIntervalSince(started))
    }

    private func pauseRecording() async {
        guard recorderState.phase == .recording, !captureOperationInFlight else { return }
        captureOperationInFlight = true
        defer { captureOperationInFlight = false }
        do {
            capturedSegments.append(try await captureSession.finishSegment())
            // Banked before the phase changes, so the seconds between here and the resume belong to
            // the pause and not to the recording.
            bankRecordedSeconds()
            recordingPausedAt = Date()
            apply(.manualPause)
        } catch {
            errorMessage = error.localizedDescription
            apply(.fail(.captureUnavailable))
        }
    }

    private func resumeRecording() async {
        guard
            recorderState.phase == .paused,
            !captureOperationInFlight,
            let activeSessionDirectory
        else { return }
        captureOperationInFlight = true
        defer { captureOperationInFlight = false }
        do {
            _ = try await captureSession.startSegment(
                directory: activeSessionDirectory,
                index: nextSegmentIndex,
                microphoneDeviceID: settings.selectedMicrophoneID
            )
            nextSegmentIndex += 1
            // The next run starts counting from now rather than from the start of the call.
            recordingStartedAt = Date()
            recordingPausedAt = nil
            apply(.manualResume)
        } catch {
            errorMessage = error.localizedDescription
            apply(.fail(.captureUnavailable))
        }
    }

    private func stopRecording(automatic: Bool) async {
        guard recorderState.phase == .recording || recorderState.phase == .paused else { return }
        guard !captureOperationInFlight else { return }
        stopGraceTask?.cancel()
        captureOperationInFlight = true
        defer { captureOperationInFlight = false }
        if automatic {
            apply(.automaticStopGraceElapsed)
        } else {
            apply(.manualStop)
        }
        do {
            if recorderState.phase == .finalizing, !capturedSegments.contains(where: {
                $0.index == nextSegmentIndex - 1
            }) {
                do {
                    capturedSegments.append(try await captureSession.finishSegment())
                } catch AudioCaptureError.notCapturing where !capturedSegments.isEmpty {}
            }
            guard
                let activeCallID,
                let activeSessionDirectory
            else { throw AudioCaptureError.notCapturing }
            let snapshot = PendingBackgroundCall(
                callID: activeCallID,
                segments: capturedSegments.map {
                    SegmentSnapshot(
                        index: $0.index,
                        systemURL: $0.system?.fileURL,
                        microphoneURL: $0.microphone?.fileURL
                    )
                },
                destination: activeSessionDirectory,
                endedAt: Date()
            )
            self.activeCallID = nil
            finalizedAudioURL = nil
            self.activeSessionDirectory = nil
            capturedSegments = []
            nextSegmentIndex = 1
            selectedParticipantIDs.removeAll()
            recordingStartedAt = nil
            recordedSecondsBeforePause = 0
            await backgroundFinalization.enqueue(snapshot)
            apply(.audioFinalizedAndQueued)
        } catch {
            errorMessage = error.localizedDescription
            apply(.fail(.storageUnavailable))
        }
    }

    private func queueCurrentCall() async {
        guard recorderState.phase == .awaitingParticipants else { return }
        guard let store, let activeCallID else {
            errorMessage = "The finalized call could not be queued."
            apply(.fail(.transcriptionFailed))
            return
        }
        errorMessage = nil
        do {
            try await store.setParticipants(Array(selectedParticipantIDs), for: activeCallID)
            self.activeCallID = nil
            finalizedAudioURL = nil
            activeSessionDirectory = nil
            capturedSegments = []
            nextSegmentIndex = 1
            selectedParticipantIDs.removeAll()
            apply(.processingQueued)
            try await refreshMetadata(from: store)
            await processor?.processNext()
        } catch {
            report(error, context: "Queue Processing")
            apply(.fail(.transcriptionFailed))
        }
    }

    private func discardCurrentCall() async {
        guard recorderState.phase == .awaitingParticipants || recorderState.phase == .failed else {
            return
        }
        guard
            let callID = activeCallID,
            let source = activeSessionDirectory
                ?? finalizedAudioURL?.deletingLastPathComponent()
        else {
            report(ArtifactRecoveryError.sourceUnavailable, context: "Discard Recording")
            return
        }
        do {
            _ = try artifactRecovery.discardCall(callID, sourceDirectory: source)
            clearRecordingContext()
            apply(.discard)
            recoverableArtifacts = try artifactRecovery.items()
            recoveryMessage = "Recording moved to Recently Deleted for 24 hours."
        } catch {
            report(error, context: "Discard Recording", category: .recovery)
        }
    }

    private func purgeExpiredArtifacts(store: CallStore) async throws {
        for item in try artifactRecovery.items() where item.purgeAfter <= Date() {
            try artifactRecovery.purge(item.callID)
            if item.kind == .discardedRecording {
                try await store.deleteCall(item.callID)
            }
        }
    }

    /// Runs one stage, and names the call whose work can be stopped while it runs.
    ///
    /// The flag below is what the process layer polls, and the call it belongs to is what the
    /// row's Stop control reaches. Only the stages that hand work to another process are named:
    /// the ones that move rows in the database finish in a moment, and a stop that did nothing
    /// would be worse than no control at all.
    private func runProcessingStage(_ job: ProcessingJob) async throws -> ProcessingStage {
        let cancellation = ProcessCancellation()
        stageCancellation = cancellation
        if job.stage.canBeStopped { stoppableCallID = job.callID }
        defer {
            if stoppableCallID == job.callID { stoppableCallID = nil }
            stageCancellation = nil
        }
        return try await performProcessingStage(job, cancellation: cancellation)
    }

    private func performProcessingStage(
        _ job: ProcessingJob,
        cancellation: ProcessCancellation
    ) async throws -> ProcessingStage {
        guard let store, let pipeline else { throw BackgroundProcessingError.pipelineUnavailable }
        switch job.stage {
        case .awaitingParticipants, .ready:
            throw BackgroundProcessingError.unexpectedStage(job.stage)
        case .queued:
            return .transcribing
        case .transcribing:
            guard
                let call = try await store.call(id: job.callID),
                let audioPath = call.audioPath,
                FileManager.default.fileExists(atPath: audioPath)
            else { throw BackgroundProcessingError.audioUnavailable }
            guard let whisperCLI = ToolLocator.standard.locate("whisper-cli") else {
                throw BackgroundProcessingError.whisperUnavailable
            }
            guard
                let model = modelManager.models.first(where: {
                    $0.id == settings.selectedWhisperModelID
                }),
                modelManager.state(for: model) == .installed
            else { throw BackgroundProcessingError.modelUnavailable }
            let participants = try await store.participants(for: job.callID)
            let glossary = try await store.listGlossaryTerms()
            let audio = URL(filePath: audioPath)
            _ = try await pipeline.transcribe(
                callID: job.callID,
                audio: audio,
                modelID: model.id,
                modelFile: modelManager.fileURL(for: model),
                participantIDs: participants.map(\.id),
                localParticipantID: settings.localParticipantID,
                glossary: glossary,
                directory: audio.deletingLastPathComponent(),
                queueIndexing: false,
                using: Transcriber(
                    ffmpeg: pipeline.finalizer.ffmpeg,
                    whisperCLI: whisperCLI,
                    vadModel: try Transcriber.resolvedVADModel(),
                    cancellation: cancellation
                )
            )
            return .diarizing
        case .diarizing:
            guard let call = try await store.call(id: job.callID), let audioPath = call.audioPath else {
                throw BackgroundProcessingError.audioUnavailable
            }
            try await pipeline.recognizeSpeakers(
                callID: job.callID,
                audioDirectory: URL(filePath: audioPath).deletingLastPathComponent(),
                using: diarizer, speakerStore: speakerStore,
                revisionManager: transcriptRevisionManager,
                cancellation: cancellation
            )
            return .attributing
        case .attributing:
            return .indexing
        case .indexing:
            guard let indexer else { throw BackgroundProcessingError.indexerUnavailable }
            try await indexer.index(
                callID: job.callID,
                store: store,
                cancellation: cancellation
            )
            return .finalizingArtifacts
        case .finalizingArtifacts:
            try await promoteTranscript(for: job.callID, store: store)
            do {
                _ = try await artifactRecovery.finalizeReadyCall(job.callID, store: store)
            } catch ArtifactRecoveryError.speakerReviewPending {
                // Keep source audio available until every detected speaker is reviewed.
            }
            try await purgeExpiredArtifacts(store: store)
            recoverableArtifacts = try artifactRecovery.items()
            recentCalls = try await store.recentCalls(limit: 5)
            return .ready
        }
    }

    /// Closes out recordings that an earlier launch left open.
    ///
    /// A call row is written before the microphone opens, so a crash or a force quit leaves a call
    /// that still says it is recording. Nothing will ever finish it, and until this runs the
    /// popover shows it as a live recording and counts it against the five recent calls. The audio
    /// is kept: it moves to Recently Deleted, where it can be restored for a day, because the
    /// person may still want the file even though the app cannot finish it.
    ///
    /// The repair is skipped in a layout render, which must not write anything, and when another
    /// copy of the app is running, whose recording is genuinely in progress.
    /// The unfinished calls that cannot be finished.
    ///
    /// A stage needs its input. Transcription and speaker detection need the audio; the last two
    /// stages need the written transcript. When both are gone the call is a stub with a start time:
    /// every retry fails the same way, on the same missing file. Those are reported here so the
    /// Recovery pane can stop promising a retry and offer to clear the row instead.
    private func unfinishableJobs(store: CallStore) async throws -> Set<CallID> {
        var result: Set<CallID> = []
        for job in processingJobs where job.executionState != .complete {
            guard let call = try await store.call(id: job.callID) else { continue }
            if let audioPath = call.audioPath,
               FileManager.default.fileExists(atPath: audioPath) {
                continue
            }
            let markdown = try await store.transcript(for: job.callID).map {
                URL(filePath: $0.markdownPath)
            }
            if let markdown, Self.isNonemptyFile(markdown) { continue }
            result.insert(job.callID)
        }
        return result
    }

    private static func isNonemptyFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return false
        }
        return (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0
    }

    /// Clears a call whose unfinished job has no input left. Nothing else is removed: such a call
    /// has no audio file and no transcript file, which is why it is in this list.
    func removeUnfinishableCall(_ callID: CallID) async {
        await removeUnfinishableCalls([callID])
    }

    /// Removes several unfinished calls in one pass.
    ///
    /// The store deletes one call per transaction, and the metadata is refreshed once at the end,
    /// so a list of six rows does not redraw the window between deletes. The wording counts the
    /// rows for the same reason the dialog does: six names on one screen, one decision.
    func removeUnfinishableCalls(_ callIDs: [CallID]) async {
        guard let store else { return }
        guard !callIDs.isEmpty else { return }
        do {
            for callID in callIDs {
                try await store.deleteCall(callID)
            }
            try await refreshMetadata(from: store)
            recoveryMessage = callIDs.count == 1
                ? "The unfinished call was removed from the list."
                : "\(callIDs.count) unfinished calls were removed from the list."
        } catch {
            report(error, context: "Remove Unfinished Call", category: .recovery)
        }
    }

    private func closeInterruptedRecordings(store: CallStore) async {
        guard !Self.isPreviewMode else { return }
        guard !anotherCopyIsRunning else { return }
        do {
            let interrupted = try await store.interruptedRecordings()
            guard !interrupted.isEmpty else { return }
            var keptAudio = 0
            for recording in interrupted {
                if let directory = sessionDirectory(for: recording),
                   FileManager.default.fileExists(atPath: directory.path) {
                    _ = try? artifactRecovery.discardCall(
                        recording.callID,
                        sourceDirectory: directory,
                        kind: .interruptedRecording
                    )
                    keptAudio += 1
                }
                // The row goes as well. A recording that cannot be finished has no stage to retry
                // and no transcript to keep, so leaving it would be a row that never changes.
                try await store.deleteCall(recording.callID)
            }
            recoverableArtifacts = try artifactRecovery.items()
            recoveryMessage = keptAudio == 1
                ? "A recording did not finish last time. Its audio is in Recently Deleted."
                : "\(keptAudio) recordings did not finish last time. Their audio is in Recently Deleted."
            Logger(subsystem: "local.callrecorder.app", category: "recovery")
                .notice("closed \(interrupted.count, privacy: .public) interrupted recordings")
        } catch {
            report(error, context: "Close Interrupted Recordings", category: .recovery)
        }
    }

    /// Where a session kept its working files: the folder named after the call, or the folder
    /// named after the minute the call started. Both namings are still in use on disk, so both are
    /// checked. The folder must be the only candidate that exists.
    private func sessionDirectory(for recording: CallStore.InterruptedRecording) -> URL? {
        let root = URL(filePath: settings.outputDirectory, directoryHint: .isDirectory)
        let candidates = [
            root.appending(path: recording.callID.rawValue.uuidString, directoryHint: .isDirectory),
            root.appending(
                path: CallRecorderFolderNameFormatter.string(from: recording.startedAt),
                directoryHint: .isDirectory
            ),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// True when a second copy of the app is open, which owns its own recording. A copy built from
    /// the command line has no bundle identifier; it also never records, so it is not a conflict.
    private var anotherCopyIsRunning: Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let current = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .contains { $0.processIdentifier != current }
    }

    private func loadMetadata() async {
        guard let store else {
            errorMessage = "The local database could not be opened."
            return
        }
        do {
            try await store.migrate()
            _ = try await store.resetInterruptedSpeakerReviewRequests()
            try await ensureLocalParticipant(in: store)
            _ = try await store.reconcileFailedIndexingJobs()
            await closeInterruptedRecordings(store: store)
            // Reading the voiceprint key raises a keychain prompt. A layout review neither
            // needs the voice profiles nor should ask for a password, so it skips them.
            if Self.isPreviewMode {
                await startPreviewVoiceIdentity(store: store)
            } else {
                startVoiceIdentity(store: store)
            }
            await refreshSpeakerAnalysisIssues()
            let completed = Set(try await store.processingJobs().filter {
                $0.stage == .ready && $0.executionState == .complete
            }.map(\.callID))
            for issue in speakerAnalysisIssues where issue.canRetry && completed.contains(issue.callID) {
                if try artifactRecovery.items().contains(where: { $0.callID == issue.callID }) {
                    try artifactRecovery.restore(issue.callID)
                }
                try await store.retrySpeakerAnalysis(callID: issue.callID)
            }
            try await purgeExpiredArtifacts(store: store)
            await recoverLegacyReadyArtifacts(store: store)
            _ = try await store.queuePendingParticipantJobs()
            try await refreshMetadata(from: store)
        } catch {
            report(error, context: "Database Startup", category: .database)
        }
        metadataIsLoaded = true
    }


    /// Loads the voice-profile key away from the main thread. Reading it can raise a keychain
    /// access prompt, and the menu bar must stay usable while that prompt waits for an answer.
    ///
    /// The read is given a deadline. A keychain dialog does not time out, so on a locked screen or
    /// behind another window the read waits forever: no error is raised, nothing is logged, and
    /// every feature that needs the key is quietly absent. The app said the storage was available
    /// throughout, because nothing had failed yet. The deadline turns "still waiting" into a state
    /// the surfaces can show, and the user can then answer the dialog or unlock the Mac.
    private func startVoiceIdentity(store: CallStore) {
        setVoiceIdentityState(.checking)
        Task.detached { [weak self] in
            do {
                let speakers = try await SpeakerStore.production(store: store)
                _ = try await speakers.purgeExpiredPending()
                _ = try await speakers.purgeExpiredProfileRecovery()
                await self?.activateSpeakerStore(speakers)
            } catch {
                await self?.speakerStoreUnavailable(error)
            }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.keychainPatience))
            await self?.reportKeychainStillWaitingIfNeeded()
        }
    }

    /// How long a keychain read may take before the app tells the user it is waiting.
    ///
    /// Long enough that an ordinary read, which returns in milliseconds, never reaches it, and
    /// short enough that the state is reported while the user is still looking at the screen.
    static let keychainPatience: Double = 8

    private func reportKeychainStillWaitingIfNeeded() {
        guard case .checking = voiceIdentityState else { return }
        setVoiceIdentityState(.waitingForPermission)
    }

    /// The one place the state changes, so every change is also recorded outside the app.
    private func setVoiceIdentityState(_ state: VoiceIdentityState) {
        voiceIdentityState = state
        Self.recordVoiceIdentityState(state)
    }

    /// Gives a layout review the speaker reviews without the keychain.
    ///
    /// The key guards the stored voice profiles, and reading it raises a prompt that a review must
    /// not trigger. The review list itself is a plain read of the assignments, and a suggestion
    /// that was already stored is shown as it stands. The renderer therefore drew "Nothing to
    /// review" over a database holding nine unresolved speakers, and the cards a person actually
    /// works in were never visible in a picture. This builds a store whose key cannot decrypt
    /// anything and reads the list, which is the part a review needs; nothing here writes.
    private func startPreviewVoiceIdentity(store: CallStore) async {
        guard let cipher = try? VoiceprintCipher(keyData: Data(repeating: 0, count: 32)) else {
            return
        }
        speakerStore = SpeakerStore(store: store, cipher: cipher)
        voiceIdentityError = nil
        setVoiceIdentityState(Self.previewVoiceIdentityState)
        if let notice = Self.previewRecoveryMessage {
            if ProcessInfo.processInfo.environment["CALL_RECORDER_NOTICE_KIND"]?.lowercased()
                == "problem" {
                announceProblem(notice)
            } else {
                recoveryMessage = notice
            }
        }
        await refreshSpeakerReviews()
    }

    /// Lets a render show the popover saying what an action just did.
    ///
    ///     CALL_RECORDER_NOTICE="Recording moved to Recently Deleted for 24 hours." scripts/preview.sh
    ///
    /// The band exists because the actions that set this message are all taken from the popover and
    /// all of them used to change the surface silently. Reaching the real state means discarding a
    /// recording, so the render is the only way to check the wording and the layout of a message
    /// that is on screen for twelve seconds.
    private static var previewRecoveryMessage: String? {
        guard isPreviewMode else { return nil }
        let text = ProcessInfo.processInfo.environment["CALL_RECORDER_NOTICE"]
        return (text?.isEmpty ?? true) ? nil : text
    }

    /// Lets a render show the two blocked states, which are otherwise unreachable outside a real
    /// keychain dialog.
    ///
    ///     CALL_RECORDER_VOICE_STATE=waiting scripts/preview.sh
    ///
    /// The states exist because a keychain read can park on a dialog with nothing on screen saying
    /// so. A picture of that screen is the only way to check that it says the right thing, and
    /// waiting for a real dialog is not a review anyone can repeat.
    private static var previewVoiceIdentityState: VoiceIdentityState {
        guard isPreviewMode else { return .available }
        return switch ProcessInfo.processInfo.environment["CALL_RECORDER_VOICE_STATE"]?.lowercased() {
        case "waiting": .waitingForPermission
        case "checking": .checking
        case "unavailable": .unavailable
        default: .available
        }
    }

    private func activateSpeakerStore(_ speakers: SpeakerStore) async {
        speakerStore = speakers
        voiceIdentityError = nil
        setVoiceIdentityState(.available)
        do {
            // Recompute suggestions the moment the voices can be read. Without this the list
            // keeps whatever the last run wrote: a call whose stored suggestion named somebody
            // who is not on it stayed on screen until a review window happened to open, which
            // can be days later.
            _ = try await speakers.rematchUnresolvedReviews()
        } catch {
            report(error, context: "Speaker Rematch", category: .processing)
        }
        await refreshSpeakerReviews()
        await refreshSpeakerReviewEvidence()
        await reconcileSharedSpeakersNow(announceWhenClean: false)
    }

    private func speakerStoreUnavailable(_ error: any Error) {
        speakerStore = nil
        voiceIdentityError = DiagnosticsReporter.redacted(error: String(reflecting: error))
        setVoiceIdentityState(.unavailable)
        report(error, context: "Voice Identity Startup", category: .processing)
    }

    private func ensureLocalParticipant(in store: CallStore) async throws {
        let savedParticipants = try await store.listParticipants()
        if
            let localID = settings.localParticipantID,
            savedParticipants.contains(where: { $0.id == localID })
        {
            return
        }
        let localName = Self.defaultLocalParticipantName
        let existing = savedParticipants.first {
            $0.name.compare(localName, options: [.caseInsensitive, .diacriticInsensitive])
                == .orderedSame
        }
        let local: Participant
        if let existing {
            local = existing
        } else {
            local = try await store.upsertParticipant(name: localName)
        }
        settings.localParticipantID = local.id
    }

    /// The name a fresh install files the user's own voice under.
    ///
    /// It is deliberately generic: a first run must not copy the macOS account name into
    /// transcripts and voice profiles without being asked. The person can be renamed at any
    /// time in the Participants pane, and an install that already chose a name keeps it.
    private static let defaultLocalParticipantName = "Me"

    private func refreshMetadata(from store: CallStore) async throws {
        participants = try await store.listParticipants()
        glossary = try await store.listGlossaryTerms()
        glossaryUsage = try await store.glossaryUsageCounts()
        namedParticipants = try await store.namedParticipantsByCall()
        callParticipants = try await store.participantsByCall()
        // A review that offers the wrong people is hard to tell from one that offers the right
        // ones, because both draw the same menu. Recording the counts makes the difference visible
        // from outside the app: a call whose people were never saved shows as zero here even
        // though the picker still lists everyone.
        let callsWithPeople = callParticipants.count
        let mostOnOneCall = callParticipants.values.map(\.count).max() ?? 0
        Logger(subsystem: "local.callrecorder.app", category: "speakers")
            .debug("speaker review candidates: \(callsWithPeople, privacy: .public) call(s) carry people, \(mostOnOneCall, privacy: .public) most")
        recentCalls = try await store.recentCalls(limit: 5)
        processingJobs = try await store.processingJobs()
        processingCallSummaries = try await store.callSummaries(
            ids: processingJobs.map(\.callID)
        )
        unfinishableCallIDs = try await unfinishableJobs(store: store)
        recoverableArtifacts = try artifactRecovery.items()
        speakerReviews = try await speakerStore?.unresolvedReviews() ?? []
        voiceProfileSummaries = try await speakerStore?.profileSummaries() ?? []
        await refreshSpeakerAnalysisIssues()
        // Last, so it also clears the lists the reads above filled. A new install has no calls, no
        // reviews, no voices, and nothing processing, and the popover draws a different shape for
        // each of those: this is what makes a render of it possible without deleting a library.
        if Self.isEmptyLibraryPreview { clearLibraryForPreview() }
    }

    /// Hides the library from a render, so the first screen of a new install can be looked at.
    func clearLibraryForPreview() {
        recentCalls = []
        processingJobs = []
        processingCallSummaries = [:]
        unfinishableCallIDs = []
        recoverableArtifacts = []
        speakerReviews = []
        voiceProfileSummaries = []
        speakerAnalysisIssues = []
        glossaryUsage = [:]
    }

    /// Adds a call whose speaker detection failed, for a render of the popover with both the
    /// voices waiting on a name and the calls that produced no voice at all.
    ///
    /// The live library has voices to name and no failed detection, so the row for the second
    /// condition could not be seen at all. A branch that cannot be looked at is a branch that
    /// cannot be checked, and this one was an else-if that hid whenever the first was drawn.
    /// Builds one review card from a real call, for a render.
    ///
    /// The review window draws whatever the database holds as still waiting, and the live library
    /// has nothing waiting: every voice in it has been named, and the ones that were not are kept
    /// anonymous. The card is therefore the one surface that cannot be seen at all from this Mac's
    /// data, including the state this seed exists for — an excerpt already moved onto somebody
    /// else. Nothing is written: the review and its excerpts live in memory for the render.
    func seedPreviewReviewCard() async {
        guard Self.isPreviewMode, let store else { return }
        let overridesSeed = ProcessInfo.processInfo.environment["CALL_RECORDER_MOVED_LINES"] == "1"
        for call in recentCalls {
            guard
                let record = try? await store.transcript(for: call.id),
                let document = try? JSONDecoder().decode(
                    NormalizedTranscript.self,
                    from: Data(contentsOf: URL(filePath: record.jsonPath))
                ),
                let speakerIndex = document.segments
                    .filter({ $0.source != .microphone && $0.speakerIndex != nil })
                    .map(\.speakerIndex!)
                    .max()
            else { continue }
            let clusterID = SpeakerClusterID(rawValue: UUID())
            let onCall = callParticipants[call.id] ?? []
            guard let person = onCall.first else { continue }
            speakerReviewCallDates[call.id] = call.startedAt
            speakerReviews = [
                SpeakerReviewItem(
                    clusterID: clusterID,
                    callID: call.id,
                    speakerIndex: speakerIndex,
                    speakerLabel: "SPEAKER_\(speakerIndex)",
                    speechDurationMilliseconds: 58_000,
                    suggestedParticipantID: nil,
                    state: .unknown,
                    createdAt: call.startedAt
                )
            ]
            let audioURL = record.markdownPath.isEmpty
                ? nil
                : URL(filePath: record.markdownPath).deletingLastPathComponent()
                    .appending(path: "system.m4a")
            let excerpts = SpeakerReviewPlayback.excerpts(
                from: document.segments,
                speakerIndex: speakerIndex
            )
            var overrides: [SpeakerLineOverride] = []
            if overridesSeed, excerpts.count > 1 {
                overrides = [
                    SpeakerLineOverride(
                        callID: call.id,
                        startMs: excerpts[1].startMs,
                        endMs: excerpts[1].endMs,
                        participantID: person.id,
                        speakerName: person.name
                    )
                ]
            }
            speakerReviewEvidence[clusterID] = SpeakerReviewPlayback.Evidence(
                excerpts: excerpts,
                audioURL: audioURL,
                overrides: overrides
            )
            previewSeededReviewCard = true
            return
        }
    }

    func seedPreviewSpeakerIssue() {
        speakerAnalysisIssues.append(
            SpeakerAnalysisIssue(
                callID: CallID(rawValue: UUID()),
                startedAt: Date(timeIntervalSinceNow: -3_600 * 20),
                canRetry: true,
                audioAvailable: true,
                message: "Speaker detection failed. Audio and text are safe.",
                details: nil
            )
        )
    }

    /// Puts two calls with the same people on the same day at the top of the list, for a render
    /// of the rows that used to read alike.
    ///
    /// Nine such pairs sit in the recent library, and every one of them is older than a day, so
    /// a render of the live data never contained one: the five calls a render shows are either
    /// from today or from different days. The fault was therefore invisible in every picture of
    /// the popover that had been taken, and this seeded render is the only way to look at the
    /// row that changed.
    func seedPreviewRepeatedRows() {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.date(byAdding: .day, value: -5, to: Date.now) ?? Date.now
        let later = calendar.date(bySettingHour: 15, minute: 12, second: 0, of: day) ?? day
        let earlier = calendar.date(bySettingHour: 13, minute: 47, second: 0, of: day)
            ?? day.addingTimeInterval(-7_500)
        let people = ["Alex Dawson", "Emma (Liz)", "Sam Rivers"]
        recentCalls.insert(
            RecentCallSummary(
                id: CallID(rawValue: UUID()),
                startedAt: later,
                endedAt: later.addingTimeInterval(1_200),
                status: .ready,
                participantNames: people,
                hasTranscript: true
            ),
            at: 0
        )
        recentCalls.insert(
            RecentCallSummary(
                id: CallID(rawValue: UUID()),
                startedAt: earlier,
                endedAt: earlier.addingTimeInterval(1_800),
                status: .ready,
                participantNames: people,
                hasTranscript: true
            ),
            at: 1
        )
    }

    private func refreshMetadataFromProcessor() async {
        guard let store else { return }
        do {
            try await refreshMetadata(from: store)
        } catch {
            report(error, context: "Processing Refresh", category: .processing)
        }
    }

    private func confirmSpeakerReview(
        _ review: SpeakerReviewItem,
        participantID: ParticipantID
    ) async -> String? {
        guard reviewingSpeakerIDs.insert(review.clusterID).inserted else { return "Speaker confirmation is already running." }
        defer { reviewingSpeakerIDs.remove(review.clusterID) }
        guard let store, let speakerStore else {
            let error = SpeakerReviewError.identityUnavailable
            report(error, context: "Speaker Confirm")
            return String(reflecting: error)
        }
        var revision: TranscriptRevision?
        let priorParticipants = (try? await store.participants(for: review.callID)) ?? []
        do {
            guard let participant = try await store.listParticipants().first(where: {
                $0.id == participantID
            }) else { throw SpeakerReviewError.participantUnavailable }
            try await speakerStore.confirm(
                clusterID: review.clusterID,
                participantID: participantID
            )
            revision = try await rewriteTranscript(
                for: review,
                naming: participant,
                store: store
            )
            revision = nil
            try await refreshMetadata(from: store)
            await finalizeReviewedCallIfReady(review.callID, store: store)
            await processor?.processNext()
            return nil
        } catch {
            let detail = DiagnosticsReporter.redacted(error: String(reflecting: error))
            if let revision { try? transcriptRevisionManager.restore(revision) }
            try? await speakerStore.reopen(review)
            try? await store.setParticipants(priorParticipants.map(\.id), for: review.callID)
            report(error, context: "Speaker Confirm", category: .processing)
            await refreshSpeakerReviews()
            return Self.speakerReviewMessage(for: error, detail: detail)
        }
    }

    /// Rewrites the stored transcript so it shows the confirmed name, or an anonymous speaker
    /// when the review is kept unknown. Returns the revision so a caller can roll back on failure.
    private func rewriteTranscript(
        for review: SpeakerReviewItem,
        naming participant: Participant?,
        store: CallStore
    ) async throws -> TranscriptRevision? {
        try await rewriteTranscript(
            callID: review.callID,
            store: store,
            renamingVoiceAt: review.speakerIndex,
            to: participant
        )
    }

    /// Rewrites a call's saved transcript.
    ///
    /// A voice is renamed when one is given, and every line the user assigned by hand is written
    /// afterwards either way. Passing no voice is how an assignment is applied on its own: the
    /// voice keeps the name the review gave it and only the moved lines change.
    private func rewriteTranscript(
        callID: CallID,
        store: CallStore,
        renamingVoiceAt speakerIndex: Int?,
        to participant: Participant?
    ) async throws -> TranscriptRevision? {
        guard let record = try await store.transcript(for: callID) else {
            throw SpeakerReviewError.transcriptUnavailable
        }
        let jsonURL = URL(filePath: record.jsonPath)
        let markdownURL = URL(filePath: record.markdownPath)
        let document = try JSONDecoder().decode(
            NormalizedTranscript.self,
            from: Data(contentsOf: jsonURL)
        )
        let named = document.segments.map { segment in
            guard let speakerIndex, segment.speakerIndex == speakerIndex,
                segment.source != .microphone
            else { return segment }
            return TranscriptSegment(
                startMs: segment.startMs,
                endMs: segment.endMs,
                text: segment.text,
                speakerIndex: segment.speakerIndex,
                source: segment.source,
                participantID: participant?.id,
                speakerName: participant?.name
            )
        }
        // The lines the user moved by hand are written last. Naming a mixed voice names the whole
        // voice, and without this it would also rename the lines that were already assigned to
        // somebody else, which is the one thing the assignment exists to prevent.
        let segments = CallStore.applying(
            overrides: (try? await store.speakerLineOverrides(callID: callID)) ?? [],
            to: named
        )
        let callParticipants = try await store.participants(for: callID)
        let updatedDocument = NormalizedTranscript(
            callId: document.callId,
            language: document.language,
            model: document.model,
            participants: callParticipants.map {
                ParticipantMetadata(id: $0.id.rawValue.uuidString, name: $0.name)
            },
            glossary: document.glossary,
            segments: segments
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let normalizedJSON = try encoder.encode(updatedDocument)
        let transcript = WhisperTranscript(language: document.language, segments: segments)
        let revision = try transcriptRevisionManager.replace(
            callID: callID,
            markdownURL: markdownURL,
            jsonURL: jsonURL,
            renderedMarkdown: TranscriptRenderer.markdown(
                transcript: transcript,
                participants: callParticipants
            ),
            normalizedJSON: normalizedJSON
        )
        try await store.saveTranscript(
            TranscriptRecord(
                callID: callID,
                language: document.language,
                model: document.model,
                text: transcript.text,
                markdownPath: record.markdownPath,
                jsonPath: record.jsonPath
            )
        )
        return revision
    }

    /// Sends a decided speaker back to review and clears the name the transcript showed.
    /// A wrong mapping and a mapping decided without enough context both stay correctable.
    private func reopenSpeakerReview(_ review: SpeakerReviewItem) async -> String? {
        guard reviewingSpeakerIDs.insert(review.clusterID).inserted else {
            return "Speaker review is already running."
        }
        defer { reviewingSpeakerIDs.remove(review.clusterID) }
        guard let speakerStore else {
            let error = SpeakerReviewError.identityUnavailable
            report(error, context: "Speaker Reopen")
            return String(reflecting: error)
        }
        do {
            try await speakerStore.reopen(review)
            if let store {
                _ = try await rewriteTranscript(for: review, naming: nil, store: store)
            }
            await refreshSpeakerReviews()
            await refreshSpeakerReviewEvidence()
            if let store {
                try await refreshMetadata(from: store)
            }
            return nil
        } catch {
            let detail = DiagnosticsReporter.redacted(error: String(reflecting: error))
            report(error, context: "Speaker Reopen", category: .processing)
            return Self.speakerReviewMessage(for: error, detail: detail)
        }
    }

    private func keepSpeakerReviewUnknown(_ review: SpeakerReviewItem) async -> String? {
        guard reviewingSpeakerIDs.insert(review.clusterID).inserted else { return "Speaker review is already running." }
        defer { reviewingSpeakerIDs.remove(review.clusterID) }
        guard let speakerStore else {
            let error = SpeakerReviewError.identityUnavailable
            report(error, context: "Speaker Keep Unknown")
            return String(reflecting: error)
        }
        do {
            try await speakerStore.keepUnknown(clusterID: review.clusterID)
            // The stored transcript must match the review, so clear the name it showed before.
            var revision: TranscriptRevision?
            if let store {
                revision = try await rewriteTranscript(for: review, naming: nil, store: store)
                revision = nil
            }
            await refreshSpeakerReviews()
            if let store {
                try await refreshMetadata(from: store)
                await finalizeReviewedCallIfReady(review.callID, store: store)
                recentCalls = try await store.recentCalls(limit: 5)
            }
            return nil
        } catch {
            let detail = DiagnosticsReporter.redacted(error: String(reflecting: error))
            report(error, context: "Speaker Keep Unknown", category: .processing)
            return Self.speakerReviewMessage(for: error, detail: detail)
        }
    }

    /// A failed review must say what happened; a silent no-op looks like a broken button.
    private static func speakerReviewMessage(for error: any Error, detail: String) -> String {
        let reason = switch error {
        case CallStoreError.participantNotFound:
            "That person is no longer in the participant list. Pick them again, or add them in Participants."
        case CallStoreError.speakerClusterNotFound:
            "This speaker is no longer awaiting review. Close and reopen Review to see the current list."
        case SpeakerReviewError.participantUnavailable:
            "That person is no longer in the participant list. Pick someone else."
        case SpeakerReviewError.transcriptUnavailable:
            "The transcript for this call is missing. Restore it from Recovery, then try again."
        case SpeakerReviewError.identityUnavailable:
            "Voice profiles could not be opened. Unlock the login keychain, then retry."
        case let error as CocoaError where error.code == .fileReadNoSuchFile:
            "A transcript file is missing on disk. Restore it from Recovery, then try again."
        default:
            "Nothing was changed. The technical detail is in the copied diagnostics."
        }
        return reason + "\n\n" + detail
    }


    /// Repairs calls where one person was named on several speakers that do not sound alike.
    /// The voiceprints decide, so a wrong name never stays just because it was confirmed once.
    func reconcileSharedSpeakers() {
        Task { await reconcileSharedSpeakersNow() }
    }

    private func reconcileSharedSpeakersNow(announceWhenClean: Bool = true) async {
        guard let store, let speakerStore else {
            let summary = SpeakerReconcileSummary(
                finishedAt: Date.now,
                failure: "Voice profiles could not be opened."
            )
            lastSpeakerReconcile = summary
            Self.recordSpeakerReconcile(summary)
            report(SpeakerReviewError.identityUnavailable, context: "Speaker Reconcile")
            if announceWhenClean {
                announceProblem(
                    "Voice profiles could not be opened. Unlock the login keychain, then retry."
                )
            }
            return
        }
        do {
            let report = try await speakerStore.reconcileSharedSpeakers()
            for review in report.reopened {
                _ = try await rewriteTranscript(for: review, naming: nil, store: store)
            }
            voiceProfileSummaries = try await speakerStore.profileSummaries()
            await refreshSpeakerReviews()
            await refreshSpeakerReviewEvidence()
            try await refreshMetadata(from: store)
            let summary = SpeakerReconcileSummary(finishedAt: Date.now, report: report)
            lastSpeakerReconcile = summary
            Self.recordSpeakerReconcile(summary)
            if !report.reopened.isEmpty {
                recoveryMessage = "Returned \(report.reopened.count) speaker fragment"
                    + (report.reopened.count == 1 ? "" : "s")
                    + " that did not sound like the person named on it to Review."
            } else if announceWhenClean {
                recoveryMessage = "Every speaker name already matches the voice it was given."
            }
        } catch {
            let detail = DiagnosticsReporter.redacted(error: String(reflecting: error))
            report(error, context: "Speaker Reconcile", category: .processing)
            let summary = SpeakerReconcileSummary(finishedAt: Date.now, failure: detail)
            lastSpeakerReconcile = summary
            Self.recordSpeakerReconcile(summary)
            announceProblem(Self.speakerReviewMessage(for: error, detail: detail))
        }
    }


    /// Keeps the last repair outcome readable from outside the app while the app cannot be
    /// opened, so a wrong result can be diagnosed instead of guessed.
    ///
    /// The line is written whenever the repair finishes, including when it could not run. It used
    /// to be written only on the path that succeeds with work to report, so a repair that failed,
    /// or that ran and found nothing, left the key absent. Anyone reading it from outside could not
    /// tell "ran and found nothing" from "never ran", which is the difference between a working app
    /// and a repair that has been silently broken since the last update.
    private static func recordSpeakerReconcile(_ summary: SpeakerReconcileSummary) {
        let stamp = ISO8601DateFormatter().string(from: summary.finishedAt)
        guard let failure = summary.failure else {
            let closest = summary.closestKeptSimilarity.map { String(format: "%.3f", $0) } ?? "none"
            preferences().set(
                stamp + " ok groups=\(summary.callsExamined)"
                    + " fragments=\(summary.voicesExamined)"
                    + " reopened=\(summary.returnedToReview) closestKept=\(closest)",
                forKey: "last-speaker-reconcile"
            )
            return
        }
        preferences().set(stamp + " failed: " + failure, forKey: "last-speaker-reconcile")
    }


    /// Rewrites the participant line of recent transcripts whose saved participants changed
    /// outside the usual save path, such as a merge done from a tool. Without this the file on
    /// disk keeps naming someone who is no longer a separate person.
    func refreshStaleTranscriptHeaders() {
        Task { await refreshStaleTranscriptHeadersNow(announceWhenClean: true) }
    }

    /// Writes back the transcript files whose row names a path that is no longer there.
    ///
    /// A call is transcribed into a working folder and the transcript is promoted to the
    /// recordings folder afterwards, with the row repointed at the promoted file. That folder is
    /// then removed, which is the point of promoting. Where the repointing did not happen the row
    /// went on naming the removed folder, and the surface said a call had a saved transcript that
    /// it could not open: the Recent row offered Copy and Open, and only Copy worked, because it
    /// falls back to the stored text.
    ///
    /// The text the database holds is the transcript, so the file is written again rather than
    /// reported as lost. A call that captured nothing but silence has almost no text and gets no
    /// file back: inventing one would put an empty transcript in the folder and, worse, make the
    /// call look transcribed.
    func restoreMissingTranscriptFiles() {
        Task { await restoreMissingTranscriptFilesNow(announceWhenClean: true) }
    }

    /// How many transcripts name a file that is not on disk. Shown in Recovery so the fix is
    /// visible before it is run and can be confirmed after.
    private(set) var missingTranscriptFileCount = 0

    /// How many transcript files hold nothing but a silence hallucination. Shown in Recovery for
    /// the same reason as the count above: it is the one repair that deletes, so what it would
    /// remove is visible before it is run rather than only reported after.
    private(set) var noSpeechTranscriptCount = 0

    /// Below this much text a call captured no speech worth a file. The shortest real transcript
    /// in the library is several thousand characters, and the silence captures hold a few dozen.
    static let minimumRestorableTranscriptCharacters = 200

    /// Whether a call's saved text holds nothing a file should be written for.
    ///
    /// Two things disqualify a call, and the second was found by reading the library. Length
    /// alone is not enough: Whisper answers silence and noise with a loop, and a loop can run
    /// long. One call holds 694 characters of "VAT (VAT, VAT, VAT...)" across forty-two lines,
    /// which is comfortably past any length floor and is not speech. The validator that guards
    /// the normal capture path already recognises a transcript dominated by one repeated phrase,
    /// so the same judgement is used here rather than a second and weaker one.
    ///
    /// A call that fails either test gets no file. Writing one would put a hallucination in the
    /// recordings folder wearing the same name as a real transcript, which is worse than leaving
    /// the row as it is: the row already says the call has a transcript, and no file claims a
    /// reading of silence that nobody made.
    static func holdsNoSpeech(_ body: String, language: String) -> Bool {
        guard body.count >= minimumRestorableTranscriptCharacters else { return true }
        return TranscriptQualityValidator.isRepetitive(
            transcript(fromStoredText: body, language: language)
        )
    }


    private func restoreMissingTranscriptFilesNow(announceWhenClean: Bool = true) async {
        guard let store else { return }
        do {
            let records = try await store.transcriptFileRecords()
            var missing: [CallStore.TranscriptFileRecord] = []
            for record in records
            where !FileManager.default.fileExists(atPath: record.markdownPath) {
                missing.append(record)
            }
            missingTranscriptFileCount = missing.count
            guard !missing.isEmpty else {
                if announceWhenClean {
                    recoveryMessage = "Every saved transcript has its file on disk."
                }
                return
            }

            var restored = 0
            var empty = 0
            var failed = 0
            for record in missing {
                let outcome = await restoreTranscriptFile(for: record, store: store)
                switch outcome {
                case .writtenBack, .repointed: restored += 1
                case .noSpeech: empty += 1
                case .failed: failed += 1
                }
            }
            missingTranscriptFileCount = failed
            try await refreshMetadata(from: store)
            // Launch runs this repair without a word: it is housekeeping, and a sentence left in
            // the Diagnostics footnote at every start would be read as a result of something the
            // user did. A run that changed nothing and broke nothing says nothing. The Recovery
            // button asks for the report and always gets one.
            if Self.shouldReportRestore(
                restored: restored, failed: failed, announceWhenClean: announceWhenClean
            ) {
                recoveryMessage = Self.restoreSummary(restored: restored, empty: empty, failed: failed)
            }
        } catch {
            report(error, context: "Restore Transcript Files", category: .recovery)
            recoveryMessage = errorMessage ?? "The transcript files could not be checked."
        }
    }

    /// Writes back the transcript file for one call whose row names a file that is no longer
    /// there, and points the row at what was written.
    ///
    /// The saved text is the transcript, so a missing file is written again rather than reported
    /// as lost. The write goes through the promoter the normal path uses, which keeps three
    /// protections a second writer would have to remember: a file is never overwritten, an
    /// identical file under the same name is reused instead of duplicated, and a real collision
    /// takes a numbered name. A call holding too little text to be speech gets no file at all,
    /// because an empty transcript in the folder would make that call look transcribed.
    private func restoreTranscriptFile(
        for record: CallStore.TranscriptFileRecord,
        store: CallStore
    ) async -> TranscriptFileOutcome {
        let body = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.holdsNoSpeech(body, language: record.language) else { return .noSpeech }

        let root = URL(filePath: settings.outputDirectory, directoryHint: .isDirectory)
        let name = CallRecorderFolderNameFormatter.string(from: record.startedAt)
        let claimed = root.appending(path: name + ".md")
        let wasClaimed = FileManager.default.fileExists(atPath: claimed.path)
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: name + "-" + UUID().uuidString + ".md")
        do {
            let participants = try await store.participants(for: record.callID)
            let markdown = TranscriptRenderer.markdown(
                transcript: Self.transcript(fromStoredText: body, language: record.language),
                participants: participants
            )
            try Data(markdown.utf8).write(to: scratch, options: .atomic)
            let destination = try TranscriptPromoter(outputRoot: root)
                .promote(source: scratch, baseName: name)
            try? FileManager.default.removeItem(at: scratch)
            try await store.updateTranscriptPath(
                callID: record.callID,
                markdownPath: destination.path
            )
            if wasClaimed && destination == claimed { return .repointed(destination) }
            return .writtenBack(destination)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            report(error, context: "Restore Transcript File", category: .recovery)
            return .failed
        }
    }

    /// Turns stored text back into the transcript the renderer expects.
    ///
    /// One segment per line, because the renderer joins segments with a blank line between them.
    /// Handing it the whole text as a single segment would collapse every paragraph into one,
    /// which is the difference between a transcript that reads and a wall of words.
    static func transcript(fromStoredText body: String, language: String) -> WhisperTranscript {
        let segments = body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                TranscriptSegment(startMs: 0, endMs: 0, text: String(line))
            }
        return WhisperTranscript(language: language, segments: segments)
    }

    /// What the repair did, in the words the Recovery pane uses.
    static func restoreSummary(restored: Int, empty: Int, failed: Int) -> String {
        var parts: [String] = []
        if restored > 0 {
            parts.append(
                "Wrote back "
                    + String(restored)
                    + (restored == 1 ? " transcript file" : " transcript files")
                    + " from the database."
            )
        }
        if empty > 0 {
            parts.append(
                String(empty)
                    + (empty == 1 ? " call held" : " calls held")
                    + " no speech, so "
                    + (empty == 1 ? "it kept" : "they kept")
                    + " no file."
            )
        }
        if failed > 0 {
            parts.append(
                String(failed)
                    + (failed == 1 ? " file" : " files")
                    + " could not be written; the detail is in the diagnostics."
            )
        }
        return parts.isEmpty ? "No transcript file was missing." : parts.joined(separator: " ")
    }

    /// Whether a run of the transcript-file repair should leave a sentence behind.
    ///
    /// The repair runs at launch and from a button, and the two want opposite things. A button
    /// press is a question, so it always gets an answer, including "there was nothing to do". A
    /// launch is housekeeping nobody asked for: three rows holding no speech are found and refused
    /// on every start, and a sentence about them in the Diagnostics footnote would be read as the
    /// result of something the user did. A launch speaks only when it changed something or failed.
    static func shouldReportRestore(restored: Int, failed: Int, announceWhenClean: Bool) -> Bool {
        announceWhenClean || restored > 0 || failed > 0
    }

    /// How a pass over empty recordings went.
    struct NoSpeechCleanupOutcome {
        let examined: Int
        let removed: Int
        let failed: Int

        var didChange: Bool { removed > 0 }
    }

    /// Removes transcript files whose whole body is a silence hallucination.
    ///
    /// This is the one repair that deletes rather than rewrites, so its reasoning is written out.
    ///
    /// Whisper does not answer silence with silence. It answers with the phrases it was trained to
    /// end videos with: "Thank you for watching.", "I hope you enjoyed this video.", "See you next
    /// time.", "1, 2, 3". Three files in this library hold nothing else, which was found by
    /// reading them rather than by a rule looking for them. Each is about 1.8 kilobytes, of which
    /// about 1.75 is the glossary header, and one of them attributes the hallucination to a
    /// named person: `**Dana Holt**: Thank you for watching.` A file like that is worse than no
    /// file. It claims a meeting happened, it names a person who did not speak, and it is the same
    /// size as a real transcript to anything that reads the folder.
    ///
    /// The app already decides a call like this gets no file at all: the same `holdsNoSpeech` test
    /// guards the write-back path, and its own comment says an empty transcript would make a call
    /// look transcribed. These three files predate that rule. Removing them puts the folder back in
    /// step with the rule the app already follows, and the row keeps its saved text, so Copy still
    /// works and Open says the truth about why there is nothing to open.
    ///
    /// Every file is copied into the Backups folder before it is removed, which is what makes this
    /// recoverable by hand, and the test it uses is not a new one: the length floor is two hundred
    /// characters against a shortest-real-transcript of several thousand, and a long text has to be
    /// dominated by one repeated phrase to qualify.
    func removeTranscriptsWithNoSpeech(dryRun: Bool = false) async -> NoSpeechCleanupOutcome? {
        guard let store else { return nil }
        do {
            let records = try await store.transcriptFileRecords()
            let empty = records.filter { record in
                guard FileManager.default.fileExists(atPath: record.markdownPath) else { return false }
                let body = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return TranscriptArtifacts.holdsOnlySilence(body)
            }
            noSpeechTranscriptCount = empty.count
            guard !empty.isEmpty else {
                return NoSpeechCleanupOutcome(examined: records.count, removed: 0, failed: 0)
            }
            guard !dryRun else {
                return NoSpeechCleanupOutcome(examined: records.count, removed: empty.count, failed: 0)
            }

            var backupDirectory: URL?
            if backupDirectory == nil { backupDirectory = try makeGlossaryRepairBackupDirectory() }
            guard let backupDirectory else {
                return NoSpeechCleanupOutcome(examined: records.count, removed: 0, failed: empty.count)
            }

            var removed = 0
            var failures: [String] = []
            for record in empty {
                do {
                    let target = backupDirectory
                        .appending(path: record.callID.rawValue.uuidString, directoryHint: .isDirectory)
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    let source = URL(filePath: record.markdownPath)
                    let destination = target.appending(path: source.lastPathComponent)
                    if !FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.copyItem(at: source, to: destination)
                    }
                    // The stored text goes beside the file, so a hand repair has both halves of
                    // what the row said and what the folder held.
                    try Data(record.text.utf8)
                        .write(to: target.appending(path: "transcript-text.txt"))
                    try FileManager.default.removeItem(at: source)
                    removed += 1
                } catch {
                    failures.append("\(record.callID.rawValue.uuidString): \(error)")
                }
            }
            noSpeechTranscriptCount = failures.count
            if removed > 0 { try await refreshMetadata(from: store) }
            writeEmptyTranscriptReport(
                examined: records.count,
                removed: removed,
                failures: failures,
                directory: backupDirectory
            )
            return NoSpeechCleanupOutcome(
                examined: records.count,
                removed: removed,
                failed: failures.count
            )
        } catch {
            report(error, context: "Remove Empty Transcripts", category: .recovery)
            return nil
        }
    }

    /// The report for the one repair that deletes, so the list of what went is readable afterwards.
    private func writeEmptyTranscriptReport(
        examined: Int,
        removed: Int,
        failures: [String],
        directory: URL?
    ) {
        let summary = "examined \(examined), removed \(removed), failed \(failures.count)"
        Logger(subsystem: "local.callrecorder.app", category: "recovery")
            .notice("empty transcript cleanup: \(summary, privacy: .public)")
        // A different prefix from the command line's own line for the same pass, so two runs that
        // both wrote nothing are not read as one pass that did something twice.
        print("empty transcript cleanup report: \(summary)")
        for failure in failures { print("  failed: \(failure)") }
        guard let directory else { return }
        let body = ([
            "removed transcript files whose whole body was a silence hallucination",
            summary,
            "each file is in its call's folder under Backups, beside the text the row held",
            "",
        ] + failures.map { "failed: \($0)" }).joined(separator: "\n")
        try? Data(body.utf8).write(to: directory.appending(path: "empty-transcript-report.txt"))
    }

    private func refreshStaleTranscriptHeadersNow(announceWhenClean: Bool) async {
        guard let store else { return }
        do {
            var repaired = 0
            var stripped = 0
            var unreadable = 0
            let aliasToPreferred = try await glossaryAliasMap(store: store)
            for row in try await store.transcriptHeaderRows() {
                let markdownURL = URL(filePath: row.markdownPath)
                guard var markdown = try? String(contentsOf: markdownURL, encoding: .utf8) else {
                    unreadable += 1
                    continue
                }
                // A file an earlier version wrote carries a copy of the glossary at the top. The
                // terms are sent to the model, where they can still change what it hears; the
                // copy in a saved file is read only after the decode is over. Files whose
                // participant line already matches are reached here, which is the point: the
                // reason to drop the line applies to those files too.
                do {
                    if try transcriptRevisionManager.stripGlossaryLine(
                        callID: row.callID,
                        markdownURL: markdownURL,
                        contents: markdown
                    ) != nil {
                        markdown = try String(contentsOf: markdownURL, encoding: .utf8)
                        stripped += 1
                    }
                } catch {
                    report(error, context: "Glossary Line Removal", category: .recovery)
                    unreadable += 1
                    continue
                }
                guard let header = storedParticipantHeader(in: markdown) else { continue }
                // Compare names as a set: the order in the file does not matter, the names do.
                let shown = Set(
                    header.split(separator: ",").map { part in
                        part.trimmingCharacters(in: CharacterSet.whitespaces)
                    }.filter { name in name != "Not specified" }
                )
                guard shown != Set(row.names) else { continue }
                do {
                    _ = try await refreshTranscriptParticipants(
                        callID: row.callID,
                        store: store,
                        revisionManager: transcriptRevisionManager
                    )
                    repaired += 1
                } catch {
                    // Older calls can have no JSON metadata left. Their file can still be
                    // renamed with the glossary spellings, and one bad call must not stop the
                    // rest of the pass.
                    if await renameLegacyTranscript(
                        row: row, markdown: markdown, shown: shown,
                        aliases: aliasToPreferred, markdownURL: markdownURL
                    ) {
                        repaired += 1
                    } else {
                        unreadable += 1
                    }
                    continue
                }
            }
            var notes: [String] = []
            if repaired > 0 {
                notes.append(
                    "Updated the participant line on \(repaired) transcript"
                        + (repaired == 1 ? "." : "s.")
                )
            }
            if stripped > 0 {
                notes.append(
                    "Removed the glossary line from \(stripped) transcript"
                        + (stripped == 1 ? "." : "s.")
                )
            }
            if unreadable > 0 {
                notes.append("\(unreadable) older call(s) could not be read.")
            }
            if !notes.isEmpty {
                recoveryMessage = notes.joined(separator: " ")
            } else if announceWhenClean {
                recoveryMessage = "Every transcript already lists its saved participants."
            }
            try await refreshMetadata(from: store)
        } catch {
            let detail = DiagnosticsReporter.redacted(error: String(reflecting: error))
            report(error, context: "Transcript Header Repair", category: .processing)
            announceProblem(errorMessage ?? detail)
        }
    }


    /// Every glossary spelling a person is known by, mapped to the spelling the app shows.
    private func glossaryAliasMap(store: CallStore) async throws -> [String: String] {
        var map: [String: String] = [:]
        for term in try await store.listGlossaryTerms() {
            for alias in term.aliases where map[alias] == nil { map[alias] = term.preferred }
        }
        return map
    }

    /// Renames a merged spelling inside a transcript that has no JSON metadata left, and keeps
    /// one backup of the file first. Returns true when the file changed.
    ///
    /// A name is compared with case and repeated spaces flattened out. Nothing else is allowed to
    /// differ, so two entries that fold together are the same person written twice.
    nonisolated static func foldedName(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func renameLegacyTranscript(
        row: (callID: CallID, markdownPath: String, names: [String]),
        markdown: String,
        shown: Set<String>,
        aliases: [String: String],
        markdownURL: URL
    ) async -> Bool {
        var renames: [String: String] = [:]
        for name in shown.subtracting(Set(row.names)) {
            if let preferred = aliases[name], row.names.contains(preferred) {
                renames[name] = preferred
            }
        }
        // A name that differs from the saved one only in case or spacing is the same name, and the
        // saved spelling is the one every other surface shows. This pair has no alias to travel
        // by: the vocabulary holds "Acme", not the team label a call was named with, and one file
        // in the library reads "Acme Team" against a stored "Acme team". The match is safe
        // because nothing but case and surrounding space is allowed to differ, so it cannot put a
        // different person on the line.
        if renames.isEmpty {
            var byFoldedName: [String: String] = [:]
            for name in row.names where byFoldedName[Self.foldedName(name)] == nil {
                byFoldedName[Self.foldedName(name)] = name
            }
            for name in shown.subtracting(Set(row.names)) {
                if let preferred = byFoldedName[Self.foldedName(name)] {
                    renames[name] = preferred
                }
            }
        }
        guard
            !renames.isEmpty,
            let result = rewritingNames(in: markdown, renames: renames)
        else { return false }
        do {
            try transcriptRevisionManager.backupMarkdown(
                callID: row.callID, markdownURL: markdownURL, contents: markdown
            )
            try Data(result.markdown.utf8).write(to: markdownURL, options: .atomic)
            return true
        } catch {
            report(error, context: "Legacy Transcript Rename", category: .processing)
            return false
        }
    }

    private func resetVoiceProfileNow(for participantID: ParticipantID) async {
        guard let speakerStore else {
            report(SpeakerReviewError.identityUnavailable, context: "Voice Profile Reset")
            return
        }
        do {
            _ = try await speakerStore.resetProfile(participantID: participantID)
            voiceProfileSummaries = try await speakerStore.profileSummaries()
            recoveryMessage = "Voice profile moved to recoverable storage for 24 hours."
        } catch {
            report(error, context: "Voice Profile Reset", category: .recovery)
        }
    }

    private func restoreVoiceProfileNow(for participantID: ParticipantID) async {
        guard let speakerStore else {
            report(SpeakerReviewError.identityUnavailable, context: "Voice Profile Restore")
            return
        }
        do {
            _ = try await speakerStore.restoreProfile(participantID: participantID)
            voiceProfileSummaries = try await speakerStore.profileSummaries()
            recoveryMessage = "Voice profile restored."
        } catch {
            report(error, context: "Voice Profile Restore", category: .recovery)
        }
    }

    private func retryVoiceIdentityNow() async {
        guard let store else { return }
        // Reading the voiceprint key can raise a keychain prompt, and this runs from several
        // places: the screen-unlock observer, the speaker-review window opening, and the
        // refresh that window triggers. A layout review touches none of it. Guarding here as
        // well as at launch covers every one of those paths, not just the first.
        guard !Self.isPreviewMode else { return }
        do {
            let speakerStore = try await Task.detached {
                try await SpeakerStore.production(store: store)
            }.value
            self.speakerStore = speakerStore
            _ = try await speakerStore.purgeExpiredPending()
            _ = try await speakerStore.purgeExpiredProfileRecovery()
            _ = try await speakerStore.rematchUnresolvedReviews()
            try await refreshMetadata(from: store)
            voiceIdentityError = nil
            setVoiceIdentityState(.available)
            recoveryMessage = "Voice identity recovered."
        } catch {
            voiceIdentityError = DiagnosticsReporter.redacted(
                error: String(reflecting: error)
            )
            setVoiceIdentityState(.unavailable)
            report(error, context: "Voice Identity Retry", category: .processing)
        }
    }

    private func recoverLegacyReadyArtifacts(store: CallStore) async {
        do {
            for job in try await store.processingJobs()
            where job.stage == .ready && job.executionState == .complete {
                guard
                    try await !store.hasUnresolvedSpeakerReviews(for: job.callID),
                    let call = try await store.call(id: job.callID),
                    let audioPath = call.audioPath,
                    FileManager.default.fileExists(atPath: audioPath)
                else { continue }
                try await promoteTranscript(for: job.callID, store: store)
                do {
                    _ = try await artifactRecovery.finalizeReadyCall(job.callID, store: store)
                } catch ArtifactRecoveryError.speakerReviewPending {
                    continue
                }
            }
        } catch {
            report(error, context: "Recover Completed Artifacts", category: .recovery)
        }
    }

    private func finalizeReviewedCallIfReady(_ callID: CallID, store: CallStore) async {
        do {
            guard
                try await !store.hasUnresolvedSpeakerReviews(for: callID),
                let call = try await store.call(id: callID),
                call.status == .ready,
                let audioPath = call.audioPath,
                FileManager.default.fileExists(
                    atPath: URL(filePath: audioPath).deletingLastPathComponent().path
                )
            else { return }
            _ = try await artifactRecovery.finalizeReadyCall(callID, store: store)
            try await purgeExpiredArtifacts(store: store)
            recoverableArtifacts = try artifactRecovery.items()
        } catch {
            report(error, context: "Finalize Reviewed Call", category: .recovery)
        }
    }

    private func startSpeakerReviewRequestPolling() {
        guard speakerReviewRequestTask == nil else { return }
        speakerReviewRequestTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.processSpeakerReviewRequests()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func processSpeakerReviewRequests() async {
        guard let store else { return }
        // A request that names a range of lines is applied from the call store alone, so it does
        // not wait for the voice layer's key. A request that names a voice does, and while the key
        // is missing those stay pending: they are not claimed, so nothing is parked in the running
        // state with nothing to finish it, and the poll picks them up once the key is there.
        let claimableActions: [SpeakerReviewRequestAction]? =
            speakerStore == nil ? [.assignLines, .releaseLines] : nil
        do {
            while let request = try await store.claimNextSpeakerReviewRequest(
                actions: claimableActions
            ) {
                // A request that names a range of lines does not need the voice's review to be
                // open, and reopening one to reach it would put a voice back in the queue that the
                // user had already finished with.
                if request.action == .assignLines || request.action == .releaseLines {
                    let failure = await applySpeakerLineRequest(request)
                    if let failure {
                        try await store.failSpeakerReviewRequest(request.id, error: failure)
                    } else {
                        try await store.completeSpeakerReviewRequest(request.id)
                    }
                    continue
                }
                guard let speakerStore else {
                    // The claim above only hands back a voice request when the voice layer is
                    // present, so this is out of reach. Failing the request keeps a claim from
                    // being stranded if that ever stops being true.
                    try await store.failSpeakerReviewRequest(
                        request.id,
                        error: "Voice identity is not available yet."
                    )
                    continue
                }
                let failure = await applySpeakerReviewRequest(
                    request,
                    speakerStore: speakerStore
                )
                if let failure {
                    try await store.failSpeakerReviewRequest(request.id, error: failure)
                } else {
                    try await store.completeSpeakerReviewRequest(request.id)
                }
            }
        } catch {
            report(error, context: "MCP Speaker Review", category: .processing)
        }
    }

    /// Applies a mapping requested over MCP. A cluster that already has a decision is reopened
    /// first, so a wrong mapping can be corrected instead of failing as "no longer pending".
    private func applySpeakerReviewRequest(
        _ request: SpeakerReviewRequest,
        speakerStore: SpeakerStore
    ) async -> String? {
        guard let clusterID = request.clusterID else {
            return "A voice is required to name a speaker."
        }
        if let review = try? await speakerStore.unresolvedReviews(limit: 500).first(
            where: { $0.clusterID == clusterID }
        ) {
            return await applySpeakerReviewRequest(request, review: review)
        }
        guard let stored = try? await speakerStore.review(clusterID: clusterID) else {
            return "Speaker review is no longer available."
        }
        do {
            try await speakerStore.reopen(stored)
        } catch {
            let detail = DiagnosticsReporter.redacted(error: String(reflecting: error))
            report(error, context: "Speaker Reopen", category: .processing)
            return Self.speakerReviewMessage(for: error, detail: detail)
        }
        guard let reopened = try? await speakerStore.unresolvedReviews(limit: 500).first(
            where: { $0.clusterID == clusterID }
        ) else {
            return "Speaker review could not be reopened."
        }
        return await applySpeakerReviewRequest(request, review: reopened)
    }

    private func applySpeakerReviewRequest(
        _ request: SpeakerReviewRequest,
        review: SpeakerReviewItem
    ) async -> String? {
        switch request.action {
        case .confirm:
            guard let participantID = request.participantID else {
                return "A participant is required to confirm a speaker."
            }
            return await confirmSpeakerReview(review, participantID: participantID)
        case .keepUnknown:
            return await keepSpeakerReviewUnknown(review)
        case .reopen:
            return await reopenSpeakerReview(review)
        case .assignLines, .releaseLines:
            // A range request names lines, not the voice, so it never needed the voice's review to
            // be open. It is handled ahead of this path for exactly that reason.
            return nil
        }
    }

    /// Applies a line request, which names a range rather than a voice.
    ///
    /// Separated from the voice path because the two do not share a precondition: naming a voice
    /// requires the review to be open, and moving lines does not. The cluster is read only to find
    /// the call the range belongs to.
    private func applySpeakerLineRequest(
        _ request: SpeakerReviewRequest
    ) async -> String? {
        guard let store, let range = request.lineRange else {
            return "A start and an end are required to move lines."
        }
        guard let callID = request.callID else {
            return "The call for these lines is no longer available."
        }
        do {
            switch request.action {
            case .assignLines:
                guard let participantID = request.participantID else {
                    return "A participant is required to assign lines."
                }
                try await store.saveSpeakerLineOverride(
                    callID: callID,
                    startMs: range.lowerBound,
                    endMs: range.upperBound,
                    participantID: participantID
                )
            case .releaseLines:
                try await store.removeSpeakerLineOverride(
                    callID: callID,
                    startMs: range.lowerBound,
                    endMs: range.upperBound
                )
            default:
                return nil
            }
            try await applyLineOverrides(callID: callID, store: store)
            return nil
        } catch {
            let detail = DiagnosticsReporter.redacted(error: String(reflecting: error))
            report(error, context: "MCP Speaker Lines", category: .processing)
            return Self.speakerReviewMessage(for: error, detail: detail)
        }
    }

    private func saveSettings() {
        // A render reads the real preferences so it can show the real pane. It must not be able to
        // change them, so every write is refused in preview mode.
        guard !Self.isPreviewMode else { return }
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.settingsKey)
    }

    private func updateStartAtLogin() {
        guard !Self.isPreviewMode else { return }
        do {
            let status = SMAppService.mainApp.status
            if startAtLoginEnabled, status != .enabled, status != .requiresApproval {
                try SMAppService.mainApp.register()
            } else if !startAtLoginEnabled, status == .enabled || status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
            defaults.set(startAtLoginEnabled, forKey: Self.startAtLoginKey)
            defaults.set(
                String(describing: SMAppService.mainApp.status),
                forKey: "start-at-login-status"
            )
        } catch {
            report(error, context: "Start at Login")
        }
    }
    private func promoteTranscript(for callID: CallID, store: CallStore) async throws {
        guard
            let call = try await store.call(id: callID),
            let transcript = try await store.transcript(for: callID)
        else {
            throw BackgroundProcessingError.transcriptUnavailable
        }
        let source = URL(filePath: transcript.markdownPath)
        let outputRoot = URL(filePath: settings.outputDirectory, directoryHint: .isDirectory)
        let baseName = CallRecorderFolderNameFormatter.string(from: call.startedAt)
        let destination = try TranscriptPromoter(outputRoot: outputRoot)
            .promote(source: source, baseName: baseName)
        var metadataSource = URL(filePath: transcript.jsonPath)
        if
            !FileManager.default.fileExists(atPath: metadataSource.path),
            let recovered = try artifactRecovery.items().first(where: { $0.callID == callID })
        {
            metadataSource = recovered.payloadDirectory.appending(path: "transcript.json")
        }
        guard FileManager.default.fileExists(atPath: metadataSource.path) else {
            let needsReview = try await speakerStore?.unresolvedReviews().contains {
                $0.callID == callID
            } ?? false
            if needsReview { throw BackgroundProcessingError.transcriptUnavailable }
            if destination != source.standardizedFileURL {
                try await store.updateTranscriptPath(
                    callID: callID,
                    markdownPath: destination.path
                )
            }
            return
        }
        let metadata = try TranscriptPromoter(
            outputRoot: applicationDirectory.appending(
                path: "Transcript Metadata",
                directoryHint: .isDirectory
            )
        ).preserveMetadata(source: metadataSource, callID: callID)
        try await store.updateTranscriptPaths(
            callID: callID,
            markdownPath: destination.path,
            jsonPath: metadata.path
        )
    }

    private func report(
        _ error: any Error,
        context: String,
        category: DiagnosticsReporter.Category = .processing
    ) {
        let detail = DiagnosticsReporter.redacted(error: String(reflecting: error))
        let diagnostics = DiagnosticsReporter.record(
            error,
            context: context,
            state: String(describing: recorderState.phase),
            category: category
        )
        if !Self.isPreviewMode {
            defaults.set(diagnostics, forKey: "last-error")
        }
        errorDetails = diagnostics
        errorMessage = detail
    }

    private func handleBackgroundStateChange(_ state: BackgroundFinalizationState) {
        backgroundState = state
        let newSuccesses = state.successes.filter {
            !backgroundCompletedCallIDs.contains($0.callID)
        }
        backgroundCompletedCallIDs.formUnion(newSuccesses.map(\.callID))
        if !newSuccesses.isEmpty {
            Task {
                await refreshMetadata()
                await processor?.processNext()
            }
        }
        let currentFailureIDs = Set(state.failures.map(\.job.callID))
        for failure in state.failures
        where !backgroundDiagnosedFailures.contains(failure.job.callID) {
            report(
                BackgroundFinalizationError(message: failure.message),
                context: "Background Save",
                category: .capture
            )
        }
        backgroundDiagnosedFailures = currentFailureIDs
    }
}

enum SpeakerReviewError: LocalizedError {
    case identityUnavailable
    case participantUnavailable
    case transcriptUnavailable

    var errorDescription: String? {
        switch self {
        case .identityUnavailable: "Voice profiles cannot be opened. Unlock the login keychain and retry in Review."
        case .participantUnavailable: "This participant no longer exists. Choose another participant."
        case .transcriptUnavailable: "The transcript is missing. Restore it from Recovery before confirming speakers."
        }
    }
}

enum BackgroundProcessingError: LocalizedError {
    case appUnavailable
    case pipelineUnavailable
    case audioUnavailable
    case whisperUnavailable
    case modelUnavailable
    case indexerUnavailable
    case transcriptUnavailable
    case unexpectedStage(ProcessingStage)

    var errorDescription: String? {
        switch self {
        case .appUnavailable: "The app stopped before processing could continue."
        case .pipelineUnavailable: "The local processing pipeline is unavailable."
        case .audioUnavailable: "The source audio is missing."
        case .whisperUnavailable: "whisper-cli is not installed."
        case .modelUnavailable: "Download the selected Whisper model in Settings."
        case .indexerUnavailable: "The local transcript indexer is unavailable."
        case .transcriptUnavailable: "The completed transcript file is missing."
        case let .unexpectedStage(stage): "The processor cannot execute stage \(stage.rawValue)."
        }
    }
}

/// Tiny main-actor capture command queue: operations submitted while a capture
/// transition is awaiting run afterward, in submission order, via Task chaining.
/// The state guards inside each operation remain the final authority.
/// ponytail: single global queue; per-mode queues only if contention ever matters.
struct CaptureCommandQueue {
    private var tail: Task<Void, Never>?

    mutating func enqueue(
        _ operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        tail = task
        return task
    }
}
