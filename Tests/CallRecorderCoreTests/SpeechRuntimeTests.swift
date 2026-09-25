import Foundation
import Testing
@testable import CallRecorderApp

/// The versions the app reads calls with.
///
/// A reading is built from the shapes a library hands back, so the library's release is part of what
/// a transcript says. These check that the pins are read as versions at all: an environment holding
/// another release must be reported rather than used. The 2026-09-25 investigation into a long call
/// that lost its second half is why they are pinned.
@Suite("Speech runtime versions")
struct SpeechRuntimeVersionTests {
    @Test("a pin names the version the check compares against")
    func pinsBecomeVersions() {
        let expected = SpeechRuntimeRequirement.expectedVersions

        #expect(expected["mlx"] == "0.32.2")
        #expect(expected["mlx-audio"] == "0.5.6")
        #expect(expected.count == SpeechRuntimeRequirement.packages.count)
    }

    @Test("the spellings of a distribution name are one name")
    func namesAreFolded() {
        // The pin writes mlx-audio and its own metadata answers mlx_audio; a check that treated
        // those as two names would report every environment as holding another version.
        #expect(
            SpeechRuntimeRequirement.distributionKey("mlx_audio")
                == SpeechRuntimeRequirement.distributionKey("mlx-audio")
        )
        #expect(
            SpeechRuntimeRequirement.distributionKey("Qwen3.ASR")
                == SpeechRuntimeRequirement.distributionKey("qwen3-asr")
        )
    }

    @Test("a pin that names a library and not a release asks for nothing to match")
    func anUnpinnedNameIsSkipped() {
        // The parser drops what it cannot read rather than inventing a version: a pin written as a
        // bare name, or with a range, must not make the check compare against an empty string.
        #expect(SpeechRuntimeRequirement.distributionKey("mlx") == "mlx")
        #expect(!SpeechRuntimeRequirement.expectedVersions.keys.contains(""))
        #expect(SpeechRuntimeRequirement.expectedVersions.values.allSatisfy { !$0.isEmpty })
    }

    @Test("a person's own interpreter is used before the app's own")
    func aChosenInterpreterWins() {
        // The same environment serves the speaker analysis, so the choice in Speaker setup decides
        // for both jobs. Reading the environment variable as well is what lets a test, or a run
        // from a shell, point the app at an environment without touching the stored setting.
        let application = URL(filePath: "/tmp/speech-runtime", directoryHint: .isDirectory)
        let chosen = "/opt/example/bin/python3"
        let suite = UserDefaults(suiteName: "speech-runtime-tests-\(UUID().uuidString)")
        defer { suite?.removePersistentDomain(forName: "speech-runtime-tests") }

        #expect(
            SpeechRuntimeRequirement.python(
                applicationDirectory: application,
                defaults: suite!
            )?.path == SpeechRuntimeRequirement.managed(applicationDirectory: application).path
        )
        suite?.set(chosen, forKey: "speaker-python")
        #expect(
            SpeechRuntimeRequirement.python(
                applicationDirectory: application,
                defaults: suite!
            )?.path == chosen
        )
        #expect(
            SpeechRuntimeRequirement.configured(defaults: suite!, environment: [:])?.path == chosen
        )
    }
}

/// Finding a Python that can build the environment.
///
/// The app carries no interpreter, so a Mac with nothing but an old /usr/bin/python3 has to be
/// answered rather than crashed into: the search skips it and the row says which Python to install.
@Suite("Speech environment")
struct SpeechEnvironmentTests {
    @Test("the first interpreter that is here and new enough is the one used")
    func theSearchSkipsWhatItCannotUse() {
        let present = URL(filePath: "/opt/homebrew/bin/python3")
        let old = URL(filePath: "/usr/bin/python3")

        // Homebrew's Python is there and answers yes: it is used.
        #expect(
            SpeechEnvironmentInterpreter.base(
                candidates: [present.path, old.path],
                isExecutable: { _ in true },
                probe: { $0 == present }
            ) == present
        )
        // The same Mac, with only the old one: nothing is usable, and the message names why.
        #expect(
            SpeechEnvironmentInterpreter.base(
                candidates: [present.path, old.path],
                isExecutable: { _ in true },
                probe: { _ in false }
            ) == nil
        )
        // An interpreter that is not installed is not probed at all.
        #expect(
            SpeechEnvironmentInterpreter.base(
                candidates: [present.path],
                isExecutable: { _ in false },
                probe: { _ in true }
            ) == nil
        )
    }

    @Test("the oldest version the packages are published for is named")
    func theFloorIsNamed() {
        #expect(SpeechEnvironmentInterpreter.minimumVersion == (3, 10))
        let message = SpeechRuntime.missingInterpreterMessage(canBuild: true)
        #expect(message.contains("3.10"))
    }

    @Test("a missing interpreter that the app may not build is reported as gone")
    func aChosenInterpreterThatIsGoneIsNotRecreated() {
        let message = SpeechRuntime.missingInterpreterMessage(canBuild: false)
        #expect(message.contains("Speaker setup"))
        #expect(!message.contains("python.org"))
    }

    @Test("only the app's own environment may be built")
    @MainActor
    func onlyTheAppsOwnEnvironmentIsBuilt() {
        let managed = URL(filePath: "/tmp/call-recorder-speech/python/bin/python3")
        let chosen = URL(filePath: "/opt/example/bin/python3")

        // Writing an environment at a path a person chose, without asking, would put hundreds of
        // megabytes somewhere they did not agree to. The app's own path is fair game.
        #expect(SpeechRuntime(python: managed, managedPython: managed).canBuildEnvironment)
        #expect(!SpeechRuntime(python: chosen, managedPython: managed).canBuildEnvironment)
        #expect(!SpeechRuntime(python: chosen, managedPython: nil).canBuildEnvironment)

        // Choosing an environment in Speaker setup moves the row onto it: the choice is about both
        // jobs the app runs in Python, and the row has to report what is in use now.
        let moved = SpeechRuntime(python: nil, managedPython: managed)
        #expect(!moved.canBuildEnvironment)
        moved.use(python: managed)
        #expect(moved.python == managed)
        #expect(moved.canBuildEnvironment)
    }
}
