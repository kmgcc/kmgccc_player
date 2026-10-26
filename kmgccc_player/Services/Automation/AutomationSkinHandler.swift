import Foundation
import PlayerAutomationProtocol

@MainActor
struct AutomationSkinHandler {
    let appSession: AppSessionHost?
    func handle(_ request: AutomationRequest) -> AutomationResponse {
        guard let catalog = appSession?.skinManager?.catalog else {
            return .failure(for: request, error: .init(code: .serverUnavailable, message: "Skin service unavailable"))
        }
        do {
            let parameters = try AutomationParameters(request)
            switch request.method {
            case AutomationMethod.skinCapabilities:
                return .success(for: request, result: .object([
                    "formatVersion": .number(2), "hostAPIVersion": .number(2),
                    "capabilities": strings(SkinHostCapabilities.all), "nodes": strings(SkinSceneCompiler.nodeTypes),
                    "components": strings(SkinComponentContract.ids), "actions": strings(SkinSceneCompiler.actionNames),
                    "fields": strings(Set(SkinDataSchema.fields.keys)), "functions": strings(Set(SkinFunctions.table.keys))
                ]))
            case AutomationMethod.skinCheck:
                let path = try parameters.string("directory", required: true)!
                guard path.hasPrefix("/") else { throw AutomationParameterError.invalidValue("directory") }
                let url = URL(fileURLWithPath: path, isDirectory: true)
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let package = try catalog.packages.validateDirectory(url)
                return .success(for: request, result: .object([
                    "valid": .boolean(true), "skinID": .string(package.id),
                    "programs": .object(package.programs.mapValues { .object([
                        "nodeCount": .number(Double($0.nodeCount)), "domains": strings(Set($0.domains.map(\.rawValue)))
                    ]) })
                ]))
            case AutomationMethod.skinReload:
                let id = try parameters.string("skinID", required: true)!
                guard catalog.registeredSkin(for: id) != nil else { throw AutomationParameterError.invalidValue("skinID") }
                try catalog.reload(id)
                return .success(for: request, result: .object(["skinID": .string(id), "revision": .number(Double(catalog.revision(for: id)))]))
            case AutomationMethod.skinRuntime:
                return .success(for: request, result: .array(SkinSceneRuntimeMetrics.shared.records.map { record in
                    .object(["id": .string(record.key), "nodes": .number(Double(record.value.nodes)),
                             "frameEvaluations": .number(Double(record.value.frames)), "audioReaders": .number(Double(record.value.audioReaders))])
                }))
            default: throw AutomationParameterError.invalidValue("method")
            }
        } catch { return .failure(for: request, error: .init(code: .invalidRequest, message: error.localizedDescription)) }
    }
    private func strings(_ values: Set<String>) -> AutomationJSONValue { .array(values.sorted().map(AutomationJSONValue.string)) }
}
