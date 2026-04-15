//
//  FileImportService.swift
//  myPlayer2
//

import Foundation

@MainActor
final class FileImportService: FileImportServiceProtocol {
    private let repository: LibraryRepositoryProtocol
    private let libraryService: LocalLibraryService
    private let importEnrichmentService: ImportEnrichmentService

    init(
        repository: LibraryRepositoryProtocol,
        libraryService: LocalLibraryService? = nil,
        importEnrichmentService: ImportEnrichmentService
    ) {
        self.repository = repository
        self.libraryService = libraryService ?? LocalLibraryService.shared
        self.importEnrichmentService = importEnrichmentService
        Log.debug("FileImportService initialized", category: .import)
    }

    func pickImportURLs(triggeredAt date: Date) async -> [URL]? {
        await ImportPipeline.pickURLs(triggeredAt: date)
    }

    @discardableResult
    func importSelectedURLs(_ urls: [URL], to playlist: Playlist) async -> Int {
        await ImportPipeline.run(
            urls: urls,
            to: playlist,
            repository: repository,
            libraryService: libraryService,
            importEnrichmentService: importEnrichmentService
        )
    }
}
