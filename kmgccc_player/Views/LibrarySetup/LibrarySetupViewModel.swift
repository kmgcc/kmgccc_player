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
    /// Explicitly chosen storage parent. Nil means the user has not selected a
    /// destination yet; `effectiveStorageParentURL` is only a picker browsing
    /// location and must never be passed to the creation service.
    var storageParentURL: URL?
    var isStorageLocationExplicitlyChosen: Bool { storageParentURL != nil }
    private(set) var existingLibraryContext: LibraryContext?
    private(set) var existingRequestedMode: MusicLibraryMode?
    var selectedMusicURLs: [URL] = [] {
        didSet {
            rebuildInitialImportSelection()
        }
    }
    private(set) var playlistSourceEntries: [LibraryImportSourceEntry] = []
    private(set) var initialImportSelection: LibraryInitialImportSelection?
    private var operationGeneration: UInt64 = 0
    private var operationCancellation: (() -> Void)?

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

    /// The initial browsing location for the storage picker. Creation still
    /// requires `storageParentURL` to be explicitly set by the user.
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

    init(mode: MusicLibraryMode = .referenced) {
        self.mode = mode
    }

    func present(_ presentation: Presentation) {
        operationGeneration &+= 1
        self.presentation = presentation
        operation = .idle
        if case .setup(let mode) = presentation {
            self.mode = mode
            step = .storage
            displayName = "音乐资料库"
            existingLibraryContext = nil
            existingRequestedMode = nil
            playlistSourceEntries = []
            selectedMusicURLs = []
            storageParentURL = nil
        }
    }

    func dismiss() {
        operationCancellation?()
        operationCancellation = nil
        operationGeneration &+= 1
        presentation = .none
        operation = .idle
        existingLibraryContext = nil
        existingRequestedMode = nil
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

    @discardableResult
    func beginOperation() -> UInt64 {
        operationCancellation = nil
        operationGeneration &+= 1
        existingLibraryContext = nil
        existingRequestedMode = nil
        operation = .working
        return operationGeneration
    }
    func isCurrentOperation(_ generation: UInt64) -> Bool {
        operationGeneration == generation
    }
    func setOperationCancellation(_ cancellation: @escaping () -> Void) {
        operationCancellation = cancellation
    }
    func finishOperation() {
        operationCancellation = nil
        operation = .idle
    }
    func fail(_ message: String) {
        operationCancellation = nil
        operation = .failed(message)
    }
    func showExistingLibrary(_ context: LibraryContext, requestedMode: MusicLibraryMode) {
        existingLibraryContext = context
        existingRequestedMode = requestedMode
        operation = .idle
    }
    func returnFromExistingLibrary() {
        operationCancellation = nil
        existingLibraryContext = nil
        existingRequestedMode = nil
        storageParentURL = nil
        operation = .idle
    }
    func completeAndDismiss() {
        operationCancellation = nil
        operationGeneration &+= 1
        operation = .idle
        presentation = .none
        existingLibraryContext = nil
        existingRequestedMode = nil
        selectedMusicURLs = []
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
