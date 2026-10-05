import Foundation

// The JSON vocabulary is independent of Swift's associated-value enum encoding.
extension SkinSceneNode {
    private enum CodingKeys: String, CodingKey {
        case id, type, component, values, bindings, children, spacing, minimumWidth, minimumHeight, wide, compact, layout
    }
    private enum Kind: String, Codable { case component, row, column, overlay, adaptive, spacer }

    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        id = try keys.decode(String.self, forKey: .id)
        layout = try keys.decodeIfPresent(SkinSceneLayout.self, forKey: .layout) ?? .init()
        switch try keys.decode(Kind.self, forKey: .type) {
        case .component:
            content = .component(
                type: try keys.decode(String.self, forKey: .component),
                configuration: .init(
                    bindings: try keys.decodeIfPresent([String: String].self, forKey: .bindings) ?? [:],
                    values: try keys.decodeIfPresent([String: SkinParameterValue].self, forKey: .values) ?? [:]
                )
            )
        case .row, .column:
            let children = try keys.decode([Self].self, forKey: .children)
            let spacing = try keys.decodeIfPresent(Double.self, forKey: .spacing) ?? 0
            content = try keys.decode(Kind.self, forKey: .type) == .row
                ? .row(children: children, spacing: spacing) : .column(children: children, spacing: spacing)
        case .overlay: content = .overlay(children: try keys.decode([Self].self, forKey: .children))
        case .adaptive:
            content = .adaptive(
                minimumWidth: try keys.decode(Double.self, forKey: .minimumWidth),
                minimumHeight: try keys.decodeIfPresent(Double.self, forKey: .minimumHeight) ?? 0,
                wide: try keys.decode(Self.self, forKey: .wide), compact: try keys.decode(Self.self, forKey: .compact)
            )
        case .spacer: content = .spacer
        }
    }

    func encode(to encoder: any Encoder) throws {
        var keys = encoder.container(keyedBy: CodingKeys.self)
        try keys.encode(id, forKey: .id)
        try keys.encode(layout, forKey: .layout)
        switch content {
        case .component(let type, let configuration):
            try keys.encode(Kind.component, forKey: .type)
            try keys.encode(type, forKey: .component)
            if !configuration.values.isEmpty { try keys.encode(configuration.values, forKey: .values) }
            if !configuration.bindings.isEmpty { try keys.encode(configuration.bindings, forKey: .bindings) }
        case .row(let children, let spacing):
            try keys.encode(Kind.row, forKey: .type)
            try keys.encode(children, forKey: .children)
            try keys.encode(spacing, forKey: .spacing)
        case .column(let children, let spacing):
            try keys.encode(Kind.column, forKey: .type)
            try keys.encode(children, forKey: .children)
            try keys.encode(spacing, forKey: .spacing)
        case .overlay(let children):
            try keys.encode(Kind.overlay, forKey: .type)
            try keys.encode(children, forKey: .children)
        case .adaptive(let width, let height, let wide, let compact):
            try keys.encode(Kind.adaptive, forKey: .type)
            try keys.encode(width, forKey: .minimumWidth)
            if height > 0 { try keys.encode(height, forKey: .minimumHeight) }
            try keys.encode(wide, forKey: .wide)
            try keys.encode(compact, forKey: .compact)
        case .spacer: try keys.encode(Kind.spacer, forKey: .type)
        }
    }
}

extension SkinSceneLayout {
    private enum CodingKeys: String, CodingKey {
        case width, height, minimumWidth, minimumHeight, maximumWidth, maximumHeight, aspectRatio, padding
        case fillsWidth, fillsHeight, zIndex, allowsHitTesting, alignment, offsetX, offsetY, rotationDegrees, opacity
    }

    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        width = try keys.decodeIfPresent(Double.self, forKey: .width)
        height = try keys.decodeIfPresent(Double.self, forKey: .height)
        minimumWidth = try keys.decodeIfPresent(Double.self, forKey: .minimumWidth)
        minimumHeight = try keys.decodeIfPresent(Double.self, forKey: .minimumHeight)
        maximumWidth = try keys.decodeIfPresent(Double.self, forKey: .maximumWidth)
        maximumHeight = try keys.decodeIfPresent(Double.self, forKey: .maximumHeight)
        aspectRatio = try keys.decodeIfPresent(Double.self, forKey: .aspectRatio)
        padding = try keys.decodeIfPresent(Double.self, forKey: .padding) ?? 0
        fillsWidth = try keys.decodeIfPresent(Bool.self, forKey: .fillsWidth) ?? false
        fillsHeight = try keys.decodeIfPresent(Bool.self, forKey: .fillsHeight) ?? false
        zIndex = try keys.decodeIfPresent(Double.self, forKey: .zIndex) ?? 0
        allowsHitTesting = try keys.decodeIfPresent(Bool.self, forKey: .allowsHitTesting) ?? true
        alignment = try keys.decodeIfPresent(Anchor.self, forKey: .alignment) ?? .center
        offsetX = try keys.decodeIfPresent(Double.self, forKey: .offsetX) ?? 0
        offsetY = try keys.decodeIfPresent(Double.self, forKey: .offsetY) ?? 0
        rotationDegrees = try keys.decodeIfPresent(Double.self, forKey: .rotationDegrees) ?? 0
        opacity = try keys.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
    }

    func encode(to encoder: any Encoder) throws {
        var keys = encoder.container(keyedBy: CodingKeys.self)
        try keys.encodeIfPresent(width, forKey: .width)
        try keys.encodeIfPresent(height, forKey: .height)
        try keys.encodeIfPresent(minimumWidth, forKey: .minimumWidth)
        try keys.encodeIfPresent(minimumHeight, forKey: .minimumHeight)
        try keys.encodeIfPresent(maximumWidth, forKey: .maximumWidth)
        try keys.encodeIfPresent(maximumHeight, forKey: .maximumHeight)
        try keys.encodeIfPresent(aspectRatio, forKey: .aspectRatio)
        if padding != 0 { try keys.encode(padding, forKey: .padding) }
        if fillsWidth { try keys.encode(true, forKey: .fillsWidth) }
        if fillsHeight { try keys.encode(true, forKey: .fillsHeight) }
        if zIndex != 0 { try keys.encode(zIndex, forKey: .zIndex) }
        if !allowsHitTesting { try keys.encode(false, forKey: .allowsHitTesting) }
        if alignment != .center { try keys.encode(alignment, forKey: .alignment) }
        if offsetX != 0 { try keys.encode(offsetX, forKey: .offsetX) }
        if offsetY != 0 { try keys.encode(offsetY, forKey: .offsetY) }
        if rotationDegrees != 0 { try keys.encode(rotationDegrees, forKey: .rotationDegrees) }
        if opacity != 1 { try keys.encode(opacity, forKey: .opacity) }
    }
}
