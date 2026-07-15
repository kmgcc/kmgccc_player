//
//  DuplicateImportDialog.swift
//  myPlayer2
//
//  kmgccc_player - Duplicate import selection presentation
//

import AVFoundation
import AppKit
import Combine
import CoreServices
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Presenter & UI Components

final class DuplicateImportDialogPresenter: NSObject, NSWindowDelegate {
    private var result: [DuplicatePairRow]?
    private let panel: NSPanel

    init(panel: NSPanel) {
        self.panel = panel
        super.init()
    }

    @MainActor
    static func present(
        rows: [DuplicatePairRow]
    ) -> [DuplicatePairRow]? {
        // Height Calculation Strategy (Compact Mode):
        // Header: 20 (top) + 24 (title) + 4 (gap) + 14 (subtitle) + 8 (gap) + 16 (columns) + 12 (bottom) ≈ 98
        // Footer: 20 (top) + 28 (button) + 20 (bottom) ≈ 68
        // Row: 56 (height) + 4 (spacing) = 60

        // Compact Layout Constants
        let headerHeight: CGFloat = 98
        let footerHeight: CGFloat = 68
        let rowHeight: CGFloat = 48
        let listVerticalPadding: CGFloat = 16
        let maxItemsWithoutScroll = 9

        let visibleRows = CGFloat(min(rows.count, maxItemsWithoutScroll))
        let contentHeight = (visibleRows * rowHeight) + (listVerticalPadding * 2)
        let idealHeight = headerHeight + contentHeight + footerHeight
        
        let clampedHeight = idealHeight

        // Width: 760 (Balanced)
        let windowSize = NSSize(width: 760, height: clampedHeight)

        // Create Panel + Visual Effect
        let (panel, visualEffect) = AppDialogTokens.makePanel(
            width: windowSize.width,
            height: windowSize.height
        )

        let presenter = DuplicateImportDialogPresenter(panel: panel)
        panel.delegate = presenter

        let viewModel = DuplicateImportDialogViewModel(rows: rows)

        let customAction: (Bool) -> Void = { shouldImport in
            if shouldImport {
                presenter.result = viewModel.selectedRows
            } else {
                presenter.result = nil
            }
            NSApp.stopModal()
            panel.close()
        }

        let rootView = DuplicateImportDialogView(viewModel: viewModel, onFinish: customAction)
            .environmentObject(ThemeStore.shared)
            .frame(width: 760, height: clampedHeight)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: windowSize)
        hostingView.autoresizingMask = [.width, .height]

        visualEffect.addSubview(hostingView)
        panel.center()

        NSApp.runModal(for: panel)
        panel.orderOut(nil)

        // Directly return the result.
        // If result is nil, it means user Cancelled.
        // If result is [], it means user Confirmed but selected nothing (which is valid).
        return presenter.result
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
    }
}

@MainActor
final class DuplicateImportDialogViewModel: ObservableObject {
    let rows: [DuplicatePairRow]

    @Published var selectedIDs: Set<String>

    init(rows: [DuplicatePairRow]) {
        self.rows = rows
        self.selectedIDs = []
    }

    func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    var buttonTitle: String {
        if selectedIDs.isEmpty {
            return "忽略重复项导入"
        } else {
            return "导入所选重复项"
        }
    }

    var selectedRows: [DuplicatePairRow] {
        rows.filter { selectedIDs.contains($0.id) }
    }
}

struct DuplicateImportDialogView: View {
    @ObservedObject var viewModel: DuplicateImportDialogViewModel
    let onFinish: (Bool) -> Void
    @EnvironmentObject var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    private let maxItemsWithoutScroll = 9

    // LAYOUT CONSTANTS (Width: 760)
    // Left: 306 (~43%) | Spacing: 12 | Right: 394 (~55%)
    private let leftColumnWidth: CGFloat = 306
    private let rightColumnWidth: CGFloat = 394
    private let horizontalPadding: CGFloat = AppDialogTokens.headerHorizontalPadding

    var body: some View {
        VStack(spacing: 0) {
            headerView
            listContent
            footerView
        }
        .task {
            print("🎬 Duplicate Dialog Appeared. Total rows: \(viewModel.rows.count)")
        }
    }
    
    private var listContent: some View {
        let rowsView = VStack(spacing: 0) {
            ForEach(viewModel.rows) { row in
                DuplicateRowView(
                    row: row,
                    isSelected: viewModel.selectedIDs.contains(row.id),
                    leftWidth: leftColumnWidth,
                    rightWidth: rightColumnWidth,
                    themeAccent: themeStore.accentColor
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        viewModel.toggleSelection(row.id)
                    }
                }
            }
        }
        
