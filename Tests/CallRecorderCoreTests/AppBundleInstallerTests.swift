import Foundation
import Testing
@testable import CallRecorderCore

/// The filesystem half of the updater, exercised on real bundles and real archives.
///
/// The bundles are built here, a few kilobytes each, and signed ad-hoc: the checks that matter are
/// the ones that read a bundle, refuse one that is not the release it claims to be, and swap two
/// folders without ever leaving no application at the path the app is launched from.
@Suite("App bundle installation")
struct AppBundleInstallerTests {
    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "app-update-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeBundle(
        at url: URL,
        identifier: String = "local.callrecorder.app",
        version: String,
        build: Int = 1,
        signed: Bool = true
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.appending(path: "Contents/MacOS"),
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": String(build),
            "CFBundleExecutable": "Fake",
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url.appending(path: "Contents/Info.plist"))
        try fileManager.copyItem(
            at: URL(filePath: "/usr/bin/true"),
            to: url.appending(path: "Contents/MacOS/Fake")
        )
        if signed {
            let result = try ProcessRunner.run(
                executable: AppBundleInstaller.codesign,
                arguments: ["--force", "--sign", "-", url.path]
            )
            #expect(result.exitCode == 0)
        }
    }

    private func makeArchive(of application: URL, at archive: URL) throws {
        let result = try ProcessRunner.run(
            executable: AppBundleInstaller.ditto,
            arguments: ["-c", "-k", "--keepParent", application.path, archive.path]
        )
        #expect(result.exitCode == 0)
    }

    @Test("a bundle describes itself")
    func bundleDescribesItself() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let application = root.appending(path: "Call Recorder.app")
        try makeBundle(at: application, version: "0.1.4", build: 95)

        let metadata = try #require(AppBundleMetadata.read(from: application))
        #expect(metadata.identifier == "local.callrecorder.app")
        #expect(metadata.version == "0.1.4")
        #expect(metadata.build == 95)
        #expect(AppBundleMetadata.read(from: root) == nil)
    }

    @Test("another app, or another version, is refused")
    func verificationRefusesTheWrongBundle() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let application = root.appending(path: "Call Recorder.app")
        try makeBundle(at: application, version: "0.1.4")

        #expect(throws: AppBundleInstallerError.self) {
            try AppBundleInstaller.verify(
                application,
                expectingIdentifier: "com.example.other",
                version: "0.1.4",
                signer: nil
            )
        }
        #expect(throws: AppBundleInstallerError.self) {
            try AppBundleInstaller.verify(
                application,
                expectingIdentifier: "local.callrecorder.app",
                version: "0.1.5",
                signer: nil
            )
        }
        // The bundle is the app and the version it says it is, so nothing is thrown.
        try AppBundleInstaller.verify(
            application,
            expectingIdentifier: "local.callrecorder.app",
            version: "0.1.4",
            signer: nil
        )
    }

    @Test("an ad-hoc signature is valid and names no signer")
    func adHocSignatureNamesNoSigner() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let signed = root.appending(path: "Signed.app")
        let unsigned = root.appending(path: "Unsigned.app")
        try makeBundle(at: signed, version: "0.1.4")
        try makeBundle(at: unsigned, version: "0.1.4", signed: false)

        #expect(AppBundleInstaller.isSignatureValid(signed))
        #expect(AppBundleInstaller.signerAuthority(of: signed) == nil)
        // An unsigned download is refused even when everything else about it is right, because a
        // signature that is missing cannot be checked at all.
        #expect(!AppBundleInstaller.isSignatureValid(unsigned))
        #expect(throws: AppBundleInstallerError.self) {
            try AppBundleInstaller.verify(
                unsigned,
                expectingIdentifier: "local.callrecorder.app",
                version: "0.1.4",
                signer: nil
            )
        }
    }

    @Test("an archive unpacks to the application inside it")
    func archiveUnpacksToTheApplication() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let application = root.appending(path: "Call Recorder.app")
        try makeBundle(at: application, version: "0.1.4")
        let archive = root.appending(path: "CallRecorder-0.1.4.zip")
        try makeArchive(of: application, at: archive)

        let extracted = try AppBundleInstaller.extract(
            archive: archive,
            into: root.appending(path: "incoming")
        )
        #expect(AppBundleMetadata.read(from: extracted)?.version == "0.1.4")
    }

    @Test("a missing archive is refused")
    func missingArchiveIsRefused() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: AppBundleInstallerError.self) {
            try AppBundleInstaller.extract(
                archive: root.appending(path: "absent.zip"),
                into: root.appending(path: "incoming")
            )
        }
    }

    @Test("an archive that wraps the app in a folder is still read")
    func wrappedArchiveIsRead() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Releases were published with the app one level down until 0.1.5, and a copy of the app
        // that cannot be found there is a download that installs nothing.
        let wrapper = root.appending(path: "release/Call Recorder 0.1.4", directoryHint: .isDirectory)
        try makeBundle(at: wrapper.appending(path: "Call Recorder.app"), version: "0.1.4")
        let archive = root.appending(path: "CallRecorder-0.1.4.zip")
        let result = try ProcessRunner.run(
            executable: AppBundleInstaller.ditto,
            arguments: ["-c", "-k", "--keepParent", wrapper.path, archive.path]
        )
        #expect(result.exitCode == 0)

        let extracted = try AppBundleInstaller.extract(
            archive: archive,
            into: root.appending(path: "incoming")
        )
        #expect(AppBundleMetadata.read(from: extracted)?.version == "0.1.4")
    }

    @Test("an archive holding two applications is refused")
    func twoApplicationsAreRefused() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapper = root.appending(path: "release", directoryHint: .isDirectory)
        try makeBundle(at: wrapper.appending(path: "One.app"), version: "0.1.4")
        try makeBundle(at: wrapper.appending(path: "Two.app"), version: "0.1.5")
        let archive = root.appending(path: "two.zip")
        let result = try ProcessRunner.run(
            executable: AppBundleInstaller.ditto,
            arguments: ["-c", "-k", "--keepParent", wrapper.path, archive.path]
        )
        #expect(result.exitCode == 0)

        #expect(throws: AppBundleInstallerError.self) {
            try AppBundleInstaller.extract(archive: archive, into: root.appending(path: "incoming"))
        }
    }

    @Test("the staged copy takes the place of the running one")
    func stagedCopyReplacesTheRunningOne() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "Call Recorder.app")
        let staged = root.appending(path: ".CallRecorder-staged.app")
        try makeBundle(at: target, version: "0.1.3")
        try makeBundle(at: staged, version: "0.1.4")

        let previous = try AppBundleInstaller.replace(target: target, with: staged)
        #expect(AppBundleMetadata.read(from: target)?.version == "0.1.4")
        #expect(AppBundleMetadata.read(from: previous)?.version == "0.1.3")
    }

    @Test("a swap with nothing staged leaves the app alone")
    func emptySwapLeavesTheAppAlone() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "Call Recorder.app")
        try makeBundle(at: target, version: "0.1.3")

        #expect(throws: AppBundleInstallerError.self) {
            try AppBundleInstaller.replace(
                target: target,
                with: root.appending(path: ".CallRecorder-staged.app")
            )
        }
        #expect(AppBundleMetadata.read(from: target)?.version == "0.1.3")
    }

    @Test("staging checks the version before it waits")
    func stagingChecksTheVersion() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "Call Recorder.app")
        try makeBundle(at: target, version: "0.1.3")
        let release = root.appending(path: "release/Call Recorder.app")
        try makeBundle(at: release, version: "0.1.4")
        let archive = root.appending(path: "CallRecorder-0.1.4.zip")
        try makeArchive(of: release, at: archive)
        let stager = AppUpdateStager(
            target: target,
            supportDirectory: root.appending(path: "Updates", directoryHint: .isDirectory)
        )

        #expect(throws: AppBundleInstallerError.self) {
            try stager.stage(
                archive: archive,
                version: "0.1.5",
                expectingIdentifier: "local.callrecorder.app",
                signer: nil
            )
        }
        #expect(stager.stagedVersion() == nil)

        try stager.stage(
            archive: archive,
            version: "0.1.4",
            expectingIdentifier: "local.callrecorder.app",
            signer: nil
        )
        #expect(stager.stagedVersion() == "0.1.4")
    }

    @Test("the version that was running is kept when the new one is installed")
    func theRunningVersionIsKept() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "Call Recorder.app")
        try makeBundle(at: target, version: "0.1.3")
        let release = root.appending(path: "release/Call Recorder.app")
        try makeBundle(at: release, version: "0.1.4")
        let support = root.appending(path: "Updates", directoryHint: .isDirectory)
        let stager = AppUpdateStager(target: target, supportDirectory: support)
        // The archive lives where the app keeps a download, and staging is what puts the checked
        // copy beside the app.
        let archive = stager.archive(version: "0.1.4")
        try FileManager.default.createDirectory(
            at: archive.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try makeArchive(of: release, at: archive)

        try stager.stage(
            archive: archive,
            version: "0.1.4",
            expectingIdentifier: "local.callrecorder.app",
            signer: nil
        )
        let installed = try stager.applyStaged()

        #expect(installed == "0.1.4")
        #expect(AppBundleMetadata.read(from: target)?.version == "0.1.4")
        // The way back is a whole bundle, not a note saying one could be downloaded again.
        #expect(stager.backupVersion() == "0.1.3")
        #expect(AppBundleInstaller.isSignatureValid(stager.backupBundle))
        #expect(stager.stagedVersion() == nil)
        // The archive stays, so repeating the update needs no network.
        #expect(FileManager.default.fileExists(atPath: stager.archive(version: "0.1.4").path))
    }

    @Test("the kept copy can be put back in the waiting place")
    func theKeptCopyCanBeStagedAgain() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "Call Recorder.app")
        try makeBundle(at: target, version: "0.1.4")
        let support = root.appending(path: "Updates", directoryHint: .isDirectory)
        let stager = AppUpdateStager(target: target, supportDirectory: support)
        let kept = root.appending(path: "kept/Call Recorder.app")
        try makeBundle(at: kept, version: "0.1.3")
        try FileManager.default.createDirectory(
            at: stager.backupBundle.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: kept, to: stager.backupBundle)

        let version = try stager.stageRollback(
            expectingIdentifier: "local.callrecorder.app",
            signer: nil
        )
        #expect(version == "0.1.3")
        #expect(stager.stagedVersion() == "0.1.3")
    }

    @Test("nothing is staged when there is no kept copy")
    func rollbackWithoutAKeptCopyDoesNothing() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "Call Recorder.app")
        try makeBundle(at: target, version: "0.1.4")
        let stager = AppUpdateStager(
            target: target,
            supportDirectory: root.appending(path: "Updates", directoryHint: .isDirectory)
        )

        #expect(throws: AppBundleInstallerError.self) {
            try stager.stageRollback(expectingIdentifier: "local.callrecorder.app", signer: nil)
        }
        #expect(stager.stagedVersion() == nil)
    }
}
