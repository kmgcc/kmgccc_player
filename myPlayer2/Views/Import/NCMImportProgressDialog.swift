//
//  NCMImportProgressDialog.swift
//  myPlayer2
//
//  kmgccc_player - NCM 导入进度对话框
//  显示 NCM 文件转换进度
//

import AppKit
import Combine
import SwiftUI

// MARK: - Individual Item Model (Observable for fine-grained updates)

@MainActor
@Observable
final class NCMProgressItemModel: Identifiable {
    let id: String
    let fileName: String
    var title: String
    var artist: String
    var step: NCMConversionStep
    var errorMessage: String?
    
    init(
        id: String,
        fileName: String,
        title: String = "",
        artist: String = "",
        step: NCMConversionStep = .waiting,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.title = title
        self.artist = artist
        self.step = step
        self.errorMessage = errorMessage
    }
}

// MARK: - View Model

@MainActor
@Observable
final class NCMImportProgressViewModel {
    var items: [NCMProgressItemModel]
    var isCancelled = false
    var displayProgress: Double = 0.0
    
    private let onComplete: (([NCMConversionResult]) -> Void)?
    private let onCancel: (() -> Void)?
    private var results: [NCMConversionResult] = []
    private var progressTimer: Timer?
    private var targetProgress: Double = 0.0
    
    init(
        items: [NCMProgressItemModel],
        onComplete: (([NCMConversionResult]) -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.items = items
        self.onComplete = onComplete
        self.onCancel = onCancel
        startSmoothProgress()
    }
    
    private func startSmoothProgress() {
        displayProgress = 0.0
        targetProgress = 0.0
        
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self else { return }
            
            Task { @MainActor [weak self] in
                guard let self else { return }
                
                if self.displayProgress < self.targetProgress {
                    self.displayProgress += 0.02
                    if self.displayProgress > self.targetProgress {
                        self.displayProgress = self.targetProgress
                    }
                }
            }
        }
    }
    
    func setProgress(_ progress: Double) {
        targetProgress = min(progress, 0.95)
    }
    
    func updateItem(id: String, title: String, artist: String, step: NCMConversionStep) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        item.title = title.isEmpty ? item.fileName : title
        item.artist = artist
        item.step = step
    }
    
    func markFailed(id: String, error: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        item.step = .failed
        item.errorMessage = error
    }
    
    func addResult(_ result: NCMConversionResult) {
        results.append(result)
    }
    
    func cancel() {
        isCancelled = true
        progressTimer?.invalidate()
        progressTimer = nil
        onCancel?()
    }
    
    func complete() {
        targetProgress = 1.0
        progressTimer?.invalidate()
        progressTimer = nil
        displayProgress = 1.0
        onComplete?(results)
    }
    
    var isAllCompleted: Bool {
        items.allSatisfy { $0.step == .completed || $0.step == .failed }
    }
    
    var completedItemsCount: Int {
        items.filter { $0.step == .completed }.count
    }
    
    var hasAnyFailed: Bool {
        items.contains { $0.step == .failed }
    }
}

// MARK: - Presenter

