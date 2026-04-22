import Foundation
import CryptoKit
import CommonCrypto
import Security

/// Centralized cryptographic operations for collection-level chunk encryption.
/// Uses AES-GCM for content encryption and PBKDF2 for password-based key wrapping.
nonisolated enum CryptoManager {

    // MARK: - Constants

    private static let pbkdf2Iterations: UInt32 = 100_000
    private static let saltSize = 16
    private static let keychainService = "com.kingharrison.indexa.cek"

    // MARK: - Key Generation

    /// Generate a random 256-bit AES Content Encryption Key (CEK).
    static func generateCEK() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    // MARK: - Content Encryption / Decryption

    /// Encrypt a plaintext string using AES-GCM.
    /// Returns a Base64-encoded sealed box (nonce + ciphertext + tag).
    static func encryptContent(_ plaintext: String, using key: SymmetricKey) throws -> String {
        let data = Data(plaintext.utf8)
        let sealedBox = try AES.GCM.seal(data, using: key)
        guard let combined = sealedBox.combined else {
            throw CryptoError.encryptionFailed
        }
        return combined.base64EncodedString()
    }

    /// Decrypt a Base64-encoded AES-GCM sealed box back to a plaintext string.
    static func decryptContent(_ ciphertext: String, using key: SymmetricKey) throws -> String {
        guard let data = Data(base64Encoded: ciphertext) else {
            throw CryptoError.decryptionFailed
        }
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        let decrypted = try AES.GCM.open(sealedBox, using: key)
        guard let plaintext = String(data: decrypted, encoding: .utf8) else {
            throw CryptoError.decryptionFailed
        }
        return plaintext
    }

    // MARK: - Password-Based Key Wrapping

    /// Wrap (encrypt) a CEK using a password via PBKDF2 + AES-GCM.
    /// Returns the wrapped key as Base64 and the salt as hex.
    static func wrapCEK(_ cek: SymmetricKey, password: String) throws -> (wrappedKey: String, salt: String) {
        // Generate random salt
        var salt = Data(count: saltSize)
        salt.withUnsafeMutableBytes { ptr in
            _ = SecRandomCopyBytes(kSecRandomDefault, saltSize, ptr.baseAddress!)
        }

        // Derive wrapping key from password
        let wrappingKey = try deriveKey(from: password, salt: salt)

        // Wrap the CEK
        let cekData = cek.withUnsafeBytes { Data($0) }
        let sealedBox = try AES.GCM.seal(cekData, using: wrappingKey)
        guard let combined = sealedBox.combined else {
            throw CryptoError.encryptionFailed
        }

        return (
            wrappedKey: combined.base64EncodedString(),
            salt: salt.map { String(format: "%02x", $0) }.joined()
        )
    }

    /// Unwrap (decrypt) a CEK using a password and salt.
    static func unwrapCEK(wrappedKey: String, salt: String, password: String) throws -> SymmetricKey {
        guard let wrappedData = Data(base64Encoded: wrappedKey) else {
            throw CryptoError.decryptionFailed
        }

        // Convert hex salt back to Data
        let saltData = try hexToData(salt)

        // Derive the same wrapping key
        let wrappingKey = try deriveKey(from: password, salt: saltData)

        // Unwrap the CEK
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: wrappedData)
            let cekData = try AES.GCM.open(sealedBox, using: wrappingKey)
            return SymmetricKey(data: cekData)
        } catch {
            throw CryptoError.wrongPassword
        }
    }

    // MARK: - Keychain Operations

    /// Store a CEK in the macOS Keychain, keyed by collection ID.
    static func storeCEKInKeychain(_ cek: SymmetricKey, collectionId: UUID) throws {
        let cekData = cek.withUnsafeBytes { Data($0) }
        let account = collectionId.uuidString

        // Delete any existing entry first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add the new entry
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: cekData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CryptoError.keychainError(status)
        }
    }

    /// Retrieve a CEK from the Keychain by collection ID.
    /// Returns nil if no entry exists.
    static func loadCEKFromKeychain(collectionId: UUID) -> SymmetricKey? {
        let account = collectionId.uuidString

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return SymmetricKey(data: data)
    }

    /// Remove a CEK from the Keychain.
    static func removeCEKFromKeychain(collectionId: UUID) {
        let account = collectionId.uuidString

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - PBKDF2 Key Derivation

    /// Derive a 256-bit key from a password using PBKDF2-HMAC-SHA256.
    private static func deriveKey(from password: String, salt: Data) throws -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var derivedKey = Data(count: 32) // 256 bits

        let status = derivedKey.withUnsafeMutableBytes { derivedPtr in
            passwordData.withUnsafeBytes { passwordPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr.baseAddress?.assumingMemoryBound(to: CChar.self),
                        passwordData.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        pbkdf2Iterations,
                        derivedPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw CryptoError.keyDerivationFailed
        }
        return SymmetricKey(data: derivedKey)
    }

    // MARK: - Helpers

    /// Convert a hex string to Data.
    private static func hexToData(_ hex: String) throws -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard nextIndex <= hex.endIndex,
                  let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                throw CryptoError.invalidData
            }
            data.append(byte)
            index = nextIndex
        }
        return data
    }
}

// MARK: - Errors

nonisolated enum CryptoError: LocalizedError {
    case encryptionFailed
    case decryptionFailed
    case wrongPassword
    case keychainError(OSStatus)
    case keyDerivationFailed
    case invalidData

    var errorDescription: String? {
        switch self {
        case .encryptionFailed:
            return "Failed to encrypt content."
        case .decryptionFailed:
            return "Failed to decrypt content."
        case .wrongPassword:
            return "Wrong password. Could not unwrap encryption key."
        case .keychainError(let status):
            return "Keychain error: \(status)"
        case .keyDerivationFailed:
            return "Failed to derive encryption key from password."
        case .invalidData:
            return "Invalid encrypted data format."
        }
    }
}
