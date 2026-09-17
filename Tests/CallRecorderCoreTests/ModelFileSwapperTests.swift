import Foundation
import Testing
@testable import CallRecorderCore

@Suite("Model file swaps")
struct ModelFileSwapperTests {
    /// A directory holding the three positions a model file can occupy.
    private func makeDirectory() throws -> URL {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "swap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    @Test("a swap installs the new file and keeps the old one")
    func swapKeepsPrevious() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "model.bin")
        let previous = directory.appending(path: "model.bin.previous")
        let staged = directory.appending(path: "model.bin.partial")
        try write("old", to: destination)
        try write("new", to: staged)

        let kept = try ModelFileSwapper.swapIn(
            verified: staged,
            destination: destination,
            previous: previous
        )

        #expect(kept)
        #expect(try read(destination) == "new")
        #expect(try read(previous) == "old")
        // The staged file has been moved, not copied.
        #expect(FileManager.default.fileExists(atPath: staged.path) == false)
    }

    @Test("a first install leaves nothing to revert to")
    func firstInstallKeepsNothing() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "model.bin")
        let previous = directory.appending(path: "model.bin.previous")
        let staged = directory.appending(path: "model.bin.partial")
        try write("first", to: staged)

        let kept = try ModelFileSwapper.swapIn(
            verified: staged,
            destination: destination,
            previous: previous
        )

        #expect(kept == false)
        #expect(try read(destination) == "first")
        #expect(FileManager.default.fileExists(atPath: previous.path) == false)
    }

    @Test("a second update replaces the kept copy rather than stacking up")
    func secondUpdateReplacesPrevious() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "model.bin")
        let previous = directory.appending(path: "model.bin.previous")

        for value in ["one", "two", "three"] {
            let staged = directory.appending(path: "staged-\(value)")
            try write(value, to: staged)
            try ModelFileSwapper.swapIn(verified: staged, destination: destination, previous: previous)
        }

        #expect(try read(destination) == "three")
        #expect(try read(previous) == "two")
    }

    @Test("a revert brings back the kept copy and consumes it")
    func revertRestores() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "model.bin")
        let previous = directory.appending(path: "model.bin.previous")
        try write("old", to: destination)
        let staged = directory.appending(path: "model.bin.partial")
        try write("new", to: staged)
        try ModelFileSwapper.swapIn(verified: staged, destination: destination, previous: previous)

        try ModelFileSwapper.revert(destination: destination, previous: previous)

        #expect(try read(destination) == "old")
        #expect(FileManager.default.fileExists(atPath: previous.path) == false)
        // No staging file is left behind by the revert.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers == ["model.bin"])
    }

    @Test("reverting without a kept copy fails instead of emptying the slot")
    func revertWithoutPreviousThrows() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "model.bin")
        let previous = directory.appending(path: "model.bin.previous")
        try write("current", to: destination)

        #expect(throws: ModelUpdateError.noEarlierCopy) {
            try ModelFileSwapper.revert(destination: destination, previous: previous)
        }
        // The working model is untouched by the failed attempt.
        #expect(try read(destination) == "current")
    }

    @Test("removing a model also removes the copy kept from the last update")
    func removeTakesPrevious() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "model.bin")
        let previous = directory.appending(path: "model.bin.previous")
        try write("old", to: destination)
        let staged = directory.appending(path: "staged")
        try write("new", to: staged)
        try ModelFileSwapper.swapIn(verified: staged, destination: destination, previous: previous)

        try ModelFileSwapper.remove(destination: destination, previous: previous)

        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
        #expect(FileManager.default.fileExists(atPath: previous.path) == false)
    }

    @Test("removing a model that was never updated is not an error")
    func removeWithoutPrevious() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "model.bin")
        try write("only", to: destination)
        try ModelFileSwapper.remove(
            destination: destination,
            previous: directory.appending(path: "model.bin.previous")
        )
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }
}
