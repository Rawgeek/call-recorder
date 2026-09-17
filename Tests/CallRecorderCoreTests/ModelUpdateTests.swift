import CoreFoundation
import Foundation
import Testing
@testable import CallRecorderCore

@Suite("Model updates")
struct ModelUpdateTests {
    private func record(
        id: String = "medium",
        sha256: String = String(repeating: "a", count: 64)
    ) -> InstalledModelRecord {
        InstalledModelRecord(
            modelID: id,
            fileName: "ggml-\(id).bin",
            sha256: sha256,
            bytes: 1_000,
            revision: "revision-1",
            installedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func remote(
        fileName: String = "ggml-medium.bin",
        sha256: String = String(repeating: "a", count: 64)
    ) -> RemoteModelFile {
        RemoteModelFile(fileName: fileName, bytes: 1_000, sha256: sha256)
    }

    @Test("an identical hash is up to date")
    func identicalHashIsCurrent() {
        let decision = ModelUpdateChecker.decision(installed: record(), remote: remote())
        #expect(decision == .upToDate)
        #expect(decision.hasVerdict)
        #expect(decision.isUpdateAvailable == false)
    }

    @Test("a differing hash is an available update")
    func differingHashOffersUpdate() {
        let published = remote(sha256: String(repeating: "b", count: 64))
        let decision = ModelUpdateChecker.decision(installed: record(), remote: published)
        #expect(decision == .updateAvailable(published))
        #expect(decision.isUpdateAvailable)
    }

    @Test("hash comparison ignores letter case")
    func hashComparisonIsCaseInsensitive() {
        let decision = ModelUpdateChecker.decision(
            installed: record(sha256: String(repeating: "A", count: 64)),
            remote: remote(sha256: String(repeating: "a", count: 64))
        )
        #expect(decision == .upToDate)
    }

    @Test("a model with no recorded hash is reported as unverified, not current")
    func missingRecordIsUnverified() {
        let decision = ModelUpdateChecker.decision(installed: nil, remote: remote())
        #expect(decision.hasVerdict == false)
        #expect(decision != .upToDate)
    }

    @Test("a host that publishes no hash cannot produce a verdict")
    func missingRemoteHashIsUnverified() {
        let decision = ModelUpdateChecker.decision(installed: record(), remote: nil)
        #expect(decision.hasVerdict == false)
    }

    @Test("an empty hash never counts as a match")
    func emptyHashesNeverMatch() {
        let decision = ModelUpdateChecker.decision(
            installed: record(sha256: ""),
            remote: remote(sha256: "")
        )
        #expect(decision.hasVerdict == false)
    }

    @Test("the manifest survives a write and read")
    func manifestRoundTrips() throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "model-manifest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "manifest.json")

        var manifest = ModelManifest()
        manifest.record(record())
        try manifest.write(to: url)

        let loaded = ModelManifest.load(from: url)
        #expect(loaded == manifest)
        #expect(loaded.record(for: "medium")?.sha256 == String(repeating: "a", count: 64))
    }

    @Test("a missing manifest reads as empty rather than failing")
    func missingManifestIsEmpty() {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "absent-\(UUID().uuidString)/manifest.json")
        #expect(ModelManifest.load(from: url).records.isEmpty)
    }

