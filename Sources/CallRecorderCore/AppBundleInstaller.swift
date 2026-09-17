import Foundation

/// What an app bundle says about itself.
public struct AppBundleMetadata: Equatable, Sendable {
    public let identifier: String
    public let version: String
    public let build: Int

    public init(identifier: String, version: String, build: Int) {
        self.identifier = identifier
        self.version = version
        self.build = build
    }

    /// Reads `Contents/Info.plist`, or returns nil when the folder is not an app bundle.
    public static func read(from bundle: URL) -> AppBundleMetadata? {
        let plist = bundle.appending(path: "Contents/Info.plist")
        guard
            let data = try? Data(contentsOf: plist),
            let document = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let fields = document as? [String: Any],
            let identifier = fields["CFBundleIdentifier"] as? String,
            let version = fields["CFBundleShortVersionString"] as? String
        else { return nil }
        let build = (fields["CFBundleVersion"] as? NSNumber)?.intValue
            ?? (fields["CFBundleVersion"] as? String).flatMap(Int.init)
            ?? 0
        return AppBundleMetadata(identifier: identifier, version: version, build: build)
    }
}

public enum AppBundleInstallerError: LocalizedError, Equatable, Sendable {
    case archiveMissing(String)
    case extractionFailed(String)
    case noApplicationInArchive(String)
    case severalApplicationsInArchive(String, count: Int)
    case metadataUnreadable(String)
    case identifierMismatch(expected: String, found: String)
    case versionMismatch(expected: String, found: String)
    case signatureInvalid(String)
    case signerMismatch(expected: String, found: String)
    case destinationNotWritable(String)
    case nothingStaged(String)
    case replaceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .archiveMissing(let path):
            "The downloaded update is missing at \(path)."
        case .extractionFailed(let detail):
            "The downloaded update could not be unpacked. " + detail
        case .noApplicationInArchive(let path):
            "The downloaded update holds no application bundle at \(path)."
        case .severalApplicationsInArchive(let path, let count):
            "The downloaded update holds \(count) application bundles at \(path), and it must hold one."
        case .metadataUnreadable(let path):
            "The application at \(path) does not describe itself."
        case .identifierMismatch(let expected, let found):
            "The download is the app \(found), not \(expected)."
        case .versionMismatch(let expected, let found):
            "The download says it is version \(found), not \(expected)."
        case .signatureInvalid(let path):
            "The application at \(path) is not signed by a valid signature."
        case .signerMismatch(let expected, let found):
            "The download is signed by \(found), not by \(expected)."
        case .destinationNotWritable(let path):
            "Call Recorder cannot replace itself in \(path). Move the app to Applications and try again."
        case .nothingStaged(let path):
            "There is no waiting update at \(path)."
        case .replaceFailed(let detail):
            "The update could not be put in place. " + detail
        }
    }
}

/// Unpacks, checks, and swaps in an application bundle.
///
/// Every check here exists because the archive arrives over the network: the bundle must be this
/// app, must be the version the release named, and must carry a valid signature from the same
/// signer as the copy that is running. Only then is it worth swapping in.
public enum AppBundleInstaller {
    public static let ditto = URL(filePath: "/usr/bin/ditto")
    public static let codesign = URL(filePath: "/usr/bin/codesign")