@MainActor
final class NCMImportProgressDialogPresenter: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var viewModel: NCMImportProgressViewModel?
    private var completionHandler: (([NCMConversionResult]?) -> Void)?
    private var hasCompleted = false
    private var startTime: Date?
    private var conversionTask: Task<Void, Never>?
    
    // Static storage to retain presenter during conversion
    private static var activePresenter: NCMImportProgressDialogPresenter?
    
    private func complete(with results: [NCMConversionResult]?) {
        guard !hasCompleted else { return }
        hasCompleted = true
        completionHandler?(results)
        Self.activePresenter = nil
    }
    
    @MainActor
    static func present(
        ncmFiles: [URL],
        completion: @escaping ([NCMConversionResult]?) -> Void
    ) {
        let items = ncmFiles.map { url in
            NCMProgressItemModel(
                id: url.path,
                fileName: url.lastPathComponent
            )
        }
        
        let presenter = NCMImportProgressDialogPresenter()
        presenter.completionHandler = completion
        presenter.startTime = Date()
        
        Self.activePresenter = presenter
        
        // Layout constants
        let rowTotalHeight: CGFloat = 52
        let headerHeight: CGFloat = 80
        let footerHeight: CGFloat = 60
        let listVerticalPadding: CGFloat = 8
        let maxItemsWithoutScroll = 9
        
        let itemCount = items.count
        let shouldScroll = itemCount > maxItemsWithoutScroll
        
        let windowHeight: CGFloat
        if shouldScroll {
            let visibleRowsHeight = CGFloat(maxItemsWithoutScroll) * rowTotalHeight
            windowHeight = headerHeight + visibleRowsHeight + listVerticalPadding + footerHeight
        } else {
            let rowsHeight = CGFloat(itemCount) * rowTotalHeight
            windowHeight = headerHeight + rowsHeight + listVerticalPadding + footerHeight
        }
        
        let windowSize = NSSize(width: 580, height: windowHeight)
        
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
        panel.delegate = presenter
        
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .popover
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.frame = NSRect(origin: .zero, size: windowSize)
        visualEffect.autoresizingMask = [.width, .height]
        panel.contentView = visualEffect
        
        presenter.panel = panel
        
        let viewModel = NCMImportProgressViewModel(
            items: items,
            onComplete: { [weak presenter] results in
                presenter?.finishWithMinimumDelay(results: results)
            },
            onCancel: { [weak presenter] in
                presenter?.complete(with: nil)
                panel.close()
            }
        )
        presenter.viewModel = viewModel
        
        let rootView = NCMImportProgressDialogView(
            viewModel: viewModel,
            shouldScroll: shouldScroll,
            visibleRowsHeight: shouldScroll ? CGFloat(maxItemsWithoutScroll) * rowTotalHeight : nil
        )
        .frame(width: 580, height: windowHeight)
        
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: windowSize)
        hostingView.autoresizingMask = [.width, .height]
        
        visualEffect.addSubview(hostingView)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        
        // Start conversion asynchronously - use DispatchQueue to ensure it doesn't block
        presenter.startConversionAsync(ncmFiles: ncmFiles, viewModel: viewModel)
    }
    
    private func finishWithMinimumDelay(results: [NCMConversionResult]) {
        let minDisplayTime: TimeInterval = 1.5
        let elapsed = Date().timeIntervalSince(startTime ?? Date())
        let remaining = max(0, minDisplayTime - elapsed)
        
        Task { @MainActor in
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            complete(with: results)
            panel?.close()
        }
    }
    
    private func startConversionAsync(ncmFiles: [URL], viewModel: NCMImportProgressViewModel) {
        conversionTask = Task.detached(priority: .userInitiated) {
            let totalCount = ncmFiles.count
            
            actor ConversionState {
                var completedCount = 0
                var pendingUpdates: [(id: String, title: String, artist: String, step: NCMConversionStep, result: NCMConversionResult?)] = []
                var lastUpdateTime = Date()
                let updateInterval: TimeInterval = 0.5
                
                func addCompleted(id: String, result: NCMConversionResult?) -> Bool {
                    completedCount += 1
                    if let result = result {
                        pendingUpdates.append((id: id, title: "", artist: "", step: .completed, result: result))
                    } else {
                        pendingUpdates.append((id: id, title: "", artist: "", step: .failed, result: nil))
                    }
                    
                    let now = Date()
                    let shouldFlush = now.timeIntervalSince(lastUpdateTime) >= updateInterval
                    if shouldFlush {
                        lastUpdateTime = now
                    }
                    return shouldFlush
                }
                
                func getAndClearPendingUpdates() -> [(id: String, title: String, artist: String, step: NCMConversionStep, result: NCMConversionResult?)] {
                    let updates = pendingUpdates
                    pendingUpdates.removeAll()
                    return updates
                }
                
                func getProgress(totalCount: Int) -> Double {
                    return Double(completedCount) / Double(totalCount)
                }
            }
            
            let state = ConversionState()
            let maxConcurrent = min(4, ProcessInfo.processInfo.processorCount)
            
            await withTaskGroup(of: Void.self) { group in
                var activeCount = 0
                
                for ncmFile in ncmFiles {
                    if Task.isCancelled { break }
                    
                    while activeCount >= maxConcurrent {
                        await group.next()
                        activeCount -= 1
                    }
                    
                    if Task.isCancelled { break }
                    
                    activeCount += 1
                    group.addTask {
                        let itemId = ncmFile.path
                        var conversionResult: NCMConversionResult?
                        
                        do {
                            let converter = NCMConverter()
                            conversionResult = try await converter.convert(
                                from: ncmFile,
                                fetchCover: true,
                                progressHandler: nil
                            )
                        } catch {
                            print("❌ NCM conversion failed: \(error.localizedDescription)")
                        }
                        
                        let shouldFlush = await state.addCompleted(id: itemId, result: conversionResult)
                        
                        if shouldFlush {
                            let updates = await state.getAndClearPendingUpdates()
                            let progress = await state.getProgress(totalCount: totalCount)
                            
                            await MainActor.run {
                                for update in updates {
                                    if let result = update.result {
                                        viewModel.updateItem(
                                            id: update.id,
                                            title: result.metadata.title,
                                            artist: result.metadata.artistName,
                                            step: .completed
                                        )
                                        viewModel.addResult(result)
                                    } else {
                                        viewModel.updateItem(
                                            id: update.id,
                                            title: update.title,
                                            artist: update.artist,
                                            step: .failed
                                        )
                                    }
                                }
                                viewModel.setProgress(progress * 0.95)
                            }
                        }
                    }
                }
                
                await group.waitForAll()
            }
            
            // Final flush
            let updates = await state.getAndClearPendingUpdates()
            let progress = await state.getProgress(totalCount: totalCount)
            
            await MainActor.run {
                for update in updates {
                    if let result = update.result {
                        viewModel.updateItem(
                            id: update.id,
                            title: result.metadata.title,
                            artist: result.metadata.artistName,
                            step: .completed
                        )
                        viewModel.addResult(result)
                    }
                }
                viewModel.setProgress(progress * 0.95)
                viewModel.complete()
            }
        }
    }
    
    func windowWillClose(_ notification: Notification) {
        if !hasCompleted {
            viewModel?.cancel()
        }
        conversionTask?.cancel()
    }
}

