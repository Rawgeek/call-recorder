import Foundation
import Testing
@testable import CallRecorderCore

@Suite("App Store distribution policy")
struct AppStoreDistributionTests {
    @Test("the App Store value disables executable distribution features")
    func appStorePolicy() {
        let channel = DistributionChannel.resolve(infoDictionary: [
            DistributionChannel.infoDictionaryKey: "app-store"
        ])

        #expect(channel == .appStore)
        #expect(!channel.allowsSelfUpdate)
        #expect(!channel.allowsExternalToolSelection)
        #expect(!channel.allowsDownloadedExecutableRuntime)
        #expect(!channel.allowsVoiceIdentity)
        #expect(channel.usesSecurityScopedOutputBookmarks)
    }

    @Test("missing, malformed, and unknown values preserve direct distribution")
    func conservativeFallback() {
        let direct = DistributionChannel.resolve(infoDictionary: nil)

        #expect(direct == .direct)
        #expect(direct.allowsSelfUpdate)
        #expect(direct.allowsExternalToolSelection)
        #expect(direct.allowsDownloadedExecutableRuntime)
        #expect(direct.allowsVoiceIdentity)
        #expect(!direct.usesSecurityScopedOutputBookmarks)
        #expect(DistributionChannel.resolve(infoDictionary: [:]) == .direct)
        #expect(DistributionChannel.resolve(infoDictionary: [
            DistributionChannel.infoDictionaryKey: 1
        ]) == .direct)
        #expect(DistributionChannel.resolve(infoDictionary: [
            DistributionChannel.infoDictionaryKey: "enterprise"
        ]) == .direct)
        #expect(DistributionChannel.resolve(infoDictionary: [
            DistributionChannel.infoDictionaryKey: "direct"
        ]) == .direct)
    }

    @Test("fresh settings require recording consent and use Application Support")
    func safeDefaults() {
        let settings = AppSettings.defaults(for: .appStore)
        let expectedDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appending(path: "CallRecorder/Recordings", directoryHint: .isDirectory).path

        #expect(!settings.automaticDetectionEnabled)
        #expect(settings.outputDirectory == expectedDirectory)
    }

    @Test("direct distribution keeps its historical fresh-install defaults")
    func directDefaults() {
        let settings = AppSettings.defaults(for: .direct)
        let expectedDirectory = FileManager.default.urls(
            for: .desktopDirectory,
            in: .userDomainMask
        )[0]
            .appending(path: "Call Recordings", directoryHint: .isDirectory).path

        #expect(settings.automaticDetectionEnabled)
        #expect(settings.outputDirectory == expectedDirectory)
    }

    @Test("explicit persisted recording choices are preserved")
    func persistedAutomaticRecordingChoice() throws {
        let enabled = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"automaticDetectionEnabled":true}"#.utf8)
        )
        let disabled = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"automaticDetectionEnabled":false}"#.utf8)
        )

        #expect(enabled.automaticDetectionEnabled)
        #expect(!disabled.automaticDetectionEnabled)

        // This key predates the resilient decoder. Treat a blob without it as an existing
        // installation, not as a first launch, so changing the fresh default does not silently
        // turn off recording for someone who already uses the app.
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(legacy.automaticDetectionEnabled)
    }
}
