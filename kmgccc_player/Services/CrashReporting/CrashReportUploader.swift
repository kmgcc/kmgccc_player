import Foundation
import zlib

nonisolated enum CrashReportDeliveryError: Error, Sendable, Equatable {
    case unauthorized
    case retryable(statusCode: Int?)
    case permanent(statusCode: Int)
    case invalidRequest
}

nonisolated struct CrashTechnicalUploadResponse: Decodable, Sendable {
    let success: Bool
    let status: String
    let reportID: String
}

nonisolated struct CrashUserContextUploadResponse: Decodable, Sendable {
    let success: Bool
    let status: String
    let reportID: String
}

@MainActor
final class CrashReportUploader {
    private static let technicalPath = "/api/v1/telemetry/crash-reports"
    private static let metricKitPath = "/api/v1/telemetry/diagnostic-reports"
    private let baseURL: URL
    private let session: URLSession
    private let signer: TelemetryRequestSigner

    init(
        baseURL: URL = URL(string: "https://player.kmgccc.cn")!,
        session: URLSession? = nil,
        signer: TelemetryRequestSigner = TelemetryRequestSigner(keyStore: .shared)
    ) {
        self.baseURL = baseURL
        self.signer = signer
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 15
            self.session = URLSession(configuration: configuration)
        }
    }

    func uploadTechnicalReport(_ report: CrashReportEnvelope) async throws {
        let json = try JSONEncoder.crashReportEncoder().encode(report)
        let body = try await Task.detached(priority: .utility) {
            try CrashGzip.compress(json)
        }.value
        guard body.count <= 512 * 1024 else {
            throw CrashReportDeliveryError.permanent(statusCode: 413)
        }
        var request = try signedRequest(
            method: "POST",
            path: Self.technicalPath,
            body: body,
            clientID: report.anonymousInstallID
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")

        let (data, response) = try await perform(request)
        guard let decoded = try? JSONDecoder().decode(CrashTechnicalUploadResponse.self, from: data),
              decoded.success,
              decoded.reportID.caseInsensitiveCompare(report.reportID) == .orderedSame else {
            throw CrashReportDeliveryError.retryable(statusCode: response.statusCode)
        }
    }

    func uploadUserContext(
        reportID: String,
        anonymousInstallID: String,
        revisionID: String,
        description: String
    ) async throws {
        let path = "\(Self.technicalPath)/\(reportID.lowercased())/user-context"
        let payload = CrashUserContextRequest(
            anonymousInstallID: anonymousInstallID,
            contextRevisionID: revisionID,
            userDescription: description
        )
        let body = try JSONEncoder.crashReportEncoder().encode(payload)
        guard body.count <= 16 * 1024 else {
            throw CrashReportDeliveryError.permanent(statusCode: 413)
        }
        var request = try signedRequest(
            method: "PUT",
            path: path,
            body: body,
            clientID: anonymousInstallID
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await perform(request)
        guard let decoded = try? JSONDecoder().decode(CrashUserContextUploadResponse.self, from: data),
              decoded.success,
              decoded.reportID.caseInsensitiveCompare(reportID) == .orderedSame else {
            throw CrashReportDeliveryError.retryable(statusCode: response.statusCode)
        }
    }

    func uploadMetricKitDiagnostic(_ diagnostic: MetricKitDiagnosticEnvelope) async throws {
        let json = try JSONEncoder.crashReportEncoder().encode(diagnostic)
        let body = try await Task.detached(priority: .utility) {
            try CrashGzip.compress(json)
        }.value
        guard body.count <= 512 * 1024 else {
            throw CrashReportDeliveryError.permanent(statusCode: 413)
        }
        var request = try signedRequest(
            method: "POST",
            path: Self.metricKitPath,
            body: body,
            clientID: diagnostic.anonymousInstallID
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        let (data, response) = try await perform(request)
        guard let decoded = try? JSONDecoder().decode(CrashTechnicalUploadResponse.self, from: data),
              decoded.success,
              decoded.reportID.caseInsensitiveCompare(diagnostic.reportID) == .orderedSame else {
            throw CrashReportDeliveryError.retryable(statusCode: response.statusCode)
        }
    }

    private func signedRequest(
        method: String,
        path: String,
        body: Data,
        clientID: String
    ) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL),
              let headers = signer.sign(method: method, path: path, body: body, clientID: clientID) else {
            throw CrashReportDeliveryError.invalidRequest
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.httpBody = body
        request.setValue(headers.clientID, forHTTPHeaderField: "X-Client-Id")
        request.setValue(headers.timestamp, forHTTPHeaderField: "X-Timestamp")
        request.setValue(headers.nonce, forHTTPHeaderField: "X-Nonce")
        request.setValue(headers.signature, forHTTPHeaderField: "X-Signature")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CrashReportDeliveryError.retryable(statusCode: nil)
            }
            switch http.statusCode {
            case 200..<300:
                return (data, http)
            case 401:
                throw CrashReportDeliveryError.unauthorized
            case 400, 403, 404, 409, 413, 415, 422:
                throw CrashReportDeliveryError.permanent(statusCode: http.statusCode)
            default:
                throw CrashReportDeliveryError.retryable(statusCode: http.statusCode)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CrashReportDeliveryError {
            throw error
        } catch {
            throw CrashReportDeliveryError.retryable(statusCode: nil)
        }
    }
}

private nonisolated struct CrashUserContextRequest: Encodable, Sendable {
    let anonymousInstallID: String
    let contextRevisionID: String
    let userDescription: String
}

private nonisolated enum CrashGzipError: Error {
    case initializationFailed(Int32)
    case compressionFailed(Int32)
}

private nonisolated enum CrashGzip {
    static func compress(_ input: Data) throws -> Data {
        var stream = z_stream()
        let initialization = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            MAX_WBITS + 16,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initialization == Z_OK else {
            throw CrashGzipError.initializationFailed(initialization)
        }
        defer { deflateEnd(&stream) }

        return try input.withUnsafeBytes { inputBuffer in
            stream.next_in = UnsafeMutablePointer<Bytef>(
                mutating: inputBuffer.bindMemory(to: Bytef.self).baseAddress
            )
            stream.avail_in = uInt(inputBuffer.count)
            var output = Data()
            var status: Int32 = Z_OK

            repeat {
                var buffer = [UInt8](repeating: 0, count: 32 * 1024)
                let written = buffer.withUnsafeMutableBytes { outputBuffer -> Int in
                    stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(outputBuffer.count)
                    status = deflate(&stream, Z_FINISH)
                    return outputBuffer.count - Int(stream.avail_out)
                }
                output.append(contentsOf: buffer.prefix(written))
            } while status == Z_OK

            guard status == Z_STREAM_END else {
                throw CrashGzipError.compressionFailed(status)
            }
            return output
        }
    }
}