// MARK: - Dialog View

struct NCMImportProgressDialogView: View {
    @Bindable var viewModel: NCMImportProgressViewModel
    var shouldScroll: Bool
    var visibleRowsHeight: CGFloat?
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            if shouldScroll {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 0) {
                        ForEach(viewModel.items) { item in
                            NCMProgressRowView(item: item)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 4)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: visibleRowsHeight)
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.items) { item in
                        NCMProgressRowView(item: item)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                    }
                }
                .padding(.vertical, 4)
            }
            
            Divider()
                .opacity(0.5)
            
            footerView
        }
    }
    
    private var headerView: some View {
        VStack(spacing: 8) {
            HStack {
                Text("正在导入 NCM 文件")
                    .font(.headline)
                    .foregroundStyle(.primary)
                
                Spacer()
                
                Text("\(viewModel.completedItemsCount)/\(viewModel.items.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            ProgressView(value: viewModel.displayProgress)
                .progressViewStyle(.linear)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.thinMaterial)
    }
    
    private var footerView: some View {
        HStack {
            if viewModel.isAllCompleted {
                if viewModel.hasAnyFailed {
                    Text("部分转换失败")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                } else {
                    Text("转换完成")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                }
            } else {
                Text("转换中...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button(viewModel.isAllCompleted ? "完成" : "取消") {
                if viewModel.isAllCompleted {
                    viewModel.complete()
                } else {
                    viewModel.cancel()
                }
            }
            .keyboardShortcut(viewModel.isAllCompleted ? .defaultAction : .cancelAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.thinMaterial)
    }
}

// MARK: - Progress Row View

struct NCMProgressRowView: View {
    @Bindable var item: NCMProgressItemModel
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        HStack(spacing: 12) {
            statusIcon
            
            VStack(alignment: .leading, spacing: 2) {
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
                
                Text(item.step.description)
                    .font(.caption2)
                    .foregroundStyle(stepColor)
                
                if let error = item.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.03))
        )
    }
    
    private var stepColor: Color {
        switch item.step {
        case .waiting: return .secondary
        case .decrypting: return .blue
        case .downloadingCover: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }
    
    private var statusIcon: some View {
        Group {
            switch item.step {
            case .waiting:
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            case .decrypting, .downloadingCover:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.blue)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
        .font(.system(size: 16))
        .frame(width: 20, height: 20)
    }
}

#Preview {
    let items = [
        NCMProgressItemModel(
            id: "1",
            fileName: "song1.ncm",
            title: "歌曲名称",
            artist: "艺术家",
            step: .decrypting
        ),
        NCMProgressItemModel(
            id: "2",
            fileName: "song2.ncm",
            title: "歌曲名称 2",
            artist: "艺术家 2",
            step: .completed
        )
    ]
    
    let viewModel = NCMImportProgressViewModel(
        items: items,
        onComplete: { _ in },
        onCancel: nil
    )
    
    NCMImportProgressDialogView(viewModel: viewModel, shouldScroll: false, visibleRowsHeight: nil)
        .frame(width: 580, height: 300)
}