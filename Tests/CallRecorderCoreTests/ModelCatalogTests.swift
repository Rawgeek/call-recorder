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

    @Test func catalogCoversEveryWhisperModelIncludingLargeAndTurbo() {
        // Given / When
        let models = WhisperModel.catalog

        // Then
        #expect(
            models.map(\.id) == [
                "tiny", "tiny.en", "base", "base.en", "small", "small.en",
                "medium", "medium.en", "large-v2", "large-v3", "large-v3-turbo",
            ]
        )
        #expect(models.contains { $0.id == "large-v3-turbo" })
        #expect(models.allSatisfy { $0.sha256.count == 64 && $0.expectedBytes > 0 })
        #expect(Set(models.map(\.downloadURL)).count == models.count)
        #expect(models.allSatisfy { $0.downloadURL.path.contains(WhisperModel.pinnedRevision) })
    }

    @Test func everyModelCarriesTheGuidanceTheModelsPageShows() {
        // Given
        let models = WhisperModel.catalog

        // Then every row has the figures the comparison table prints.
        for model in models {
            #expect(!model.parameters.isEmpty)
            #expect(model.memoryBytes > 0)
            #expect(!model.requiredVRAM.isEmpty)
            #expect(!model.speed.isEmpty)
            #expect(model.englishWordErrorRate != nil)
        }
        // English-only files say so in the name, and they are the ones without a multilingual
        // score. A multilingual model names the English-only twin a reader can choose instead.
        for model in models where model.englishOnly {
            #expect(model.fileName.contains(".en.bin"))
            #expect(model.multilingualWordErrorRate == nil)
            #expect(model.englishTwinID == nil)
        }
        for model in models where !model.englishOnly {
            #expect(model.multilingualWordErrorRate != nil)
            // Only the smaller sizes have an English-only file to point at; OpenAI publishes
            // no English-only large or turbo model.
            if let twinID = model.englishTwinID {
                #expect(models.first { $0.id == twinID }?.englishOnly == true)
            } else {
                #expect(model.id.hasPrefix("large"))
            }
        }
    }

    @Test func theMemoryWarningKeepsThirtyPercentInReserve() throws {
        // Given
        let tiny = try #require(WhisperModel.catalog.first { $0.id == "tiny" })
        let large = try #require(WhisperModel.catalog.first { $0.id == "large-v3" })

        // Then the recommendation is the published working set plus thirty percent.
        #expect(tiny.recommendedMemoryBytes == tiny.memoryBytes * 13 / 10)
        #expect(tiny.fits(inMemoryOf: 8_000_000_000))
        // Large v3 needs 3.9 GB of working set, so 4 GB of memory is not enough with headroom.
        #expect(!large.fits(inMemoryOf: 4_000_000_000))
        #expect(large.fits(inMemoryOf: 16_000_000_000))
    }

    @Test func theThreeColoursSayWhichFailureAModelHas() throws {
        // Given a model whose working set is 2.1 GB, so its headroom line is 2.73 GB.
        let medium = try #require(WhisperModel.catalog.first { $0.id == "medium" })

        // Then a Mac above the headroom line is comfortable, one between the working set and the
        // headroom is tight, and one below the working set is too small.
        #expect(medium.memoryFit(inMemoryOf: 8_000_000_000) == .comfortable)
        #expect(medium.memoryFit(inMemoryOf: 2_500_000_000) == .tight)
        #expect(medium.memoryFit(inMemoryOf: 2_000_000_000) == .insufficient)
        // The boundary counts as comfortable, because it is the point the app promises.
        #expect(medium.memoryFit(inMemoryOf: medium.recommendedMemoryBytes) == .comfortable)
    }

    @Test func thePagePointsAtTwoModelsAndNoOthers() {
        // Given / When
        let recommended = WhisperModel.catalog.filter(\.isRecommended).map(\.id)

        // Then
        #expect(recommended == ["small", "large-v3-turbo"])
    }

    @Test func thePageShowsFourModelsBeforeItIsAskedForMore() {
        // Given / When the four the card lists without being unfolded.
        let listed = WhisperModel.catalog.filter(\.isPrimary).map(\.id)

        // Then one per kind of decision, so both picks are in the first screen and neither the
        // English-only twins nor the older large files are.
        #expect(listed == WhisperModel.primaryIDs)
        #expect(listed == ["base", "small", "medium", "large-v3-turbo"])
        #expect(WhisperModel.catalog.filter(\.isPrimary).allSatisfy { $0.englishWordErrorRate != nil })
        #expect(listed.contains("large-v3-turbo"))
    }

    @Test func sizeLabelsStateFileAndMemorySizesTheWayTheModelTableDoes() {
        #expect(ModelSizeLabel.file(bytes: 487_601_967) == "465 MiB")
        #expect(ModelSizeLabel.file(bytes: 3_095_033_483) == "2.9 GiB")
        #expect(ModelSizeLabel.memory(bytes: 852_000_000) == "852 MB")
        #expect(ModelSizeLabel.memory(bytes: 2_100_000_000) == "2.1 GB")
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
