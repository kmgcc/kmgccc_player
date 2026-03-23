//
//  FileImportService.swift
//  myPlayer2
//
//  kmgccc_player - File Import Service
//  Imports audio files into a SPECIFIC PLAYLIST using NSOpenPanel.
//  Creates security-scoped bookmarks for sandbox access.
//

import AVFoundation
import AppKit
import Combine
import CoreServices
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared Types

struct ImportPreview {
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let lyrics: String?
    let artworkData: Data?
}

struct TrackPreview {
    let title: String
    let artist: String
    let artworkData: Data?
}

struct DuplicatePairRow: Identifiable {
    let id: String
    let fileURL: URL
    let incoming: ImportPreview
    let existing: TrackPreview?
    let existingCount: Int
    let dedupKey: String
}

enum ArtworkExtractor {
    // Removed
}

// MARK: - Service

/// Service for importing audio files into a playlist.
/// Supports mp3, m4a, aac, alac, flac, wav.
@MainActor
final class FileImportService: FileImportServiceProtocol {
    private struct ImportCandidate {
        let fileURL: URL
        let metadata: ImportPreview
    }

    // MARK: - Supported Types

    nonisolated static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "alac", "flac", "wav", "aiff", "aif", "ncm",
    ]

    static let supportedUTTypes: [UTType] = [
        .mp3,
        .mpeg4Audio,
        .aiff,
        .wav,
        UTType(filenameExtension: "flac") ?? .audio,
        UTType(filenameExtension: "m4a") ?? .mpeg4Audio,
        UTType(filenameExtension: "alac") ?? .audio,
        UTType(filenameExtension: "ncm") ?? .audio,
    ].compactMap { $0 }

    // MARK: - Properties

    private let repository: LibraryRepositoryProtocol
    private let libraryService: LocalLibraryService
    private let coverDownloadService: CoverDownloadServiceProtocol
    private let netEaseCoverService: NetEaseCoverServiceProtocol

    // MARK: - Initialization

    init(
        repository: LibraryRepositoryProtocol,
        libraryService: LocalLibraryService? = nil,
        coverDownloadService: CoverDownloadServiceProtocol? = nil,
        netEaseCoverService: NetEaseCoverServiceProtocol? = nil
    ) {
        self.repository = repository
        self.libraryService = libraryService ?? LocalLibraryService.shared
        self.coverDownloadService = coverDownloadService ?? CoverDownloadService()
        self.netEaseCoverService = netEaseCoverService ?? NetEaseCoverService()
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
        panel.title = String(
            format: NSLocalizedString("import.panel.title", comment: ""), playlist.name)
        panel.message = NSLocalizedString("import.panel.message", comment: "")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.supportedUTTypes

        // Show panel
        // Use app-modal panel (instead of sheet) so NSOpenPanel uses full system styling
        // and does not inherit custom host window chrome tweaks.
        print("📂 Showing NSOpenPanel...")
        panel.appearance = NSApp.appearance
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

        // Collect all audio files (including from directories) - OFF MAIN THREAD
        // Capture panel URLs first since panel is MainActor-isolated
        let panelURLs = panel.urls
        let (filesToImport, ncmFiles) = await Task.detached(priority: .userInitiated) { 
            var filesToImport: [URL] = []
            var ncmFiles: [URL] = []

            for url in panelURLs {
                if url.hasDirectoryPath {
                    let audioFiles = FileImportService.findAudioFiles(in: url)
                    for file in audioFiles {
                        if FileImportService.isNCMFile(file) {
                            ncmFiles.append(file)
                        } else {
                            filesToImport.append(file)
                        }
                    }
                } else if FileImportService.isAudioFile(url) {
                    if FileImportService.isNCMFile(url) {
                        ncmFiles.append(url)
                    } else {
                        filesToImport.append(url)
                    }
                }
            }
            return (filesToImport, ncmFiles)
        }.value
        var ncmResults: [String: NCMConversionResult] = [:]
        var mutableFilesToImport = filesToImport

        // Process NCM files if any
        if !ncmFiles.isEmpty {
            print("🎵 Found \(ncmFiles.count) NCM files to convert")
            let results = await convertNCMFiles(ncmFiles)
            for result in results {
                mutableFilesToImport.append(result.audioFileURL)
                ncmResults[result.audioFileURL.path] = result
            }
        }

        print("📁 Found \(mutableFilesToImport.count) audio files to import to '\(playlist.name)'")

        // Preflight by normalized title + artist (runtime dedup set semantics).
        let libraryTracks = await repository.fetchTracks(in: nil)
        let existingByDedupKey = Dictionary(grouping: libraryTracks) {
            LibraryNormalization.normalizedDedupKey(title: $0.title, artist: $0.artist)
        }

        var uniqueCandidates: [ImportCandidate] = []
        var duplicateRows: [DuplicatePairRow] = []

        for fileURL in mutableFilesToImport {
            // Check if this is a converted NCM file
            let preview: ImportPreview
            if let ncmResult = ncmResults[fileURL.path] {
                // Use NCM metadata
                preview = ImportPreview(
                    title: ncmResult.metadata.title,
                    artist: ncmResult.metadata.artistName,
                    album: ncmResult.metadata.album,
                    duration: ncmResult.metadata.durationSeconds,
                    lyrics: nil,
                    artworkData: ncmResult.coverData
                )
            } else {
                // Extract metadata from audio file - now runs nonisolated
                let raw = await extractMetadata(from: fileURL)
                preview = ImportPreview(
                    title: raw.title,
                    artist: raw.artist,
                    album: raw.album,
                    duration: raw.duration,
                    lyrics: raw.lyrics,
                    artworkData: nil
                )
            }
            
            let candidate = ImportCandidate(
                fileURL: fileURL,
                metadata: preview
            )

            let dedupKey = LibraryNormalization.normalizedDedupKey(
                title: preview.title,
                artist: preview.artist
            )
            let matches = existingByDedupKey[dedupKey] ?? []
            if matches.isEmpty {
                uniqueCandidates.append(candidate)
            } else {
                let first = matches.first
                duplicateRows.append(
                    DuplicatePairRow(
                        id: fileURL.path,
                        fileURL: fileURL,
                        incoming: preview,
                        existing: first.map {
                            TrackPreview(
                                title: $0.title,
                                artist: $0.artist,
                                artworkData: $0.artworkData
                            )
                        },
                        existingCount: matches.count,
                        dedupKey: dedupKey
                    )
                )
            }
        }

        var selectedDuplicates: [ImportCandidate] = []
        if !duplicateRows.isEmpty {
            print("🔍 Found \(duplicateRows.count) duplicates, presenting dialog...")
            if let selectedRows = presentDuplicateSelectionDialog(duplicateRows) {
                print("✅ Dialog confirmed. Selected duplicates to import: \(selectedRows.count)")
                let selectedIDSet = Set(selectedRows.map(\.id))
                selectedDuplicates = duplicateRows.compactMap { row in
                    guard selectedIDSet.contains(row.id) else { return nil }
                    return ImportCandidate(fileURL: row.fileURL, metadata: row.incoming)
                }
            } else {
                print("📥 User cancelled import via duplicate dialog (result was nil)")
                return 0
            }
        }

        // Logic Verification Logs
        print("--------------------------------------------------")
        print("📊 Import Logic Verification:")
        print("   Unique Candidates : \(uniqueCandidates.count)")
        print("   Duplicate Rows    : \(duplicateRows.count)")
        print("   Selected Dups     : \(selectedDuplicates.count)")

        let finalCandidates = uniqueCandidates + selectedDuplicates
        print("   -> FINAL Candidates: \(finalCandidates.count)")
        print("--------------------------------------------------")

        var importedTracks: [Track] = []
        for candidate in finalCandidates {
            if let track = await importFile(
                url: candidate.fileURL,
                metadata: (
                    title: candidate.metadata.title,
                    artist: candidate.metadata.artist,
                    album: candidate.metadata.album,
                    duration: candidate.metadata.duration,
                    lyrics: candidate.metadata.lyrics
                ),
                preloadedArtworkData: candidate.metadata.artworkData  // This will be nil, triggering extraction
            ) {
                await repository.addTrack(track)
                importedTracks.append(track)
            }
        }

        // Add all imported tracks to the playlist
        if !importedTracks.isEmpty {
            print("🔗 Adding \(importedTracks.count) tracks to playlist '\(playlist.name)'")
            await repository.addTracks(importedTracks, to: playlist)
        }

        print("✅ Import complete: \(importedTracks.count) imported")
        return importedTracks.count
    }

    // MARK: - Private Methods

    /// Import a single audio file, creating a Track with bookmark.
    /// ASSUMES: Parent caller has already started accessing security-scoped resource.
    private func importFile(
        url: URL,
        metadata: (title: String, artist: String, album: String, duration: Double, lyrics: String?),
        preloadedArtworkData: Data?
    ) async -> Track? {
        let artworkData: Data?
        if let preloaded = preloadedArtworkData {
            artworkData = preloaded
        } else if let embedded = await Self.extractArtwork(from: url) {
            artworkData = embedded
        } else {
            artworkData = await fetchCoverForImport(artist: metadata.artist, album: metadata.album)
        }

        let trackId = UUID()

        let libraryRelativePath: String
        do {
            libraryRelativePath = try libraryService.importAudioFile(from: url, trackId: trackId)
        } catch {
            print("❌ Failed to copy into library: \(error)")
            return nil
        }

        let lyricsText = metadata.lyrics
        let isTTML = lyricsText?.lowercased().contains("<tt") ?? false

        let track = Track(
            id: trackId,
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            duration: metadata.duration,
            importedAt: Date(),
            fileBookmarkData: Data(),
            originalFilePath: url.path,
            libraryRelativePath: libraryRelativePath,
            artworkData: artworkData,
            ttmlLyricText: isTTML ? lyricsText : nil,
            lyricsText: isTTML ? nil : lyricsText
        )

        return track
    }

    /// Extract metadata from audio file using AVAsset.
    /// Made nonisolated to allow concurrent execution from TaskGroup.
    nonisolated private func extractMetadata(from url: URL) async -> (
        title: String, artist: String, album: String, duration: Double, lyrics: String?
    ) {
        let asset = AVURLAsset(url: url)

        // Default values
        var title: String?
        var artist: String?
        var album: String?
        var lyrics: String?
        var duration: Double = 0

        // Get duration
        do {
            let durationTime = try await asset.load(.duration)
            duration = CMTimeGetSeconds(durationTime)
        } catch {
            print("⚠️ Failed to load duration: \(error)")
        }

        // Collect all metadata items: common first, then full set as fallback
        var allItems: [AVMetadataItem] = []
        if let common = try? await asset.load(.commonMetadata) {
            allItems.append(contentsOf: common)
        }
        if let full = try? await asset.load(.metadata) {
            allItems.append(contentsOf: full)
        }

        for item in allItems {
            // 1. Try Common Key
            if let key = item.commonKey?.rawValue {
                switch key {
                case "title":
                    if title == nil { title = try? await item.load(.stringValue) }
                case "artist":
                    if artist == nil { artist = try? await item.load(.stringValue) }
                case "albumName":
                    if album == nil { album = try? await item.load(.stringValue) }
                case "lyrics":
                    if lyrics == nil { lyrics = try? await item.load(.stringValue) }
                default:
                    break
                }
            }

            // 2. Try raw key string (fallback for FLAC / Vorbis Comment tags)
            if let keyString = (item.key as? String)?.uppercased() {
                if title == nil && keyString == "TITLE" {
                    title = try? await item.load(.stringValue)
                }
                if artist == nil && keyString == "ARTIST" {
                    artist = try? await item.load(.stringValue)
                }
                if album == nil && (keyString == "ALBUM" || keyString == "ALBUMTITLE") {
                    album = try? await item.load(.stringValue)
                }
                if lyrics == nil
                    && (keyString == "LYRICS" || keyString == "UNSYNCEDLYRICS"
                        || keyString == "USLT")
                {
                    lyrics = try? await item.load(.stringValue)
                }
            }

            // 3. ID3 USLT via identifier
            if lyrics == nil,
                let identifier = item.identifier?.rawValue,
                identifier == "id3/USLT"
            {
                lyrics = try? await item.load(.stringValue)
            }
        }

        // 4. Fallback: Try Spotlight Metadata (MDItem) if AVAsset failed
        // This handles cases where file has atypical tags or is only recognized by system indexers
        if title == nil || artist == nil {
            if let mdItem = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) {
                // Title
                if title == nil {
                    if let mdTitle = MDItemCopyAttribute(mdItem, kMDItemTitle) as? String {
                        title = mdTitle
                    }
                }

                // Artist (Authors)
                if artist == nil {
                    if let mdAuthors = MDItemCopyAttribute(mdItem, kMDItemAuthors) as? [String],
                        let firstAuthor = mdAuthors.first
                    {
                        artist = firstAuthor
                    }
                }

                // Album
                if album == nil {
                    if let mdAlbum = MDItemCopyAttribute(mdItem, kMDItemAlbum) as? String {
                        album = mdAlbum
                    }
                }
            }
        }

        // Apply defaults
        let finalTitle = title ?? url.deletingPathExtension().lastPathComponent
        let finalArtist = artist ?? NSLocalizedString("library.unknown_artist", comment: "")
        let finalAlbum = album ?? NSLocalizedString("library.unknown_album", comment: "")

        return (finalTitle, finalArtist, finalAlbum, duration, lyrics)
    }

    /// Extract artwork from audio file.
    nonisolated static func extractArtwork(from url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)

        // Collect all metadata items
        var allItems: [AVMetadataItem] = []
        if let common = try? await asset.load(.commonMetadata) {
            allItems.append(contentsOf: common)
        }
        if let full = try? await asset.load(.metadata) {
            allItems.append(contentsOf: full)
        }

        for item in allItems {
            if let key = item.commonKey?.rawValue, key == "artwork" {
                if let data = try? await item.load(.dataValue) {
                    return data
                }
            }
        }

        return nil
    }

    /// Recursively find audio files in a directory.
    /// Made nonisolated static to allow calling from background tasks.
    nonisolated private static func findAudioFiles(in directory: URL) -> [URL] {
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
            if Self.isAudioFile(fileURL) {
                audioFiles.append(fileURL)
            }
        }

        return audioFiles
    }

    /// Check if a URL is a supported audio file.
    /// Made nonisolated static to allow calling from background tasks.
    nonisolated private static func isAudioFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return Self.supportedExtensions.contains(ext)
    }

    /// Check if a URL is an NCM file.
    /// Made nonisolated static to allow calling from background tasks.
    nonisolated private static func isNCMFile(_ url: URL) -> Bool {
        return url.pathExtension.lowercased() == "ncm"
    }

    /// Convert NCM files and return conversion results with metadata.
    /// Runs nonisolated to avoid blocking MainActor during the conversion process.
    nonisolated private func convertNCMFiles(_ ncmFiles: [URL]) async -> [NCMConversionResult] {
        await withCheckedContinuation { continuation in
            // Use a class wrapper for thread-safe mutable state
            final class ResumptionState: @unchecked Sendable {
                var hasResumed = false
            }
            let state = ResumptionState()
            
            // Present dialog on MainActor but keep this method nonisolated
            Task { @MainActor in
                NCMImportProgressDialogPresenter.present(ncmFiles: ncmFiles) { results in
                    guard !state.hasResumed else { return }
                    state.hasResumed = true
                    
                    continuation.resume(returning: results ?? [])
                }
            }
        }
    }

    private func fetchCoverForImport(artist: String, album: String) async -> Data? {
        do {
            let coverData = try await coverDownloadService.downloadCover(
                artist: artist,
                album: album,
                size: 1200
            )
            print("✅ Cover fetch success via sacad: \(artist) - \(album)")
            return coverData
        } catch {
            print("⚠️ sacad cover fetch failed, trying NetEase fallback: \(error)")
        }

        do {
            let coverData = try await netEaseCoverService.searchAndDownloadCover(
                artist: artist,
                album: album
            )
            print("✅ Cover fetch success via NetEase fallback: \(artist) - \(album)")
            return coverData
        } catch {
            print("❌ Cover fetch failed after fallback (sacad -> NetEase): \(error)")
            return nil
        }
    }

    @MainActor
    private func presentDuplicateSelectionDialog(_ duplicateRows: [DuplicatePairRow])
        -> [DuplicatePairRow]?
    {
        return DuplicateImportDialogPresenter.present(
            rows: duplicateRows
        )
    }
}

