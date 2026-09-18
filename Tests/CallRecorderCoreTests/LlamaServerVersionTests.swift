import Foundation
import Testing
@testable import CallRecorderCore

@Suite("llama.cpp version")
struct LlamaServerVersionTests {
    @Test("reads the version llama.cpp prints")
    func readsTheVersionTheToolPrints() {
        let output = """
            version: 0.4.1 (build 10964, commit b29c606e2)
            built with AppleClang 21.0.0.21000334 for Darwin arm64
            """

        #expect(LlamaServerVersion.parse(output) == "0.4.1")
    }

    @Test("a build that prints no version is not guessed at")
    func aBuildWithoutAVersionIsNotGuessed() {
        #expect(LlamaServerVersion.parse("usage: llama-server [options]") == nil)
        #expect(LlamaServerVersion.parse("version:") == nil)
    }

    @Test("reads the version out of the Homebrew install path")
    func readsTheVersionOutOfTheHomebrewInstallPath() {
        let path = URL(filePath: "/opt/homebrew/Cellar/llama.cpp/0.4.1/bin/llama-server")

        #expect(LlamaServerVersion.fromInstallPath(path) == "0.4.1")
    }

    @Test("a source build path is not mistaken for a version")
    func aSourceBuildPathIsNotMistakenForAVersion() {
        let path = URL(filePath: "/Users/somebody/src/llama.cpp/build/bin/llama-server")

        #expect(LlamaServerVersion.fromInstallPath(path) == nil)
    }

    @Test("the brief model is the file the runtime is handed")
    func theBriefModelKnowsItsFile() {
        let component = SupportingModel.catalog.first { $0.id == CallBrief.modelID }

        #expect(component?.ggufFileName == "Qwen3.5-4B-Q4_K_M.gguf")
        #expect(component?.files.count == 1)
        // The digest is the publisher's own for these bytes, taken from the model host rather than
        // composed here.
        #expect(component?.files.first?.sha256.count == 64)
        #expect(component?.totalBytes == 2_740_937_888)
        // The row shows this label, and it is where the quantisation is named: the file that was
        // pinned and the words that describe it have to keep saying the same thing.
        #expect(component?.versionLabel.contains("4-bit") == true)
        #expect(component?.versionLabel.contains("Q4_K_M") == true)
    }

    @Test("a model that fits is told from one that would swap, with room to spare")
    func memoryFitLeavesHeadroom() throws {
        let component = try #require(SupportingModel.catalog.first { $0.id == CallBrief.modelID })

        // Sixteen gigabytes is the Mac this was measured on: the model and its headroom fit.
        #expect(component.memoryFit(inMemoryOf: 16 * 1_024 * 1_024 * 1_024) == .comfortable)
        // Two and a half gigabytes of weights is under three gigabytes with the headroom, so a Mac
        // that has three runs the model and swaps under it.
        #expect(component.memoryFit(inMemoryOf: 3 * 1_024 * 1_024 * 1_024) == .tight)
        // Two gigabytes cannot hold the file at all.
        #expect(component.memoryFit(inMemoryOf: 2 * 1_024 * 1_024 * 1_024) == .insufficient)
    }
}