    @Test("a damaged manifest reads as empty instead of crashing")
    func damagedManifestIsEmpty() throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "model-manifest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "manifest.json")
        try Data("not json".utf8).write(to: url)
        #expect(ModelManifest.load(from: url).records.isEmpty)
    }

    @Test("removing a record forgets that model")
    func removeForgetsModel() {
        var manifest = ModelManifest()
        manifest.record(record())
        manifest.remove("medium")
        #expect(manifest.record(for: "medium") == nil)
    }

    @Test("host metadata keeps only files that publish a hash")
    func hostMetadataSkipsUnhashedFiles() throws {
        let json = """
        {"sha":"revision-9","siblings":[
          {"rfilename":"ggml-medium.bin","size":1533763059,"lfs":{"sha256":"deadbeef"}},
          {"rfilename":"README.md","size":100},
          {"rfilename":"empty.bin","size":10,"lfs":{}}
        ]}
        """
        let metadata = try ModelHostMetadata.parse(Data(json.utf8))
        #expect(metadata.revision == "revision-9")
        #expect(metadata.files.count == 1)
        #expect(metadata.files["ggml-medium.bin"]?.sha256 == "deadbeef")
        #expect(metadata.files["ggml-medium.bin"]?.bytes == 1_533_763_059)
        #expect(metadata.files["README.md"] == nil)
        #expect(metadata.files["empty.bin"] == nil)
    }

    @Test("host metadata URL asks for file hashes")
    func hostMetadataURLRequestsBlobs() {
        let url = ModelHostMetadata.url(repository: "ggerganov/whisper.cpp")
        #expect(url.host() == "huggingface.co")
        #expect(url.path() == "/api/models/ggerganov/whisper.cpp")
        #expect(url.query()?.contains("blobs=true") == true)
    }

    @Test("malformed host metadata is rejected")
    func malformedHostMetadataThrows() {
        #expect(throws: (any Error).self) {
            try ModelHostMetadata.parse(Data("nonsense".utf8))
        }
    }

    /// The body Hugging Face returned for ggerganov/whisper.cpp, captured on 2026-09-16 and cut
    /// down to the five entries that matter here. Kept verbatim so a change to the host response
    /// shape shows up as a failure instead of a silently missing update.
    private let capturedWhisperResponse = """
    {
      "sha": "5359861c739e955e79d9a303bcbc70fb988958b1",
      "siblings": [
        {
          "rfilename": "README.md",
          "blobId": "bb0749e3c17cdf1d040a7e95fbf45610a212ec0a",
          "size": 3196
        },
        {
          "rfilename": "ggml-base.bin",
          "blobId": "17993a254ac4e9db7642a261cf53af3dc446145c",
          "size": 147951465,
          "lfs": {
            "sha256": "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
            "size": 147951465,
            "pointerSize": 134
          }
        },
        {
          "rfilename": "ggml-medium.bin",
          "blobId": "be775c464024bdcd9e834c2f9ed42aae6b708d2b",
          "size": 1533763059,
          "lfs": {
            "sha256": "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208",
            "size": 1533763059,
            "pointerSize": 135
          }
        },
        {
          "rfilename": "ggml-small.bin",
          "blobId": "bc4c4d96b528654fb067e2b243bdc438cfaf0072",
          "size": 487601967,
          "lfs": {
            "sha256": "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
            "size": 487601967,
            "pointerSize": 134
          }
        },
        {
          "rfilename": "ggml-tiny.bin",
          "blobId": "d144f735b005ae8cbfa04a49e22fe40faa24dbec",
          "size": 77691713,
          "lfs": {
            "sha256": "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21",
            "size": 77691713,
            "pointerSize": 133
          }
        }
      ]
    }
    """

    @Test("the host response in use today still parses")
    func realHostResponseParses() throws {
        let metadata = try ModelHostMetadata.parse(Data(capturedWhisperResponse.utf8))
        #expect(metadata.revision == "5359861c739e955e79d9a303bcbc70fb988958b1")
        // Four model files carry a hash; the README does not and is left out.
        #expect(metadata.files.count == 4)
        #expect(metadata.files["README.md"] == nil)
        #expect(metadata.files["ggml-medium.bin"]?.bytes == 1_533_763_059)
    }

    @Test("every model in the catalog still matches what the host publishes")
    func catalogAgreesWithHost() throws {
        let metadata = try ModelHostMetadata.parse(Data(capturedWhisperResponse.utf8))
        for model in WhisperModel.catalog {
            let published = try #require(metadata.files[model.fileName])
            // A mismatch here means the models this build ships with are no longer the ones the
            // host serves, which is exactly when an automatic update should be offered.
            #expect(published.sha256 == model.sha256)
            #expect(published.bytes == model.expectedBytes)
        }
    }

    @Test("a catalog model and the host agree, so no update is offered")
    func installedCatalogModelIsCurrent() throws {
        let metadata = try ModelHostMetadata.parse(Data(capturedWhisperResponse.utf8))
        let model = try #require(WhisperModel.catalog.first { $0.id == "medium" })
        let installed = InstalledModelRecord(
            modelID: model.id,
            fileName: model.fileName,
            sha256: model.sha256,
            bytes: model.expectedBytes,
            revision: WhisperModel.pinnedRevision,
            installedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let decision = ModelUpdateChecker.decision(
            installed: installed,
            remote: metadata.files[model.fileName]
        )
        #expect(decision == .upToDate)
    }
}