// MARK: - Presenter & UI Components

final class DuplicateImportDialogPresenter: NSObject, NSWindowDelegate {
    private var result: [DuplicatePairRow]?
    private let panel: NSPanel

    init(panel: NSPanel) {
        self.panel = panel
        super.init()
    }

    @MainActor
    static func present(
        rows: [DuplicatePairRow]
    ) -> [DuplicatePairRow]? {
        // Height Calculation Strategy (Compact Mode):
        // Header: 20 (top) + 24 (title) + 4 (gap) + 14 (subtitle) + 8 (gap) + 16 (columns) + 12 (bottom) ≈ 98
        // Footer: 20 (top) + 28 (button) + 20 (bottom) ≈ 68
        // Row: 56 (height) + 4 (spacing) = 60

        // Compact Layout Constants
        let headerHeight: CGFloat = 98
        let footerHeight: CGFloat = 68
        let rowHeight: CGFloat = 48
        let listVerticalPadding: CGFloat = 16
        let maxItemsWithoutScroll = 9

        let visibleRows = CGFloat(min(rows.count, maxItemsWithoutScroll))
        let contentHeight = (visibleRows * rowHeight) + (listVerticalPadding * 2)
        let idealHeight = headerHeight + contentHeight + footerHeight
        
        let clampedHeight = idealHeight

        // Width: 760 (Balanced)
        let windowSize = NSSize(width: 760, height: clampedHeight)

        // Create Panel
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.title = ""
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false

        // Visual Effect (Neutral Liquid Glass)
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .popover
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.frame = NSRect(origin: .zero, size: windowSize)
        visualEffect.autoresizingMask = [.width, .height]
        panel.contentView = visualEffect

        let presenter = DuplicateImportDialogPresenter(panel: panel)
        panel.delegate = presenter

        let viewModel = DuplicateImportDialogViewModel(rows: rows)

        let customAction: (Bool) -> Void = { shouldImport in
            if shouldImport {
                presenter.result = viewModel.selectedRows
            } else {
                presenter.result = nil
            }
            NSApp.stopModal()
            panel.close()
        }

        let rootView = DuplicateImportDialogView(viewModel: viewModel, onFinish: customAction)
            .environmentObject(ThemeStore.shared)
            .frame(width: 760, height: clampedHeight)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: windowSize)
        hostingView.autoresizingMask = [.width, .height]

