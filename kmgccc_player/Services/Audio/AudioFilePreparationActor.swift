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
/// MainActor-bound and cannot be read off-main. This snapshot carries the
/// unified locator inputs needed by `LocalAudioResourceResolver`. Only this
/// value (never the `Track`) crosses into
/// `AudioFilePreparationActor`.
struct AudioPrepRequest: Sendable {
    let trackID: UUID
    let locator: TrackMediaLocator
    let libraryPaths: LibraryPaths
    let authorizedSourceRoots: [UUID: AuthorizedSourceRoot]
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
    let lease: SecurityScopedResourceLease
    let refreshedLocator: TrackMediaLocator?
    let newAvailability: TrackAvailability
    let sampleRate: Double
    let frameLength: AVAudioFramePosition
    let duration: Double
    /// AAC encoder priming/padding metadata (nil when it could not be read).
    /// Consumed only by the gapless-append path to skip the encoder's
    /// leading/trailing silence at an AAC→AAC boundary; never used for
    /// single-track playback or for non-AAC files.
    let aacGaplessInfo: AACGaplessInfo?
}

/// Prepares audio files off the MainActor. Each `prepare(_:)` call is an
/// independent unit of work; a failure throws and never blocks other prepares.
actor AudioFilePreparationActor {
    private let bookmarkResolver: any BookmarkResolving
    private let requiresSecurityScope: Bool

    init(
        bookmarkResolver: any BookmarkResolving = SystemBookmarkResolver(),
        requiresSecurityScope: Bool = false
    ) {
        self.bookmarkResolver = bookmarkResolver
        self.requiresSecurityScope = requiresSecurityScope
    }

    enum PrepError: Error {
        /// File does not exist / bookmark empty / security scope refused.
        case missingFile
        /// Bookmark data could not be resolved to a URL.
        case bookmarkUnresolved
        case permissionDenied
        case volumeUnavailable
        case notDownloaded
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
            resolution.lease.release()
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
            resolution.lease.release()
            throw PrepError.openFailed(underlying: error)
        }
        FirstUseHitchDiagnostics.end(openToken)

        let sampleRate = file.processingFormat.sampleRate
        let frameLength = file.length
        let duration = sampleRate > 0 ? Double(frameLength) / sampleRate : 0

        // Read AAC gapless metadata off-main here (cheap property reads on a
        // separate AudioToolbox handle). Carried on the resource and used only by
        // the gapless-append path; resilient (nil on any failure).
        let aacGaplessInfo = AACGaplessMetadata.read(url: resolution.url)

        return PreparedAudioResource(
            trackID: request.trackID,
            file: file,
            resolvedURL: resolution.url,
            lease: resolution.lease,
            refreshedLocator: resolution.refreshedLocator,
            newAvailability: resolution.newAvailability,
            sampleRate: sampleRate,
            frameLength: frameLength,
            duration: duration,
            aacGaplessInfo: aacGaplessInfo
        )
    }

    // MARK: - Resolution (mirrors Track.resolveFileURL semantics, off-main)

    private struct Resolution {
        let url: URL
        let lease: SecurityScopedResourceLease
        let refreshedLocator: TrackMediaLocator?
        let newAvailability: TrackAvailability
    }

    private func resolveURL(_ request: AudioPrepRequest) throws -> Resolution {
        let resolveToken = FirstUseHitchDiagnostics.begin(
            "bookmark.resolve",
            detail: "track=\(request.trackID.uuidString.prefix(8))"
        )
        defer { FirstUseHitchDiagnostics.end(resolveToken) }

        let resolver = LocalAudioResourceResolver(
            paths: request.libraryPaths,
            authorizedSourceRoots: request.authorizedSourceRoots,
            bookmarkResolver: bookmarkResolver,
            requiresSecurityScope: requiresSecurityScope
        )
        do {
            let result = try resolver.resolve(request.locator)
            return Resolution(
                url: result.url,
                lease: result.lease,
                refreshedLocator: result.refreshedLocator,
                newAvailability: result.availability
            )
        } catch LocalAudioResolutionError.bookmarkUnresolved {
            throw PrepError.bookmarkUnresolved
        } catch LocalAudioResolutionError.permissionDenied {
            throw PrepError.permissionDenied
        } catch LocalAudioResolutionError.volumeUnavailable {
            throw PrepError.volumeUnavailable
        } catch LocalAudioResolutionError.notDownloaded {
            throw PrepError.notDownloaded
        } catch {
            throw PrepError.missingFile
        }
    }
}
