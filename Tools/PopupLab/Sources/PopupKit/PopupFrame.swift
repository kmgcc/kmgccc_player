import SwiftUI

/// Shared layout with arbitrary content and footer slots, independent of its host.
public struct PopupFrame<Content: View, Footer: View>: View {
    private let title: String
    private let subtitle: String?
    private let systemImage: String?
    private let onClose: (() -> Void)?
    private let showsFooter: Bool
    private let rendersSurface: Bool
    private let foregroundBlendMode: BlendMode
    private let content: Content
    private let footer: Footer

    @Environment(\.popupStyle) private var style
    @Environment(\.popupPalette) private var palette

    public init(
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        onClose: (() -> Void)? = nil,
        showsFooter: Bool = true,
        rendersSurface: Bool = true,
        foregroundBlendMode: BlendMode = .normal,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.onClose = onClose
        self.showsFooter = showsFooter
        self.rendersSurface = rendersSurface
        self.foregroundBlendMode = foregroundBlendMode
        self.content = content()
        self.footer = footer()
    }

    public var body: some View {
        Group {
            if rendersSurface { PopupSurface { foregroundLayout } } else { foregroundLayout }
        }
    }

    @ViewBuilder
    private var foregroundLayout: some View {
        if foregroundBlendMode == .normal {
            layout
        } else {
            layout.compositingGroup().blendMode(foregroundBlendMode)
        }
    }

    private var layout: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: style.sectionSpacing) {
                if style.showsSeparators { Divider().opacity(0.35) }
                content
                    .font(.system(size: style.bodySize))
                    .lineSpacing(style.bodyLineSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, style.sectionSpacing)
            .padding(.horizontal, style.padding)
            .padding(.bottom, showsFooter ? 0 : style.padding)
            if showsFooter {
                VStack(alignment: .trailing, spacing: style.sectionSpacing) {
                    if style.showsSeparators { Divider().opacity(0.35) }
                    footer.frame(maxWidth: .infinity, alignment: actionAlignment)
                }
                .padding(
                    EdgeInsets(
                        top: style.buttonMarginTop, leading: style.buttonMarginLeading,
                        bottom: style.buttonMarginBottom, trailing: style.buttonMarginTrailing))
            }
        }
    }

    private var actionAlignment: Alignment {
        switch style.actionAlignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private var header: some View {
        PopupHeader(title: title, subtitle: subtitle, systemImage: systemImage, onClose: onClose)
    }
}
