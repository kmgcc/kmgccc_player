import SwiftUI

/// Reusable first-line optical alignment for dialogs and larger editing workspaces.
public struct PopupHeader<Accessory: View>: View {
    private let title: String
    private let subtitle: String?
    private let systemImage: String?
    private let onClose: (() -> Void)?
    private let accessory: Accessory
    private let hasAccessory: Bool
    @Environment(\.popupStyle) private var style
    @Environment(\.popupPalette) private var palette

    public init(
        title: String, subtitle: String? = nil, systemImage: String? = nil,
        onClose: (() -> Void)? = nil
    ) where Accessory == EmptyView {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.onClose = onClose
        self.accessory = EmptyView()
        self.hasAccessory = false
    }

    public init(
        title: String, subtitle: String? = nil, systemImage: String? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.onClose = nil
        self.accessory = accessory()
        self.hasAccessory = Accessory.self != EmptyView.self
    }

    public var body: some View {
        PopupHeaderLayout(
            title: title, titleSize: style.titleSize, spacing: style.headerSpacing,
            hasIcon: style.showsIcon && systemImage != nil,
            hasClose: hasAccessory || (style.showsCloseButton && onClose != nil),
            contentInset: style.padding,
            closeTop: style.closeMarginTop, closeTrailing: style.closeMarginTrailing
        ) {
            if style.showsIcon, let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: style.iconSize, weight: .medium))
                    .foregroundStyle(palette.accent)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: style.titleBodySpacing) {
                Text(title)
                    .font(.system(size: style.titleSize, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: style.bodySize))
                        .foregroundStyle(palette.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            if hasAccessory {
                accessory
            } else if style.showsCloseButton, let onClose {
                PopupCloseButton(action: onClose)
            }
        }
    }
}

public struct PopupCloseButton: View {
    private let action: () -> Void
    @Environment(\.popupPalette) private var palette

    public init(action: @escaping () -> Void) { self.action = action }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").foregroundStyle(palette.secondary)
        }
        .buttonStyle(PopupButtonStyle(isCloseButton: true))
        .accessibilityLabel("关闭")
        .help("关闭")
    }
}
