import Foundation
import Testing
@testable import CallRecorderCore

struct WhisperCLIVersionTests {
    @Test func readsTheVersionTheToolPrints() {
        // Given the tool's own output, which carries back-end noise around the version line.
        let output = """
            load_backend: loaded BLAS backend from /opt/homebrew/Cellar/ggml/0.17.0
            ggml_metal_device_init: GPU name: MTL0 (Apple M1 Max)
            whisper.cpp version: 1.9.1
            """

        // Then
        #expect(WhisperCLIVersion.parse(output) == "1.9.1")
    }

    @Test func aBuildThatPrintsNoVersionIsNotGuessed() {
        // Given output that carries no version line, or an empty one.
        // Then
        #expect(WhisperCLIVersion.parse("usage: whisper-cli [options] file0 file1 ...") == nil)
        #expect(WhisperCLIVersion.parse("whisper.cpp version:   ") == nil)
        #expect(WhisperCLIVersion.parse("") == nil)
    }

    @Test func readsTheVersionOutOfTheHomebrewInstallPath() {
        // Given the path a Homebrew install resolves to.
        let url = URL(filePath: "/opt/homebrew/Cellar/whisper.cpp/1.9.1/bin/whisper-cli")

        // Then
        #expect(WhisperCLIVersion.fromInstallPath(url) == "1.9.1")
    }

    @Test func aSourceBuildPathIsNotMistakenForAVersion() {
        // Given a checkout that also lives in a folder called whisper.cpp.
        let url = URL(filePath: "/Users/someone/src/whisper.cpp/bin/whisper-cli")

        // Then
        #expect(WhisperCLIVersion.fromInstallPath(url) == nil)
    }
}
