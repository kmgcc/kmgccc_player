import SwiftUI

enum SidebarSetBarMetrics {
    static let separatorWidth: CGFloat = 8
}

/// The live bar and its editor use identical button sizes, grouping and glass surfaces.
struct SidebarSetBar<ButtonContent: View, SeparatorContent: View>: View {
    let configuration: SidebarSetBarConfiguration
    @ViewBuilder var button: (SidebarSetBarItem) -> ButtonContent
    @ViewBuilder var separator: (SidebarSetBarItem) -> SeparatorContent

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    private struct ButtonGroup: Identifiable {
        var buttons: [SidebarSetBarItem]
        var separator: SidebarSetBarItem?
        var id: UUID { buttons[0].id }
    }

    private var groups: [ButtonGroup] {
        var result: [ButtonGroup] = []
        var buttons: [SidebarSetBarItem] = []
        for item in configuration.items {
            if item.kind == .separator {
                result.append(ButtonGroup(buttons: buttons, separator: item))
                buttons = []
            } else {
                buttons.append(item)
            }
        }
        if !buttons.isEmpty {
            result.append(ButtonGroup(buttons: buttons))
        }
        return result
    }

    var body: some View {
        // The boundary gap exceeds the glass sampling distance, preserving separate capsules.
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(groups) { group in
                    HStack(spacing: 0) {
                        ForEach(group.buttons) { item in
                            button(item)
                        }
                    }
                    .liquidGlassPill(colorScheme: colorScheme)

                    if let boundary = group.separator {
                        separator(boundary)
                            .frame(width: SidebarSetBarMetrics.separatorWidth, height: GlassStyleTokens.headerControlHeight)
                    }
                }
            }
        }
        .tint(themeStore.accentColor)
        .frame(height: GlassStyleTokens.headerControlHeight)
        .fixedSize(horizontal: true, vertical: false)
    }
}
