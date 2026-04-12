//
//  ResetPreferenceDataDialog.swift
//  myPlayer2
//
//  Canonical reference implementation of the app-native dialog style.
//  All import/data-management dialogs should match this skeleton:
//    - AppDialogConfirmHeader (icon backing + title + description)
//    - AppDialogDivider
//    - Footer: cancel + primary/destructive button with token-defined spacing
//

import AppKit
import SwiftUI

// MARK: - Presenter

@MainActor
final class ResetPreferenceDataDialogPresenter: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var hasResponded = false

    @MainActor
    static func present(onConfirm: @escaping () -> Void) {
        let dialogWidth: CGFloat = 440
        let dialogHeight: CGFloat = 260

        let (panel, effectView) = AppDialogTokens.makePanel(
            width: dialogWidth,
            height: dialogHeight
        )

        let presenter = ResetPreferenceDataDialogPresenter()
        presenter.panel = panel
        panel.delegate = presenter

        let rootView = ResetPreferenceDataDialogView(
            onConfirm: {
                presenter.hasResponded = true
                panel.close()
                onConfirm()
            },
            onCancel: {
                presenter.hasResponded = true
                panel.close()
            }
        )
        .frame(width: dialogWidth, height: dialogHeight)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: NSSize(width: dialogWidth, height: dialogHeight))
        hostingView.autoresizingMask = [.width, .height]

        effectView.addSubview(hostingView)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {}
}

// MARK: - Dialog View

struct ResetPreferenceDataDialogView: View {
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            AppDialogConfirmHeader(
                iconName: "brain.head.profile",
                iconColor: .orange,
                title: "重置音乐偏好数据",
                description: "将清除所有歌曲的播放习惯记录，包括完成率、跳过次数和喜好状态。智能播放将从零开始重新学习。"
            )

            AppDialogDivider()

            Spacer(minLength: 0)

            footerView
        }
    }

    private var footerView: some View {
        HStack {
            Button("取消") {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)
            .controlSize(.large)

            Spacer()

            Button("重置偏好数据") {
                onConfirm()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.orange)
        }
        .padding(.horizontal, AppDialogTokens.footerHorizontalPadding)
        .padding(.vertical, AppDialogTokens.footerVerticalPadding)
        .background(.thinMaterial)
        .overlay(alignment: .top) {
            AppDialogDivider()
        }
    }
}

// MARK: - Preview

#Preview {
    ResetPreferenceDataDialogView(onConfirm: {}, onCancel: {})
        .frame(width: 440, height: 260)
}
