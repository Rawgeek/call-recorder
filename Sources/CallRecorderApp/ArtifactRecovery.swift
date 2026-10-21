import CallRecorderCore
import Foundation

enum ArtifactRecoveryError: Error, Equatable {
    case callNotReady
    case indexNotReady
    case speakerReviewPending
    case transcriptUnavailable
    case transcriptNotPromoted
    case sourceUnavailable
    case unsafeSourceDirectory
    case recoveryItemNotFound
    case restoreTargetExists
    case invalidManifest
}

struct RecoverableArtifact: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case completedCall
        case discardedRecording
        /// A recording that a crash or a force quit left open. The audio is kept the same way a
        /// deliberate discard is, because the person may still want the file even though the app
        /// can no longer finish it.
        case interruptedRecording
    }

    let callID: CallID
    let kind: Kind
    let originalDirectory: URL
    let recoveryDirectory: URL
    let deletedAt: Date
    let purgeAfter: Date

    var id: CallID { callID }
    var payloadDirectory: URL {
        recoveryDirectory.appending(path: "payload", directoryHint: .isDirectory)
    }

    /// The moment the recording started, read back from the folder it was saved in.
    ///
    /// A deleted recording keeps no readable identity of its own: its call row can be gone, and the
    /// timestamp the list used to show was when the app *removed* the file. Someone reading the
    /// list is trying to remember which recording this is, so the listed time has to be the time
    /// the recording was made. The folder is named for that moment, which makes it the one fact
    /// still available without reading the database.
    ///
    /// The name is local time, so it is parsed in local time and round-trips to the moment the
    /// recorder started. A recording made before the folders were named this way keeps its call
    /// identifier as a folder name, which is not a date, and reports nothing rather than a guess.
    var recordedAt: Date? {
        let parts = originalDirectory.lastPathComponent.split(separator: "T")
        guard parts.count == 2 else { return nil }
        let date = parts[0].split(separator: "-")
        let clock = parts[1].split(separator: "-")
        guard
            date.count == 3,
            clock.count == 3,
            let year = Int(date[0]),
            let month = Int(date[1]),
            let day = Int(date[2]),
            let hour = Int(clock[0]),
            let minute = Int(clock[1]),
            let second = Int(clock[2])
        else { return nil }
        return Calendar.current.date(
            from: DateComponents(
                year: year, month: month, day: day,
                hour: hour, minute: minute, second: second
            )
        )
    }
}

struct ArtifactRecovery: Sendable {
    let directory: URL
    let recordingsRoot: URL
    let retention: TimeInterval

