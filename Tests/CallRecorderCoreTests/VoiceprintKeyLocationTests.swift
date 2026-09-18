import Foundation
import Testing
@testable import CallRecorderApp
@testable import CallRecorderCore

/// Where the key that opens stored voice profiles is kept.
///
/// The login keychain answers a read by a program it does not recognise with a password dialog, and
/// a rebuild is a program it does not recognise. A development run therefore keeps the same key in
/// a file only this account can read, and the installed app keeps it in the keychain. What is
/// checked here is the file itself and the choice between the two: a key that survives a second
/// read, a file nobody else can read, and the cases that choose one store over the other.
@Suite("Voiceprint key location")
struct VoiceprintKeyLocationTests {
    private func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "voiceprint-key-\(UUID().uuidString)")
    }

    @Test("a file that is being seeded makes its own key when nothing is sealed yet")
    func seededFileWithNothingToOpenMakesAKey() throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = VoiceprintKeyStore.fileLocation(inApplicationDirectory: directory)

        // Nothing is stored yet, so there is nothing to ask the keychain for: the key is made here
        // and the keychain is never reached. A development run that has profiles to open does read
        // it, which is the one question such a run asks, and that path needs a keychain to test.
        let cipher = try VoiceprintKeyStore.loadOrCreate(
            hasEncryptedData: false,
            in: .fileSeededFromKeychain(url)
        )
        let envelope = try cipher.seal([1, 0], modelVersion: "v1")

        #expect(try cipher.open(envelope, modelVersion: "v1") == [1, 0])
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a file keeps the same key across runs, and only this account can read it")
    func theFileKeepsTheSameKey() throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = VoiceprintKeyStore.fileLocation(inApplicationDirectory: directory)

        let first = try VoiceprintKeyStore.loadOrCreate(hasEncryptedData: false, in: .file(url))
        // The second read has profiles to open, which is the run after the first: it must find the
        // key that sealed them rather than make another one.
        let second = try VoiceprintKeyStore.loadOrCreate(hasEncryptedData: true, in: .file(url))
        let envelope = try first.seal([0.5, 0.25], modelVersion: "v1")

        #expect(try second.open(envelope, modelVersion: "v1") == [0.5, 0.25])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("a key that is gone with profiles to open is a fault, not a new key")
    func aMissingKeyWithDataIsAFault() {
        let url = VoiceprintKeyStore.fileLocation(inApplicationDirectory: scratchDirectory())

        #expect(throws: VoiceprintKeyStoreError.missingKey) {
            _ = try VoiceprintKeyStore.loadOrCreate(hasEncryptedData: true, in: .file(url))
        }
    }

    @Test("a file that is not a key is refused rather than used")
    func aWrongSizedFileIsRefused() throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = VoiceprintKeyStore.fileLocation(inApplicationDirectory: directory)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 1, count: 8).write(to: url)

        #expect(throws: VoiceprintKeyStoreError.invalidStoredKey) {
            _ = try VoiceprintKeyStore.loadOrCreate(hasEncryptedData: true, in: .file(url))
        }
    }

    @Test("an installed app uses the keychain, a development run does not")
    func theChoiceFollowsTheBuild() {
        let directory = URL(filePath: "/tmp/call-recorder-choice", directoryHint: .isDirectory)
        let file = VoiceprintKeyLocation.fileSeededFromKeychain(
            VoiceprintKeyStore.fileLocation(inApplicationDirectory: directory)
        )

        // The app that ships: it has a bundle identifier and is not a render.
        #expect(
            VoiceprintKeyChoice.resolve(
                environment: [:],
                isPreview: false,
                bundleIdentifier: "local.callrecorder.app",
                applicationDirectory: directory
            ) == .keychain
        )
        // A binary built and started from the command line has no bundle identifier.
        #expect(
            VoiceprintKeyChoice.resolve(
                environment: [:],
                isPreview: false,
                bundleIdentifier: nil,
                applicationDirectory: directory
            ) == file
        )
        // A render reads the real library and must never raise a prompt over it.
        #expect(
            VoiceprintKeyChoice.resolve(
                environment: [:],
                isPreview: true,
                bundleIdentifier: "local.callrecorder.app",
                applicationDirectory: directory
            ) == file
        )
    }

    @Test("the environment can name either store")
    func theEnvironmentWins() {
        let directory = URL(filePath: "/tmp/call-recorder-choice", directoryHint: .isDirectory)
        let file = VoiceprintKeyLocation.fileSeededFromKeychain(
            VoiceprintKeyStore.fileLocation(inApplicationDirectory: directory)
        )

        #expect(
            VoiceprintKeyChoice.resolve(
                environment: ["CALL_RECORDER_VOICEPRINT_KEY": "keychain"],
                isPreview: true,
                bundleIdentifier: nil,
                applicationDirectory: directory
            ) == .keychain
        )
        #expect(
            VoiceprintKeyChoice.resolve(
                environment: ["CALL_RECORDER_VOICEPRINT_KEY": "file"],
                isPreview: false,
                bundleIdentifier: "local.callrecorder.app",
                applicationDirectory: directory
            ) == file
        )
    }
}