        visualEffect.addSubview(hostingView)
        panel.center()

        NSApp.runModal(for: panel)
        panel.orderOut(nil)

        // Directly return the result.
        // If result is nil, it means user Cancelled.
        // If result is [], it means user Confirmed but selected nothing (which is valid).
        return presenter.result
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
    }
}

@MainActor
final class DuplicateImportDialogViewModel: ObservableObject {
    let rows: [DuplicatePairRow]

    @Published var selectedIDs: Set<String>

    init(rows: [DuplicatePairRow]) {
        self.rows = rows
        self.selectedIDs = []
    }

    func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    var buttonTitle: String {
        if selectedIDs.isEmpty {
            return "忽略重复项导入"
        } else {
            return "导入所选重复项"
        }
    }

    var selectedRows: [DuplicatePairRow] {
        rows.filter { selectedIDs.contains($0.id) }
    }
}

struct DuplicateImportDialogView: View {
    @ObservedObject var viewModel: DuplicateImportDialogViewModel
    let onFinish: (Bool) -> Void
    @EnvironmentObject var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    private let maxItemsWithoutScroll = 9

    // LAYOUT CONSTANTS (Width: 760)
    // Padding: 20 -> Header Top moved up slightly
    // Left: 306 (~43%) | Spacing: 12 | Right: 394 (~55%)
    private let leftColumnWidth: CGFloat = 306
    private let rightColumnWidth: CGFloat = 394
    private let horizontalPadding: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            headerView
            listContent
            footerView
        }
        .task {
            print("🎬 Duplicate Dialog Appeared. Total rows: \(viewModel.rows.count)")
        }
    }
    
    private var listContent: some View {
        let rowsView = VStack(spacing: 0) {
            ForEach(viewModel.rows) { row in
                DuplicateRowView(
                    row: row,
                    isSelected: viewModel.selectedIDs.contains(row.id),
                    leftWidth: leftColumnWidth,
                    rightWidth: rightColumnWidth,
                    themeAccent: themeStore.accentColor
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        viewModel.toggleSelection(row.id)
                    }
                }
            }
        }
        
        let paddedView = rowsView
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 16)
        
        if viewModel.rows.count > maxItemsWithoutScroll {
            return AnyView(
                ScrollView {
                    paddedView
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        } else {
            return AnyView(
                paddedView
                    .frame(maxWidth: .infinity)
            )
        }
    }
    
    private var headerView: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("发现重复歌曲")
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                Text("点击右侧条目选择是否重复导入")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            HStack(spacing: 12) {
                Text("资料库中已存在")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: leftColumnWidth, alignment: .leading)
                
                Divider()
                    .frame(height: 12)
                    .overlay(Color.secondary.opacity(0.3))
                
                Text("本次待导入")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: rightColumnWidth, alignment: .leading)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
        .zIndex(1)
    }
    
    private var footerView: some View {
        HStack {
            Button("取消") {
                onFinish(false)
            }
            .keyboardShortcut(.cancelAction)
            .controlSize(.large)
            
            Spacer()
            
            Button(viewModel.buttonTitle) {
                onFinish(true)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(themeStore.accentColor)
        }
        .padding(.vertical, 20)
        .padding(.horizontal, horizontalPadding)
        .background(.thinMaterial)
        .overlay(alignment: .top) {
            Divider().opacity(0.5)
        }
    }
}

