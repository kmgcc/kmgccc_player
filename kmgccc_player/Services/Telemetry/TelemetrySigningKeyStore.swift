import Foundation
import CryptoKit

/// Owns the per-install software P-256 signing key.
///
/// The private key is generated on first launch and stored as a raw 32-byte
/// file at `~/Library/Application Support/<bundleID>/Telemetry/signing-key`
/// (file mode 0600, directory mode 0700, atomic write). No Keychain, no Secure
/// Enclave, no `keychain-access-groups` entitlement required.
///
/// **Migration from the old Secure Enclave / Keychain-backed store:** the old
/// `kSecClassKey` entries are simply not read. If the software key file is
/// absent (new install, or migrated from the old store), a fresh key is
/// generated and `needsRegistration` is set so the caller forces re-registration
/// with the server. If the file exists but is corrupted, the same path applies:
/// discard, regenerate, re-register.
///
/// Public key registration, canonical string, ECDSA-P256-SHA256 signing,
/// timestamp, nonce, and body-hash formats are unchanged - the server-side
/// verification contract is identical.
final class TelemetrySigningKeyStore {
    static let shared = TelemetrySigningKeyStore()

    private var cachedKey: P256.Signing.PrivateKey?

    /// True when the key was generated in this process rather than loaded from
    /// disk. The caller should force re-registration when this is true, because
    /// the server has no record of the new public key.
    private(set) var needsRegistration = false

    // MARK: - Path

    private static var keyDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "kmgccc_player"
        return appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Telemetry", isDirectory: true)
    }

    private static var keyFileURL: URL {
        keyDirectory.appendingPathComponent("signing-key")
    }

    // MARK: - Public API

    /// Returns the existing private key or creates one. Returns nil only if key
    /// generation fails (effectively impossible for software keys).
    func privateKey() -> P256.Signing.PrivateKey? {
        if let cachedKey {
            Log.debug("[TelemetrySigning] privateKey cache hit", category: .telemetry)
            return cachedKey
        }
        if let loaded = loadKeyFromFile() {
            Log.info("[TelemetrySigning] loaded existing software key from disk", category: .telemetry)
            cachedKey = loaded
            return loaded
        }
        Log.info("[TelemetrySigning] no key file found, generating new software P-256 key", category: .telemetry)
        let new = P256.Signing.PrivateKey()
        do {
            try saveKeyToFile(new)
        } catch {
            Log.error("[TelemetrySigning] failed to save new key: \(error)", category: .telemetry)
            return nil
        }
        cachedKey = new
        needsRegistration = true
        return new
    }

    /// Base64 of the uncompressed X9.63 public point (0x04 ‖ X ‖ Y, 65 bytes).
    /// Byte-identical format to the old `SecKeyCopyExternalRepresentation` output.
    /// Uses `x963Representation` (not `rawRepresentation`, which is the 64-byte
    /// compact form without the 0x04 prefix that the server rejects).
    func publicKeyBase64() -> String? {
        guard let priv = privateKey() else {
            Log.warning("[TelemetrySigning] publicKeyBase64() failed: privateKey() returned nil", category: .telemetry)
            return nil
        }
        let x963 = priv.publicKey.x963Representation
        let fp = Self.fingerprint(x963)
        Log.info("[TelemetrySigning] publicKeyBase64() success fp=\(fp) bytes=\(x963.count)", category: .telemetry)
        return x963.base64EncodedString()
    }

    /// DER-encoded ECDSA-P256-SHA256 signature of `message`, base64-encoded.
    /// Signs SHA-256 of `message` (same as the old
    /// `.ecdsaSignatureMessageX962SHA256`), DER-encoded (same as `SecKeyCreateSignature`
    /// output). The server verifies with `Prehashed(SHA256)` + DER decode.
    func signBase64(message: Data) -> String? {
        guard let priv = privateKey() else {
            Log.warning("[TelemetrySigning] signBase64() failed: privateKey() returned nil", category: .telemetry)
            return nil
        }
        do {
            let signature = try priv.signature(for: message)
            let der = signature.derRepresentation
            Log.debug("[TelemetrySigning] signBase64() success bytes=\(der.count)", category: .telemetry)
            return der.base64EncodedString()
        } catch {
            Log.warning("[TelemetrySigning] signBase64() failed: \(error)", category: .telemetry)
            return nil
        }
    }

    // MARK: - File I/O

    private func loadKeyFromFile() -> P256.Signing.PrivateKey? {
        let url = Self.keyFileURL
        guard let data = try? Data(contentsOf: url) else {
            Log.debug("[TelemetrySigning] key file not found at \(url.path)", category: .telemetry)
            return nil
        }
        do {
            return try P256.Signing.PrivateKey(rawRepresentation: data)
        } catch {
            Log.warning("[TelemetrySigning] key file exists but could not be decoded (\(data.count) bytes), will regenerate: \(error)", category: .telemetry)
            return nil
        }
    }

    private func saveKeyToFile(_ key: P256.Signing.PrivateKey) throws {
        let dir = Self.keyDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Tighten directory to owner-only. setAttributes is idempotent.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        // Atomic write (temp file + rename within the same 0700 directory), then
        // tighten file permissions to 0600. The 0700 directory protects the file
        // during the brief window before chmod completes.
        let url = Self.keyFileURL
        try key.rawRepresentation.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Short public-key fingerprint for log correlation (first 4 bytes of SHA-256,
    /// 8 hex chars). Does not reveal the key itself.
    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
