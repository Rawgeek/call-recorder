import Foundation
import Testing
@testable import CallRecorderApp

/// Serves a fixed body in chunks, so a download has progress to report.
final class ModelDownloadStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var chunkBytes = 32 * 1024

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.body
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid/model.bin")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(body.count)]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var offset = 0
        while offset < body.count {
            let end = min(offset + Self.chunkBytes, body.count)
            client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Announces a length, sends one chunk, and then waits for the caller to cancel it.
final class ModelDownloadStallStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid/model.bin")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "1048576"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 4096))
    }

    override func stopLoading() {}
}

/// Collects the byte counts a download reports, from the queue the session calls back on.
private final class ProgressCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [Int64] = []
    private var expected: Int64 = 0

    func record(received: Int64, expected: Int64) {
        lock.lock()
        defer { lock.unlock() }
        self.received.append(received)
        self.expected = expected
    }

    var values: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    var announcedSize: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return expected
    }
}

@Suite("Model downloads report how much has arrived")
struct ModelDownloadProgressTests {
    private func configuration(_ stub: URLProtocol.Type) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [stub]
        return configuration
    }

    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "download-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("the bytes are counted as they arrive, and the file lands where the caller asked")
    func reportsProgressAndWritesTheFile() async throws {
        let body = Data((0..<(512 * 1024)).map { UInt8($0 % 251) })
        ModelDownloadStub.body = body
        ModelDownloadStub.chunkBytes = 16 * 1024
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "model.bin.partial")
        let counts = ProgressCounts()

        let download = ModelFileDownload(
            destination: destination,
            configuration: configuration(ModelDownloadStub.self)
        ) { received, expected in
            counts.record(received: received, expected: expected)
        }
        let request = URLRequest(url: URL(string: "https://example.invalid/model.bin")!)
        let response = try await download.run(request)

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try Data(contentsOf: destination) == body)
        // The row draws a ring from these numbers, so they have to move: a download that reported
        // only its end would look stopped for the minutes a model takes.
        let reported = counts.values
        #expect(reported.count >= 2)
        #expect(reported == reported.sorted())
        #expect(reported.last == Int64(body.count))
        // The row draws a ring from these numbers, so the first one has to be short of the end.
        // A transfer that only reported its finish would look stopped the whole way.
        #expect((reported.first ?? Int64(body.count)) < Int64(body.count))
        #expect(counts.announcedSize == Int64(body.count))
    }

    @Test("a cancelled transfer is reported as a cancellation, not as a failure")
    func cancellingReportsACancellation() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "model.bin.partial")
        let counts = ProgressCounts()
        let download = ModelFileDownload(
            destination: destination,
            configuration: configuration(ModelDownloadStallStub.self)
        ) { received, expected in
            counts.record(received: received, expected: expected)
        }
        let request = URLRequest(url: URL(string: "https://example.invalid/model.bin")!)
        let task = Task { try await download.run(request) }

        // Wait for the transfer to be under way before stopping it, so the test is about a
        // cancellation and not about a race with the start.
        var waited = 0
        while counts.values.isEmpty, waited < 200 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(!counts.values.isEmpty)
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("a size the server never named leaves the ring with nothing to fill")
    func unknownSizeHasNoFraction() {
        #expect(ModelManager.fraction(received: 10, expected: 0) == nil)
        #expect(ModelManager.fraction(received: 500, expected: 1000) == 0.5)
        // A server that reports more than it promised must not push the ring past a full turn.
        #expect(ModelManager.fraction(received: 1200, expected: 1000) == 1)
        #expect(ModelManager.fraction(received: 0, expected: 1000) == 0)
    }
}
