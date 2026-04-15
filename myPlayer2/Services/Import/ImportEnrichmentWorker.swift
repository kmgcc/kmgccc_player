//
//  ImportEnrichmentWorker.swift
//  myPlayer2
//

import AppKit
import Foundation

nonisolated enum ImportEnrichmentWorker {
    private final class ContinuationState: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?

        init(_ continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
        }

        func resume(_ result: Result<Void, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard let continuation else { return }
            self.continuation = nil
            switch result {
            case .success:
                continuation.resume()
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    static func fetchLyrics(
        title: String,
        artist: String,
        album: String? = nil,
        duration: Double? = nil
    ) async -> ImportLyricsLookupOutcome {
        let ttml = await LyricsSearchHelper.searchAndFetchBestLyrics(
            title: title,
            artist: artist.isEmpty ? nil : artist,
            album: album?.isEmpty == true ? nil : album,
            duration: duration
        )

        if let ttml {
            return .completed(ttml)
        } else {
            return .noResults
        }
    }

    static func fetchCover(
        artist: String,
        album: String
    ) async -> ImportCoverLookupOutcome {
        let normalizedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedArtist.isEmpty || !normalizedAlbum.isEmpty else {
            return .noResults
        }

        do {
            let coverData = try await withCoverLookupTimeout(
                CoverLookupConfiguration.importPerTrackTimeout
            ) {
                do {
                    return try await withCoverLookupTimeout(
                        CoverLookupConfiguration.netEaseCandidatesTimeout
                    ) {
                        try await downloadNetEaseCover(
                            artist: normalizedArtist,
                            album: normalizedAlbum
                        )
                    }
                } catch let error as NetEaseCoverError {
                    if case .noResults = error {
                        // Fall through to sacad.
                    } else {
                        Log.warning(
                            "NetEase cover fetch failed for \(normalizedArtist) - \(normalizedAlbum): \(error)",
                            category: .import
                        )
                    }
                } catch {
                    Log.warning(
                        "NetEase cover fetch failed for \(normalizedArtist) - \(normalizedAlbum): \(error)",
                        category: .import
                    )
                }

                return try await withCoverLookupTimeout(CoverLookupConfiguration.sacadTimeout) {
                    try await downloadCoverViaSacad(
                        artist: normalizedArtist,
                        album: normalizedAlbum,
                        size: 1200
                    )
                }
            }
            return .completed(coverData)
        } catch let error as NetEaseCoverError {
            if case .noResults = error {
                return .noResults
            }
            Log.warning(
                "Import cover fetch failed for \(normalizedArtist) - \(normalizedAlbum): \(error)",
                category: .import
            )
            return .failed(error.localizedDescription)
        } catch let error as CoverLookupTimeoutError {
            Log.warning(
                "Import cover fetch timed out for \(normalizedArtist) - \(normalizedAlbum): \(error)",
                category: .import
            )
            return .failed("封面查找超时")
        } catch {
            Log.warning(
                "Import cover fetch failed for \(normalizedArtist) - \(normalizedAlbum): \(error)",
                category: .import
            )
            return .failed(error.localizedDescription)
        }
    }

    private static func downloadCoverViaSacad(
        artist: String,
        album: String,
        size: Int
    ) async throws -> Data {
        let executablePath = "/Users/kmg/.cargo/bin/sacad"
        let fileManager = FileManager.default

        guard fileManager.isExecutableFile(atPath: executablePath) else {
            throw CoverDownloadError.executableMissing(path: executablePath)
        }

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("temp_\(UUID().uuidString).jpg")

        defer {
            try? fileManager.removeItem(at: tempURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [artist, album, String(size), tempURL.path]

        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let state = ContinuationState(continuation)
                process.terminationHandler = { process in
                    let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    guard process.terminationStatus == 0 else {
                        let stderrText = String(data: stderrData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        state.resume(
                            .failure(
                                CoverDownloadError.processFailed(
                                    exitCode: process.terminationStatus,
                                    message: stderrText?.isEmpty == false
                                        ? stderrText!
                                        : "sacad exited with an error"
                                )
                            )
                        )
                        return
                    }
                    state.resume(.success(()))
                }

                do {
                    try process.run()
                } catch {
                    state.resume(
                        .failure(
                            CoverDownloadError.processFailed(
                                exitCode: -1,
                                message: error.localizedDescription
                            )
                        )
                    )
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }

        guard fileManager.fileExists(atPath: tempURL.path) else {
            throw CoverDownloadError.outputMissing
        }

        let imageData = try Data(contentsOf: tempURL)
        guard !imageData.isEmpty, NSImage(data: imageData) != nil else {
            throw CoverDownloadError.invalidImageData
        }
        return imageData
    }

    private static func downloadNetEaseCover(
        artist: String,
        album: String
    ) async throws -> Data {
        let session = await makeNetEaseSession()
        let query = "\(artist) \(album)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw NetEaseCoverError.noResults
        }

        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else {
            throw NetEaseCoverError.badURL
        }

        let searchURLString =
            "https://music.163.com/api/search/get/web?type=10&s=\(encodedQuery)&limit=5"
        guard let searchURL = URL(string: searchURLString) else {
            throw NetEaseCoverError.badURL
        }

        let searchData: Data
        do {
            let (data, response) = try await session.data(from: searchURL)
            try validateNetEaseHTTP(response: response)
            searchData = data
        } catch let error as NetEaseCoverError {
            throw error
        } catch {
            throw NetEaseCoverError.requestFailed(underlying: error)
        }

        let result: NetEaseSearchResponse
        do {
            result = try JSONDecoder().decode(NetEaseSearchResponse.self, from: searchData)
        } catch {
            throw NetEaseCoverError.decodingFailed(underlying: error)
        }

        guard let picURLString = result.result.albums.first?.picURL else {
            throw NetEaseCoverError.noResults
        }

        let finalCoverURLString = makeLargeCoverURLString(from: picURLString)
        guard let coverURL = URL(string: finalCoverURLString) else {
            throw NetEaseCoverError.badURL
        }

        do {
            let (imageData, response) = try await session.data(from: coverURL)
            try validateNetEaseHTTP(response: response)
            guard !imageData.isEmpty, NSImage(data: imageData) != nil else {
                throw NetEaseCoverError.imageDownloadFailed(
                    underlying: CoverDownloadError.invalidImageData
                )
            }
            return imageData
        } catch let error as NetEaseCoverError {
            throw error
        } catch {
            throw NetEaseCoverError.imageDownloadFailed(underlying: error)
        }
    }

    private static func validateNetEaseHTTP(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let error = NSError(
                domain: "NetEaseCoverService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
            )
            throw NetEaseCoverError.requestFailed(underlying: error)
        }
    }

    private static func makeLargeCoverURLString(from picURLString: String) -> String {
        if picURLString.contains("?") {
            return "\(picURLString)&param=1200y1200"
        }
        return "\(picURLString)?param=1200y1200"
    }

    @MainActor
    private static func makeNetEaseSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = CoverLookupConfiguration.netEasePreferredTimeout
        configuration.timeoutIntervalForResource = CoverLookupConfiguration.netEaseCandidatesTimeout
        return URLSession(configuration: configuration)
    }

    private struct NetEaseSearchResponse: Decodable, Sendable {
        let result: ResultPayload

        struct ResultPayload: Decodable, Sendable {
            let albums: [Album]
        }

        struct Album: Decodable, Sendable {
            let picURL: String

            enum CodingKeys: String, CodingKey {
                case picURL = "picUrl"
            }
        }
    }
}