struct DuplicateRowView: View {
    let row: DuplicatePairRow
    let isSelected: Bool
    let leftWidth: CGFloat
    let rightWidth: CGFloat
    let themeAccent: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {  // Tighter horizontal spacing
            // Left Column (Existing)
            columnView(
                title: row.existing?.title ?? "未知标题",
                artist: row.existing?.artist ?? "未知艺术家",
                artworkData: row.existing?.artworkData,
                badge: "库中",
                isIncoming: false,
                isSelected: false,
                width: leftWidth
            )

            Divider()
                .frame(height: 32)  // Shorter divider for compact row
                .overlay(Color.secondary.opacity(0.1))

            // Right Column (Incoming)
            columnView(
                title: row.incoming.title,
                artist: row.incoming.artist,
                artworkData: nil,
                badge: isSelected ? "导入" : "跳过",
                isIncoming: true,
                isSelected: isSelected,
                width: rightWidth
            )
        }
        .frame(height: 48)  // Ultra Compact Row Height
    }

    private func columnView(
        title: String,
        artist: String,
        artworkData: Data?,
        badge: String,
        isIncoming: Bool,
        isSelected: Bool,
        width: CGFloat
    ) -> some View {
        HStack(spacing: 12) {
            // Artwork
            if isIncoming {
                // Simplified static icon for incoming files (Stable & Fast)
                Image(systemName: "music.note")
                    .font(.system(size: 18))
                    .foregroundStyle(themeAccent)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(themeAccent.opacity(0.08))
                    )
            } else if let data = artworkData, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 36, height: 36)  // Compact artwork
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))  // Larger radius
                    .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .frame(width: 36, height: 36)
                    .background(Color.secondary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            // Metadata
            VStack(alignment: .leading, spacing: 1) {  // Tighter vertical text spacing
                HStack {
                    Text(title)
                        .font(.body)  // Default size covers 13pt
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if isSelected || !isIncoming {
                        Text(badge)
                            .font(.system(size: 9, weight: .semibold))  // Smaller badge text
                            .foregroundStyle(isSelected ? themeAccent : .secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule()
                                    .fill(
                                        isSelected
                                            ? themeAccent.opacity(0.15)
                                            : Color.primary.opacity(0.05))
                            )
                    }
                }

                Text(artist)
                    .font(.caption)  // Smaller artist text
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)  // Slightly reduced internal padding
        .padding(.vertical, 6)  // Tighter vertical padding
        .frame(width: width, alignment: .leading)
        .background {
            // Background Logic
            if isIncoming {
                if isSelected {
                    // Stronger highlight for selection
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(themeAccent.opacity(colorScheme == .dark ? 0.22 : 0.12))
                } else {
                    // Subtle background for incoming candidates
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                }
            } else {
                // Simple transparent for existing, or very subtle
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.01))
            }
        }
    }
}
