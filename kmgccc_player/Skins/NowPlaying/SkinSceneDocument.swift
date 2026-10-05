import SwiftUI

/// A small native component tree. Swift authors can also provide an unrestricted SkinScene.
struct SkinSceneDocument: Codable {
    let root: SkinSceneNode

    var scene: SkinScene {
        SkinScene { _, _, components in
            SkinSceneNodeView(node: root, components: components)
        }
    }

    var componentTypes: Set<String> { root.componentTypes }
    var simultaneousLyricsCount: Int { root.simultaneousLyricsCount }
}

struct SkinSceneNode: Codable, Identifiable {
    let id: String
    let content: Content
    var layout = SkinSceneLayout()

    indirect enum Content {
        case component(type: String, configuration: SkinComponentConfiguration)
        case row(children: [SkinSceneNode], spacing: Double)
        case column(children: [SkinSceneNode], spacing: Double)
        case overlay(children: [SkinSceneNode])
        case adaptive(minimumWidth: Double, minimumHeight: Double = 0, wide: SkinSceneNode, compact: SkinSceneNode)
        case spacer
    }

    static func component(_ id: String, _ type: String, values: [String: SkinParameterValue] = [:], layout: SkinSceneLayout = .init()) -> Self {
        Self(id: id, content: .component(type: type, configuration: .init(values: values)), layout: layout)
    }

    var componentTypes: Set<String> {
        switch content {
        case .component(let type, _): return [type]
        case .row(let children, _), .column(let children, _), .overlay(let children):
            return children.reduce(into: []) { $0.formUnion($1.componentTypes) }
        case .adaptive(_, _, let wide, let compact): return wide.componentTypes.union(compact.componentTypes)
        case .spacer: return []
        }
    }

    var simultaneousLyricsCount: Int {
        switch content {
        case .component(let type, _): return type == "native.lyrics" ? 1 : 0
        case .row(let children, _), .column(let children, _), .overlay(let children):
            return children.reduce(0) { $0 + $1.simultaneousLyricsCount }
        case .adaptive(_, _, let wide, let compact): return max(wide.simultaneousLyricsCount, compact.simultaneousLyricsCount)
        case .spacer: return 0
        }
    }
}

/// Standard SwiftUI sizing, measured in points. Native text never becomes a scaled bitmap.
struct SkinSceneLayout: Codable {
    enum Anchor: String, Codable {
        case topLeading, top, topTrailing, leading, center, trailing, bottomLeading, bottom, bottomTrailing

        var alignment: Alignment {
            switch self {
            case .topLeading: .topLeading
            case .top: .top
            case .topTrailing: .topTrailing
            case .leading: .leading
            case .center: .center
            case .trailing: .trailing
            case .bottomLeading: .bottomLeading
            case .bottom: .bottom
            case .bottomTrailing: .bottomTrailing
            }
        }
    }

    var width: Double?
    var height: Double?
    var minimumWidth: Double?
    var minimumHeight: Double?
    var maximumWidth: Double?
    var maximumHeight: Double?
    var aspectRatio: Double?
    var padding: Double = 0
    var fillsWidth = false
    var fillsHeight = false
    var zIndex: Double = 0
    var allowsHitTesting = true
    var alignment: Anchor = .center
    var offsetX: Double = 0
    var offsetY: Double = 0
    var rotationDegrees: Double = 0
    var opacity: Double = 1
}

private struct SkinSceneNodeView: View {
    let node: SkinSceneNode
    let components: SkinComponents

    var body: some View {
        content
            .modifier(SkinSceneSizing(layout: node.layout))
            .zIndex(node.layout.zIndex)
            .offset(x: node.layout.offsetX, y: node.layout.offsetY)
            .rotationEffect(.degrees(node.layout.rotationDegrees))
            .opacity(node.layout.opacity)
            .allowsHitTesting(node.layout.allowsHitTesting)
    }

    @ViewBuilder
    private var content: some View {
        switch node.content {
        case .component(let type, let configuration):
            components.component(type, configuration: configuration)
        case .row(let children, let spacing):
            HStack(spacing: spacing) {
                ForEach(children) { SkinSceneNodeView(node: $0, components: components) }
            }
        case .column(let children, let spacing):
            VStack(spacing: spacing) {
                ForEach(children) { SkinSceneNodeView(node: $0, components: components) }
            }
        case .overlay(let children):
            ZStack(alignment: node.layout.alignment.alignment) {
                ForEach(children) { SkinSceneNodeView(node: $0, components: components) }
            }
        case .adaptive(let minimumWidth, let minimumHeight, let wide, let compact):
            GeometryReader { proxy in
                SkinSceneNodeView(
                    node: proxy.size.width >= minimumWidth && proxy.size.height >= minimumHeight ? wide : compact,
                    components: components
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        case .spacer:
            Spacer(minLength: 0)
        }
    }
}

private struct SkinSceneSizing: ViewModifier {
    let layout: SkinSceneLayout

    func body(content: Content) -> some View {
        aspectAdjusted(content)
            .frame(width: layout.width.map { CGFloat($0) }, height: layout.height.map { CGFloat($0) }, alignment: layout.alignment.alignment)
            .frame(minWidth: layout.minimumWidth.map { CGFloat($0) }, maxWidth: layout.maximumWidth.map { CGFloat($0) },
                   minHeight: layout.minimumHeight.map { CGFloat($0) }, maxHeight: layout.maximumHeight.map { CGFloat($0) },
                   alignment: layout.alignment.alignment)
            .frame(
                maxWidth: layout.fillsWidth ? .infinity : nil,
                maxHeight: layout.fillsHeight ? .infinity : nil,
                alignment: layout.alignment.alignment
            )
            .padding(CGFloat(layout.padding))
    }

    @ViewBuilder
    private func aspectAdjusted(_ content: Content) -> some View {
        if let ratio = layout.aspectRatio {
            content.aspectRatio(CGFloat(ratio), contentMode: .fit)
        } else {
            content
        }
    }
}
