import Foundation
import Observation

@MainActor
@Observable
final class LibrarySetupViewModel {
    enum Step: Equatable {
        case storage
        case music
        case location
    }

    enum Presentation: Equatable {
        case none
        case setup(MusicLibraryMode)
        case chooser(MusicLibraryMode)
        case reconnectRequired(libraryID: UUID, mode: MusicLibraryMode)
        case sourceReconnect(libraryID: UUID, sourceIDs: [UUID])
    }

    enum Operation: Equatable {
        case idle
        case working
        case failed(String)
    }

    private(set) var presentation: Presentation = .none
    private(set) var operation: Operation = .idle
    var step: Step = .storage
    var mode: MusicLibraryMode
    var displayName = "音乐资料库"
    /// Explicitly chosen storage parent. Nil means "use the default directory"
    /// derived from the selected music sources (see `defaultStorageParentURL`).
    var storageParentURL: URL?
    private(set) var existingLibraryContext: LibraryContext?
    private(set) var existingRequestedMode: MusicLibraryMode?
    private(set) var createdLibraryAwaitingImport: LibraryContext?
    var selectedMusicURLs: [URL] = [] {
        didSet {
            rebuildInitialImportSelection()
        }
    }
    var wantsPlaylistCreation = false
    private(set) var playlistSourceEntries: [LibraryImportSourceEntry] = []
    private(set) var initialImportSelection: LibraryInitialImportSelection?

    /// Default storage parent derived from the selected music sources:
    /// the first selected folder, or the parent directory of the first
    /// selected song file when no folder was selected, or the standard music
    /// directory when nothing was selected at all.
    var defaultStorageParentURL: URL {
        if let firstDirectory = selectedMusicURLs.first(where: { Self.urlIsDirectory($0) }) {
            return firstDirectory.standardizedFileURL
        }
        if let firstFile = selectedMusicURLs.first {
            return firstFile.deletingLastPathComponent().standardizedFileURL
        }
        let base = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        return (base ?? URL(fileURLWithPath: NSHomeDirectory())).standardizedFileURL
    }

    /// The storage parent that creation will use.
    var effectiveStorageParentURL: URL {
        (storageParentURL ?? defaultStorageParentURL).standardizedFileURL
    }

    private static func urlIsDirectory(_ url: URL) -> Bool {
        if url.hasDirectoryPath { return true }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    func addMusicURLs(_ urls: [URL]) {
        var existing = Set(selectedMusicURLs.map { $0.standardizedFileURL.path })
        var appended = selectedMusicURLs
        for url in urls {
            let key = url.standardizedFileURL.path
            guard existing.insert(key).inserted else { continue }
            appended.append(url)
        }
        wantsPlaylistCreation = false
        playlistSourceEntries = []
        selectedMusicURLs = appended
    }

    func removeMusicURL(_ url: URL) {
        let key = url.standardizedFileURL.path
        wantsPlaylistCreation = false
        playlistSourceEntries = []
        selectedMusicURLs = selectedMusicURLs.filter { $0.standardizedFileURL.path != key }
    }

    func setPlaylistSourceEntries(_ entries: [LibraryImportSourceEntry]) {
        playlistSourceEntries = entries
        wantsPlaylistCreation = !entries.isEmpty
        rebuildInitialImportSelection()
    }

    func clearPlaylistSourceEntries() {
        playlistSourceEntries = []
        wantsPlaylistCreation = false
        rebuildInitialImportSelection()
    }

    init(mode: MusicLibraryMode = .managed) {
        self.mode = mode
    }

    func present(_ presentation: Presentation) {
        self.presentation = presentation
        operation = .idle
        if case .setup(let mode) = presentation {
            self.mode = mode
            step = .storage
            displayName = "音乐资料库"
            existingLibraryContext = nil
            existingRequestedMode = nil
            createdLibraryAwaitingImport = nil
            wantsPlaylistCreation = false
            playlistSourceEntries = []
            selectedMusicURLs = []
            storageParentURL = nil
        }
    }

    func dismiss() {
        guard operation != .working else { return }
        presentation = .none
        operation = .idle
        selectedMusicURLs = []
        wantsPlaylistCreation = false
        playlistSourceEntries = []
        storageParentURL = nil
    }

    func routeModeSelection(
        _ requestedMode: MusicLibraryMode,
        activeMode: MusicLibraryMode?,
        registry: MusicLibraryRegistry
    ) -> UUID? {
        guard requestedMode != activeMode else { return nil }
        let libraries = registry.libraries.filter { $0.modeProjection == requestedMode }
        guard !libraries.isEmpty else {
            present(.setup(requestedMode))
            return nil
        }
        if let recentID = registry.recentLibraryID(for: requestedMode),
           libraries.contains(where: { $0.id == recentID }) {
            return recentID
        }
        present(.chooser(requestedMode))
        return nil
    }

    func beginOperation() {
        existingLibraryContext = nil
        existingRequestedMode = nil
        operation = .working
    }
    func finishOperation() { operation = .idle }
    func fail(_ message: String) { operation = .failed(message) }
    func failInitialImport(in context: LibraryContext, message: String) {
        createdLibraryAwaitingImport = context
        operation = .failed(message)
    }
    func showExistingLibrary(_ context: LibraryContext, requestedMode: MusicLibraryMode) {
        existingLibraryContext = context
        existingRequestedMode = requestedMode
        operation = .idle
    }
    func returnFromExistingLibrary() {
        existingLibraryContext = nil
        existingRequestedMode = nil
        operation = .idle
    }
    func completeAndDismiss() {
        operation = .idle
        presentation = .none
        createdLibraryAwaitingImport = nil
        storageParentURL = nil
        wantsPlaylistCreation = false
        playlistSourceEntries = []
        initialImportSelection?.release()
        initialImportSelection = nil
    }

    private func rebuildInitialImportSelection() {
        initialImportSelection?.release()
        initialImportSelection = selectedMusicURLs.isEmpty
            ? nil
            : LibraryInitialImportSelection(
                urls: selectedMusicURLs,
                playlistSourceEntries: playlistSourceEntries
            )
    }
}
