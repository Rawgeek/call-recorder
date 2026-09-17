import Foundation
import Testing
@testable import CallRecorderCore

@Suite("App releases")
struct AppUpdatesTests {
    /// A release list shaped like the host's own, including everything the app has to survive:
    /// a draft, a pre-release, the runtime release, and a version published without its archive.
    private let releaseList = """
    [
      {
        "tag_name": "v0.2.0",
        "html_url": "https://github.com/Rawgeek/call-recorder/releases/tag/v0.2.0",
        "draft": false,
        "prerelease": false,
        "published_at": "2026-10-01T10:00:00Z",
        "assets": [
          {
            "name": "CallRecorder-0.2.0.zip",
            "size": 6000000,
            "browser_download_url": "https://example.test/CallRecorder-0.2.0.zip",
            "digest": "sha256:aa11bb22cc33dd44ee55ff66aa77bb88cc99dd00ee11ff22aa33bb44cc55dd66"
          }
        ]
      },
      {
        "tag_name": "v0.1.9",
        "html_url": "https://github.com/Rawgeek/call-recorder/releases/tag/v0.1.9",
        "draft": false,
        "prerelease": false,
        "published_at": "2026-09-30T10:00:00Z",
        "assets": []
      },
      {
        "tag_name": "v0.1.8",
        "html_url": "https://github.com/Rawgeek/call-recorder/releases/tag/v0.1.8",
        "draft": false,
        "prerelease": true,
        "published_at": "2026-09-29T10:00:00Z",
        "assets": [
          {
            "name": "CallRecorder-0.1.8.zip",
            "size": 5900000,
            "browser_download_url": "https://example.test/CallRecorder-0.1.8.zip",
            "digest": null
          }
        ]
      },
      {
        "tag_name": "runtime-0e3810d9",
        "html_url": "https://github.com/Rawgeek/call-recorder/releases/tag/runtime-0e3810d9",
        "draft": false,
        "prerelease": false,
        "published_at": "2026-09-17T13:19:47Z",
        "assets": [
          {
            "name": "CallRecorder-runtime-0e3810d9.zip",
            "size": 36437239,
            "browser_download_url": "https://example.test/CallRecorder-runtime-0e3810d9.zip",
            "digest": "sha256:0e3810d925063026fff348f2ca071beeee6504fb9e7671c39c7e808fe77ee1f5"
          }
        ]
      },
      {
        "tag_name": "v0.1.5",
        "html_url": "https://github.com/Rawgeek/call-recorder/releases/tag/v0.1.5",
        "draft": true,
        "prerelease": false,
        "published_at": "2026-09-20T10:00:00Z",
        "assets": [
          {
            "name": "CallRecorder-0.1.5.zip",
            "size": 5800000,
            "browser_download_url": "https://example.test/CallRecorder-0.1.5.zip",
            "digest": null
          }
        ]
      },
      {
        "tag_name": "v0.1.4",
        "html_url": "https://github.com/Rawgeek/call-recorder/releases/tag/v0.1.4",
        "draft": false,
        "prerelease": false,
        "published_at": "2026-09-18T10:00:00Z",
        "assets": [
          {
            "name": "CallRecorder-0.1.4.zip",
            "size": 5833233,
            "browser_download_url": "https://example.test/CallRecorder-0.1.4.zip",
            "digest": "sha256:2ac2a42b04d6e9b863b39c8259d4410080c2b5553354bc0d483133044d9862b1"
          }
        ]
      },
      {
        "tag_name": "v0.1.3",
        "html_url": "https://github.com/Rawgeek/call-recorder/releases/tag/v0.1.3",
        "draft": false,
        "prerelease": false,
        "published_at": "2026-09-17T13:22:28Z",
        "assets": [
          {
            "name": "CallRecorder-0.1.3.zip",
            "size": 5833233,
            "browser_download_url": "https://example.test/CallRecorder-0.1.3.zip",
            "digest": "sha256:2ac2a42b04d6e9b863b39c8259d4410080c2b5553354bc0d483133044d9862b1"
          }
        ]
      }
    ]
    """

