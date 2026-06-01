//
//  LyricsFetchProgressDialog.swift
//  myPlayer2
//
//  kmgccc_player - Lyrics Fetch Progress Dialog
//  Shows lyrics search and save progress during import.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Lyrics Fetch Step

enum LyricsFetchStep {
    case waiting
    case searching
    case found
    case converting
    case savingTTML
    case completed
    case noResults
    case failed
    
    var description: String {
        switch self {
        case .waiting: return "等待中..."
        case .searching: return "正在搜索歌词..."
        case .found: return "找到歌词"
        case .converting: return "转换为 TTML..."
        case .savingTTML: return "保存 TTML..."
        case .completed: return "完成"
        case .noResults: return "未找到歌词"
        case .failed: return "失败"
        }
    }
}

// MARK: - Individual Item Model

@MainActor
@Observable
final class LyricsFetchProgressItemModel: Identifiable {
    let id: String
    let fileName: String
    var title: String
    var artist: String
    var step: LyricsFetchStep
    var errorMessage: String?
    
    init(
        id: String,
        fileName: String,
        title: String = "",
        artist: String = "",
        step: LyricsFetchStep = .waiting,
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
final class LyricsFetchProgressViewModel {
    var items: [LyricsFetchProgressItemModel]
    var isCancelled = false
    var displayProgress: Double = 0.0
    
    private let onComplete: (() -> Void)?
    private let onCancel: (() -> Void)?
    private var progressTimer: Timer?
    private var targetProgress: Double = 0.0
    
    init(
        items: [LyricsFetchProgressItemModel],
        onComplete: (() -> Void)? = nil,
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
    
    func updateItem(id: String, title: String, artist: String, step: LyricsFetchStep) {
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
    
    func markNoResults(id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        item.step = .noResults
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
        onComplete?()
    }
    
    var isAllCompleted: Bool {
        items.allSatisfy { $0.step == .completed || $0.step == .noResults || $0.step == .failed }
    }
    
    var completedItemsCount: Int {
        items.filter { $0.step == .completed }.count
    }
    
    var noResultsCount: Int {
        items.filter { $0.step == .noResults }.count
    }
    
    var failedCount: Int {
        items.filter { $0.step == .failed }.count
    }
    
    var hasAnyIssues: Bool {
        items.contains { $0.step == .noResults || $0.step == .failed }
    }
}

// MARK: - Presenter

@MainActor
final class LyricsFetchProgressDialogPresenter: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var viewModel: LyricsFetchProgressViewModel?
    private var completionHandler: (() -> Void)?
    private var hasCompleted = false
    private var startTime: Date?
    private var fetchTask: Task<Void, Never>?
    private var resultTracks: [Track] = []
    
    private static var activePresenter: LyricsFetchProgressDialogPresenter?
    
    private func complete() {
        guard !hasCompleted else { return }
        hasCompleted = true
        completionHandler?()
        Self.activePresenter = nil
    }
    
    @MainActor
    static func presentAndFetch(
        tracks: [Track],
        completion: @escaping ([Track]) -> Void
    ) {
        guard !tracks.isEmpty else {
            completion([])
            return
        }
        
        let items = tracks.map { track in
            LyricsFetchProgressItemModel(
                id: track.id.uuidString,
                fileName: track.title,
                title: track.title,
                artist: track.artist
            )
        }
        
        let presenter = LyricsFetchProgressDialogPresenter()
        presenter.resultTracks = tracks
        presenter.startTime = Date()
        
        Self.activePresenter = presenter
        
        let itemCount = items.count
        let shouldScroll = itemCount > AppDialogTokens.maxVisibleRows
        let windowHeight = AppDialogTokens.windowHeight(rowCount: itemCount)

        let (panel, visualEffect) = AppDialogTokens.makePanel(
            width: AppDialogTokens.progressDialogWidth,
            height: windowHeight
        )
        panel.delegate = presenter
        presenter.panel = panel
        
        let viewModel = LyricsFetchProgressViewModel(
            items: items,
            onComplete: { [weak presenter] in
                presenter?.finishWithMinimumDelay(completion: completion)
            },
            onCancel: { [weak presenter] in
                presenter?.complete(with: [], completion: completion)
                panel.close()
            }
        )
        presenter.viewModel = viewModel
        
        let visibleRowsHeight: CGFloat? = shouldScroll
            ? CGFloat(AppDialogTokens.maxVisibleRows) * AppDialogTokens.rowHeight
            : nil
        let rootView = LyricsFetchProgressDialogView(
            viewModel: viewModel,
            shouldScroll: shouldScroll,
            visibleRowsHeight: visibleRowsHeight
        )
        .frame(width: AppDialogTokens.progressDialogWidth, height: windowHeight)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: AppDialogTokens.progressDialogWidth, height: windowHeight)
        )
        hostingView.autoresizingMask = [.width, .height]
        
        visualEffect.addSubview(hostingView)
        AppDialogTokens.presentWithFade(panel)

        presenter.startFetchAsync(tracks: tracks, viewModel: viewModel)
    }
    
    private func finishWithMinimumDelay(completion: @escaping ([Track]) -> Void) {
        let minDisplayTime: TimeInterval = 1.5
        let elapsed = Date().timeIntervalSince(startTime ?? Date())
        let remaining = max(0, minDisplayTime - elapsed)
        
        Task { @MainActor in
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            complete(with: resultTracks, completion: completion)
            panel?.close()
        }
    }
    
    private func complete(with tracks: [Track], completion: @escaping ([Track]) -> Void) {
        guard !hasCompleted else { return }
        hasCompleted = true
        completion(tracks)
        Self.activePresenter = nil
    }
    
    private func startFetchAsync(tracks: [Track], viewModel: LyricsFetchProgressViewModel) {
        // Extract Sendable snapshots before entering detached task
        // (Track is a SwiftData @Model class, not Sendable)
        struct TrackSnapshot: Sendable {
            let id: String
            let title: String
            let artist: String
        }
        let snapshots: [TrackSnapshot] = tracks.map { track in
            TrackSnapshot(
                id: track.id.uuidString,
                title: track.title,
                artist: track.artist
            )
        }
        
        fetchTask = Task { @MainActor in
            let completedLyrics = await Task.detached(priority: .userInitiated) { @Sendable in
                let client = LDDCClient()
                let totalCount = snapshots.count

                actor ProgressState {
                    var completedCount = 0
                    var completedLyrics: [(id: String, ttml: String)] = []

                    func addCompleted(id: String, ttml: String?) {
                        completedCount += 1
                        if let ttml {
                            completedLyrics.append((id: id, ttml: ttml))
                        }
                    }

                    func getCompletedLyrics() -> [(id: String, ttml: String)] {
                        completedLyrics
                    }

                    func getProgress(totalCount: Int) -> Double {
                        return Double(completedCount) / Double(totalCount)
                    }
                }

                let state = ProgressState()

                await withTaskGroup(of: Void.self) { group in
                    for snapshot in snapshots {
                        group.addTask {
                            let itemId = snapshot.id

                            do {
                                await MainActor.run {
                                    viewModel.updateItem(id: itemId, title: snapshot.title, artist: snapshot.artist, step: .searching)
                                }

                                let response = try await client.search(
                                    title: snapshot.title,
                                    artist: snapshot.artist.isEmpty ? nil : snapshot.artist,
                                    sources: [.QM, .KG, .NE],
                                    mode: .verbatim,
                                    translation: true,
                                    limitPerSource: 5
                                )

                                guard let firstCandidate = response.results.first else {
                                    await state.addCompleted(id: itemId, ttml: nil)
                                    return
                                }

                                await MainActor.run {
                                    viewModel.updateItem(id: itemId, title: snapshot.title, artist: snapshot.artist, step: .found)
                                }

                                let (origLyrics, transLyrics) = try await client.fetchByIdSeparate(
                                    candidate: firstCandidate,
                                    mode: .verbatim
                                )

                                await MainActor.run {
                                    viewModel.updateItem(id: itemId, title: snapshot.title, artist: snapshot.artist, step: .converting)
                                }

                                let ttml: String
                                if let transLyrics = transLyrics, !transLyrics.isEmpty {
                                    ttml = try await TTMLConverter.shared.convertToTTMLWithTranslation(
                                        origLyrics: origLyrics,
                                        transLyrics: transLyrics,
                                        stripMetadata: false
                                    )
                                } else {
                                    ttml = try await TTMLConverter.shared.convertToTTML(
                                        rawLyrics: origLyrics,
                                        stripMetadata: false
                                    )
                                }

                                await MainActor.run {
                                    viewModel.updateItem(id: itemId, title: snapshot.title, artist: snapshot.artist, step: .savingTTML)
                                }

                                await state.addCompleted(id: itemId, ttml: ttml)
                            } catch {
                                await state.addCompleted(id: itemId, ttml: nil)
                            }
                        }
                    }

                    await group.waitForAll()
                }

                let progress = await state.getProgress(totalCount: totalCount)

                await MainActor.run {
                    viewModel.setProgress(progress * 0.95)
                }

                return await state.getCompletedLyrics()
            }.value

            for lyric in completedLyrics {
                if let track = tracks.first(where: { $0.id.uuidString == lyric.id }) {
                    track.ttmlLyricText = lyric.ttml
                }
            }

            viewModel.complete()
        }
    }
    
    func windowWillClose(_ notification: Notification) {
        if !hasCompleted {
            viewModel?.cancel()
        }
        fetchTask?.cancel()
    }
}

// MARK: - Dialog View

struct LyricsFetchProgressDialogView: View {
    @Bindable var viewModel: LyricsFetchProgressViewModel
    var shouldScroll: Bool
    var visibleRowsHeight: CGFloat?
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            if shouldScroll {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 0) {
                        ForEach(viewModel.items) { item in
                            LyricsFetchProgressRowView(item: item)
                                .padding(.horizontal, AppDialogTokens.contentHorizontalPadding)
                                .padding(.vertical, AppDialogTokens.contentRowVerticalPadding)
                        }
                    }
                    .padding(.vertical, AppDialogTokens.contentRowVerticalPadding)
                }
                .frame(height: visibleRowsHeight)
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.items) { item in
                        LyricsFetchProgressRowView(item: item)
                            .padding(.horizontal, AppDialogTokens.contentHorizontalPadding)
                            .padding(.vertical, AppDialogTokens.contentRowVerticalPadding)
                    }
                }
                .padding(.vertical, AppDialogTokens.contentRowVerticalPadding)
            }

            AppDialogDivider()

            footerView
        }
    }
    
    private var headerView: some View {
        AppDialogProgressHeader(
            title: "正在获取歌词",
            counterText: "\(viewModel.completedItemsCount)/\(viewModel.items.count)",
            progress: viewModel.displayProgress
        )
    }

    private var footerView: some View {
        HStack {
            if viewModel.isAllCompleted {
                if viewModel.hasAnyIssues {
                    VStack(alignment: .leading, spacing: 2) {
                        if viewModel.noResultsCount > 0 {
                            Text("\(viewModel.noResultsCount) 首未找到歌词")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if viewModel.failedCount > 0 {
                            Text("\(viewModel.failedCount) 首获取失败")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                } else {
                    Text("歌词获取完成")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                }
            } else {
                Text("处理中...")
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
            .buttonStyle(
                AppDialogGlassButtonStyle(
                    kind: viewModel.isAllCompleted ? .primary : .secondary,
                    tint: ThemeStore.shared.accentColor
                )
            )
        }
        .padding(.horizontal, AppDialogTokens.footerHorizontalPadding)
        .padding(.top, AppDialogTokens.footerVerticalPadding)
        .padding(.bottom, AppDialogTokens.footerBottomPadding)
        .background(.thinMaterial)
    }
}

// MARK: - Progress Row View

struct LyricsFetchProgressRowView: View {
    @Bindable var item: LyricsFetchProgressItemModel

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
        .padding(.horizontal, AppDialogTokens.rowHorizontalPadding)
        .padding(.vertical, AppDialogTokens.rowVerticalPadding)
        .appDialogRowBackground()
    }
    
    private var stepColor: Color {
        switch item.step {
        case .waiting: return .secondary
        case .searching: return .blue
        case .found: return .cyan
        case .converting: return .orange
        case .savingTTML: return .indigo
        case .completed: return .green
        case .noResults: return .orange
        case .failed: return .red
        }
    }
    
    private var statusIcon: some View {
        Group {
            switch item.step {
            case .waiting:
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            case .searching, .converting, .savingTTML:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.blue)
            case .found:
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.cyan)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .noResults:
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.orange)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
        .font(.system(size: 16))
        .frame(width: 20, height: 20)
    }
}

// MARK: - Preview

#Preview {
    let items = [
        LyricsFetchProgressItemModel(
            id: "1",
            fileName: "song1.mp3",
            title: "歌曲名称",
            artist: "艺术家",
            step: .searching
        ),
        LyricsFetchProgressItemModel(
            id: "2",
            fileName: "song2.mp3",
            title: "歌曲名称 2",
            artist: "艺术家 2",
            step: .completed
        ),
        LyricsFetchProgressItemModel(
            id: "3",
            fileName: "song3.mp3",
            title: "歌曲名称 3",
            artist: "艺术家 3",
            step: .noResults
        )
    ]
    
    let viewModel = LyricsFetchProgressViewModel(
        items: items,
        onComplete: {},
        onCancel: nil
    )
    
    LyricsFetchProgressDialogView(viewModel: viewModel, shouldScroll: false, visibleRowsHeight: nil)
        .frame(width: 580, height: 300)
}
