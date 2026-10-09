import Foundation

nonisolated struct DSPScriptDraftDocument: Codable, Equatable, Sendable, Identifiable {
    nonisolated static let schemaVersion = 1

    var schemaVersion: Int
    var nodeID: UUID
    var languageVersion: Int
    var source: String
    var values: [String: Double]
    var updatedAt: Date
    var revisionString: String

    nonisolated var id: UUID { nodeID }

    nonisolated init(
        schemaVersion: Int = Self.schemaVersion,
        nodeID: UUID,
        languageVersion: Int,
        source: String,
        values: [String: Double],
        updatedAt: Date = Date(),
        revisionString: String = UUID().uuidString
    ) {
        self.schemaVersion = schemaVersion
        self.nodeID = nodeID
        self.languageVersion = languageVersion
        self.source = source
        self.values = values
        self.updatedAt = updatedAt
        self.revisionString = revisionString
    }
}

nonisolated enum DSPScriptDraftStoreError: Error, LocalizedError, Equatable, Sendable {
    case revisionConflict
    case corruptExistingFile
    case unsupportedSchema(Int)
    case sourceTooLarge
    case invalidValues
    case fileOperation(String)

    nonisolated var errorDescription: String? {
        switch self {
        case .revisionConflict:
            "脚本草稿已更新，请重新载入后再保存。"
        case .corruptExistingFile:
            "脚本草稿无法读取，原文件已保留。"
        case .unsupportedSchema(let version):
            "脚本草稿版本 \(version) 暂不支持。"
        case .sourceTooLarge:
            "脚本源码不能超过 64 KiB。"
        case .invalidValues:
            "脚本参数名或数值无效。"
        case .fileOperation(let message):
            message
        }
    }
}

/// Draft I/O stays off MainActor. Each node has its own atomically replaced file
/// so independent editors do not rewrite a shared document.
actor DSPScriptDraftStore {
    nonisolated static var defaultRootURL: URL {
        DSPPresetStore.defaultRootURL.appendingPathComponent("ScriptDrafts", isDirectory: true)
    }

    private let rootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL = DSPScriptDraftStore.defaultRootURL) {
        self.rootURL = rootURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func getDraft(nodeID: UUID) throws -> DSPScriptDraftDocument? {
        let url = draftURL(nodeID: nodeID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let document = try decoder.decode(DSPScriptDraftDocument.self, from: Data(contentsOf: url))
            guard document.schemaVersion == DSPScriptDraftDocument.schemaVersion else {
                throw DSPScriptDraftStoreError.unsupportedSchema(document.schemaVersion)
            }
            guard document.nodeID == nodeID else { throw DSPScriptDraftStoreError.corruptExistingFile }
            return document
        } catch let error as DSPScriptDraftStoreError {
            throw error
        } catch {
            throw DSPScriptDraftStoreError.corruptExistingFile
        }
    }

    func updateDraft(
        nodeID: UUID,
        languageVersion: Int,
        source: String,
        values: [String: Double],
        expectedRevision: String? = nil
    ) throws -> DSPScriptDraftDocument {
        guard source.utf8.count <= DSPScriptCompiler.maximumSourceBytes else {
            throw DSPScriptDraftStoreError.sourceTooLarge
        }
        guard values.count <= DSPScriptCompiler.maximumParameterCount,
              values.allSatisfy({
            !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.value.isFinite
        }) else {
            throw DSPScriptDraftStoreError.invalidValues
        }

        let existing = try getDraft(nodeID: nodeID)
        if let expectedRevision, existing?.revisionString != expectedRevision {
            throw DSPScriptDraftStoreError.revisionConflict
        }

        let document = DSPScriptDraftDocument(
            nodeID: nodeID,
            languageVersion: languageVersion,
            source: source,
            values: values
        )
        let data: Data
        do {
            data = try encoder.encode(document)
        } catch {
            throw DSPScriptDraftStoreError.fileOperation(error.localizedDescription)
        }

        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let url = draftURL(nodeID: nodeID)
            if let oldData = try? Data(contentsOf: url) {
                try oldData.write(to: backupURL(nodeID: nodeID), options: .atomic)
            }
            try data.write(to: url, options: .atomic)
            return document
        } catch {
            throw DSPScriptDraftStoreError.fileOperation(error.localizedDescription)
        }
    }

    private func draftURL(nodeID: UUID) -> URL {
        rootURL.appendingPathComponent("\(nodeID.uuidString).json")
    }

    private func backupURL(nodeID: UUID) -> URL {
        rootURL.appendingPathComponent("\(nodeID.uuidString).json.bak")
    }
}
