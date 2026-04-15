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
    private let enrichmentModeResolver: @MainActor () -> ImportEnrichmentMode
    private let ttmlConverter: any EmbeddedLyricsTTMLConverting

    init(
        repository: LibraryRepositoryProtocol,
        libraryService: LocalLibraryService? = nil,
        importEnrichmentService: ImportEnrichmentService,
        enrichmentModeResolver: @escaping @MainActor () -> ImportEnrichmentMode = {
            AppSettings.shared.deferImportEnrichment ? .deferred : .immediate
        },
        ttmlConverter: any EmbeddedLyricsTTMLConverting = TTMLConverter.shared
    ) {
        self.repository = repository
        self.libraryService = libraryService ?? LocalLibraryService.shared
        self.importEnrichmentService = importEnrichmentService
        self.enrichmentModeResolver = enrichmentModeResolver
        self.ttmlConverter = ttmlConverter
        Log.debug("FileImportService initialized", category: .import)
    }

    func pickImportURLs(triggeredAt date: Date) async -> [URL]? {
        await ImportPipeline.pickURLs(triggeredAt: date)
    }

    @discardableResult
    func importSelectedURLs(_ urls: [URL], to playlist: Playlist?) async -> Int {
        await ImportPipeline.run(
            urls: urls,
            to: playlist,
            repository: repository,
            libraryService: libraryService,
            importEnrichmentService: importEnrichmentService,
            enrichmentMode: enrichmentModeResolver(),
            ttmlConverter: ttmlConverter
        )
    }
}
