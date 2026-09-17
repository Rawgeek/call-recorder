import Foundation

public struct SessionID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct CallID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct PendingBackgroundCall: Hashable, Identifiable, Sendable {
    public let callID: CallID
    public let segments: [SegmentSnapshot]
    public let destination: URL
    public let endedAt: Date

    public init(
        callID: CallID,
        segments: [SegmentSnapshot],
        destination: URL,
        endedAt: Date
    ) {
        self.callID = callID
        self.segments = segments
        self.destination = destination
        self.endedAt = endedAt
    }

    public var id: CallID { callID }
}

public struct SegmentSnapshot: Hashable, Sendable {
    public let index: Int
    public let systemURL: URL?
    public let microphoneURL: URL?

    public init(
        index: Int,
        systemURL: URL?,
        microphoneURL: URL?
    ) {
        self.index = index
        self.systemURL = systemURL
        self.microphoneURL = microphoneURL
    }
}

public struct ParticipantID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct GlossaryTermID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct Participant: Codable, Equatable, Identifiable, Sendable {
    public let id: ParticipantID
    public let name: String
    public let role: String?
    public let company: String?
    public let email: String?

    public init(
        id: ParticipantID,
        name: String,
        role: String? = nil,
        company: String? = nil,
        email: String? = nil
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.company = company
        self.email = email
    }
}

public struct GlossaryTerm: Codable, Equatable, Identifiable, Sendable {
    public let id: GlossaryTermID
    public let preferred: String
    public let aliases: [String]

    public init(id: GlossaryTermID, preferred: String, aliases: [String]) {
        self.id = id
        self.preferred = preferred
        self.aliases = aliases
    }
}

public enum CallStatus: String, Codable, Sendable {
    case recording
    case metadata
    case transcribing
    case indexing
    case ready
    case failed
}

public enum ProcessingStage: String, Codable, CaseIterable, Sendable {
    case awaitingParticipants
    case queued
    case transcribing
    case diarizing
    case attributing
    case indexing
    case finalizingArtifacts
    case ready
}

public extension ProcessingStage {
    /// Plain wording for people, so the Recovery list never shows a raw case name.
    var displayName: String {
        switch self {
        case .awaitingParticipants: "Waiting for participants"
        case .queued: "Queued"
        case .transcribing: "Transcribing audio"
        case .diarizing: "Detecting speakers"
        case .attributing: "Matching voices to people"
        case .indexing: "Indexing for search"
        case .finalizingArtifacts: "Tidying up files"
        case .ready: "Ready"
        }
    }

    /// The same stage said as the action that did not finish, so a failure reads as a sentence:
    /// "Failed at transcribing audio", not "Failed at waiting for participants".
    var failureName: String {
        switch self {
        case .awaitingParticipants: "choosing participants"
        case .queued: "starting"
        case .transcribing: "transcribing audio"
        case .diarizing: "detecting speakers"
        case .attributing: "matching voices to people"
        case .indexing: "indexing for search"
        case .finalizingArtifacts: "tidying up files"
        case .ready: "finishing"
        }
    }

    /// What the person should expect while this stage runs.
    var displayDetail: String {
        switch self {
        case .awaitingParticipants: "Choose who was on the call"
        case .queued: "Waiting for an earlier call to finish"
        case .transcribing: "Turning speech into text"
        case .diarizing: "Working out how many people spoke"
        case .attributing: "Linking each voice to a saved person"
        case .indexing: "Making the transcript searchable"
        case .finalizingArtifacts: "Removing temporary files"
        case .ready: "Nothing left to do"
        }
    }

    /// Whether this stage runs a command the app can end.
    ///
    /// The three stages that hand work to another process are the ones that can take minutes and
    /// the ones that have needed rescuing from outside the app. The stages that only move rows in
    /// the database finish in a moment, so no surface offers to stop them.
    var canBeStopped: Bool {
        switch self {
        case .transcribing, .diarizing, .indexing: true
        case .awaitingParticipants, .queued, .attributing, .finalizingArtifacts, .ready: false
        }
    }
}

public enum ProcessingExecutionState: String, Codable, Sendable {
    case pending
    case running
    case failed
    case complete
}

public struct ProcessingJob: Codable, Equatable, Sendable {
    public let callID: CallID
    public let stage: ProcessingStage
    public let executionState: ProcessingExecutionState
    public let attemptCount: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let startedAt: Date?
    public let completedAt: Date?
    public let latestEventID: UUID?