    func finalizeReadyCall(
        _ callID: CallID,
        store: CallStore,
        removingAudio: Bool = true,
        at date: Date = Date()
    ) async throws -> RecoverableArtifact? {
        guard let call = try await store.call(id: callID) else {
            throw ArtifactRecoveryError.callNotReady
        }
        // The call is either finished, or one step from finished: the pipeline runs this while
        // the job is still at the finalizing stage, and a call whose job failed there and was
        // retried still carries the failed status until this stage succeeds.
        let job = try await store.processingJob(callID: callID)
        guard call.status == .ready || job?.stage == .finalizingArtifacts else {
            throw ArtifactRecoveryError.callNotReady
        }
        guard try await store.indexIsReady(for: callID) else {
            throw ArtifactRecoveryError.indexNotReady
        }
        guard try await !store.hasUnresolvedSpeakerReviews(for: callID) else {
            throw ArtifactRecoveryError.speakerReviewPending
        }
        guard
            let transcript = try await store.transcript(for: callID),
            isNonemptyFile(URL(filePath: transcript.markdownPath))
        else { throw ArtifactRecoveryError.transcriptUnavailable }

        // Keeping the audio is a choice, not a failure. Every measure this stage exists to check
        // has passed, and the folder that holds the audio stays where the recording is played
        // from. Nothing is left half-moved: the stage simply has nothing to do.
        guard removingAudio else { return nil }

        // A finished call keeps its working files for a day, then loses them. Re-running this
        // stage is normal: a re-index, a retry, or a repair walks a finished call back through
        // it. The working files are gone by then, which is the state this stage exists to
        // produce, so the call is reported as finished instead of as broken. Failing here used
        // to mark a complete, searchable transcript as "Needs attention" for ever, and every
        // retry failed the same way because there was nothing left to retry with.
        if let saved = try? load(callID),
           FileManager.default.fileExists(atPath: saved.payloadDirectory.path) {
            return saved
        }
        guard let audioPath = call.audioPath else { return nil }
        let source = URL(filePath: audioPath).deletingLastPathComponent().standardizedFileURL
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        // The folder can outlive the audio: the screen photographs are set aside below, and a
        // repeat of this stage then finds a folder that holds pictures and no media. That is a
        // finished call, not a missing source to fail on.
        let tracks = MediaFinalizer.existingTracks(in: source)
        guard
            FileManager.default.fileExists(atPath: audioPath) || tracks.system != nil
                || tracks.microphone != nil
        else { return nil }

        guard FileManager.default.fileExists(atPath: transcript.jsonPath) else {
            throw ArtifactRecoveryError.sourceUnavailable
        }
        let document = try JSONDecoder().decode(
            NormalizedTranscript.self, from: Data(contentsOf: URL(filePath: transcript.jsonPath))
        )
        guard !document.needsSpeakerDetection else {
            throw ArtifactRecoveryError.speakerReviewPending
        }

        let markdown = URL(filePath: transcript.markdownPath).standardizedFileURL
        guard !isDescendant(markdown, of: source) else {
            throw ArtifactRecoveryError.transcriptNotPromoted
        }
        // The recording folder also holds the screen photographs. Those are a record of the call
        // rather than working audio: they stay in place when the audio moves to Recently Deleted,
        // and only the audio children are moved. A day later the audio is purged and the pictures
        // are still beside the transcript.
        return try moveToRecovery(
            callID,
            kind: .completedCall,
            source: source,
            excluding: [ScreenshotArchive.directoryName],
            at: date
        )
    }

    func discardCall(
        _ callID: CallID,
        sourceDirectory: URL,
        kind: RecoverableArtifact.Kind = .discardedRecording,
        at date: Date = Date()
    ) throws -> RecoverableArtifact {
        try moveToRecovery(
            callID,
            kind: kind,
            source: sourceDirectory.standardizedFileURL,
            at: date
        )
    }

