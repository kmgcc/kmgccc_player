import Foundation
import CryptoKit

/// Builds the canonical signing string and the four signing headers. The
/// canonical-string format MUST stay byte-identical to the server
/// (`app/signing.py`) — see the shared test vector asserted in `runSelfCheck()`.
struct TelemetryRequestSigner {
    let keyStore: TelemetrySigningKeyStore

    struct SignedHeaders {
        let clientID: String
        let timestamp: String
        let nonce: String
        let signature: String
    }

    static func canonicalString(method: String, path: String, timestamp: String,
                                nonce: String, body: Data) -> String {
        let bodyHash = SHA256.hash(data: body)
            .map { String(format: "%02x", $0) }.joined()
        return "\(method.uppercased())\n\(path)\n\(timestamp)\n\(nonce)\n\(bodyHash)"
    }

    /// Returns signing headers for a request, or nil if the key is unavailable.
    func sign(method: String, path: String, body: Data, clientID: String) -> SignedHeaders? {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        var nonceBytes = Data(count: 16)
        let ok = nonceBytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        guard ok == errSecSuccess else { return nil }
        let nonce = nonceBytes.base64EncodedString()
        let canonical = Self.canonicalString(method: method, path: path,
                                             timestamp: timestamp, nonce: nonce, body: body)
        guard let signature = keyStore.signBase64(message: Data(canonical.utf8)) else {
            return nil
        }
        return SignedHeaders(clientID: clientID, timestamp: timestamp,
                             nonce: nonce, signature: signature)
    }

    #if DEBUG
    /// Asserts the canonical string matches the cross-language shared test vector.
    /// Call once at startup in Debug builds.
    static func runSelfCheck() {
        let body = Data("{\"a\":1}".utf8)
        let cs = canonicalString(method: "POST",
                                 path: "/api/v1/telemetry/events/batch",
                                 timestamp: "1750000000",
                                 nonce: "AAAAAAAAAAAAAAAAAAAAAA==",
                                 body: body)
        let expected = """
        POST
        /api/v1/telemetry/events/batch
        1750000000
        AAAAAAAAAAAAAAAAAAAAAA==
        015abd7f5cc57a2dd94b7590f04ad8084273905ee33ec5cebeae62276a97f862
        """
        assert(cs == expected, "Canonical string drifted from server contract:\n\(cs)")
    }
    #endif
}
