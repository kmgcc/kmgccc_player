//
//  AudioFilePreparationActor.swift
//  myPlayer2
//
//  Off-main audio file preparation for the playback start path.
//  Moves bookmark resolution, AVAudioFile(forReading:), and format/duration
//  extraction out of the MainActor so the real audio start path does no
//  synchronous disk I/O on the main thread.
//

import AVFoundation
import Foundation

/// Sendable value snapshot captured cheaply on MainActor from a `Track`.
///
/// `Track` is a SwiftData `@Model`; its stored properties are context /
/// MainActor-bound and cannot be read off-main. This snapshot mirrors exactly
/// the fields `Track.resolveFileURL()` reads, so resolution can move off-main
/// with no semantic change. Only this value (never the `Track`) crosses into
/// `AudioFilePreparationActor`.
struct AudioPrepRequest: Sendable {
    let trackID: UUID
    let libraryRelativePath: String
    let fileBookmarkData: Data
    let titleForLog: String
}

/// Result of off-main audio file preparation.
///
/// INVARIANT (single-owner handoff): `file` (AVAudioFile) is created ONLY
/// inside `AudioFilePreparationActor`. After creation the actor never touches
/// it again. It is handed to `AVAudioPlaybackService` / `playerNode` for
/// single-point scheduling — there is NO concurrent multi-thread access.
/// AVAudioFile is not Sendable; this type is `@unchecked Sendable` solely
/// because that single-owner handoff is upheld by construction.
///
/// INVARIANT (security scope): when `didStartSecurityScopedAccess` is true,
/// `resolvedURL` holds an active security-scoped access that was started during
/// resolution. Any path that drops this resource WITHOUT keeping it as the
/// current file (generation discard, prepare-after-the-fact failure, stop, or
/// replacement) MUST call `resolvedURL.stopAccessingSecurityScopedResource()`
/// — and ONLY when `didStartSecurityScopedAccess` is true. Library-relative
/// paths never start a security scope, so the flag is false and no release is
/// performed for them.
struct PreparedAudioResource: @unchecked Sendable {
    let trackID: UUID
    let file: AVAudioFile
    let resolvedURL: URL
    let didStartSecurityScopedAccess: Bool
    let refreshedBookmarkData: Data?
    let newAvailability: TrackAvailability
    let sampleRate: Double
    let frameLength: AVAudioFramePosition
    let duration: Double
}

/// Prepares audio files off the MainActor. Each `prepare(_:)` call is an
/// independent unit of work; a failure throws and never blocks other prepares.
actor AudioFilePreparationActor {

    enum PrepError: Error {
        /// File does not exist / bookmark empty / security scope refused.
        case missingFile
        /// Bookmark data could not be resolved to a URL.
        case bookmarkUnresolved
        /// The file resolved but AVAudioFile could not open it.
        case openFailed(underlying: Error)
        /// The prepare was cancelled (superseded by a newer play request).
        case cancelled
    }

    /// Resolve the file URL off-main, open the audio file, and extract format
    /// and duration. Throws `PrepError` on any failure.
    ///
    /// `FirstUseHitchDiagnostics` is `nonisolated` and thread-safe (NSLock-
    /// guarded state + concurrency-safe `OSSignposter`), so its signposts are
    /// safe to emit from this actor's executor (off-main).
    func prepare(_ request: AudioPrepRequest) async throws -> PreparedAudioResource {
        let prepToken = FirstUseHitchDiagnostics.begin(
            "AudioPrepare",
            detail: "track=\(request.trackID.uuidString.prefix(8))"
        )
        defer { FirstUseHitchDiagnostics.end(prepToken) }

        if Task.isCancelled { throw PrepError.cancelled }

        // 1. Resolve to a usable (possibly security-scoped) URL.
        let resolution = try resolveURL(request)

        // If cancelled after starting security-scoped access but before opening
        // the file, release the access so it does not leak.
        if Task.isCancelled {
            if resolution.didStartSecurityScopedAccess {
                resolution.url.stopAccessingSecurityScopedResource()
            }
            throw PrepError.cancelled
        }

        // 2. Open the file + extract format/duration.
        let openToken = FirstUseHitchDiagnostics.begin(
            "AVAudioFile.open",
            detail: "track=\(request.trackID.uuidString.prefix(8))"
        )
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: resolution.url)
        } catch {
            FirstUseHitchDiagnostics.end(openToken)
            if resolution.didStartSecurityScopedAccess {
                resolution.url.stopAccessingSecurityScopedResource()
            }
            throw PrepError.openFailed(underlying: error)
        }
        FirstUseHitchDiagnostics.end(openToken)

        let sampleRate = file.processingFormat.sampleRate
        let frameLength = file.length
        let duration = sampleRate > 0 ? Double(frameLength) / sampleRate : 0

        return PreparedAudioResource(
            trackID: request.trackID,
            file: file,
            resolvedURL: resolution.url,
            didStartSecurityScopedAccess: resolution.didStartSecurityScopedAccess,
            refreshedBookmarkData: resolution.refreshedBookmarkData,
            newAvailability: resolution.newAvailability,
            sampleRate: sampleRate,
            frameLength: frameLength,
            duration: duration
        )
    }

    // MARK: - Resolution (mirrors Track.resolveFileURL semantics, off-main)

    private struct Resolution {
        let url: URL
        let didStartSecurityScopedAccess: Bool
        let refreshedBookmarkData: Data?
        let newAvailability: TrackAvailability
    }

    private func resolveURL(_ request: AudioPrepRequest) throws -> Resolution {
        let resolveToken = FirstUseHitchDiagnostics.begin(
            "bookmark.resolve",
            detail: "track=\(request.trackID.uuidString.prefix(8))"
        )
        defer { FirstUseHitchDiagnostics.end(resolveToken) }

        // Library-relative path takes priority (no security scope needed).
        if !request.libraryRelativePath.isEmpty {
            let localURL = LocalLibraryPaths.libraryURL(from: request.libraryRelativePath)
            if FileManager.default.fileExists(atPath: localURL.path) {
                return Resolution(
                    url: localURL,
                    didStartSecurityScopedAccess: false,
                    refreshedBookmarkData: nil,
                    newAvailability: .available
                )
            }
            throw PrepError.missingFile
        }

        guard !request.fileBookmarkData.isEmpty else {
            throw PrepError.missingFile
        }

        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: request.fileBookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw PrepError.bookmarkUnresolved
        }

        guard url.startAccessingSecurityScopedResource() else {
            throw PrepError.missingFile
        }

        var refreshedData: Data? = nil
        if isStale {
            refreshedData = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }

        return Resolution(
            url: url,
            didStartSecurityScopedAccess: true,
            refreshedBookmarkData: refreshedData,
            newAvailability: isStale ? .stale : .available
        )
    }
}
