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

    /// Probes a physical file on a background executor before a referenced
    /// duplicate is promoted to the preferred location. Keep this probe
    /// separate from `prepare` so the import path never blocks the main actor.
    /// The synchronous decoder read is deliberately left to the prepare actor:
    /// malformed containers can block Core Audio while it tries to recover, and
    /// an import probe must never hold up the rest of a batch.
    nonisolated static func canOpenForPlayback(_ url: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return false }
            guard let file = try? AVAudioFile(forReading: url),
                  file.length > 0,
                  file.processingFormat.sampleRate.isFinite,
                  file.processingFormat.sampleRate > 0,
                  file.processingFormat.channelCount > 0 else {
                return false
            }
            return true
        }.value
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

        // 1. Resolve every usable (possibly security-scoped) URL. A referenced
        // duplicate can put a metadata-readable but codec-incompatible copy
        // first; playback must then fall back to the original location.
        var resolutions = try resolveURLs(request)

        // If cancelled after starting security-scoped access but before opening
        // the file, release every access so it does not leak.
        if Task.isCancelled {
            resolutions.forEach { $0.lease.release() }
            throw PrepError.cancelled
        }

        // 2. Open the first playable file + extract format/duration. Resolver
        // failures (missing/permission) are handled before this loop; an
        // AVAudioFile failure is local to one physical location and should not
        // discard the remaining fallbacks.
        var file: AVAudioFile?
        var selectedResolution: Resolution?
        var lastOpenError: Error?
        while !resolutions.isEmpty {
            let resolution = resolutions.removeFirst()
            if Task.isCancelled {
                resolution.lease.release()
                resolutions.forEach { $0.lease.release() }
                throw PrepError.cancelled
            }

            let openToken = FirstUseHitchDiagnostics.begin(
                "AVAudioFile.open",
                detail: "track=\(request.trackID.uuidString.prefix(8))"
            )
            do {
                file = try openPlayableFile(at: resolution.url)
                FirstUseHitchDiagnostics.end(openToken)
                selectedResolution = resolution
                break
            } catch {
                FirstUseHitchDiagnostics.end(openToken)
                lastOpenError = error
                resolution.lease.release()
            }
        }

        guard let file, let resolution = selectedResolution else {
            resolutions.forEach { $0.lease.release() }
            throw PrepError.openFailed(
                underlying: lastOpenError ?? NSError(
                    domain: "AudioFilePreparation",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No playable audio location"]
                )
            )
        }

        // The selected resource owns the only lease needed by the caller; all
        // later fallback candidates are released now that opening succeeded.
        resolutions.forEach { $0.lease.release() }

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

    /// Opens a candidate and validates the format before handing it to the
    /// playback graph. AVAudioFile can construct a zero-frame resource for a
    /// damaged container; treating that as a failed candidate lets the caller
    /// try the next physical copy without retaining an unusable file.
    private func openPlayableFile(at url: URL) throws -> AVAudioFile {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0,
              file.processingFormat.sampleRate.isFinite,
              file.processingFormat.sampleRate > 0,
              file.processingFormat.channelCount > 0 else {
            throw NSError(
                domain: "AudioFilePreparation",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Audio file has no decodable frames"]
            )
        }
        return file
    }

    // MARK: - Resolution (mirrors Track.resolveFileURL semantics, off-main)

    private struct Resolution {
        let url: URL
        let lease: SecurityScopedResourceLease
        let refreshedLocator: TrackMediaLocator?
        let newAvailability: TrackAvailability
    }

    private func resolveURLs(_ request: AudioPrepRequest) throws -> [Resolution] {
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
            return try resolver.resolveCandidates(request.locator).map { result in
                Resolution(
                    url: result.url,
                    lease: result.lease,
                    refreshedLocator: result.refreshedLocator,
                    newAvailability: result.availability
                )
            }
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
