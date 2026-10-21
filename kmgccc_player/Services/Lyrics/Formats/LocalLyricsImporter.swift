//
//  LocalLyricsImporter.swift
//  kmgccc_player
//
//  Lyrics from the user's own files: the lyric file picker in the track
//  editors, same-name lyric files beside imported audio, and lyrics embedded
//  in audio tags. Everything comes back as validated TTML.
//

import Foundation
import UniformTypeIdentifiers

nonisolated enum LocalLyricsImporter {
    /// File types offered by the lyric file picker.
    static let pickerContentTypes: [UTType] = ["ttml", "lrc", "yrc", "qrc", "lys", "lyl", "lqe", "txt"]
        .compactMap { UTType(filenameExtension: $0) }

    /// Same-name lyric files looked up beside imported audio, best first:
    /// TTML, then word-synced formats, then line-synced ones.
    static let sidecarFileExtensions = ["ttml", "yrc", "qrc", "lys", "lqe", "lrc", "lyl"]

    static func ttml(fromFileAt url: URL) async throws -> String {
        let data: Data
        do {
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess { url.stopAccessingSecurityScopedResource() }
            }
            data = try Data(contentsOf: url)
        } catch {
            throw LyricsConversionError.unreadableFile
        }
        guard let text = LyricsTextDecoder.decode(data) else {
            throw LyricsConversionError.unreadableEncoding
        }
        return try await LyricsTTMLConverter.ttml(from: text)
    }

    /// Reads and converts off the main actor, for UI callers.
    static func loadTTML(fromFileAt url: URL) async -> Result<String, LyricsConversionError> {
        await Task.detached(priority: .userInitiated) { () async -> Result<String, LyricsConversionError> in
            do {
                return .success(try await LocalLyricsImporter.ttml(fromFileAt: url))
            } catch let error as LyricsConversionError {
                return .failure(error)
            } catch {
                return .failure(.unreadableFile)
            }
        }.value
    }

    /// Lyrics for newly imported audio. A same-name lyric file beside the audio is the
    /// user's deliberate choice, so it wins over lyrics embedded in the tags.
    static func ttmlForImportedAudio(at audioURL: URL, embeddedLyrics: String?) async -> String? {
        if let sidecar = await sidecarTTML(forAudioAt: audioURL) {
            return sidecar
        }
        return await embeddedTTML(embeddedLyrics)
    }

    static func sidecarTTML(forAudioAt audioURL: URL) async -> String? {
        let baseURL = audioURL.deletingPathExtension()
        for fileExtension in sidecarFileExtensions {
            guard !Task.isCancelled else { return nil }
            // The uppercase spelling only matters on case-sensitive volumes.
            guard let candidateURL = [fileExtension, fileExtension.uppercased()]
                .map({ baseURL.appendingPathExtension($0) })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { continue }
            do {
                let converted = try await ttml(fromFileAt: candidateURL)
                Log.info("[LocalLyrics] sidecar lyrics imported: \(candidateURL.lastPathComponent)", category: .lyrics)
                return converted
            } catch {
                Log.warning(
                    "[LocalLyrics] sidecar lyrics skipped \(candidateURL.lastPathComponent): \(error.localizedDescription)",
                    category: .lyrics
                )
            }
        }
        return nil
    }

    static func embeddedTTML(_ rawLyrics: String?) async -> String? {
        guard let rawLyrics, !Task.isCancelled,
              !rawLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            return try await LyricsTTMLConverter.ttml(from: rawLyrics)
        } catch {
            Log.warning("[LocalLyrics] embedded lyrics skipped: \(error.localizedDescription)", category: .lyrics)
            return nil
        }
    }
}
