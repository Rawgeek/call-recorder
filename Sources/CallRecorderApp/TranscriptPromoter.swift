import CallRecorderCore
import Foundation

enum TranscriptPromotionError: LocalizedError, Equatable {
    case invalidBaseName
    case sourceUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidBaseName: "The transcript filename is invalid."
        case .sourceUnavailable: "The completed transcript file is missing or empty."
        }
    }
}

struct TranscriptPromoter {
    let outputRoot: URL

    func promote(source: URL, baseName: String) throws -> URL {
        guard
            !baseName.isEmpty,
            URL(filePath: baseName).lastPathComponent == baseName
        else { throw TranscriptPromotionError.invalidBaseName }

        let source = source.standardizedFileURL
        let root = outputRoot.standardizedFileURL
        guard
            let sourceData = try? Data(contentsOf: source),
            !sourceData.isEmpty
        else { throw TranscriptPromotionError.sourceUnavailable }
        if source.deletingLastPathComponent() == root { return source }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var destination = root.appending(path: "\(baseName).md")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            if (try? Data(contentsOf: destination)) == sourceData { return destination }
            destination = root.appending(path: "\(baseName)-\(suffix).md")
            suffix += 1
        }
        try sourceData.write(to: destination, options: .atomic)
        return destination
    }

    func preserveMetadata(source: URL, callID: CallID) throws -> URL {
        guard
            let sourceData = try? Data(contentsOf: source.standardizedFileURL),
            !sourceData.isEmpty
        else { throw TranscriptPromotionError.sourceUnavailable }
        let root = outputRoot.standardizedFileURL
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = root.appending(path: "\(callID.rawValue.uuidString).json")
        if (try? Data(contentsOf: destination)) != sourceData {
            try sourceData.write(to: destination, options: .atomic)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
        return destination
    }
}