    /// Unpacks an archive and returns the application bundle inside it.
    public static func extract(archive: URL, into directory: URL) throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: archive.path) else {
            throw AppBundleInstallerError.archiveMissing(archive.path)
        }
        try? fileManager.removeItem(at: directory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try ProcessRunner.run(
            executable: ditto,
            arguments: ["-x", "-k", archive.path, directory.path]
        )
        guard result.exitCode == 0 else {
            throw AppBundleInstallerError.extractionFailed(trimmed(result.standardError))
        }
        return try application(in: directory)
    }

    /// The one application bundle an archive unpacked, at whatever depth it was packed.
    ///
    /// Releases have been published both ways: the app at the top of the archive, and the app
    /// inside a folder named for the version. Both are the same app, so the search walks down
    /// until it reaches a level that holds one and refuses an archive that holds none or two.
    static func application(in directory: URL, depth: Int = 3) throws -> URL {
        let fileManager = FileManager.default
        var level = [directory]
        for _ in 0..<depth {
            var found: [URL] = []
            var below: [URL] = []
            for folder in level {
                let contents = (try? fileManager.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: [.isDirectoryKey]
                )) ?? []
                for entry in contents {
                    if entry.pathExtension == "app" {
                        found.append(entry)
                    } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                        below.append(entry)
                    }
                }
            }
            if found.count == 1 { return found[0] }
            if found.count > 1 {
                throw AppBundleInstallerError.severalApplicationsInArchive(
                    directory.path,
                    count: found.count
                )
            }
            guard !below.isEmpty else { break }
            level = below
        }
        throw AppBundleInstallerError.noApplicationInArchive(directory.path)
    }

    /// Refuses anything that is not the release it claims to be.
    public static func verify(
        _ bundle: URL,
        expectingIdentifier identifier: String,
        version: String,
        signer: String?
    ) throws {
        guard let metadata = AppBundleMetadata.read(from: bundle) else {
            throw AppBundleInstallerError.metadataUnreadable(bundle.path)
        }
        guard metadata.identifier == identifier else {
            throw AppBundleInstallerError.identifierMismatch(
                expected: identifier,
                found: metadata.identifier
            )
        }
        guard metadata.version == version else {
            throw AppBundleInstallerError.versionMismatch(expected: version, found: metadata.version)
        }
        guard isSignatureValid(bundle) else {
            throw AppBundleInstallerError.signatureInvalid(bundle.path)
        }
        // A copy signed ad-hoc carries no signer to pin, so the version and the identifier are the
        // whole check there. A copy signed with a certificate must be signed by the same one.
        if let signer {
            let found = signerAuthority(of: bundle)
            guard found == signer else {
                throw AppBundleInstallerError.signerMismatch(
                    expected: signer,
                    found: found ?? "an ad-hoc signature"
                )
            }
        }
    }

    /// Whether the bundle carries a signature macOS accepts.
    public static func isSignatureValid(_ bundle: URL) -> Bool {
        guard
            let result = try? ProcessRunner.run(
                executable: codesign,
                arguments: ["--verify", "--deep", "--strict", bundle.path]
            )
        else { return false }
        return result.exitCode == 0
    }

    /// The certificate the bundle was signed with, or nil when it carries an ad-hoc signature.
    public static func signerAuthority(of bundle: URL) -> String? {
        guard
            let result = try? ProcessRunner.run(
                executable: codesign,
                arguments: ["--display", "--verbose=4", bundle.path]
            )
        else { return nil }
        // codesign prints its report on standard error. The first authority is the leaf, which is
        // the certificate that actually signed this bundle.
        for line in result.standardError.split(separator: "\n") where line.hasPrefix("Authority=") {
            return String(line.dropFirst("Authority=".count))
        }
        return nil
    }

    /// Swaps a staged bundle into place, and says where the bundle it replaced now lives.
    ///
    /// The swap is one filesystem call where the volume supports it, so the path the app is
    /// launched from is never missing and a crash in the middle cannot leave no app at all. The
    /// two-rename fallback restores the running copy if the second rename fails.
    @discardableResult
    public static func replace(target: URL, with staged: URL) throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: staged.path) else {
            throw AppBundleInstallerError.nothingStaged(staged.path)
        }
        let parent = target.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: parent.path) else {
            throw AppBundleInstallerError.destinationNotWritable(parent.path)
        }
        if swap(target: target, staged: staged) { return staged }
        let aside = parent.appending(path: ".\(target.lastPathComponent).previous-\(UUID().uuidString)")
        do {
            try fileManager.moveItem(at: target, to: aside)
        } catch {
            throw AppBundleInstallerError.replaceFailed(
                "The running copy could not be moved aside. " + error.localizedDescription
            )
        }
        do {
            try fileManager.moveItem(at: staged, to: target)
        } catch {
            try? fileManager.moveItem(at: aside, to: target)
            throw AppBundleInstallerError.replaceFailed(
                "The new copy could not be put in place. " + error.localizedDescription
            )
        }
        return aside
    }

    private static func swap(target: URL, staged: URL) -> Bool {
        staged.path.withCString { old in
            target.path.withCString { new in
                renamex_np(old, new, UInt32(RENAME_SWAP)) == 0
            }
        }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Where an update waits between being downloaded and the app quitting.
///
/// The staged copy is unpacked beside the app, on the same volume, because the swap that installs
/// it is a rename and a rename cannot cross volumes. The copy of the app that was working is kept
/// in Application Support, which is the way back if the new version misbehaves.
public struct AppUpdateStager: Sendable {
    /// The application being replaced.
    public let target: URL
    /// Application Support folder for downloads and the kept copy.
    public let supportDirectory: URL

    public init(target: URL, supportDirectory: URL) {
        self.target = target
        self.supportDirectory = supportDirectory
    }

    public static let stagedName = ".CallRecorder-staged.app"

    /// The folder a release archive unpacks into while it is checked.
    public var incomingDirectory: URL {
        target.deletingLastPathComponent().appending(path: ".CallRecorder-incoming")
    }

    /// The bundle waiting to be installed, beside the app so the swap is a rename.
    public var stagedBundle: URL {
        target.deletingLastPathComponent().appending(path: Self.stagedName)
    }

    /// The copy of the version that was working before the last update.
    public var backupBundle: URL {
        supportDirectory.appending(path: "Previous/Call Recorder.app")
    }

    /// Where a release archive is kept after it is fetched. Kept rather than deleted, so an
    /// update that has to be repeated does not need the network again.
    public func archive(version: String) -> URL {
        supportDirectory.appending(path: "CallRecorder-\(version).zip")
    }

    /// The version waiting to be installed, or nil when nothing is.
    public func stagedVersion() -> String? {
        AppBundleMetadata.read(from: stagedBundle)?.version
    }

    /// The version kept as the way back, or nil when there is none.
    public func backupVersion() -> String? {
        AppBundleMetadata.read(from: backupBundle)?.version
    }

    /// Unpacks an archive beside the app and checks it before letting it wait there.
    @discardableResult
    public func stage(
        archive: URL,
        version: String,
        expectingIdentifier identifier: String,
        signer: String?
    ) throws -> URL {
        let fileManager = FileManager.default
        let extracted = try AppBundleInstaller.extract(archive: archive, into: incomingDirectory)
        defer { try? fileManager.removeItem(at: incomingDirectory) }
        try AppBundleInstaller.verify(
            extracted,
            expectingIdentifier: identifier,
            version: version,
            signer: signer
        )
        try? fileManager.removeItem(at: stagedBundle)
        do {
            try fileManager.moveItem(at: extracted, to: stagedBundle)
        } catch {
            // A staging folder on another volume cannot be renamed across, so copying is the
            // fallback. The copy is still checked: it is the same bytes that were verified.
            try fileManager.copyItem(at: extracted, to: stagedBundle)
        }
        return stagedBundle
    }

    /// Puts the kept copy in the waiting place, so the app runs it after it quits.
    @discardableResult
    public func stageRollback(expectingIdentifier identifier: String, signer: String?) throws -> String {
        let fileManager = FileManager.default
        guard let metadata = AppBundleMetadata.read(from: backupBundle) else {
            throw AppBundleInstallerError.nothingStaged(backupBundle.path)
        }
        try AppBundleInstaller.verify(
            backupBundle,
            expectingIdentifier: identifier,
            version: metadata.version,
            signer: signer
        )
        try? fileManager.removeItem(at: stagedBundle)
        try fileManager.copyItem(at: backupBundle, to: stagedBundle)
        return metadata.version
    }

    /// Keeps the version running now, then swaps the waiting one in.
    @discardableResult
    public func applyStaged() throws -> String {
        let fileManager = FileManager.default
        guard let version = AppBundleMetadata.read(from: stagedBundle)?.version else {
            throw AppBundleInstallerError.nothingStaged(stagedBundle.path)
        }
        try fileManager.createDirectory(
            at: backupBundle.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.removeItem(at: backupBundle)
        // ditto copies a bundle the way the system does: signature, extended attributes, and all.
        let copy = try ProcessRunner.run(
            executable: AppBundleInstaller.ditto,
            arguments: [target.path, backupBundle.path]
        )
        guard copy.exitCode == 0 else {
            throw AppBundleInstallerError.replaceFailed(
                "The copy of the working version could not be kept. "
                    + copy.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let replaced = try AppBundleInstaller.replace(target: target, with: stagedBundle)
        try? fileManager.removeItem(at: replaced)
        return version
    }

    /// Removes anything waiting to be installed, leaving the app alone.
    public func discardStaged() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: stagedBundle)
        try? fileManager.removeItem(at: incomingDirectory)
    }
}
