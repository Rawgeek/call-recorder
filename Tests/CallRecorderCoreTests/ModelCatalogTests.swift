import Foundation
import Testing
@testable import CallRecorderCore

struct ModelCatalogTests {
    @Test func defaultsToMultilingualSmallModelAndDesktopOutput() {
        // Given / When
        let settings = AppSettings.default

        // Then
        #expect(settings.automaticDetectionEnabled)
        #expect(settings.selectedMicrophoneID == nil)
        #expect(settings.selectedWhisperModelID == "small")
        #expect(settings.outputDirectory.hasSuffix("/Desktop/Call Recordings"))
    }

    @Test func catalogContainsOnlyPinnedMultilingualModels() {
        // Given / When
        let models = WhisperModel.catalog

        // Then
        #expect(models.map(\.id) == ["tiny", "base", "small", "medium"])
        #expect(models.allSatisfy { !$0.fileName.contains(".en.") })
        #expect(models.allSatisfy { $0.sha256.count == 64 && $0.expectedBytes > 0 })
        #expect(Set(models.map(\.downloadURL)).count == models.count)
    }

    @Test func olderSettingsRemainDecodableWithoutAMicrophoneSelection() throws {
        // Given
        let data = Data(
            #"{"automaticDetectionEnabled":true,"automaticStopGraceSeconds":2,"selectedWhisperModelID":"small","outputDirectory":"/tmp"}"#.utf8
        )

        // When
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        // Then
        #expect(settings.selectedMicrophoneID == nil)
        #expect(settings.localParticipantID == nil)
    }

    @Test func verifierRequiresExactSizeAndSHA256() throws {
        // Given
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "call-recorder-model-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "model.bin")
        try Data("model".utf8).write(to: file)

        // When / Then
        #expect(
            try ModelFileVerifier.verify(
                fileAt: file,
                expectedBytes: 5,
                sha256: "9372c470eeadd5ecd9c3c74c2b3cb633f8e2f2fad799250a0f70d652b6b825e4"
            )
        )
        #expect(
            try !ModelFileVerifier.verify(
                fileAt: file,
                expectedBytes: 4,
                sha256: "9372c470eeadd5ecd9c3c74c2b3cb633f8e2f2fad799250a0f70d652b6b825e4"
            )
        )
    }
}
