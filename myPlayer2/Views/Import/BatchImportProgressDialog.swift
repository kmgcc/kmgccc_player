//
//  BatchImportProgressDialog.swift
//  myPlayer2
//

import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
private final class BatchImportProgressItemModel: Identifiable {
    let id: String
    let fileName: String
    var title: String = ""
    var artist: String = ""
    var stage: BatchImportItemStage = .scanning
    var status: BatchImportItemStatus = .waiting
    var detail: String = ""
    var issueMessage: String?

    init(id: String, fileName: String) {
        self.id = id
        self.fileName = fileName
    }
}

@MainActor
@Observable
private final class BatchImportProgressViewModel {
    var stage: BatchImportStage = .scanning
    var progress: Double = 0
    var detail: String = ""
    var completedCount: Int = 0
    var totalCount: Int = 0
    var items: [BatchImportProgressItemModel] = []

    var sortedItems: [BatchImportProgressItemModel] {
        items
    }
}

@MainActor
final class BatchImportProgressDialogController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let viewModel = BatchImportProgressViewModel()
    private var isClosed = false

    override init() {
        super.init()

        let windowSize = NSSize(width: 600, height: 560)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.title = ""
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.frame = NSRect(origin: .zero, size: windowSize)
        visualEffect.autoresizingMask = [.width, .height]
        panel.contentView = visualEffect

        let rootView = BatchImportProgressDialogView(viewModel: viewModel)
            .frame(width: windowSize.width, height: windowSize.height)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: windowSize)
        hostingView.autoresizingMask = [.width, .height]
        visualEffect.addSubview(hostingView)

        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func setItems(_ items: [BatchImportProgressItemSeed]) {
        guard !isClosed else { return }
        viewModel.items = items.map { BatchImportProgressItemModel(id: $0.id, fileName: $0.fileName) }
    }

    func update(
        stage: BatchImportStage,
        progress: Double,
        detail: String,
        completedCount: Int,
        totalCount: Int
    ) {
        guard !isClosed else { return }
        viewModel.stage = stage
        viewModel.progress = min(max(progress, 0), 1)
        viewModel.detail = detail
        viewModel.completedCount = completedCount
        viewModel.totalCount = totalCount
    }

    func updateItem(
        id: String,
        title: String? = nil,
        artist: String? = nil,
        stage: BatchImportItemStage,
        status: BatchImportItemStatus,
        detail: String,
        issueMessage: String? = nil
    ) {
        guard !isClosed, let item = viewModel.items.first(where: { $0.id == id }) else { return }
        if let title, !title.isEmpty {
            item.title = title
        }
        if let artist {
            item.artist = artist
        }
        item.stage = stage
        item.status = status
        item.detail = detail
        item.issueMessage = issueMessage
    }

    func completeImportedItem(id: String) {
        guard !isClosed, let item = viewModel.items.first(where: { $0.id == id }) else { return }

        let status: BatchImportItemStatus
        let detail: String
        switch item.status {
        case .warning:
            status = .warning
            if item.detail.isEmpty {
                detail = "歌曲已导入，但歌词未完全就绪"
            } else if item.detail.hasPrefix("歌曲已") {
                detail = item.detail
            } else {
                detail = "歌曲已导入，\(item.detail)"
            }
        case .failed:
            status = .failed
            detail = item.detail.isEmpty ? "导入失败" : item.detail
        case .skipped:
            status = .skipped
            detail = item.detail.isEmpty ? "已跳过导入" : item.detail
        default:
            status = .success
            if item.detail.isEmpty {
                detail = "歌曲已成功导入"
            } else if item.detail.hasPrefix("歌曲已") {
                detail = item.detail
            } else {
                detail = "歌曲已导入，\(item.detail)"
            }
        }

        item.stage = .completed
        item.status = status
        item.detail = detail
    }

    func closeNow() {
        guard !isClosed else { return }
        isClosed = true
        panel?.close()
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        isClosed = true
        panel = nil
    }
}

private struct BatchImportProgressDialogView: View {
    @Bindable var viewModel: BatchImportProgressViewModel

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()
                .opacity(0.45)

            contentView
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(viewModel.stage.title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer()

                if viewModel.totalCount > 0 {
                    Text("\(viewModel.completedCount)/\(viewModel.totalCount)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            ProgressView(value: viewModel.progress)
                .progressViewStyle(.linear)

            Text(viewModel.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(.thinMaterial)
    }

    private var contentView: some View {
        VStack(spacing: 0) {
            if viewModel.sortedItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("歌曲列表将在扫描完成后显示。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 0) {
                        ForEach(viewModel.sortedItems) { item in
                            BatchImportProgressRowView(item: item)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 4)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }
}

private struct BatchImportProgressRowView: View {
    @Bindable var item: BatchImportProgressItemModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            statusIcon

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.title.isEmpty ? item.fileName : item.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    if !item.artist.isEmpty {
                        Text("- \(item.artist)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 8) {
                    Text(item.stage.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(item.status.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(statusColor)
                }

                Text(item.detail)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
                    .lineLimit(2)

                if let issueMessage = item.issueMessage, !issueMessage.isEmpty {
                    Text(issueMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.03))
        )
    }

    private var statusColor: Color {
        switch item.status {
        case .waiting:
            return .secondary
        case .active:
            return .blue
        case .success:
            return .green
        case .warning:
            return .orange
        case .skipped:
            return .secondary
        case .failed:
            return .red
        }
    }

    private var statusIcon: some View {
        Group {
            switch item.status {
            case .waiting:
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            case .active:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.blue)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .warning:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            case .skipped:
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
        .font(.system(size: 16))
        .frame(width: 20, height: 20)
    }
}
