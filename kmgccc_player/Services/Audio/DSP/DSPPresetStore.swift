//
//  DSPPresetStore.swift
//  myPlayer2
//
//  Serial, atomic persistence for DSP presets and the separate working draft.
//

import Foundation

nonisolated struct DSPWorkingDraftDocument: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var revisionString: String
    var selectedPresetID: UUID?
    var updatedAt: Date
    var configuration: AudioDSPConfiguration

    nonisolated init(
        schemaVersion: Int = 1,
        revisionString: String,
        selectedPresetID: UUID?,
        updatedAt: Date = Date(),
        configuration: AudioDSPConfiguration
    ) {
        self.schemaVersion = schemaVersion
        self.revisionString = revisionString
        self.selectedPresetID = selectedPresetID
        self.updatedAt = updatedAt
        self.configuration = configuration
    }
}

nonisolated struct DSPPresetStoreLoadResult: Sendable {
    var presets: [DSPPresetDocument]
    var diagnostics: [DSPDiagnostic]
    var workingDraft: DSPWorkingDraftDocument?
}

nonisolated enum DSPPresetStoreError: Error, LocalizedError, Equatable, Sendable {
    case invalidName
    case immutableBuiltIn
    case notFound
    case revisionConflict
    case corruptExistingFile
    case unsupportedSchema(Int)
    case incompatibleImport
    case fileOperation(String)

    nonisolated var errorDescription: String? {
        switch self {
        case .invalidName:
            "预设名称不能为空。"
        case .immutableBuiltIn:
            "内置预设不可修改。"
        case .notFound:
            "找不到该预设。"
        case .revisionConflict:
            "预设已在其他位置更新，请重新载入后再试。"
        case .corruptExistingFile:
            "预设文件无法读取，原文件已保留。"
        case .unsupportedSchema(let version):
            "预设版本 \(version) 暂不支持。"
        case .incompatibleImport:
            "预设包含当前无法启用的效果。"
        case .fileOperation(let message):
            message
        }
    }
}

