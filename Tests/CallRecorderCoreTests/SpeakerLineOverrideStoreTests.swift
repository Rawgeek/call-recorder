import Foundation
import Libsql
import Testing
@testable import CallRecorderCore

/// The corrections as the database keeps them.
///
/// What a correction covers is checked without a database in SpeakerLineOverrideTests. These check
/// the round trip: that a correction is stored against the call it belongs to, that assigning the
/// same excerpt twice corrects the first answer rather than leaving two, and that a person stored
/// under a different casing can still be assigned, which is the fault that stopped the last
/// speaker repair from running at all.
@Suite("Speaker line corrections in the store")
struct SpeakerLineOverrideStoreTests {
    private func store() throws -> (CallStore, String) {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "call-recorder-override-\(UUID().uuidString).db").path
        let store = try CallStore(path: path)
        return (store, path)
    }

    private func call(_ store: CallStore) async throws -> CallID {
        let id = CallID(rawValue: UUID())
        try await store.createCall(.started(id: id, at: Date(timeIntervalSince1970: 1_800_000_000)))
        return id
    }

    @Test("a correction is stored against its call and read back with the person name")
    func roundTrip() async throws {
        let (store, path) = try store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await store.migrate()
        let callID = try await call(store)
        let person = try await store.upsertParticipant(name: "Adam")

        let saved = try await store.saveSpeakerLineOverride(
            callID: callID, startMs: 16_000, endMs: 30_000, participantID: person.id
        )
        #expect(saved.speakerName == "Adam")

        let read = try await store.speakerLineOverrides(callID: callID)
        #expect(read.count == 1)
        #expect(read.first?.startMs == 16_000)
        #expect(read.first?.endMs == 30_000)
        #expect(read.first?.speakerName == "Adam")
        #expect(try await store.hasSpeakerLineOverrides())
    }

    @Test("assigning the same excerpt twice corrects the first answer instead of adding one")
    func sameExcerptTwiceReplaces() async throws {
        // A user changes their mind about an excerpt about as often as they get it right. Two rows
        // for one range would leave the transcript dependent on which of them was read first.
        let (store, path) = try store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await store.migrate()
        let callID = try await call(store)
        let adam = try await store.upsertParticipant(name: "Adam")
        let simon = try await store.upsertParticipant(name: "Simon")

        _ = try await store.saveSpeakerLineOverride(
            callID: callID, startMs: 16_000, endMs: 30_000, participantID: adam.id
        )
        _ = try await store.saveSpeakerLineOverride(
            callID: callID, startMs: 16_000, endMs: 30_000, participantID: simon.id
        )

        let read = try await store.speakerLineOverrides(callID: callID)
        #expect(read.count == 1)
        #expect(read.first?.speakerName == "Simon")
    }

    @Test("a person stored in lower case can still be assigned")
    func lowercaseParticipantIsResolved() async throws {
        // The table holds some identifiers in lower case and a foreign key compares byte for byte.
        // The last speaker repair wrote the caller spelling and failed on exactly those rows every
        // launch from then on, so a person is written in lower case here on purpose.
        let (store, path) = try store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await store.migrate()
        let callID = try await call(store)

        let lowercaseID = UUID().uuidString.lowercased()
        let writer = try Database(path).connect()
        try writer.executeBatch("PRAGMA foreign_keys = ON;")
        _ = try writer.execute(
            "INSERT INTO participants (id, name, normalized_name) VALUES (?, ?, ?)",
            [lowercaseID, "Adam", "adam-" + lowercaseID]
        )
        let person = Participant(
            id: ParticipantID(rawValue: UUID(uuidString: lowercaseID)!),
            name: "Adam",
            role: nil,
            company: nil,
            email: nil
        )

        _ = try await store.saveSpeakerLineOverride(
            callID: callID, startMs: 16_000, endMs: 30_000, participantID: person.id
        )
        #expect(try await store.speakerLineOverrides(callID: callID).count == 1)
    }

    @Test("a correction can be taken back off")
    func removal() async throws {
        let (store, path) = try store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await store.migrate()
        let callID = try await call(store)
        let person = try await store.upsertParticipant(name: "Adam")
        _ = try await store.saveSpeakerLineOverride(
            callID: callID, startMs: 16_000, endMs: 30_000, participantID: person.id
        )

        #expect(try await store.removeSpeakerLineOverride(
            callID: callID, startMs: 16_000, endMs: 30_000
        ))
        #expect(try await store.speakerLineOverrides(callID: callID).isEmpty)
        // A second press changes nothing and says so, rather than reporting a removal that did
        // not happen.
        #expect(try await store.removeSpeakerLineOverride(
            callID: callID, startMs: 16_000, endMs: 30_000
        ) == false)
    }

    @Test("a correction belongs to one call and is not read for another")
    func correctionsAreScopedToTheirCall() async throws {
        let (store, path) = try store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await store.migrate()
        let first = try await call(store)
        let second = try await call(store)
        let person = try await store.upsertParticipant(name: "Adam")
        _ = try await store.saveSpeakerLineOverride(
            callID: first, startMs: 16_000, endMs: 30_000, participantID: person.id
        )
        #expect(try await store.speakerLineOverrides(callID: second).isEmpty)
    }

    @Test("deleting a call takes its corrections with it")
    func deletingTheCallRemovesThem() async throws {
        // A correction is written into a saved transcript, so a row left behind would be a
        // correction to a call that no longer exists.
        let (store, path) = try store()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await store.migrate()
        let callID = try await call(store)
        let person = try await store.upsertParticipant(name: "Adam")
        _ = try await store.saveSpeakerLineOverride(
            callID: callID, startMs: 16_000, endMs: 30_000, participantID: person.id
        )

        try await store.deleteCall(callID)
        #expect(try await store.speakerLineOverrides(callID: callID).isEmpty)
    }
}
