import Foundation

enum CaptureSegmentManifestError: Error {
    case invalidManifest
}

enum CaptureSegmentManifest {
    static func write(_ segment: CaptureSegment, in directory: URL) throws -> URL {
        try validate(segment, in: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = url(in: directory, index: segment.index)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(segment).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
        return destination
    }

    static func read(from manifestURL: URL) throws -> CaptureSegment {
        do {
            let segment = try JSONDecoder().decode(
                CaptureSegment.self,
                from: Data(contentsOf: manifestURL)
            )
            let directory = manifestURL.deletingLastPathComponent()
            guard manifestURL == url(in: directory, index: segment.index) else {
                throw CaptureSegmentManifestError.invalidManifest
            }
            try validate(segment, in: directory)
            return segment
        } catch let error as CaptureSegmentManifestError {
            throw error
        } catch {
            throw CaptureSegmentManifestError.invalidManifest
        }
    }

    private static func url(in directory: URL, index: Int) -> URL {
        directory.appending(path: String(format: "segment-%03d.json", index))
    }

    private static func validate(_ segment: CaptureSegment, in directory: URL) throws {
        guard segment.index > 0, segment.hasRecoverableAudio else {
            throw CaptureSegmentManifestError.invalidManifest
        }
        let expected = CaptureSegment.paths(in: directory, index: segment.index)
        if let system = segment.system {
            guard
                system.fileURL.standardizedFileURL == expected.system.standardizedFileURL,
                system.firstPresentationSeconds.isFinite,
                system.durationSeconds.isFinite,
                system.durationSeconds >= 0
            else { throw CaptureSegmentManifestError.invalidManifest }
        }
        if let microphone = segment.microphone {
            guard
                microphone.fileURL.standardizedFileURL == expected.microphone.standardizedFileURL,
                microphone.firstPresentationSeconds.isFinite,
                microphone.durationSeconds.isFinite,
                microphone.durationSeconds >= 0
            else { throw CaptureSegmentManifestError.invalidManifest }
        }
    }
}