actor DSPPresetStore {
    nonisolated static let shared = DSPPresetStore(rootURL: defaultRootURL)

    nonisolated static var defaultRootURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("kmgccc_player", isDirectory: true)
            .appendingPathComponent("AudioDSP", isDirectory: true)
    }

    private let rootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL) {
        self.rootURL = rootURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load() -> DSPPresetStoreLoadResult {
        do {
            try ensureDirectory()
            let urls = try FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            var presets: [DSPPresetDocument] = []
            var diagnostics: [DSPDiagnostic] = []
            var workingDraft: DSPWorkingDraftDocument?

            for url in urls where url.pathExtension == "json" {
                if url.lastPathComponent == Self.workingDraftFilename {
                    do {
                        let draft = try decoder.decode(DSPWorkingDraftDocument.self, from: Data(contentsOf: url))
                        guard draft.schemaVersion == 1 else {
                            throw DSPPresetStoreError.unsupportedSchema(draft.schemaVersion)
                        }
                        workingDraft = draft
                    } catch {
                        diagnostics.append(Self.corruptionDiagnostic(for: url, error: error))
                    }
                    continue
                }

                do {
                    let document = try decoder.decode(DSPPresetDocument.self, from: Data(contentsOf: url))
                    guard document.schemaVersion == DSPPresetDocument.schemaVersion else {
                        throw DSPPresetStoreError.unsupportedSchema(document.schemaVersion)
                    }
                    guard document.presetID != DSPPresetDocument.flatPresetID,
                          url.deletingPathExtension().lastPathComponent == document.presetID.uuidString
                    else {
                        throw DSPPresetStoreError.corruptExistingFile
                    }
                    presets.append(document)
                } catch {
                    diagnostics.append(Self.corruptionDiagnostic(for: url, error: error))
                }
            }

            presets.sort {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame
                    ? $0.presetID.uuidString < $1.presetID.uuidString
                    : order == .orderedAscending
            }
            return DSPPresetStoreLoadResult(
                presets: presets,
                diagnostics: diagnostics,
                workingDraft: workingDraft
            )
        } catch {
            return DSPPresetStoreLoadResult(
                presets: [],
                diagnostics: [DSPDiagnostic(
                    code: "dsp.presetStoreReadFailed",
                    message: error.localizedDescription,
                    retryable: true
                )],
                workingDraft: nil
            )
        }
    }

    func save(
        _ document: DSPPresetDocument,
        expectedRevision: String? = nil
    ) throws -> DSPPresetDocument {
        guard document.presetID != DSPPresetDocument.flatPresetID else {
            throw DSPPresetStoreError.immutableBuiltIn
        }
        let name = document.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw DSPPresetStoreError.invalidName }
        guard document.schemaVersion == DSPPresetDocument.schemaVersion else {
            throw DSPPresetStoreError.unsupportedSchema(document.schemaVersion)
        }
        try ensureDirectory()

        let destination = presetURL(for: document.presetID)
        let fileExists = FileManager.default.fileExists(atPath: destination.path)
        if fileExists {
            let existing = try readExistingPreset(at: destination)
            guard let expectedRevision,
                  existing.revisionString == expectedRevision
            else {
                throw DSPPresetStoreError.revisionConflict
            }
        } else if expectedRevision != nil {
            throw DSPPresetStoreError.revisionConflict
        }

        var saved = document
        saved.name = name
        saved.revisionString = UUID().uuidString
        try writeAtomically(try encoder.encode(saved), to: destination)
        return saved
    }

    func preset(id: UUID) throws -> DSPPresetDocument {
        guard id != DSPPresetDocument.flatPresetID else { return .flat }
        return try readExistingPreset(at: presetURL(for: id))
    }

    func delete(id: UUID, expectedRevision: String? = nil) throws {
        guard id != DSPPresetDocument.flatPresetID else {
            throw DSPPresetStoreError.immutableBuiltIn
        }
        let url = presetURL(for: id)
        let existing = try readExistingPreset(at: url)
        if let expectedRevision, existing.revisionString != expectedRevision {
            throw DSPPresetStoreError.revisionConflict
        }
        try preserveBackup(for: url)
        try FileManager.default.removeItem(at: url)
    }

    func saveWorkingDraft(_ draft: DSPWorkingDraftDocument) throws {
        try ensureDirectory()
        try writeAtomically(
            try encoder.encode(draft),
            to: rootURL.appendingPathComponent(Self.workingDraftFilename)
        )
    }

    func export(_ document: DSPPresetDocument) throws -> Data {
        try encoder.encode(document)
    }

    func importPreview(from data: Data) -> DSPPresetImportPreview? {
        guard let document = try? decoder.decode(DSPPresetDocument.self, from: data) else { return nil }
        let diagnostics: [DSPDiagnostic]
        if document.schemaVersion != DSPPresetDocument.schemaVersion {
            diagnostics = [DSPDiagnostic(
                code: "dsp.presetIncompatible",
                message: DSPPresetStoreError.unsupportedSchema(document.schemaVersion).localizedDescription,
                fieldPath: "schemaVersion"
            )]
        } else {
            diagnostics = []
        }
        return DSPPresetImportPreview(
            document: document,
            isCompatible: diagnostics.isEmpty,
            warnings: [],
            diagnostics: diagnostics
        )
    }

    func importPreset(_ document: DSPPresetDocument, name: String? = nil) throws -> DSPPresetDocument {
        guard document.schemaVersion == DSPPresetDocument.schemaVersion else {
            throw DSPPresetStoreError.unsupportedSchema(document.schemaVersion)
        }
        let imported = DSPPresetDocument(
            presetID: UUID(),
            name: name ?? document.name,
            configuration: document.configuration
        )
        return try save(imported)
    }

    private static let workingDraftFilename = "working-draft.json"

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
    }

    private func presetURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent("\(id.uuidString).json")
    }

    private func readExistingPreset(at url: URL) throws -> DSPPresetDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DSPPresetStoreError.notFound
        }
        do {
            let document = try decoder.decode(DSPPresetDocument.self, from: Data(contentsOf: url))
            guard document.schemaVersion == DSPPresetDocument.schemaVersion,
                  document.presetID != DSPPresetDocument.flatPresetID,
                  url.deletingPathExtension().lastPathComponent == document.presetID.uuidString
            else {
                throw DSPPresetStoreError.corruptExistingFile
            }
            return document
        } catch let error as DSPPresetStoreError {
            throw error
        } catch {
            throw DSPPresetStoreError.corruptExistingFile
        }
    }

    private func preserveBackup(for url: URL) throws {
        let backupURL = url.appendingPathExtension("bak")
        do {
            let existingData = try Data(contentsOf: url)
            try existingData.write(to: backupURL, options: .atomic)
        } catch {
            throw DSPPresetStoreError.fileOperation(error.localizedDescription)
        }
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        do {
            try ensureDirectory()
            if FileManager.default.fileExists(atPath: url.path) {
                try preserveBackup(for: url)
            }
            try data.write(to: url, options: .atomic)
        } catch let error as DSPPresetStoreError {
            throw error
        } catch {
            throw DSPPresetStoreError.fileOperation(error.localizedDescription)
        }
    }

    private static func corruptionDiagnostic(for url: URL, error: Error) -> DSPDiagnostic {
        DSPDiagnostic(
            code: "dsp.presetFileInvalid",
            message: "\(url.lastPathComponent)：\(error.localizedDescription)",
            fieldPath: url.lastPathComponent,
            retryable: false
        )
    }
}
