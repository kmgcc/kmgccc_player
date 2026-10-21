//
//  FullscreenDetailReaderPanel.swift
//  myPlayer2
//
//  kmgccc_player - Fullscreen Detail Reader Panel
//  Liquid Glass self-drawn panel for viewing track/album/artist description text
//  in fullscreen mode, adhering to polarity-aware overlay styling.
//

import AppKit
import PopupKit
import SwiftUI

struct FullscreenDetailReaderPanel: View {
    let title: String
    var attributionNote: String? = nil
    let text: String
    let scale: CGFloat
    let foregroundProfile: FullscreenOverlayForegroundProfile
    let onDismiss: () -> Void

    @State private var dismissRegistrationID: UUID?

    private var presentationStyle: FullscreenSettingsPresentationStyle {
        .fullscreenOverlay(scale: scale, foregroundProfile: foregroundProfile)
    }

    static func panelSize(for scale: CGFloat) -> CGSize {
        CGSize(width: 580 * scale, height: 640 * scale)
    }

    private var panelWidth: CGFloat { presentationStyle.panelSize.width }
    private var panelHeight: CGFloat { presentationStyle.scaled(640) }

    private var paragraphs: [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let split = normalized.components(separatedBy: "\n\n")
        let trimmed = split.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return trimmed.isEmpty ? [text] : trimmed
    }

    var body: some View {
        AppPopupFrame(
            title: title, subtitle: attributionNote, systemImage: "text.quote",
            onClose: onDismiss, showsFooter: false, showsCloseButton: false, style: popupStyle,
            primaryColor: presentationStyle.primaryTextColor,
            secondaryColor: presentationStyle.secondaryTextColor
        ) {
            AppPopupScrollRegion {
                VStack(alignment: .leading, spacing: popupStyle.sectionSpacing) {
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        emptyStateView
                    } else {
                        ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                            Text(paragraph)
                                .font(.system(size: popupStyle.bodySize))
                                .lineSpacing(popupStyle.bodyLineSpacing)
                                .foregroundStyle(presentationStyle.primaryTextColor)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            } actions: {
                Button("关闭", action: onDismiss).buttonStyle(AppDialogGlassButtonStyle())
            }
        } footer: {
            EmptyView()
        }
        .frame(width: panelWidth, height: panelHeight, alignment: .topLeading)
        .controlSize(presentationStyle.controlSize)
        .environment(\.colorScheme, foregroundProfile.colorScheme)
        .onAppear(perform: registerDismissHandler)
        .onDisappear(perform: unregisterDismissHandler)
    }

    private var popupStyle: AppPopupStyle { AppPopupStyle().scaled(by: Double(scale)) }

    private var emptyStateView: some View {
        VStack(spacing: presentationStyle.scaled(10)) {
            Image(systemName: "text.quote")
                .font(.system(size: presentationStyle.scaled(32)))
                .foregroundStyle(presentationStyle.secondaryTextColor.opacity(0.6))

            Text("暂无详细介绍")
                .font(.system(size: presentationStyle.scaled(14), weight: .medium))
                .foregroundStyle(presentationStyle.secondaryTextColor)
        }
        .frame(maxWidth: .infinity, minHeight: presentationStyle.scaled(200))
    }

    // MARK: - Dismiss Handling

    private func registerDismissHandler() {
        guard dismissRegistrationID == nil else { return }
        dismissRegistrationID = FullscreenTransientDismissCoordinator.shared.register {
            onDismiss()
            return true
        }
    }

    private func unregisterDismissHandler() {
        guard let dismissRegistrationID else { return }
        FullscreenTransientDismissCoordinator.shared.unregister(dismissRegistrationID)
        self.dismissRegistrationID = nil
    }
}
