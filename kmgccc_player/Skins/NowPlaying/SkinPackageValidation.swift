import Foundation

extension SkinPackageManifest {
    func validateDefinition() throws {
        guard !descriptor.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !descriptor.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !descriptor.surfaces.isEmpty else {
            throw SkinPackageError.invalidManifest("需要 ID、名称和支持的显示模式")
        }
        guard scene != nil || nativePreset != nil else {
            throw SkinPackageError.invalidManifest("需要 scene 或 nativePreset")
        }
        guard Set(parameters.map(\.id)).count == parameters.count else {
            throw SkinPackageError.invalidManifest("参数 ID 重复")
        }
        for parameter in parameters { try parameter.validateDefinition() }
        try scene?.root.validateNode()
    }
}

extension SkinParameterDefinition {
    func validateDefinition() throws {
        guard !id.isEmpty else { throw SkinPackageError.invalidManifest("参数 ID 为空") }
        switch (control, defaultValue) {
        case (.toggle, .boolean): break
        case (.range(let minimum, let maximum, let step), .number(let value)):
            guard minimum.isFinite, maximum.isFinite, step.isFinite, value.isFinite,
                  minimum < maximum, step > 0, (minimum...maximum).contains(value) else {
                throw SkinPackageError.invalidManifest("参数 \(id) 的范围或默认值无效")
            }
        case (.choice(let choices), .text(let value)):
            guard !choices.isEmpty, Set(choices.map(\.id)).count == choices.count,
                  choices.contains(where: { $0.id == value }) else {
                throw SkinPackageError.invalidManifest("参数 \(id) 的选项或默认值无效")
            }
        default: throw SkinPackageError.invalidManifest("参数 \(id) 的默认值类型不匹配")
        }
    }

    func resolvedValue(_ saved: SkinParameterValue?) -> SkinParameterValue {
        guard let saved else { return defaultValue }
        switch (control, saved) {
        case (.toggle, .boolean): return saved
        case (.range(let minimum, let maximum, _), .number(let value)) where value.isFinite:
            return .number(min(maximum, max(minimum, value)))
        case (.choice(let choices), .text(let value)) where choices.contains(where: { $0.id == value }):
            return saved
        default: return defaultValue
        }
    }
}

private extension SkinSceneNode {
    func validateNode() throws {
        switch content {
        case .row(let children, _), .column(let children, _), .overlay(let children):
            guard Set(children.map(\.id)).count == children.count else {
                throw SkinPackageError.invalidManifest("节点 \(id) 的子节点 ID 重复")
            }
            for child in children { try child.validateNode() }
        case .adaptive(_, _, let wide, let compact):
            try wide.validateNode()
            try compact.validateNode()
        case .component, .spacer: break
        }
    }
}