    public init(
        callID: CallID,
        stage: ProcessingStage,
        executionState: ProcessingExecutionState,
        attemptCount: Int,
        createdAt: Date,
        updatedAt: Date,
        startedAt: Date?,
        completedAt: Date?,
        latestEventID: UUID?
    ) {
        self.callID = callID
        self.stage = stage
        self.executionState = executionState
        self.attemptCount = attemptCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.latestEventID = latestEventID
    }
}

public enum ProcessingEventSeverity: String, Codable, Sendable {
    case info
    case warning
    case error
}

public struct ProcessingEvent: Codable, Equatable, Sendable {
    public let id: UUID
    public let callID: CallID
    public let stage: ProcessingStage
    public let severity: ProcessingEventSeverity
    public let summary: String
    public let errorType: String?
    public let details: String?
    public let stderr: String?
    public let createdAt: Date

    public init(
        id: UUID,
        callID: CallID,
        stage: ProcessingStage,
        severity: ProcessingEventSeverity,
        summary: String,
        errorType: String?,
        details: String?,
        stderr: String?,
        createdAt: Date
    ) {
        self.id = id
        self.callID = callID
        self.stage = stage
        self.severity = severity
        self.summary = summary
        self.errorType = errorType
        self.details = details
        self.stderr = stderr
        self.createdAt = createdAt
    }
}

public struct DatabaseIntegrityReport: Codable, Equatable, Sendable {
    public let quickCheckMessages: [String]
    public let foreignKeyViolations: [String]

    public init(quickCheckMessages: [String], foreignKeyViolations: [String]) {
        self.quickCheckMessages = quickCheckMessages
        self.foreignKeyViolations = foreignKeyViolations
    }

    public var isHealthy: Bool {
        quickCheckMessages == ["ok"] && foreignKeyViolations.isEmpty
    }
}

public struct CallRecord: Codable, Equatable, Sendable {
    public let id: CallID
    public let startedAt: Date
    public let endedAt: Date?
    public let audioPath: String?
    public let status: CallStatus

    public static func started(id: CallID, at date: Date) -> CallRecord {
        CallRecord(id: id, startedAt: date, endedAt: nil, audioPath: nil, status: .recording)
    }
}

/// What became of the track the other side of a call arrives on.
public enum SystemAudioState: String, Codable, Sendable {
    /// The other side of the call was recorded.
    case captured
    /// A system track was written but holds no sound, so the transcript carries one side only.
    case missing
}

public struct RecentCallSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: CallID
    public let startedAt: Date
    public let endedAt: Date?
    public let status: CallStatus
    public let participantNames: [String]
    public let hasTranscript: Bool
    public let unresolvedSpeakerCount: Int

    /// Whether the saved transcript holds any speech at all.
    ///
    /// A recording can be a room with nobody talking in it, and the transcriber then returns no
    /// segments and writes a file that is a heading and nothing else. The file exists, so every
    /// question the surface used to ask answered yes, and the row said Ready over a call that has
    /// nothing in it. One call in the library is exactly that: 4 minutes 35 seconds of audio whose
    /// peak level is minus 39 dB, and a 42-byte file. The state is carried here so the row can say
    /// what happened instead of implying a transcript is worth opening.
    public let hasSpeech: Bool

    /// What became of the other side of the call, when it could be told.
    ///
    /// Nil is unknown rather than fine: calls recorded before the app measured this carry nothing
    /// here, and so do calls whose two sources could not be told apart.
    public let systemAudio: SystemAudioState?

    public init(
        id: CallID,
        startedAt: Date,
        endedAt: Date?,
        status: CallStatus,
        participantNames: [String],
        hasTranscript: Bool,
        unresolvedSpeakerCount: Int = 0,
        // Defaulted to true so the many callers that build a summary for a call they know holds
        // speech keep their meaning, and only the reader that can actually tell has to say so.
        hasSpeech: Bool = true,
        systemAudio: SystemAudioState? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.participantNames = participantNames
        self.hasTranscript = hasTranscript
        self.unresolvedSpeakerCount = unresolvedSpeakerCount
        self.hasSpeech = hasSpeech
        self.systemAudio = systemAudio
    }
}

