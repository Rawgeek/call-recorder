import CallRecorderCore
import Foundation

struct RevisionFileSystem: Sendable {
    let atomicWrite: @Sendable (Data, URL) throws -> Void

    init(_ atomicWrite: @escaping @Sendable (Data, URL) throws -> Void) {
        self.atomicWrite = atomicWrite
    }

    static let live = RevisionFileSystem { data, url in
        try data.write(to: url, options: .atomic)
    }
}

struct TranscriptRevision: Equatable, Sendable {
    let markdownBackup: URL
    let jsonBackup: URL
    let activeMarkdown: URL
    let activeJSON: URL
}

struct TranscriptRevisionManager: Sendable {
    let root: URL
    var fileSystem: RevisionFileSystem = .live

    func replace(
        callID: CallID,
        markdownURL: URL,
        jsonURL: URL,
        renderedMarkdown: String,
        normalizedJSON: Data
    ) throws -> TranscriptRevision {
        let priorMarkdown = try Data(contentsOf: markdownURL)
        let priorJSON = try Data(contentsOf: jsonURL)
        let directory = root
            .appending(path: callID.rawValue.uuidString, directoryHint: .isDirectory)
            .appending(
                path: String(format: "%.6f-%@", Date().timeIntervalSince1970, UUID().uuidString),
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let markdownBackup = directory.appending(path: "transcript.md")
        let jsonBackup = directory.appending(path: "transcript.json")
        try priorMarkdown.write(to: markdownBackup, options: .atomic)
        try priorJSON.write(to: jsonBackup, options: .atomic)
        let revision = TranscriptRevision(
            markdownBackup: markdownBackup,
            jsonBackup: jsonBackup,
            activeMarkdown: markdownURL,
            activeJSON: jsonURL
        )
        do {
            try fileSystem.atomicWrite(normalizedJSON, jsonURL)
            try fileSystem.atomicWrite(Data(renderedMarkdown.utf8), markdownURL)
        } catch {
            try? priorJSON.write(to: jsonURL, options: .atomic)
            try? priorMarkdown.write(to: markdownURL, options: .atomic)
            throw error
        }
        try prune(callID: callID, keeping: 3)
        return revision
    }


    /// Keeps a copy of a transcript that has no JSON metadata left, so a rename on an older
    /// call can still be undone by hand.
    @discardableResult
    func backupMarkdown(callID: CallID, markdownURL: URL, contents: String) throws -> URL {
        let directory = root
            .appending(path: callID.rawValue.uuidString, directoryHint: .isDirectory)
            .appending(
                path: String(format: "%.6f-%@", Date().timeIntervalSince1970, UUID().uuidString),
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let backup = directory.appending(path: "transcript.md")
        try Data(contents.utf8).write(to: backup, options: .atomic)
        try prune(callID: callID, keeping: 3)
        return backup
    }

    /// Removes the glossary line an earlier version wrote at the top of a transcript.
    ///
    /// The terms shape the decode and the vocabulary holds them; the copy in the file was the same
    /// list at the top of every transcript, and it could not change a word of one. Returns the
    /// backup when the file changed and nil when it held no such line.
    ///
    /// The file as it was is copied into the revision folder before the new one is written, so a
    /// strip over a whole library can be undone by hand. The JSON metadata is left alone: the terms
    /// recorded there are the ones the decode ran with, which is a record of what happened rather
    /// than a list to keep in step with the vocabulary.
    @discardableResult
    func stripGlossaryLine(callID: CallID, markdownURL: URL, contents: String) throws -> URL? {
        guard let stripped = TranscriptRenderer.removingGlossaryLine(from: contents) else {
            return nil
        }
        let backup = try backupMarkdown(
            callID: callID,
            markdownURL: markdownURL,
            contents: contents
        )
        try fileSystem.atomicWrite(Data(stripped.utf8), markdownURL)
        return backup
    }

    func restore(_ revision: TranscriptRevision) throws {
        try Data(contentsOf: revision.jsonBackup).write(to: revision.activeJSON, options: .atomic)
        try Data(contentsOf: revision.markdownBackup).write(
            to: revision.activeMarkdown,
            options: .atomic
        )
    }

    func revisions(for callID: CallID) throws -> [URL] {
        let directory = root.appending(
            path: callID.rawValue.uuidString,
            directoryHint: .isDirectory
        )
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func prune(callID: CallID, keeping limit: Int) throws {
        for revision in try revisions(for: callID).dropFirst(limit) {
            try FileManager.default.removeItem(at: revision)
        }
    }
}


/// Reads the participant line a transcript shows, so a header that no longer matches the saved
/// participants can be found and rewritten. Returns nil when the transcript has no such line.
func storedParticipantHeader(in markdown: String) -> String? {
    let prefix = "Participants: "
    // Only the header is read. Searching the whole file would let a line of speech that happens to
    // open with the same word be taken for the participant line and rewritten as one.
    let header = TranscriptRenderer.spokenTextStart(in: markdown)
        .map { String(markdown[..<$0]) } ?? markdown
    for line in header.split(separator: "\n", omittingEmptySubsequences: false) {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
    }
    return nil
}


/// Renames people inside a transcript that no longer has JSON metadata. Only the exact names
/// given in `renames` are replaced, and the rest of the wording is left alone. Returns nil when
/// nothing matched, so a caller can skip writing the file.
func rewritingNames(
    in markdown: String,
    renames: [String: String]
) -> (markdown: String, replacements: Int)? {
    guard !renames.isEmpty else { return nil }
    var replacements = 0
    let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
    let rewritten = lines.map { line -> String in
        var text = String(line)
        let prefix = "Participants: "
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(prefix) {
            let names = trimmed.dropFirst(prefix.count).split(separator: ",").map { part in
                part.trimmingCharacters(in: CharacterSet.whitespaces)
            }
            let mapped = names.map { renames[$0] ?? $0 }
            for (old, new) in zip(names, mapped) where old != new { replacements += 1 }
            return prefix + mapped.joined(separator: ", ")
        }
        if text.contains("**") {
            for (old, new) in renames {
                let needle = "**\(old)**"
                guard text.contains(needle) else { continue }
                replacements += text.components(separatedBy: needle).count - 1
                text = text.replacingOccurrences(of: needle, with: "**\(new)**")
            }
        }
        return text
    }
    guard replacements > 0 else { return nil }
    return (rewritten.joined(separator: "\n"), replacements)
}

func refreshTranscriptParticipants(
    callID: CallID,
    store: CallStore,
    revisionManager: TranscriptRevisionManager
) async throws -> TranscriptRevision? {
    guard let record = try await store.transcript(for: callID) else { return nil }
    let participants = try await store.participants(for: callID)
    let markdownURL = URL(filePath: record.markdownPath)
    let jsonURL = URL(filePath: record.jsonPath)
    let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
    let document = try JSONDecoder().decode(
        NormalizedTranscript.self,
        from: Data(contentsOf: jsonURL)
    )
    let prefix = "Participants: "
    let participantNames = participants.map(\.name).joined(separator: ", ")
    let names = participantNames.isEmpty ? "Not specified" : participantNames
    var lineStart = markdown.startIndex
    while lineStart < markdown.endIndex {
        let lineEnd = markdown[lineStart...].firstIndex {
            $0 == "\n" || $0 == "\r"
        } ?? markdown.endIndex
        if markdown[lineStart..<lineEnd].hasPrefix(prefix) {
            let renderedMarkdown = markdown.replacingCharacters(
                in: lineStart..<lineEnd,
                with: prefix + names
            )
            let updatedDocument = NormalizedTranscript(
                callId: document.callId,
                language: document.language,
                model: document.model,
                participants: participants.map {
                    ParticipantMetadata(id: $0.id.rawValue.uuidString, name: $0.name)
                },
                glossary: document.glossary,
                segments: document.segments
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try revisionManager.replace(
                callID: callID,
                markdownURL: markdownURL,
                jsonURL: jsonURL,
                renderedMarkdown: renderedMarkdown,
                normalizedJSON: try encoder.encode(updatedDocument)
            )
        }
        guard lineEnd < markdown.endIndex else { break }
        lineStart = markdown.index(after: lineEnd)
        if markdown[lineEnd] == "\r",
            lineStart < markdown.endIndex,
            markdown[lineStart] == "\n"
        {
            lineStart = markdown.index(after: lineStart)
        }
    }
    throw CocoaError(.fileReadCorruptFile)
}
