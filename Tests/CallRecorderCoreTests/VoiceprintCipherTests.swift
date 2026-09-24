import Foundation
import Security
import Testing
@testable import CallRecorderCore

@Suite("Voiceprint cipher")
struct VoiceprintCipherTests {
    @Test("AES-GCM envelope round-trips and binds the model version")
    func roundTripsEmbedding() throws {
        let cipher = try VoiceprintCipher(keyData: Data(0..<32))
        let embedding: [Float] = [0.25, -0.5, 0.75, 1]

        let sealed = try cipher.seal(embedding, modelVersion: "model-v1")

        #expect(try cipher.open(sealed, modelVersion: "model-v1") == embedding)
        #expect(throws: VoiceprintCipherError.authenticationFailed) {
            try cipher.open(sealed, modelVersion: "model-v2")
        }
        for value in embedding {
            #expect(sealed.range(of: littleEndianData(value)) == nil)
        }
    }

    @Test("invalid key and envelope fail with typed errors")
    func rejectsInvalidInput() {
        #expect(throws: VoiceprintCipherError.invalidKey) {
            try VoiceprintCipher(keyData: Data(repeating: 0, count: 31))
        }
        let cipher = try? VoiceprintCipher(keyData: Data(repeating: 0, count: 32))
        #expect(throws: VoiceprintCipherError.invalidEnvelope) {
            try cipher?.open(Data("not-an-envelope".utf8), modelVersion: "model-v1")
        }
    }

    @Test("a cancelled keychain dialog is read as a decision rather than as a fault")
    func aCancelledDialogIsADecision() {
        // -128 is what the keychain answers when the person pressed Cancel in the access dialog.
        #expect(VoiceprintKeyStoreError.inaccessible(errSecUserCanceled).isUserDecline)

        // Everything else is a fault that has to be reported: a locked keychain, a refused
        // password, a key that is not there, a key of the wrong size.
        #expect(!VoiceprintKeyStoreError.inaccessible(errSecInteractionNotAllowed).isUserDecline)
        #expect(!VoiceprintKeyStoreError.inaccessible(errSecAuthFailed).isUserDecline)
        #expect(!VoiceprintKeyStoreError.missingKey.isUserDecline)
        #expect(!VoiceprintKeyStoreError.invalidStoredKey.isUserDecline)
        #expect(!VoiceprintKeyStoreError.generationFailed(errSecUserCanceled).isUserDecline)
        #expect(!VoiceprintKeyStoreError.fileUnavailable(-128).isUserDecline)
    }

    private func littleEndianData(_ value: Float) -> Data {
        var bits = value.bitPattern.littleEndian
        return withUnsafeBytes(of: &bits) { Data($0) }
    }
}
