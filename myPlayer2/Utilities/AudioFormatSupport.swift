//
//  AudioFormatSupport.swift
//  myPlayer2
//
//  kmgccc_player - Single source of truth for supported audio formats.
//
//  Three layers used to maintain their own list and drifted apart, which is
//  how `.aac` ended up importable in code but greyed-out in the file picker:
//    1. the import file picker (NSOpenPanel `allowedContentTypes`),
//    2. the import whitelist (`isAudioFile` / folder scanning),
//    3. library folder scanning (finding the audio file inside a track folder).
//  All three now derive from this type so they cannot diverge again.
//

import Foundation
import UniformTypeIdentifiers

/// Canonical definition of the audio formats the app supports.
///
/// `playableExtensions` lists container/codec extensions that Core Audio
/// (`AVAudioFile` / `AVURLAsset`) can decode on the app's deployment target.
/// `importableExtensions` adds formats that are decrypted/transcoded during
/// import (currently NCM) before they live in the library as a playable file.
///
/// Formats deliberately excluded: `ogg` / `opus`. Core Audio cannot decode
/// Vorbis or Ogg-Opus, so whitelisting them would create a "selectable but the
/// import/playback fails" trap. They stay out until a real decoder exists.
nonisolated enum AudioFormatSupport {

    /// Extensions Core Audio can decode directly (lowercased, no dot).
    static let playableExtensions: Set<String> = [
        "mp3",
        "m4a",
        "aac",   // bare ADTS stream and AAC-in-MP4
        "alac",
        "flac",  // Core Audio FLAC support (macOS 11+)
        "wav",
        "aiff",
        "aif",
        "caf",   // Core Audio Format container
        "m4b",   // MPEG-4 audiobook
        "mp4",   // MPEG-4 container (audio track)
    ]

    /// Extensions accepted by the importer. Superset of `playableExtensions`
    /// plus formats converted to a playable file during import.
    static let importableExtensions: Set<String> = playableExtensions.union([
        "ncm",   // NetEase encrypted; decrypted during import
    ])

    /// Content types offered by the import `NSOpenPanel`. Built from explicit
    /// system types where they exist, with `UTType(filenameExtension:)`
    /// fallbacks so bare extensions (notably `.aac`) are never greyed out.
    static let openPanelContentTypes: [UTType] = {
        var types: [UTType] = [
            .mp3,
            .mpeg4Audio,
            .aiff,
            .wav,
        ]
        // Explicit identifiers (more stable than extension lookups) first.
        let identifierFallbacks = [
            "public.aac-audio",            // bare ADTS AAC
            "org.xiph.flac",               // FLAC
            "com.apple.coreaudio-format",  // CAF
        ]
        for identifier in identifierFallbacks {
            if let type = UTType(identifier) { types.append(type) }
        }
        // Extension-derived fallbacks for everything else. A bare `.aac` is the
        // important one: it is not a stable built-in preset, so resolving it by
        // extension is what makes it selectable in the panel.
        let extensionFallbacks = [
            "aac", "flac", "m4a", "alac", "caf", "m4b", "mp4", "aif", "ncm",
        ]
        for ext in extensionFallbacks {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        // De-duplicate while preserving order.
        var seen = Set<UTType>()
        return types.filter { seen.insert($0).inserted }
    }()

    /// Whether `url`'s extension is something the importer accepts.
    static func isImportable(_ url: URL) -> Bool {
        importableExtensions.contains(url.pathExtension.lowercased())
    }
}
