//
//  FileImportService.swift
//  myPlayer2
//
//  TrueMusic - File Import Service
//  Imports audio files into a SPECIFIC PLAYLIST using NSOpenPanel.
//  Creates security-scoped bookmarks for sandbox access.
//

import AVFoundation
import AppKit
import Foundation

/// Service for importing audio files into a playlist.
/// Supports mp3, m4a, aac, alac, flac, wav.
@MainActor
final class FileImportService: FileImportServiceProtocol {

    // MARK: - Supported Types

    static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "alac", "flac", "wav", "aiff", "aif",
    ]

    static let supportedUTTypes: [UTType] = [
        .mp3,
        .mpeg4Audio,
        .aiff,
        .wav,
        UTType(filenameExtension: "flac") ?? .audio,
        UTType(filenameExtension: "m4a") ?? .mpeg4Audio,
        UTType(filenameExtension: "alac") ?? .audio,
    ].compactMap { $0 }

    // MARK: - Properties

    private let repository: LibraryRepositoryProtocol

    // MARK: - Initialization

    init(repository: LibraryRepositoryProtocol) {
        self.repository = repository
        print("📂 FileImportService initialized")
    }

    // MARK: - Public Methods

    /// Present file picker and import selected files/folders into a specific playlist.
    /// - Parameter playlist: The target playlist to import into.
    /// - Returns: Number of tracks successfully imported.
    @discardableResult
    func pickAndImport(to playlist: Playlist) async -> Int {
        print("🎯 pickAndImport called for playlist: '\(playlist.name)' (id=\(playlist.id))")

        // Configure open panel
        let panel = NSOpenPanel()
        panel.title = "Import Music to \"\(playlist.name)\""
        panel.message = "Select audio files or folders to add to this playlist"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.supportedUTTypes

        // Show panel
        print("📂 Showing NSOpenPanel...")
        let response = panel.runModal()

        guard response == .OK else {
            print("📂 NSOpenPanel cancelled by user")
            return 0
        }

        print("📂 NSOpenPanel returned \(panel.urls.count) URLs")
        if let first = panel.urls.first {
            print("   ↳ First URL: \(first.lastPathComponent)")
        }

        // CRITICAL: Start accessing security-scoped resources IMMEDIATELY
        // NSOpenPanel returns security-scoped URLs that expire if not accessed
        var accessingURLs: [URL] = []
        for url in panel.urls {
            let didStart = url.startAccessingSecurityScopedResource()
            print(
                "🔐 startAccessingSecurityScopedResource for '\(url.lastPathComponent)': \(didStart)"
            )

            // Additional diagnostics
            print("   ↳ URL.isFileURL: \(url.isFileURL)")
            print("   ↳ URL.path: \(url.path)")
            let isReadable = FileManager.default.isReadableFile(atPath: url.path)
            print("   ↳ FileManager.isReadableFile: \(isReadable)")

            if didStart {
                accessingURLs.append(url)
            } else {
                print("   ⚠️ Failed to start accessing security-scoped resource!")
            }
        }

        // Ensure we stop accessing at the end
        defer {
            for url in accessingURLs {
                url.stopAccessingSecurityScopedResource()
                print("🔓 stopAccessingSecurityScopedResource for '\(url.lastPathComponent)'")
            }
        }

        // Collect all audio files (including from directories)
        var filesToImport: [URL] = []

        for url in panel.urls {
            if url.hasDirectoryPath {
                // Recursively find audio files in directory
                let audioFiles = findAudioFiles(in: url)
                filesToImport.append(contentsOf: audioFiles)
            } else if isAudioFile(url) {
                filesToImport.append(url)
            }
        }

        print("📁 Found \(filesToImport.count) audio files to import to '\(playlist.name)'")

        // Import each file
        var importedTracks: [Track] = []
        var skippedCount = 0

        for fileURL in filesToImport {
            // Check if already exists in library
            let exists = await repository.trackExists(filePath: fileURL.path)
            if exists {
                skippedCount += 1
                continue
            }

            // Import the file (bookmark creation now happens while we have access)
            if let track = await importFile(url: fileURL) {
                print(
                    "📀 Created Track: '\(track.title)', bookmarkData=\(track.fileBookmarkData.count) bytes"
                )
                await repository.addTrack(track)
                importedTracks.append(track)
            }
        }

        // Add all imported tracks to the playlist
        if !importedTracks.isEmpty {
            print("🔗 Adding \(importedTracks.count) tracks to playlist '\(playlist.name)'")
            await repository.addTracks(importedTracks, to: playlist)
        }

        print("✅ Import complete: \(importedTracks.count) imported, \(skippedCount) skipped")
        return importedTracks.count
    }

    // MARK: - Private Methods

    /// Import a single audio file, creating a Track with bookmark.
    /// ASSUMES: Parent caller has already started accessing security-scoped resource.
    private func importFile(url: URL) async -> Track? {
        // Create security-scoped bookmark
        guard let bookmarkData = createBookmark(for: url) else {
            print("❌ Failed to create bookmark for: \(url.lastPathComponent)")
            return nil
        }

        // Extract metadata
        let metadata = await extractMetadata(from: url)

        // Extract artwork
        let artworkData = await extractArtwork(from: url)

        let track = Track(
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            duration: metadata.duration,
            fileBookmarkData: bookmarkData,
            originalFilePath: url.path,
            artworkData: artworkData,
            ttmlLyricText: metadata.lyrics
        )

        return track
    }

    /// Create a security-scoped bookmark for a file URL.
    /// ASSUMES: Caller has already called startAccessingSecurityScopedResource.
    private func createBookmark(for url: URL) -> Data? {
        print("🔖 Creating security-scoped bookmark for '\(url.lastPathComponent)'...")

        do {
            // CRITICAL: Use array syntax for options to ensure security-scoped bookmark
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            print("✅ Created security-scoped bookmark: \(bookmarkData.count) bytes")
            return bookmarkData
        } catch {
            print("❌ Bookmark creation failed for '\(url.lastPathComponent)':")
            print("   ↳ Error: \(error)")
            print("   ↳ Error domain: \((error as NSError).domain)")
            print("   ↳ Error code: \((error as NSError).code)")
            return nil
        }
    }

    /// Extract metadata from audio file using AVAsset.
    private func extractMetadata(from url: URL) async -> (
        title: String, artist: String, album: String, duration: Double, lyrics: String?
    ) {
        let asset = AVAsset(url: url)

        // Default values
        var title = url.deletingPathExtension().lastPathComponent
        var artist = "Unknown Artist"
        var album = "Unknown Album"
        var duration: Double = 0
        var lyrics: String? = nil

        // Get duration
        do {
            let durationTime = try await asset.load(.duration)
            duration = CMTimeGetSeconds(durationTime)
        } catch {
            print("⚠️ Failed to load duration: \(error)")
        }

        // Get metadata
        do {
            let metadata = try await asset.load(.commonMetadata)

            for item in metadata {
                guard let key = item.commonKey?.rawValue,
                    let value = try? await item.load(.stringValue)
                else {
                    continue
                }

                switch key {
                case "title":
                    title = value
                case "artist":
                    artist = value
                case "albumName":
                    album = value
                case "lyrics":
                    lyrics = value
                default:
                    break
                }
            }

            // Fallback: Check for ID3 USLT if common metadata failed
            if lyrics == nil {
                let id3Metadata = try await asset.load(.metadata)
                for item in id3Metadata {
                    if let key = item.identifier?.rawValue, key == "id3/USLT",
                        let value = try? await item.load(.stringValue)
                    {
                        lyrics = value
                        break
                    }
                }
            }
        } catch {
            print("⚠️ Failed to load metadata: \(error)")
        }

        return (title, artist, album, duration, lyrics)
    }

    /// Extract artwork from audio file.
    private func extractArtwork(from url: URL) async -> Data? {
        let asset = AVAsset(url: url)

        do {
            let metadata = try await asset.load(.commonMetadata)

            for item in metadata {
                guard let key = item.commonKey?.rawValue, key == "artwork" else {
                    continue
                }

                if let data = try? await item.load(.dataValue) {
                    return data
                }
            }
        } catch {
            print("⚠️ Failed to load artwork: \(error)")
        }

        return nil
    }

    /// Recursively find audio files in a directory.
    private func findAudioFiles(in directory: URL) -> [URL] {
        var audioFiles: [URL] = []

        let fileManager = FileManager.default
        guard
            let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return audioFiles
        }

        for case let fileURL as URL in enumerator {
            if isAudioFile(fileURL) {
                audioFiles.append(fileURL)
            }
        }

        return audioFiles
    }

    /// Check if a URL is a supported audio file.
    private func isAudioFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return Self.supportedExtensions.contains(ext)
    }
}
