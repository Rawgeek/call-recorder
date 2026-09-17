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

    /// The body Hugging Face returned for ggerganov/whisper.cpp, captured on 2026-09-17 and cut
    /// down to the README plus every model file this build offers, quantized ones included.
    /// Each entry is kept verbatim so a change to the host response shape shows up as a failure
    /// instead of a silently missing update.
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
          "rfilename": "ggml-base-q5_1.bin",
          "blobId": "4947e22c7365d941a9864b2d0f9f474a505cf39b",
          "size": 59707625,
          "lfs": {
            "sha256": "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898",
            "size": 59707625,
            "pointerSize": 133
          }
        },
        {
          "rfilename": "ggml-base-q8_0.bin",
          "blobId": "1a710c5bff0c9b764ee332dd9a8422bc978bfb1e",
          "size": 81768585,
          "lfs": {
            "sha256": "c577b9a86e7e048a0b7eada054f4dd79a56bbfa911fbdacf900ac5b567cbb7d9",
            "size": 81768585,
            "pointerSize": 133
          }
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
          "rfilename": "ggml-base.en-q5_1.bin",
          "blobId": "5c89fe2c0d47f0d16d536610dc5f7c4a6fe81bc7",
          "size": 59721011,
          "lfs": {
            "sha256": "4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f",
            "size": 59721011,
            "pointerSize": 133
          }
        },
        {
          "rfilename": "ggml-base.en-q8_0.bin",
          "blobId": "f459c0ad21ffd7b3661f62914745c59bb63f2422",
          "size": 81781811,
          "lfs": {
            "sha256": "a4d4a0768075e13cfd7e19df3ae2dbc4a68d37d36a7dad45e8410c9a34f8c87e",
            "size": 81781811,
            "pointerSize": 133
          }
        },
        {
          "rfilename": "ggml-base.en.bin",
          "blobId": "87c664c563ef3ff52424dd4fa925cf95b306dba6",
          "size": 147964211,
          "lfs": {
            "sha256": "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002",
            "size": 147964211,
            "pointerSize": 134
          }
        },
        {
          "rfilename": "ggml-large-v1.bin",
          "blobId": "047db73ddfd7789113dfc94c20b22bc1d044586f",
          "size": 3094623691,
          "lfs": {
            "sha256": "7d99f41a10525d0206bddadd86760181fa920438b6b33237e3118ff6c83bb53d",
            "size": 3094623691,
            "pointerSize": 135
          }
        },
        {
          "rfilename": "ggml-large-v2-q5_0.bin",
          "blobId": "8ea090d899ab4099f57a60abcba4d4008553b675",
          "size": 1080732091,
          "lfs": {
            "sha256": "3a214837221e4530dbc1fe8d734f302af393eb30bd0ed046042ebf4baf70f6f2",
            "size": 1080732091,
            "pointerSize": 135
          }
        },
        {
          "rfilename": "ggml-large-v2-q8_0.bin",
          "blobId": "423bfb2f2932572249bc17a16139883d9aaed65f",
          "size": 1656129691,
          "lfs": {
            "sha256": "fef54e6d898246a65c8285bfa83bd1807e27fadf54d5d4e81754c47634737e8c",
            "size": 1656129691,
            "pointerSize": 135
          }
        },
        {
          "rfilename": "ggml-large-v2.bin",
          "blobId": "649aafd67e30021d0140c24342ee2ffb947f4bde",
          "size": 3094623691,
          "lfs": {
            "sha256": "9a423fe4d40c82774b6af34115b8b935f34152246eb19e80e376071d3f999487",
            "size": 3094623691,
            "pointerSize": 135
          }
        },
        {
          "rfilename": "ggml-large-v3-q5_0.bin",
          "blobId": "14150f8463725bde9626c0656683ad5735e01ac2",
          "size": 1081140203,
          "lfs": {
            "sha256": "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1",
            "size": 1081140203,
            "pointerSize": 135
          }
        },
        {
          "rfilename": "ggml-large-v3-turbo-q5_0.bin",
          "blobId": "0e2474d5ec0361bb1726829aa83317ed4cbc3f18",
          "size": 574041195,
          "lfs": {
            "sha256": "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
            "size": 574041195,
            "pointerSize": 134
          }
        },
        {
          "rfilename": "ggml-large-v3-turbo-q8_0.bin",
          "blobId": "dd827281ffb9642e91f152f2a90de53907d4603a",
          "size": 874188075,
          "lfs": {
            "sha256": "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1",
            "size": 874188075,
            "pointerSize": 134
          }
        },
        {
          "rfilename": "ggml-large-v3-turbo.bin",
          "blobId": "819841c70bdf4488c4ff778f8becdcb37df43969",
          "size": 1624555275,
          "lfs": {
            "sha256": "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
            "size": 1624555275,
            "pointerSize": 135
          }
        },
        {
          "rfilename": "ggml-large-v3.bin",
          "blobId": "30488f6b9eeae93e026c978ac7a3190274732ea2",
          "size": 3095033483,
          "lfs": {
            "sha256": "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2",
            "size": 3095033483,
            "pointerSize": 135
          }
        },
        {
          "rfilename": "ggml-medium-q5_0.bin",
          "blobId": "9cc19f38fec2314f6c00f666ca708e8cf22d189d",
          "size": 539212467,
          "lfs": {
            "sha256": "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f",
            "size": 539212467,
            "pointerSize": 134
          }
        },
        {
          "rfilename": "ggml-medium-q8_0.bin",
          "blobId": "6c783bed539147853779c28702e59d170ab6a5bb",
          "size": 823369779,
          "lfs": {
            "sha256": "42a1ffcbe4167d224232443396968db4d02d4e8e87e213d3ee2e03095dea6502",
            "size": 823369779,
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
          "rfilename": "ggml-medium.en-q5_0.bin",
          "blobId": "8722db4993ba67f49c4f20cdd9880202c8cc3f2b",
          "size": 539225533,
          "lfs": {
            "sha256": "76733e26ad8fe1c7a5bf7531a9d41917b2adc0f20f2e4f5531688a8c6cd88eb0",
            "size": 539225533,
            "pointerSize": 134
          }
        },
        {
          "rfilename": "ggml-medium.en-q8_0.bin",
          "blobId": "c4ca4e1562dffe8db2381e32299fe64110228156",
          "size": 823382461,
          "lfs": {
            "sha256": "43fa2cd084de5a04399a896a9a7a786064e221365c01700cea4666005218f11c",
            "size": 823382461,
            "pointerSize": 134
          }
        },
        {
          "rfilename": "ggml-medium.en.bin",
          "blobId": "f8d7f988b60916d7f7e7feee9897c037a09b2f85",
          "size": 1533774781,
          "lfs": {
            "sha256": "cc37e93478338ec7700281a7ac30a10128929eb8f427dda2e865faa8f6da4356",
            "size": 1533774781,
            "pointerSize": 135
          }
        },
        {
          "rfilename": "ggml-small-q5_1.bin",
          "blobId": "87631c52c89d37ed2337a46ec4a009976db1f3f4",
          "size": 190085487,
          "lfs": {
            "sha256": "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb",
            "size": 190085487,
            "pointerSize": 134
          }
        },
        {
          "rfilename": "ggml-small-q8_0.bin",
          "blobId": "8a9937d2be60bae6b1efbb01b9ca1612ab2a617c",
          "size": 264464607,
          "lfs": {
            "sha256": "49c8fb02b65e6049d5fa6c04f81f53b867b5ec9540406812c643f177317f779f",
            "size": 264464607,
            "pointerSize": 134
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
          "rfilename": "ggml-small.en-q5_1.bin",
          "blobId": "bf61baaf463626fe45fc9157b8e9c69de8943c87",
          "size": 190098681,
          "lfs": {
            "sha256": "bfdff4894dcb76bbf647d56263ea2a96645423f1669176f4844a1bf8e478ad30",
            "size": 190098681,
            "pointerSize": 134
          }
        },
        {
          "rfilename": "ggml-small.en-q8_0.bin",
          "blobId": "9c826215654cf46674a38d02f19e123e17c5b2d3",
          "size": 264477561,
          "lfs": {
            "sha256": "67a179f608ea6114bd3fdb9060e762b588a3fb3bd00c4387971be4d177958067",
            "size": 264477561,
            "pointerSize": 134
          }
        },
        {
          "rfilename": "ggml-small.en.bin",
          "blobId": "eaeeb6d63378cf6515ff2c1cb4e33486ae6bcc2f",
          "size": 487614201,
          "lfs": {
            "sha256": "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d",
            "size": 487614201,
            "pointerSize": 134
          }
        },
        {
          "rfilename": "ggml-tiny-q5_1.bin",
          "blobId": "42701a9c1d8a9f4f0b96dbcefcc049075814bcf3",
          "size": 32152673,
          "lfs": {
            "sha256": "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7",
            "size": 32152673,
            "pointerSize": 133
          }
        },
        {
          "rfilename": "ggml-tiny-q8_0.bin",
          "blobId": "fc48fd17b13f7eb147bab1c66dee10c97f471b27",
          "size": 43537433,
          "lfs": {
            "sha256": "c2085835d3f50733e2ff6e4b41ae8a2b8d8110461e18821b09a15c40c42d1cca",
            "size": 43537433,
            "pointerSize": 133
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
        },
        {
          "rfilename": "ggml-tiny.en-q5_1.bin",
          "blobId": "46aeed3b01f3fc86f05fa3e8ca711cc1773ead08",
          "size": 32166155,
          "lfs": {
            "sha256": "c77c5766f1cef09b6b7d47f21b546cbddd4157886b3b5d6d4f709e91e66c7c2b",
            "size": 32166155,
            "pointerSize": 133
          }
        },
        {
          "rfilename": "ggml-tiny.en-q8_0.bin",
          "blobId": "959468eb9f72c2100ab5e4a9efc102a45cc8b313",
          "size": 43550795,
          "lfs": {
            "sha256": "5bc2b3860aa151a4c6e7bb095e1fcce7cf12c7b020ca08dcec0c6d018bb7dd94",
            "size": 43550795,
            "pointerSize": 133
          }
        },
        {
          "rfilename": "ggml-tiny.en.bin",
          "blobId": "17ad750438d1d42162fe06ab4b21aef2389d2137",
          "size": 77704715,
          "lfs": {
            "sha256": "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f",
            "size": 77704715,
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
        // Thirty-three model files carry a hash; the README does not and is left out.
        #expect(metadata.files.count == 33)
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