/// A length of recorded audio as a clock.
public enum CallLength {
    /// The length as `h:mm:ss`.
    ///
    /// Every field is always drawn, including a zero hour. The popover's own timer drops the hour
    /// until a recording has reached one, because it counts up while it is watched; a row in the
    /// recent list is read beside its neighbours, and a fixed shape is what lets two lengths be
    /// compared at a glance.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(
            format: "%d:%02d:%02d",
            total / 3_600,
            (total % 3_600) / 60,
            total % 60
        )
    }
}

public extension RecentCallSummary {
    /// How long the call lasted, or nil when it has not ended.
    ///
    /// A call still being recorded has no length yet, and neither has one whose end was never
    /// written. Both say nothing rather than showing a length the recording does not have.
    var lengthLabel: String? {
        guard let endedAt, endedAt > startedAt else { return nil }
        return CallLength.clock(endedAt.timeIntervalSince(startedAt))
    }
}

public struct TranscriptRecord: Codable, Equatable, Sendable {
    public let callID: CallID
    public let language: String
    public let model: String
    public let text: String
    public let markdownPath: String
    public let jsonPath: String

    public init(
        callID: CallID,
        language: String,
        model: String,
        text: String,
        markdownPath: String,
        jsonPath: String
    ) {
        self.callID = callID
        self.language = language
        self.model = model
        self.text = text
        self.markdownPath = markdownPath
        self.jsonPath = jsonPath
    }
}

public enum RecordingPhase: Equatable, Sendable {
    case idle
    case recording
    case paused
    case finalizing
    case awaitingParticipants
    case transcribing
    case indexing
    case failed
}

public enum RecorderFailure: Equatable, Sendable {
    case captureUnavailable
    case permissionDenied
    case storageUnavailable
    case transcriptionFailed
    case indexingFailed
}

public struct RecordingState: Equatable, Sendable {
    public let phase: RecordingPhase
    public let sessionID: SessionID?
    public let externalMicrophoneActive: Bool
    public let automaticStartSuppressed: Bool
    public let failure: RecorderFailure?

    public init(
        phase: RecordingPhase,
        sessionID: SessionID?,
        externalMicrophoneActive: Bool,
        automaticStartSuppressed: Bool,
        failure: RecorderFailure?
    ) {
        self.phase = phase
        self.sessionID = sessionID
        self.externalMicrophoneActive = externalMicrophoneActive
        self.automaticStartSuppressed = automaticStartSuppressed
        self.failure = failure
    }

    public static let idle = RecordingState(
        phase: .idle,
        sessionID: nil,
        externalMicrophoneActive: false,
        automaticStartSuppressed: false,
        failure: nil
    )

    public static func recording(
        sessionID: SessionID,
        externalMicrophoneActive: Bool = false
    ) -> RecordingState {
        RecordingState(
            phase: .recording,
            sessionID: sessionID,
            externalMicrophoneActive: externalMicrophoneActive,
            automaticStartSuppressed: false,
            failure: nil
        )
    }

    public static func failed(_ failure: RecorderFailure) -> RecordingState {
        RecordingState(
            phase: .failed,
            sessionID: nil,
            externalMicrophoneActive: false,
            automaticStartSuppressed: false,
            failure: failure
        )
    }

    func replacing(
        phase: RecordingPhase? = nil,
        sessionID: SessionID?? = nil,
        externalMicrophoneActive: Bool? = nil,
        automaticStartSuppressed: Bool? = nil,
        failure: RecorderFailure?? = nil
    ) -> RecordingState {
        RecordingState(
            phase: phase ?? self.phase,
            sessionID: sessionID ?? self.sessionID,
            externalMicrophoneActive: externalMicrophoneActive ?? self.externalMicrophoneActive,
            automaticStartSuppressed: automaticStartSuppressed ?? self.automaticStartSuppressed,
            failure: failure ?? self.failure
        )
    }
}

public enum RecorderEvent: Equatable, Sendable {
    case restorePendingSession(sessionID: SessionID)
    case manualStart(sessionID: SessionID)
    case manualPause
    case manualResume
    case manualStop
    case externalMicrophoneChanged(isActive: Bool, newSessionID: SessionID?)
    case automaticStopGraceElapsed
    case audioFinalizedAndQueued
    case processingQueued
    case participantsSaved
    case transcriptionFinished
    case indexingFinished
    case fail(RecorderFailure)
    case recover
    case discard
}
