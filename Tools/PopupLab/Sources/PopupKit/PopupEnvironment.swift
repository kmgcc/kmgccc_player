import SwiftUI

/// Semantic colors are supplied by the host. The player adapter should read ThemeStore.
public struct PopupPalette {
    public var primary: Color
    public var secondary: Color
    public var accent: Color
    public var danger: Color
    public var surface: Color
    public var accentForeground: Color
    public var dangerForeground: Color

    public init(
        primary: Color = .primary,
        secondary: Color = .secondary,
        accent: Color = .accentColor,
        danger: Color = .red,
        surface: Color = Color(nsColor: .windowBackgroundColor),
        accentForeground: Color = .white,
        dangerForeground: Color = .white
    ) {
        self.primary = primary
        self.secondary = secondary
        self.accent = accent
        self.danger = danger
        self.surface = surface
        self.accentForeground = accentForeground
        self.dangerForeground = dangerForeground
    }
}

private struct PopupStyleKey: EnvironmentKey {
    static let defaultValue = PopupStyle()
}

private struct PopupPaletteKey: EnvironmentKey {
    static let defaultValue = PopupPalette()
}

extension EnvironmentValues {
    public var popupStyle: PopupStyle {
        get { self[PopupStyleKey.self] }
        set { self[PopupStyleKey.self] = newValue }
    }

    public var popupPalette: PopupPalette {
        get { self[PopupPaletteKey.self] }
        set { self[PopupPaletteKey.self] = newValue }
    }
}

extension View {
    public func popupAppearance(style: PopupStyle, palette: PopupPalette) -> some View {
        environment(\.popupStyle, style)
            .environment(\.popupPalette, palette)
            .tint(palette.accent)
    }
}
