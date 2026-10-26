import Foundation

/// Internal Swift fixture support. JSON v1 is never decoded or installed.
extension SkinSceneDocument {
    var v2Document: SkinSceneV2Document { .init(root: root.v2Node) }
}

private extension SkinSceneNode {
    var v2Node: SkinParameterValue {
        var fields: [String: SkinParameterValue] = ["id": .text(id)]
        switch content {
        case .row(let children, let spacing), .column(let children, let spacing):
            if case .row = content { fields["type"] = .text("row") } else { fields["type"] = .text("column") }
            fields["children"] = .array(children.map(\.v2Node)); fields["spacing"] = .number(spacing)
        case .overlay(let children): fields["type"] = .text("layer"); fields["children"] = .array(children.map(\.v2Node))
        case .adaptive(let width, let height, let wide, let compact):
            fields["type"] = .text("switch")
            var first = wide.v2Node.objectValue ?? [:]
            first["when"] = .text("=viewport.width >= \(width) && viewport.height >= \(height)")
            fields["cases"] = .array([.object(first)]); fields["default"] = compact.v2Node
        case .component(let type, let configuration):
            fields["type"] = .text("component")
            fields["component"] = .text(SkinComponentContract.aliases.first(where: { $0.value == type })?.key ?? type)
            var props = configuration.values
            for (key, binding) in configuration.bindings { props[key] = .text("=params.\(binding)") }
            fields["props"] = .object(props)
        case .spacer: fields["type"] = .text("spacer")
        }
        var frame: [String: SkinParameterValue] = ["padding": .number(layout.padding)]
        if let width = layout.width { frame["width"] = .number(width) }
        if let height = layout.height { frame["height"] = .number(height) }
        if layout.fillsWidth && layout.fillsHeight { frame["fill"] = .boolean(true) }
        fields["frame"] = .object(frame)
        fields["opacity"] = .number(layout.opacity); fields["hitTesting"] = .boolean(layout.allowsHitTesting)
        fields["offsetX"] = .number(layout.offsetX); fields["offsetY"] = .number(layout.offsetY)
        fields["rotation"] = .number(layout.rotationDegrees)
        return .object(fields)
    }
}
