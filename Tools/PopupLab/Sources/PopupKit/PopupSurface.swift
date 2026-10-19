import SwiftUI

/// A single material layer. The host owns the surrounding sheet/window/popover chrome.
public struct PopupSurface<Content: View>: View {
    private let content: Content
    @Environment(\.popupStyle) private var style
    @Environment(\.popupPalette) private var palette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @ViewBuilder public var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
        let foreground = content.foregroundStyle(palette.primary)
        if reduceTransparency || style.surface == .solid {
            foreground.background(palette.surface, in: shape)
        } else {
            switch style.surface {
            case .glass:
                foreground.glassEffect(.regular, in: shape)
            case .clearGlass:
                foreground.glassEffect(.clear, in: shape)
            case .solid:
                foreground.background(palette.surface, in: shape)
            case .regular:
                foreground.background(.regularMaterial, in: shape)
            case .thin:
                foreground.background(.thinMaterial, in: shape)
            }
        }
    }
}
