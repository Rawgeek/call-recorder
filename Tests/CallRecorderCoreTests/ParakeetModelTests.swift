import Foundation
import Testing
@testable import CallRecorderCore
@testable import CallRecorderApp

/// The Parakeet model on disk: what a complete install is, and what the app does without one.
@Suite("The Parakeet model a call is read with")
struct ParakeetModelTests {
    private func makeRepository(holding names: [String]) throws -> URL {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "parakeet-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in names {
            let url = root.appending(path: name)
            if name.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try Data("{}".utf8).write(to: url)
            }
        }
        return root
    }

    @Test("an install that holds every part of the model is complete")
    func aWholeInstallIsComplete() throws {
        let repository = try makeRepository(holding: ParakeetModel.requiredFileNames)
        defer { try? FileManager.default.removeItem(at: repository) }

        #expect(ParakeetModel.isComplete(at: repository))
    }

    @Test("an install missing the vocabulary is not complete")
    func aVocabularylessInstallIsNotComplete() throws {
        // The graphs load and then decode nothing without it, which fails a call at the end of its
        // own work. The check has to catch it here instead.
        let repository = try makeRepository(
            holding: ParakeetModel.requiredFileNames.filter { $0 != "parakeet_vocab.json" }
        )
        defer { try? FileManager.default.removeItem(at: repository) }

        #expect(!ParakeetModel.isComplete(at: repository))
    }

    @Test("an install missing one of the four graphs is not complete")
    func aPartialInstallIsNotComplete() throws {
        let repository = try makeRepository(
            holding: ParakeetModel.requiredFileNames.filter { $0 != "Encoder.mlmodelc" }
        )
        defer { try? FileManager.default.removeItem(at: repository) }

        #expect(!ParakeetModel.isComplete(at: repository))
    }

    @Test("no model at all is not complete, and reports nothing on disk")
    func anAbsentModelIsNotComplete() {
        let applicationDirectory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "parakeet-app-" + UUID().uuidString, directoryHint: .isDirectory)

        #expect(!ParakeetModel.isComplete(in: applicationDirectory))
        #expect(ParakeetModel.installedBytes(in: applicationDirectory) == 0)
    }

    @Test("the model lives beside the whisper files, in the folder it is published under")
    func theModelLivesBesideTheWhisperFiles() {
        let applicationDirectory = URL(filePath: "/tmp/somewhere", directoryHint: .isDirectory)
        let repository = ParakeetModel.repository(in: applicationDirectory)

        #expect(repository.lastPathComponent == ParakeetModel.repositoryFolderName)
        #expect(repository.deletingLastPathComponent().lastPathComponent == "models")
    }
}

/// What the transcript says the call was read with, once the model has read it.
@Suite("Naming a language for a reading")
struct SpeechEngineLanguageTests {
    @Test("a language the setting named is the language the transcript carries")
    func aNamedLanguageIsCarried() {
        #expect(SpeechEngineChoice.transcriptLanguage(requested: "ru", text: "hello") == "ru")
        #expect(SpeechEngineChoice.transcriptLanguage(requested: "RU", text: "hello") == "ru")
        #expect(SpeechEngineChoice.transcriptLanguage(requested: "en-GB", text: "привет") == "en")
    }

    @Test("a call read in Russian words is named as Russian when nothing was chosen")
    func russianWordsAreNamed() {
        let text = "Спасибо всем, что присоединились."
        #expect(SpeechEngineChoice.transcriptLanguage(requested: "auto", text: text) == "ru")
    }

    @Test("a call read in Latin words is named as English when nothing was chosen")
    func latinWordsAreNamed() {
        #expect(
            SpeechEngineChoice.transcriptLanguage(requested: "auto", text: "Thanks everyone.")
                == "en"
        )
    }
}
