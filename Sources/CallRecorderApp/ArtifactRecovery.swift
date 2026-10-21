import CallRecorderCore
import CryptoKit
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
    private let restoreMoveItem: @Sendable (URL, URL) throws -> Void
    private let cleanupMoveItem: @Sendable (URL, URL) throws -> Void
    private let removeRecoveryWrapper: @Sendable (URL) throws -> Void

    init(
        directory: URL,
        recordingsRoot: URL,
        retention: TimeInterval,
        restoreMoveItem: @escaping @Sendable (URL, URL) throws -> Void = {
            try FileManager.default.moveItem(at: $0, to: $1)
        },
        cleanupMoveItem: @escaping @Sendable (URL, URL) throws -> Void = {
            try FileManager.default.moveItem(at: $0, to: $1)
        },
        removeRecoveryWrapper: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        }
    ) {
        self.directory = directory
        self.recordingsRoot = recordingsRoot
        self.retention = retention
        self.restoreMoveItem = restoreMoveItem
        self.cleanupMoveItem = cleanupMoveItem
        self.removeRecoveryWrapper = removeRecoveryWrapper
    }

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
        //
        // A saved copy is finished only when nothing eligible is left beside it. A pass that
        // failed after creating the payload, or after moving part of it, leaves children in the
        // source; this pass has to move those before it can report the copy complete.
        let saved = try? load(callID)
        let savedPayload = saved.flatMap {
            FileManager.default.fileExists(atPath: $0.payloadDirectory.path) ? $0 : nil
        }
        guard let audioPath = call.audioPath else { return savedPayload }
        let source = URL(filePath: audioPath).deletingLastPathComponent().standardizedFileURL
        if let savedPayload {
            guard FileManager.default.fileExists(atPath: source.path) else {
                let moved = try FileManager.default.contentsOfDirectory(
                    atPath: savedPayload.payloadDirectory.path
                )
                guard !moved.isEmpty else { throw ArtifactRecoveryError.sourceUnavailable }
                return savedPayload
            }
            return try moveToRecovery(
                callID,
                kind: .completedCall,
                source: source,
                excluding: [ScreenshotArchive.directoryName],
                at: date
            )
        }
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
            // The manifest decides which call owns this wrapper and where the payload goes. A
            // copied or corrupt manifest must not direct this call's files into another wrapper
            // or an unrelated directory, so its identity is checked before anything is created.
            guard
                item.callID == callID,
                item.recoveryDirectory.standardizedFileURL == wrapper.standardizedFileURL,
                item.kind == kind,
                item.originalDirectory.standardizedFileURL == source.standardizedFileURL
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
            // A repeat after every eligible child has moved, with the screenshots still beside
            // them. The source is finished when the payload already holds what was moved.
            let moved = try FileManager.default.contentsOfDirectory(atPath: item.payloadDirectory.path)
            guard !moved.isEmpty else { throw ArtifactRecoveryError.sourceUnavailable }
            return item
        }
        for child in moving {
            let destination = item.payloadDirectory.appending(path: child.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                // A matching name is not proof a child was moved. The bytes have to match too, and
                // a different file under the same name fails closed rather than being overwritten.
                guard try fingerprint(of: child) == fingerprint(of: destination) else {
                    throw ArtifactRecoveryError.invalidManifest
                }
                // The payload already keeps these bytes, so this copy adds nothing. Removing it
                // lets a finished pass remove the source folder.
                try FileManager.default.removeItem(at: child)
                continue
            }
            try cleanupMoveItem(child, destination)
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
        if FileManager.default.fileExists(atPath: item.originalDirectory.path) {
            try restoreBesideScreenshots(item)
        } else {
            try FileManager.default.createDirectory(
                at: item.originalDirectory.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: item.payloadDirectory, to: item.originalDirectory)
        }
        try? removeRecoveryWrapper(item.recoveryDirectory)
    }

    private struct RestoreJournal: Codable {
        struct Entry: Codable {
            let name: String
            let size: Int
            let sha256: String
        }

        let entries: [Entry]
    }

    private struct RestoreFingerprint: Equatable {
        let size: Int
        let sha256: String
    }

    /// Merges into a target that still owns the call's screenshots.
    ///
    /// The journal records exactly which payload files may appear in the target. That makes a
    /// half-completed move safe to retry without turning restore into a merge with any folder that
    /// happens to be at the same path.
    private func restoreBesideScreenshots(_ item: RecoverableArtifact) throws {
        let journalURL = item.recoveryDirectory.appending(path: "restore-journal.json")
        let existing = try FileManager.default.contentsOfDirectory(
            at: item.originalDirectory,
            includingPropertiesForKeys: nil
        )
        let journal: RestoreJournal
        if FileManager.default.fileExists(atPath: journalURL.path) {
            journal = try JSONDecoder().decode(
                RestoreJournal.self,
                from: Data(contentsOf: journalURL)
            )
            try validate(journal)
            try validateExistingTarget(existing, against: journal)
        } else {
            try validateFirstMerge(existing, payload: item.payloadDirectory)
            journal = RestoreJournal(entries: try restoreEntries(in: item.payloadDirectory))
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: journalURL.path
            )
        }
        try mergePayload(into: item.originalDirectory, from: item, journal: journal)
        // The empty payload and this journal stay until the wrapper is removed by restore(). If
        // that removal fails, the next restore can fingerprint what is already in the call folder
        // against the journal and finish instead of finding a wrapper without a payload.
    }

    /// Checks a journal read back from disk before it is turned into a name lookup.
    ///
    /// The journal is app-owned, but it is still decoded data: a duplicate name traps a
    /// dictionary built with `uniqueKeysWithValues`, and a name with path syntax could point a
    /// merge outside the call folder. Every entry has to describe exactly one file in that folder.
    private func validate(_ journal: RestoreJournal) throws {
        var names = Set<String>()
        for entry in journal.entries {
            let name = entry.name
            guard
                !name.isEmpty,
                name != ".",
                name != "..",
                !name.contains("/"),
                !name.contains("\\"),
                name != ScreenshotArchive.directoryName,
                entry.size >= 0,
                isSHA256(entry.sha256),
                names.insert(name).inserted
            else { throw ArtifactRecoveryError.invalidManifest }
        }
    }

    private func isSHA256(_ value: String) -> Bool {
        let bytes = value.utf8
        guard bytes.count == 64 else { return false }
        return bytes.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private func restoreEntries(in payload: URL) throws -> [RestoreJournal.Entry] {
        try FileManager.default.contentsOfDirectory(
            at: payload,
            includingPropertiesForKeys: [.isRegularFileKey]
        ).map { child in
            let values = try child.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                throw ArtifactRecoveryError.restoreTargetExists
            }
            let fingerprint = try fingerprint(of: child)
            return RestoreJournal.Entry(
                name: child.lastPathComponent,
                size: fingerprint.size,
                sha256: fingerprint.sha256
            )
        }.sorted { $0.name < $1.name }
    }

    /// The first merge accepts Finder metadata and an exact copy left by an interrupted copy.
    /// Everything else is an unrelated target, even when its filename would fit a recording.
    private func validateFirstMerge(_ existing: [URL], payload: URL) throws {
        let payloadChildren = try FileManager.default.contentsOfDirectory(
            at: payload,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        let payloadByName = Dictionary(
            uniqueKeysWithValues: payloadChildren.map { ($0.lastPathComponent, $0) }
        )
        for child in existing {
            let name = child.lastPathComponent
            if name == ScreenshotArchive.directoryName {
                guard try isDirectory(child) else {
                    throw ArtifactRecoveryError.restoreTargetExists
                }
                continue
            }
            if name == ".DS_Store" { continue }
            guard
                let source = payloadByName[name],
                try fingerprint(of: child) == fingerprint(of: source)
            else { throw ArtifactRecoveryError.restoreTargetExists }
        }
    }

    private func validateExistingTarget(_ existing: [URL], against journal: RestoreJournal) throws {
        let recorded = Dictionary(
            uniqueKeysWithValues: journal.entries.map { ($0.name, $0) }
        )
        for child in existing {
            let name = child.lastPathComponent
            if name == ScreenshotArchive.directoryName {
                guard try isDirectory(child) else {
                    throw ArtifactRecoveryError.restoreTargetExists
                }
                continue
            }
            if name == ".DS_Store" { continue }
            guard
                let entry = recorded[name],
                try fingerprint(of: child)
                    == RestoreFingerprint(size: entry.size, sha256: entry.sha256)
            else { throw ArtifactRecoveryError.restoreTargetExists }
        }
    }

    private func mergePayload(
        into target: URL,
        from item: RecoverableArtifact,
        journal: RestoreJournal
    ) throws {
        let payloadChildren = try FileManager.default.contentsOfDirectory(
            at: item.payloadDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        let payloadByName = Dictionary(
            uniqueKeysWithValues: payloadChildren.map { ($0.lastPathComponent, $0) }
        )
        let recorded = Dictionary(
            uniqueKeysWithValues: journal.entries.map { ($0.name, $0) }
        )
        guard payloadByName.keys.allSatisfy({ recorded[$0] != nil }) else {
            throw ArtifactRecoveryError.restoreTargetExists
        }

        var duplicates: [URL] = []
        var moves: [(source: URL, destination: URL)] = []
        for entry in journal.entries {
            let destination = target.appending(path: entry.name)
            let recordedFingerprint = RestoreFingerprint(size: entry.size, sha256: entry.sha256)
            if entry.name == ".DS_Store" {
                if let source = payloadByName[entry.name] {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        duplicates.append(source)
                    } else {
                        moves.append((source, destination))
                    }
                }
                continue
            }
            if let source = payloadByName[entry.name] {
                guard try fingerprint(of: source) == recordedFingerprint else {
                    throw ArtifactRecoveryError.restoreTargetExists
                }
                if FileManager.default.fileExists(atPath: destination.path) {
                    guard try fingerprint(of: destination) == recordedFingerprint else {
                        throw ArtifactRecoveryError.restoreTargetExists
                    }
                    duplicates.append(source)
                } else {
                    moves.append((source, destination))
                }
            } else {
                guard
                    FileManager.default.fileExists(atPath: destination.path),
                    try fingerprint(of: destination) == recordedFingerprint
                else { throw ArtifactRecoveryError.restoreTargetExists }
            }
        }

        for duplicate in duplicates {
            try FileManager.default.removeItem(at: duplicate)
        }
        for move in moves {
            try restoreMoveItem(move.source, move.destination)
        }
        let remaining = try FileManager.default.contentsOfDirectory(
            atPath: item.payloadDirectory.path
        )
        guard remaining.isEmpty else { throw ArtifactRecoveryError.restoreTargetExists }
    }

    private func isDirectory(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    }

    private func fingerprint(of url: URL) throws -> RestoreFingerprint {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw ArtifactRecoveryError.restoreTargetExists
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return RestoreFingerprint(
            size: size,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
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
