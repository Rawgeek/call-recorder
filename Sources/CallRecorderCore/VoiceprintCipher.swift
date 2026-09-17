import CryptoKit
import Foundation
import Security

public enum VoiceprintCipherError: Error, Equatable {
    case invalidKey
    case invalidEmbedding
    case invalidEnvelope
    case authenticationFailed
}

public struct VoiceprintCipher: Sendable {
    private static let magic = Data([0x43, 0x52, 0x56, 0x50])
    private static let version: UInt8 = 1
    private let key: SymmetricKey

    public init(keyData: Data) throws {
        guard keyData.count == 32 else { throw VoiceprintCipherError.invalidKey }
        key = SymmetricKey(data: keyData)
    }

    public func seal(_ embedding: [Float], modelVersion: String) throws -> Data {
        guard
            !embedding.isEmpty,
            embedding.count <= Int(UInt16.max),
            embedding.allSatisfy(\.isFinite),
            !modelVersion.isEmpty
        else { throw VoiceprintCipherError.invalidEmbedding }
        let plaintext = Self.encode(embedding)
        let box = try AES.GCM.seal(
            plaintext,
            using: key,
            authenticating: Data(modelVersion.utf8)
        )
        guard let combined = box.combined else { throw VoiceprintCipherError.invalidEnvelope }
        let dimension = UInt16(embedding.count)
        return Self.magic + Data([
            Self.version,
            UInt8(dimension >> 8),
            UInt8(dimension & 0xff),
        ]) + combined
    }

    public func open(_ envelope: Data, modelVersion: String) throws -> [Float] {
        let headerSize = Self.magic.count + 3
        guard
            envelope.count >= headerSize + 12 + 16,
            envelope.prefix(Self.magic.count) == Self.magic,
            envelope[Self.magic.count] == Self.version,
            !modelVersion.isEmpty
        else { throw VoiceprintCipherError.invalidEnvelope }
        let high = UInt16(envelope[Self.magic.count + 1]) << 8
        let low = UInt16(envelope[Self.magic.count + 2])
        let dimension = Int(high | low)
        guard dimension > 0 else { throw VoiceprintCipherError.invalidEnvelope }
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: envelope.dropFirst(headerSize))
        } catch {
            throw VoiceprintCipherError.invalidEnvelope
        }
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(
                box,
                using: key,
                authenticating: Data(modelVersion.utf8)
            )
        } catch {
            throw VoiceprintCipherError.authenticationFailed
        }
        guard plaintext.count == dimension * MemoryLayout<UInt32>.size else {
            throw VoiceprintCipherError.invalidEnvelope
        }
        let embedding = Self.decode(plaintext)
        guard embedding.allSatisfy(\.isFinite) else {
            throw VoiceprintCipherError.invalidEnvelope
        }
        return embedding
    }

    private static func encode(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * MemoryLayout<UInt32>.size)
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func decode(_ data: Data) -> [Float] {
        stride(from: 0, to: data.count, by: MemoryLayout<UInt32>.size).map { offset in
            let bits = data[offset..<(offset + MemoryLayout<UInt32>.size)]
                .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            return Float(bitPattern: UInt32(littleEndian: bits))
        }
    }
}

public enum VoiceprintKeyStoreError: Error, Equatable {
    case missingKey
    case invalidStoredKey
    case inaccessible(OSStatus)
    case generationFailed(OSStatus)
}

public enum VoiceprintKeyStore {
    private static let service = "local.callrecorder.app.voiceprints"
    private static let account = "embedding-key-v1"

    public static func loadOrCreate(hasEncryptedData: Bool) throws -> VoiceprintCipher {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess {
            guard let data = item as? Data, data.count == 32 else {
                throw VoiceprintKeyStoreError.invalidStoredKey
            }
            return try VoiceprintCipher(keyData: data)
        }
        guard status == errSecItemNotFound else {
            throw VoiceprintKeyStoreError.inaccessible(status)
        }
        guard !hasEncryptedData else { throw VoiceprintKeyStoreError.missingKey }

        var bytes = Data(repeating: 0, count: 32)
        let generationStatus = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard generationStatus == errSecSuccess else {
            throw VoiceprintKeyStoreError.generationFailed(generationStatus)
        }
        let insert: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: bytes,
        ]
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw VoiceprintKeyStoreError.inaccessible(insertStatus)
        }
        return try VoiceprintCipher(keyData: bytes)
    }
}