    private func moveToRecovery(
        _ callID: CallID,
        kind: RecoverableArtifact.Kind,
        source: URL,
        excluding excludedNames: Set<String> = [],
        at date: Date
    ) throws -> RecoverableArtifact {
        try validateSource(source)
        let wrapper = recoveryDirectory(for: callID)
        let manifest = wrapper.appending(path: "manifest.json")
        let item: RecoverableArtifact
        if FileManager.default.fileExists(atPath: manifest.path) {
            // Decoded rather than loaded: a pass interrupted after the manifest was written can
            // leave the payload missing, and this is the pass that creates it.
            item = try decode(manifest)
            guard
                item.kind == kind,
                item.originalDirectory == source
            else { throw ArtifactRecoveryError.invalidManifest }
        } else {
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw ArtifactRecoveryError.sourceUnavailable
            }
            item = RecoverableArtifact(
                callID: callID,
                kind: kind,
                originalDirectory: source,
                recoveryDirectory: wrapper,
                deletedAt: date,
                purgeAfter: date.addingTimeInterval(retention)
            )
            try FileManager.default.createDirectory(
                at: wrapper,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try write(item, to: manifest)
        }
        try FileManager.default.createDirectory(
            at: item.payloadDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard FileManager.default.fileExists(atPath: source.path) else {
            // A resumed pass after a crash: the source may already have been emptied.
            let moved = try FileManager.default.contentsOfDirectory(atPath: item.payloadDirectory.path)
            guard !moved.isEmpty else { throw ArtifactRecoveryError.sourceUnavailable }
            return item
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil
        )
        let moving = children.filter { !excludedNames.contains($0.lastPathComponent) }
        guard !moving.isEmpty else {
            throw ArtifactRecoveryError.sourceUnavailable
        }
        for child in moving {
            let destination = item.payloadDirectory.appending(path: child.lastPathComponent)
            // A pass interrupted halfway leaves some children in the payload already. The copy in
            // the payload is the one being kept, so a name that is already there is this same move
            // resumed, not a conflict.
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            try FileManager.default.moveItem(at: child, to: destination)
        }
        // The call's folder is removed when the audio was its last content. When the screenshots
        // stay, the folder stays with them.
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? []
        if remaining.isEmpty { try? FileManager.default.removeItem(at: source) }
        return item
    }

    func items() throws -> [RecoverableArtifact] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).compactMap { wrapper in
            let manifest = wrapper.appending(path: "manifest.json")
            guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
            let item = try decode(manifest)
            guard
                item.recoveryDirectory.standardizedFileURL == wrapper.standardizedFileURL,
                FileManager.default.fileExists(atPath: item.payloadDirectory.path)
            else { throw ArtifactRecoveryError.invalidManifest }
            return item
        }.sorted { $0.deletedAt > $1.deletedAt }
    }

    func restore(_ callID: CallID) throws {
        let item = try load(callID)
        guard FileManager.default.fileExists(atPath: item.payloadDirectory.path) else {
            throw ArtifactRecoveryError.recoveryItemNotFound
        }
        let targetExists = FileManager.default.fileExists(atPath: item.originalDirectory.path)
        if targetExists {
            // A finished call can leave its Screenshots folder beside the original recording even
            // after the audio has been given back. Those pictures belong to the same call, so a
            // restore puts the audio back beside them instead of refusing to work at all.
            let contents = try FileManager.default.contentsOfDirectory(
                at: item.originalDirectory,
                includingPropertiesForKeys: nil
            )
            guard contents.allSatisfy({ $0.lastPathComponent == ScreenshotArchive.directoryName })
            else {
                throw ArtifactRecoveryError.restoreTargetExists
            }
        } else {
            try FileManager.default.createDirectory(
                at: item.originalDirectory.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        if targetExists {
            let children = try FileManager.default.contentsOfDirectory(
                at: item.payloadDirectory,
                includingPropertiesForKeys: nil
            )
            // Every destination is checked before anything moves, so a conflict cannot leave the
            // call half restored.
            for child in children {
                let destination = item.originalDirectory.appending(path: child.lastPathComponent)
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw ArtifactRecoveryError.restoreTargetExists
                }
            }
            for child in children {
                let destination = item.originalDirectory.appending(path: child.lastPathComponent)
                try FileManager.default.moveItem(at: child, to: destination)
            }
            try? FileManager.default.removeItem(at: item.payloadDirectory)
        } else {
            try FileManager.default.moveItem(at: item.payloadDirectory, to: item.originalDirectory)
        }
        try? FileManager.default.removeItem(at: item.recoveryDirectory)
    }

    func purge(_ callID: CallID) throws {
        let item = try load(callID)
        guard FileManager.default.fileExists(atPath: item.payloadDirectory.path) else {
            throw ArtifactRecoveryError.recoveryItemNotFound
        }
        try FileManager.default.removeItem(at: item.recoveryDirectory)
    }

    func purgeExpired(now: Date = Date()) throws {
        for item in try items() where item.purgeAfter <= now {
            try purge(item.callID)
        }
    }

    private func load(_ callID: CallID) throws -> RecoverableArtifact {
        let wrapper = recoveryDirectory(for: callID)
        let manifest = wrapper.appending(path: "manifest.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            throw ArtifactRecoveryError.recoveryItemNotFound
        }
        let item = try decode(manifest)
        guard
            item.callID == callID,
            item.recoveryDirectory.standardizedFileURL == wrapper.standardizedFileURL
        else { throw ArtifactRecoveryError.invalidManifest }
        return item
    }

    private func recoveryDirectory(for callID: CallID) -> URL {
        directory.appending(path: callID.rawValue.uuidString, directoryHint: .isDirectory)
    }

    private func validateSource(_ source: URL) throws {
        let root = recordingsRoot.standardizedFileURL
        guard source != root, isDescendant(source, of: root) else {
            throw ArtifactRecoveryError.unsafeSourceDirectory
        }
    }

    private func isDescendant(_ candidate: URL, of parent: URL) -> Bool {
        candidate.path.hasPrefix(parent.path + "/")
    }

    private func isNonemptyFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return false
        }
        return (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0
    }

    private func write(_ item: RecoverableArtifact, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(item).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func decode(_ url: URL) throws -> RecoverableArtifact {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(RecoverableArtifact.self, from: Data(contentsOf: url))
        } catch {
            throw ArtifactRecoveryError.invalidManifest
        }
    }
}
