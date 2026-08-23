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
    /// Explicitly chosen storage parent. Nil means "use the standard default
    /// directory" (see `defaultStorageParentURL`).
    var storageParentURL: URL?
    var isStorageLocationExplicitlyChosen: Bool { storageParentURL != nil }
    private(set) var existingLibraryContext: LibraryContext?
    private(set) var existingRequestedMode: MusicLibraryMode?
    private(set) var createdLibraryAwaitingImport: LibraryContext?
    var selectedMusicURLs: [URL] = [] {
        didSet {
            rebuildInitialImportSelection()
        }
    }
    private(set) var playlistSourceEntries: [LibraryImportSourceEntry] = []
    private(set) var initialImportSelection: LibraryInitialImportSelection?

    /// Default storage parent for a newly created library.
    ///
    /// The storage location is independent from the selected source folders.
    /// Falling back to the first source would put the library inside a user's
    /// music folder and, worse, make the result depend on selection order.
    var defaultStorageParentURL: URL {
        LibraryLocationStore.defaultLibraryRootURL
            .deletingLastPathComponent()
            .standardizedFileURL
    }

    /// The storage parent that creation will use.
    var effectiveStorageParentURL: URL {
        (storageParentURL ?? defaultStorageParentURL).standardizedFileURL
    }

    func addMusicURLs(_ urls: [URL]) {
        var existing = Set(selectedMusicURLs.map { $0.standardizedFileURL.path })
        var appended = selectedMusicURLs
        for url in urls {
            let key = url.standardizedFileURL.path
            guard existing.insert(key).inserted else { continue }
            appended.append(url)
        }
        playlistSourceEntries = []
        selectedMusicURLs = appended
    }

    func removeMusicURL(_ url: URL) {
        let key = url.standardizedFileURL.path
        playlistSourceEntries = []
        selectedMusicURLs = selectedMusicURLs.filter { $0.standardizedFileURL.path != key }
    }

    func setPlaylistSourceEntries(_ entries: [LibraryImportSourceEntry]) {
        playlistSourceEntries = entries
        rebuildInitialImportSelection()
    }

    func clearPlaylistSourceEntries() {
        playlistSourceEntries = []
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
