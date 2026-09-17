import Foundation
import Testing
@testable import CallRecorderApp

@Suite("Capture command queue")
struct CaptureCommandQueueTests {
    @Test("a command arriving during an active capture transition runs after it, never dropped")
    func queuedCommandsRunSerially() async throws {
        // Given: a first capture transition that awaits an external gate.
        var queue = CaptureCommandQueue()
        let gate = AsyncGate()
        let probe = LockedStringProbe()

        // When: a second capture command arrives while the first is still awaiting.
        let first = queue.enqueue {
            await gate.wait()
            probe.record("first")
        }
        let second = queue.enqueue {
            probe.record("second")
        }

        // Then: the second command is not dropped, but it must not run while the
        // first transition is still awaiting.
        try await Task.sleep(for: .milliseconds(100))
        #expect(probe.values().isEmpty)

        gate.open()
        await first.value
        await second.value
        #expect(probe.values() == ["first", "second"])
    }
}

/// Deterministic gate: `wait()` suspends until `open()` resumes it exactly once.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            defer { lock.unlock() }
            if isOpen {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func open() {
        lock.lock()
        defer { lock.unlock() }
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

final class LockedStringProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func record(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        items.append(value)
    }

    func values() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
