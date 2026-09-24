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
    /// The file a development run keeps its key in could not be written. The number is the error
    /// the file system reported.
    case fileUnavailable(Int32)

    /// Whether the keychain asked for the key and the person said no.
    ///
    /// A dialog that was cancelled is a decision rather than a fault: nothing is broken, the key
    /// stays where it was, and the next attempt asks again. Told apart from the other failures
    /// because it used to be recorded as the app's last error, where a deliberately cancelled
    /// dialog read as a defect for days -- on 2026-09-24 it woke the fault watcher, which is built
    /// to wake on faults and not on choices.
    public var isUserDecline: Bool {
        guard case .inaccessible(let status) = self else { return false }
        return status == errSecUserCanceled
    }
}

/// Where the key that opens stored voice profiles is kept.
///
/// The keychain decides whether a program may read one of its items by the program's signature, and
/// a rebuild is a new program to it: a development run then waits on a password dialog with nothing
/// on screen to explain it, and the features behind the key are quietly absent. A build that ships
/// is never one of those runs.
public enum VoiceprintKeyLocation: Sendable, Equatable {
    /// The login keychain, which is where the installed app keeps the key.
    case keychain

    /// A file under the app's own folder that only this account can read.
    case file(URL)

    /// The same file, given the key out of the keychain the first time a key is needed and the
    /// library already holds sealed profiles.
    ///
    /// A development run reads the same library as the installed app, and the profiles in it were
    /// sealed with the key the installed app keeps in the keychain. Making a new key instead would
    /// leave those profiles unreadable to both programs, and would seal everything the development
    /// run writes with a key the installed app cannot open. So the one key is copied out of the
    /// keychain once, with the question the keychain asks a program it does not recognise, and
    /// every run after that reads the file and asks nothing.
    case fileSeededFromKeychain(URL)
}

public enum VoiceprintKeyStore {
    private static let service = "local.callrecorder.app.voiceprints"
    private static let account = "embedding-key-v1"

    public static func loadOrCreate(hasEncryptedData: Bool) throws -> VoiceprintCipher {
        try loadOrCreate(hasEncryptedData: hasEncryptedData, in: .keychain)
    }

    /// Reads the key, or makes one when there is nothing for it to open yet.
    ///
    /// - Parameter hasEncryptedData: whether stored profiles exist. A key that is gone with data to
    ///   open is a fault and is reported as one; with nothing to open, a new key is made.
    public static func loadOrCreate(
        hasEncryptedData: Bool,
        in location: VoiceprintKeyLocation
    ) throws -> VoiceprintCipher {
        switch location {
        case .keychain:
            return try VoiceprintCipher(
                keyData: try keychainKey(hasEncryptedData: hasEncryptedData)
            )
        case .file(let url):
            return try keyFromFile(url, hasEncryptedData: hasEncryptedData, seeded: false)
        case .fileSeededFromKeychain(let url):
            return try keyFromFile(url, hasEncryptedData: hasEncryptedData, seeded: true)
        }
    }

    /// The file a development run keeps the key in, inside the app's own folder.
    public static func fileLocation(inApplicationDirectory directory: URL) -> URL {
        directory
            .appending(path: "voiceprints", directoryHint: .isDirectory)
            .appending(path: account, directoryHint: .notDirectory)
    }

    /// The key the keychain holds, made only when there is nothing for it to open.
    private static func keychainKey(hasEncryptedData: Bool) throws -> Data {
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
            return data
        }
        guard status == errSecItemNotFound else {
            throw VoiceprintKeyStoreError.inaccessible(status)
        }
        guard !hasEncryptedData else { throw VoiceprintKeyStoreError.missingKey }

        let bytes = try generatedKey()
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
        return bytes
    }

    /// The same key in a file, for a run whose program the keychain does not know.
    private static func keyFromFile(
        _ url: URL,
        hasEncryptedData: Bool,
        seeded: Bool
    ) throws -> VoiceprintCipher {
        if let data = try? Data(contentsOf: url) {
            guard data.count == 32 else { throw VoiceprintKeyStoreError.invalidStoredKey }
            return try VoiceprintCipher(keyData: data)
        }
        let bytes: Data
        if hasEncryptedData {
            // Something is stored that this key has to open. A file that is not there yet can only
            // be given the key that sealed it, and the keychain is where the installed app put it.
            guard seeded else { throw VoiceprintKeyStoreError.missingKey }
            bytes = try keychainKey(hasEncryptedData: true)
        } else {
            bytes = try generatedKey()
        }
        do {
            // The folder is closed to everyone else, and the file is made unreadable to them before
            // anything is ever sealed with it.
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try bytes.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch let error as CocoaError {
            throw VoiceprintKeyStoreError.fileUnavailable(Int32(error.code.rawValue))
        } catch {
            throw VoiceprintKeyStoreError.fileUnavailable(Int32(errno))
        }
        return try VoiceprintCipher(keyData: bytes)
    }

    /// Thirty-two random bytes, or the failure the system reported.
    private static func generatedKey() throws -> Data {
        var bytes = Data(repeating: 0, count: 32)
        let generationStatus = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard generationStatus == errSecSuccess else {
            throw VoiceprintKeyStoreError.generationFailed(generationStatus)
        }
        return bytes
    }
}
