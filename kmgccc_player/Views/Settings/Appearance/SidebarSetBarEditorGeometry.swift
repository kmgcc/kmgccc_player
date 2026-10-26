import SwiftUI

/// Shared coordinate keys for the SwiftUI layout and its pointer surface.
enum SidebarSetBarEditorRegion: Hashable {
    case preview
    case palette
    case layout([UUID])
    case item(UUID)
    case candidate(SidebarSetBarItemKind)
    case candidateCard(SidebarSetBarItemKind)
}

struct SidebarSetBarEditorFrames: PreferenceKey {
    static var defaultValue: [SidebarSetBarEditorRegion: CGRect] { [:] }

    static func reduce(value: inout [SidebarSetBarEditorRegion: CGRect], nextValue: () -> [SidebarSetBarEditorRegion: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

extension View {
    func sidebarSetBarFrame(_ region: SidebarSetBarEditorRegion, in space: Namespace.ID) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SidebarSetBarEditorFrames.self,
                    value: [region: proxy.frame(in: .named(space))]
                )
            }
        }
    }
}

struct SidebarSetBarDropTarget: View {
    let tint: Color

    private var dropTargetColor: Color {
        tint.mix(with: .white, by: 0.28, in: .device)
    }

    var body: some View {
        // UI exception: the user explicitly requested a dashed pending drop target.
        // It appears only during dragging/landing, never as a permanent control border.
        Capsule()
            .strokeBorder(dropTargetColor, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct SidebarSetBarSeparatorDropTarget: View {
    let tint: Color

    private var dropTargetColor: Color {
        tint.mix(with: .white, by: 0.28, in: .device)
    }

    var body: some View {
        VStack(spacing: 2.5) {
            ForEach(0..<6, id: \.self) { _ in
                Capsule()
                    .fill(dropTargetColor)
                    .frame(width: 1.75, height: 2.5)
            }
        }
        .frame(width: SidebarSetBarMetrics.separatorWidth, height: GlassStyleTokens.headerControlHeight)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
