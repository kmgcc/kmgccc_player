import Foundation
import Security

/// Owns the per-install Secure Enclave signing key. The private key is generated
/// in and never leaves the Secure Enclave; only signing and public-key export are
/// exposed. Access control uses `.privateKeyUsage` only — no biometric/passcode
/// prompts. Accessibility is `afterFirstUnlockThisDeviceOnly` so termination /
/// background uploads can sign while the screen is locked.
final class TelemetrySigningKeyStore {
    static let shared = TelemetrySigningKeyStore()

    private let tag = "cn.kmgccc.player.telemetry.signingKey".data(using: .utf8)!
    private var cachedKey: SecKey?

    /// Returns the existing private key or creates one. Returns nil only if the
    /// Secure Enclave is unavailable or key creation fails.
    func privateKey() -> SecKey? {
        if let cachedKey { return cachedKey }
        if let existing = loadKey() {
            cachedKey = existing
            return existing
        }
        let created = createKey()
        cachedKey = created
        return created
    }

    /// Base64 of the uncompressed X9.63 public point (0x04 ‖ X ‖ Y, 65 bytes).
    func publicKeyBase64() -> String? {
        guard let priv = privateKey(),
              let pub = SecKeyCopyPublicKey(priv) else { return nil }
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(pub, &error) as Data? else {
            return nil
        }
        return data.base64EncodedString()
    }

    /// DER-encoded ECDSA-P256-SHA256 signature of `message`, base64-encoded.
    func signBase64(message: Data) -> String? {
        guard let priv = privateKey() else { return nil }
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(
            priv, .ecdsaSignatureMessageX962SHA256, message as CFData, &error
        ) as Data? else {
            return nil
        }
        return sig.base64EncodedString()
    }

    private func loadKey() -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return (item as! SecKey)
    }

    private func createKey() -> SecKey? {
        var acError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            .privateKeyUsage,
            &acError
        ) else {
            return nil
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessControl as String: access,
            ],
        ]
        var error: Unmanaged<CFError>?
        return SecKeyCreateRandomKey(attributes as CFDictionary, &error)
    }
}