    @Test("the settings menu offers six steps, and they only get longer")
    func theCheckStepMenuOffersSixStepsInOrder() {
        // Given the steps the menu is built from.
        let steps = AppUpdateInterval.allCases

        // Then there are six of them, in order, and each one is a step further apart than the one
        // before: a menu of six options is a choice rather than a form to fill in.
        #expect(steps.count == 6)
        #expect(steps.map(\.seconds) == steps.map(\.seconds).sorted())
        #expect(Set(steps.map(\.seconds)).count == 6)
        #expect(steps.first == .everyThirtyMinutes)
        #expect(steps.last == .daily)
        // And the app keeps checking on the step it shipped with, so a Mac that never opens this
        // setting behaves exactly as it did before the setting existed.
        #expect(AppUpdateInterval.default == .everySixHours)
        #expect(AppUpdateInterval.default.seconds == 6 * 60 * 60)
    }

    @Test("every step says itself as a menu item and inside a sentence")
    func everyStepHasItsOwnWords() {
        let steps = AppUpdateInterval.allCases
        #expect(steps.allSatisfy { !$0.title.isEmpty && !$0.phrase.isEmpty })
        // The phrase continues a sentence that starts with a small letter, as in "Checked at launch
        // and every 6 hours."
        #expect(steps.allSatisfy { $0.phrase.first?.isLowercase == true })
        #expect(steps.allSatisfy { $0.title.first?.isUppercase == true })
        #expect(Set(steps.map(\.title)).count == 6)
        #expect(AppUpdateInterval.everySixHours.phrase == "every 6 hours")
    }

    @Test("a later version reads as later")
    func laterVersionsReadAsLater() {
        #expect(AppVersionOrder.isNewer("0.1.4", than: "0.1.3"))
        #expect(AppVersionOrder.isNewer("v0.2.0", than: "0.1.9"))
        #expect(AppVersionOrder.isNewer("0.1.10", than: "0.1.9"))
        #expect(AppVersionOrder.isNewer("0.2", than: "0.1.9"))
        #expect(!AppVersionOrder.isNewer("0.1.3", than: "0.1.3"))
        #expect(!AppVersionOrder.isNewer("0.1.3", than: "0.1.4"))
        // A missing component counts as zero, so a tag that drops the patch is not an update.
        #expect(!AppVersionOrder.isNewer("0.1", than: "0.1.0"))
    }

    @Test("a tag that is not a version names no version")
    func nonVersionTagsAreRefused() {
        #expect(AppVersionOrder.numbers(in: "runtime-0e3810d9") == nil)
        #expect(AppVersionOrder.numbers(in: "v") == nil)
        #expect(AppVersionOrder.numbers(in: "0.1.x") == nil)
        #expect(!AppVersionOrder.isNewer("runtime-0e3810d9", than: "0.1.3"))
    }

    @Test("the release list keeps only what could be installed")
    func releaseListIsFiltered() throws {
        let releases = try AppReleaseCatalog.parse(Data(releaseList.utf8))
        let versions = releases.map(\.version)
        // The pre-release, the draft, and the runtime release are all gone. The release without
        // an archive stays: the app has to be able to say why it is not offered.
        #expect(!versions.contains("0.1.8"))
        #expect(!versions.contains("0.1.5"))
        #expect(!versions.contains(where: { $0.contains("runtime") }))
        #expect(versions == ["0.2.0", "0.1.9", "0.1.4", "0.1.3"])
        #expect(releases.first(where: { $0.version == "0.1.9" })?.asset == nil)
    }

