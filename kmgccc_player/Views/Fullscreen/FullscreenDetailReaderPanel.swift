//
//  FullscreenDetailReaderPanel.swift
//  myPlayer2
//
//  kmgccc_player - Fullscreen Detail Reader Panel
//  Liquid Glass self-drawn panel for viewing track/album/artist description text
//  in fullscreen mode, adhering to polarity-aware overlay styling.
//

import AppKit
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
    private var cornerRadius: CGFloat { presentationStyle.panelCornerRadius }
    private var contentPadding: CGFloat { presentationStyle.panelContentPadding }
    private var closeButtonSize: CGFloat { presentationStyle.closeButtonSize }

    private var paragraphs: [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let split = normalized.components(separatedBy: "\n\n")
        let trimmed = split.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return trimmed.isEmpty ? [text] : trimmed
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Polarity-aware tint layer
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(presentationStyle.surfaceTintColor.opacity(0.20))
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: presentationStyle.scaled(14)) {
                // Header Area
                panelHeader
                    .padding(.trailing, closeButtonSize + presentationStyle.scaled(10))

                // Text reader card with ultra thin material
                textReaderCard
            }
            .padding(.horizontal, contentPadding)
            .padding(.top, contentPadding)
            .padding(.bottom, presentationStyle.panelBottomPadding)
            .environment(\.colorScheme, foregroundProfile.colorScheme)

            closeButton
                .padding(.top, presentationStyle.panelBottomPadding)
                .padding(.trailing, presentationStyle.panelBottomPadding)
        }
        .frame(width: panelWidth, height: panelHeight, alignment: .topLeading)
        .glassEffect(
            .clear,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    GlassStyleTokens.glassBorderColor(for: foregroundProfile.colorScheme),
                    lineWidth: presentationStyle.scaled(GlassStyleTokens.hairlineWidth)
                )
                .allowsHitTesting(false)
        )
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(presentationStyle.surfaceTintColor.opacity(0.08))
                .allowsHitTesting(false)
        )
        .subtleFloatingShadow()
        .controlSize(presentationStyle.controlSize)
        .environment(\.colorScheme, foregroundProfile.colorScheme)
        .onAppear(perform: registerDismissHandler)
        .onDisappear(perform: unregisterDismissHandler)
    }

    // MARK: - Header

    private var panelHeader: some View {
        VStack(alignment: .leading, spacing: presentationStyle.scaled(4)) {
            Text(title)
                .font(.system(size: presentationStyle.scaled(20), weight: .bold))
                .foregroundStyle(presentationStyle.primaryTextColor)
                .lineLimit(2)

            if let attributionNote, !attributionNote.isEmpty {
                Text(attributionNote)
                    .font(.system(size: presentationStyle.scaled(12), weight: .medium))
                    .foregroundStyle(presentationStyle.secondaryTextColor)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Text Reader Card

    private var textReaderCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: presentationStyle.scaled(14)) {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    emptyStateView
                } else {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.system(size: presentationStyle.scaled(14.5), weight: .regular))
                            .lineSpacing(presentationStyle.scaled(7))
                            .foregroundStyle(presentationStyle.primaryTextColor.opacity(0.95))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(presentationStyle.scaled(18))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: presentationStyle.scaled(16), style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: presentationStyle.scaled(16), style: .continuous)
                .strokeBorder(
                    GlassStyleTokens.glassBorderColor(for: foregroundProfile.colorScheme).opacity(0.5),
                    lineWidth: presentationStyle.scaled(0.5)
                )
                .allowsHitTesting(false)
        )
    }

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

    // MARK: - Close Button

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 12 * scale, weight: .semibold))
                .foregroundStyle(presentationStyle.primaryTextColor)
                .frame(width: closeButtonSize, height: closeButtonSize)
                .contentShape(Circle())
                .background(
                    Circle()
                        .fill(presentationStyle.primaryTextColor.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
        .help("关闭")
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
