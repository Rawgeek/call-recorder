import Foundation
import Testing
@testable import CallRecorderCore
@testable import CallRecorderApp

@Suite("The screenshots folder is its own index")
struct ScreenshotArchiveTests {
    @Test("pictures are read back in the order they were taken")
    func readsPicturesInClockOrder() throws {
        let callDirectory = FileManager.default.temporaryDirectory
            .appending(path: "call-recorder-shots-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: callDirectory) }
        let directory = ScreenshotArchive.directory(in: callDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Written out of order, as a late write of an early frame would leave them.
        for name in [
            "shot-000012500-0000000000000002-000.jpg",
            "shot-000000000-0000000000000001-000.jpg",
        ] {
            try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: directory.appending(path: name))
        }
        try Data().write(to: directory.appending(path: "notes.txt"))

        let shots = ScreenshotArchive.read(in: callDirectory)

        #expect(shots.map(\.offsetMs) == [0, 12_500])
        #expect(shots.map(\.url.lastPathComponent) == [
            "shot-000000000-0000000000000001-000.jpg",
            "shot-000012500-0000000000000002-000.jpg",
        ])
    }

    @Test("a call with no folder has no pictures rather than a failure")
    func missingFolderIsEmpty() {
        let callDirectory = FileManager.default.temporaryDirectory
            .appending(path: "call-recorder-missing-\(UUID().uuidString)", directoryHint: .isDirectory)

        #expect(ScreenshotArchive.read(in: callDirectory).isEmpty)
    }

    @Test("a moment on the clock picks the closest photograph")
    func nearestPictureToAMoment() {
        let shots = [0, 5_000, 10_000, 20_000].map { offsetMs in
            CallScreenshot(
                url: URL(filePath: "/tmp/shot-\(offsetMs).jpg"),
                offsetMs: offsetMs,
                sequence: offsetMs
            )
        }

        #expect(ScreenshotSelection.nearest(to: 2_000, among: shots)?.offsetMs == 0)
        #expect(ScreenshotSelection.nearest(to: 4_000, among: shots)?.offsetMs == 5_000)
        #expect(ScreenshotSelection.nearest(to: 14_000, among: shots)?.offsetMs == 10_000)
        #expect(ScreenshotSelection.nearest(to: 60_000, among: shots)?.offsetMs == 20_000)
        #expect(ScreenshotSelection.nearest(to: 0, among: []) == nil)
    }

    @Test("Full HD caps a 4K display and keeps a MacBook's 16:10 frame")
    func fullHDFitsTheDisplay() {
        #expect(
            ScreenshotResolution.fullHD.targetSize(nativeWidth: 3840, nativeHeight: 2160)
                == (1920, 1080)
        )
        #expect(
            ScreenshotResolution.fullHD.targetSize(nativeWidth: 3024, nativeHeight: 1964)
                == (1_848, 1_200)
        )
        // A small display is not upscaled: the ceiling only decides when to shrink.
        #expect(
            ScreenshotResolution.fullHD.targetSize(nativeWidth: 1280, nativeHeight: 800)
                == (1280, 800)
        )
        #expect(
            ScreenshotResolution.hd.targetSize(nativeWidth: 3840, nativeHeight: 2160)
                == (1280, 720)
        )
        #expect(
            ScreenshotResolution.native.targetSize(nativeWidth: 3024, nativeHeight: 1964)
                == (3024, 1964)
        )
    }
}