        let paddedView = rowsView
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 16)
        
        if viewModel.rows.count > maxItemsWithoutScroll {
            return AnyView(
                ScrollView {
                    paddedView
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        } else {
            return AnyView(
                paddedView
                    .frame(maxWidth: .infinity)
            )
        }
    }
    
    private var headerView: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("发现重复歌曲")
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                Text("点击右侧条目选择是否重复导入")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            HStack(spacing: 12) {
                Text("资料库中已存在")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: leftColumnWidth, alignment: .leading)
                
                Divider()
                    .frame(height: 12)
                    .overlay(Color.secondary.opacity(0.3))
                
                Text("本次待导入")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: rightColumnWidth, alignment: .leading)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) {
            AppDialogDivider()
        }
        .zIndex(1)
    }

    private var footerView: some View {
        HStack {
            Button("取消") {
                onFinish(false)
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(AppDialogGlassButtonStyle(kind: .secondary))

            Spacer()

            Button(viewModel.buttonTitle) {
                onFinish(true)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(
                AppDialogGlassButtonStyle(kind: .primary, tint: themeStore.accentColor)
            )
        }
        .padding(.top, AppDialogTokens.footerVerticalPadding)
        .padding(.bottom, AppDialogTokens.footerBottomPadding)
        .padding(.horizontal, horizontalPadding)
        .background(.thinMaterial)
        .overlay(alignment: .top) {
            AppDialogDivider()
        }
    }
}

struct DuplicateRowView: View {
    let row: DuplicatePairRow
    let isSelected: Bool
    let leftWidth: CGFloat
    let rightWidth: CGFloat
    let themeAccent: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {  // Tighter horizontal spacing
            // Left Column (Existing)
            columnView(
                title: row.existing?.title ?? "未知标题",
                artist: row.existing?.artist ?? "未知艺术家",
                artworkData: row.existing?.artworkData,
                badge: "库中",
                isIncoming: false,
                isSelected: false,
                width: leftWidth
            )

            Divider()
                .frame(height: 32)  // Shorter divider for compact row
                .overlay(Color.secondary.opacity(0.1))

            // Right Column (Incoming)
            columnView(
                title: row.incoming.title,
                artist: row.incoming.artist,
                artworkData: nil,
                badge: isSelected ? "导入" : "跳过",
                isIncoming: true,
                isSelected: isSelected,
                width: rightWidth
            )
        }
        .frame(height: 48)  // Ultra Compact Row Height
    }

    private func columnView(
        title: String,
        artist: String,
        artworkData: Data?,
        badge: String,
        isIncoming: Bool,
        isSelected: Bool,
        width: CGFloat
    ) -> some View {
        HStack(spacing: 12) {
            // Artwork
            if isIncoming {
                // Simplified static icon for incoming files (Stable & Fast)
                Image(systemName: "music.note")
                    .font(.system(size: 18))
                    .foregroundStyle(themeAccent)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(themeAccent.opacity(0.08))
                    )
            } else if let data = artworkData, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 36, height: 36)  // Compact artwork
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))  // Larger radius
                    .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .frame(width: 36, height: 36)
                    .background(Color.secondary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            // Metadata
            VStack(alignment: .leading, spacing: 1) {  // Tighter vertical text spacing
                HStack {
                    Text(title)
                        .font(.body)  // Default size covers 13pt
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if isSelected || !isIncoming {
                        Text(badge)
                            .font(.system(size: 9, weight: .semibold))  // Smaller badge text
                            .foregroundStyle(isSelected ? themeAccent : .secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule()
                                    .fill(
                                        isSelected
                                            ? themeAccent.opacity(0.15)
                                            : Color.primary.opacity(0.05))
                            )
                    }
                }

                Text(artist)
                    .font(.caption)  // Smaller artist text
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)  // Slightly reduced internal padding
        .padding(.vertical, 6)  // Tighter vertical padding
        .frame(width: width, alignment: .leading)
        .background {
            // Background Logic
            if isIncoming {
                if isSelected {
                    // Stronger highlight for selection
                    RoundedRectangle(cornerRadius: AppDialogTokens.rowCornerRadius, style: .continuous)
                        .fill(themeAccent.opacity(colorScheme == .dark ? 0.22 : 0.12))
                } else {
                    // Subtle background for incoming candidates
                    RoundedRectangle(cornerRadius: AppDialogTokens.rowCornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                }
            } else {
                // Simple transparent for existing, or very subtle
                RoundedRectangle(cornerRadius: AppDialogTokens.rowCornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.01))
            }
        }
    }
}