    @Test("the archive is chosen by the version it carries")
    func archiveMatchesTheVersion() throws {
        let releases = try AppReleaseCatalog.parse(Data(releaseList.utf8))
        let release = try #require(releases.first(where: { $0.version == "0.1.4" }))
        let asset = try #require(release.asset)
        #expect(asset.name == "CallRecorder-0.1.4.zip")
        #expect(asset.bytes == 5_833_233)
        #expect(asset.sha256 == "2ac2a42b04d6e9b863b39c8259d4410080c2b5553354bc0d483133044d9862b1")
        #expect(release.publishedAt != nil)
    }

    @Test("a digest that is not a sha256 is not treated as one")
    func foreignDigestsAreRefused() {
        let asset = AppReleaseAsset(
            name: "CallRecorder-0.2.0.zip",
            bytes: 1,
            downloadURL: URL(string: "https://example.test/a.zip")!,
            digest: "sha512:abcd"
        )
        #expect(asset.sha256 == nil)
        let short = AppReleaseAsset(
            name: "CallRecorder-0.2.0.zip",
            bytes: 1,
            downloadURL: URL(string: "https://example.test/a.zip")!,
            digest: "sha256:abcd"
        )
        #expect(short.sha256 == nil)
    }

    @Test("the newest release is offered")
    func newestReleaseIsOffered() throws {
        let releases = try AppReleaseCatalog.parse(Data(releaseList.utf8))
        let decision = AppReleaseCatalog.decision(releases: releases, currentVersion: "0.1.3")
        guard case .update(let release) = decision else {
            Issue.record("expected an update, got \(decision)")
            return
        }
        #expect(release.version == "0.2.0")
    }

    @Test("a release without an archive is reported, not installed")
    func releaseWithoutArchiveIsReported() throws {
        // The newest version on offer is the one with nothing to install, which is the case the
        // app has to speak about rather than quietly treating as current.
        let releases = [
            AppRelease(
                tag: "v0.1.9",
                version: "0.1.9",
                pageURL: URL(string: "https://example.test/0.1.9")!,
                publishedAt: nil,
                asset: nil
            )
        ]
        let decision = AppReleaseCatalog.decision(releases: releases, currentVersion: "0.1.8")
        guard case .cannotVerify(let reason) = decision else {
            Issue.record("expected no verdict, got \(decision)")
            return
        }
        #expect(reason.contains("0.1.9"))
        #expect(reason.contains("archive"))
    }

    @Test("the newest version is what is up to date")
    func newestVersionIsUpToDate() throws {
        let releases = try AppReleaseCatalog.parse(Data(releaseList.utf8))
        #expect(
            AppReleaseCatalog.decision(releases: releases, currentVersion: "0.2.0")
                == .upToDate(version: "0.2.0")
        )
    }

    @Test("a copy that reports no version is not compared against anything")
    func unreadableVersionHasNoVerdict() throws {
        let releases = try AppReleaseCatalog.parse(Data(releaseList.utf8))
        let decision = AppReleaseCatalog.decision(releases: releases, currentVersion: "development")
        #expect(!decision.isUpdateAvailable)
        if case .cannotVerify = decision {} else {
            Issue.record("expected no verdict, got \(decision)")
        }
    }

    @Test("a body that is not a release list is refused")
    func malformedBodyIsRefused() {
        #expect(throws: (any Error).self) {
            try AppReleaseCatalog.parse(Data("not json".utf8))
        }
    }

    @Test(
        "the live release list parses and offers a newer version",
        .enabled(if: ProcessInfo.processInfo.environment["CALL_RECORDER_LIVE_UPDATE_CHECK"] == "1")
    )
    func liveReleaseListParses() async throws {
        var request = URLRequest(url: AppReleaseCatalog.url(repository: "Rawgeek/call-recorder"))
        request.setValue("CallRecorder", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let releases = try AppReleaseCatalog.parse(data)
        #expect(!releases.isEmpty)
        let decision = AppReleaseCatalog.decision(releases: releases, currentVersion: "0.1.0")
        guard case .update(let release) = decision else {
            Issue.record("expected an update, got \(decision)")
            return
        }
        #expect(release.asset?.sha256 != nil)
    }
}
