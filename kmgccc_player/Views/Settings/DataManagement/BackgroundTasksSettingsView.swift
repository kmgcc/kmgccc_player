//
//  BackgroundTasksSettingsView.swift
//  myPlayer2
//
//  kmgccc_player - The "background tasks" tab of the data settings: one switch
//  for idle preparation, the pace, and a card for each task the App prepares
//  while the computer is quiet.
//

import SwiftUI

struct BackgroundTasksSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryCacheServices.self) private var cacheServices
    @EnvironmentObject private var appSession: AppSessionHost
    @EnvironmentObject private var themeStore: ThemeStore
    @ObservedObject private var updateCoordinator = UpdateCoordinator.shared

    private var scheduler: BackgroundWorkScheduler { appSession.backgroundWorkScheduler }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            generalSection
            taskSection
        }
    }

    // MARK: - General

    private var generalSection: some View {
        SettingsSection("后台任务") {
            VStack(alignment: .leading, spacing: 14) {
                SettingsSwitchRow(
                    title: "空闲时提前准备",
                    isOn: preparationBinding,
                    detail: "接通电源且空闲时提前分析响度、整理封面与歌词；使用电池时，仅准备即将播放的歌曲。"
                )

                Divider()

                CapsulePicker(
                    label: "处理节奏",
                    options: BackgroundPacingMode.allCases,
                    selection: pacingBinding,
                    displayName: { Self.pacingTitle($0) }
                )

                Text("轻缓计算更放松，且每项工作之间稍作停歇，电脑更安静、更凉爽。")
                    .settingsDescriptionStyle()
            }
        }
    }

    private var preparationBinding: Binding<Bool> {
        Binding(
            get: { settings.backgroundPreparationEnabled },
            set: { settings.backgroundPreparationEnabled = $0 }
        )
    }

    private var pacingBinding: Binding<BackgroundPacingMode> {
        Binding(
            get: { settings.backgroundPacingMode },
            set: { settings.backgroundPacingMode = $0 }
        )
    }

    private static func pacingTitle(_ mode: BackgroundPacingMode) -> String {
        switch mode {
        case .gentle: "轻缓"
        case .fast: "尽快完成"
        }
    }

    // MARK: - Cards

    private var taskSection: some View {
        SettingsSection("任务") {
            // Progress comes from the domain services, which do not publish
            // every step; refresh on a slow clock while the page is open.
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                VStack(spacing: 10) {
                    ForEach(cards) { card in
                        BackgroundTaskCardView(
                            card: card,
                            isOn: card.controlledDomains.map(domainBinding)
                        )
                    }
                }
            }
        }
    }

    private var cards: [BackgroundTaskCard] {
        var result: [BackgroundTaskCard] = []
        if let loudness = loudnessCard { result.append(loudness) }
        result.append(artworkAndColorsCard)
        result.append(thumbnailsCard)
        result.append(nextSongCard)
        result.append(lyricsIndexCard)
        if let update = appUpdateCard { result.append(update) }
        result.append(maintenanceCard)
        if let sources = sourceSyncCard { result.append(sources) }
        return result
    }

    private func domainBinding(_ domains: [BackgroundWorkDomain]) -> Binding<Bool> {
        Binding(
            get: { !domains.contains { settings.backgroundDisabledDomains.contains($0) } },
            set: { enabled in
                var disabled = settings.backgroundDisabledDomains
                for domain in domains {
                    if enabled { disabled.remove(domain) } else { disabled.insert(domain) }
                }
                settings.backgroundDisabledDomains = disabled
            }
        )
    }

    /// The reason work in `domain` is waiting, when something is waiting.
    private func waitNote(
        _ domain: BackgroundWorkDomain,
        resources: BackgroundWorkResources,
        priority: BackgroundWorkPriority = .idleBatch,
        hasWork: Bool
    ) -> String? {
        guard hasWork else { return nil }
        if scheduler.activity(of: domain).running > 0 { return nil }
        return scheduler.waitReason(for: domain, resources: resources, priority: priority)?.message
    }

    private var loudnessCard: BackgroundTaskCard? {
        guard appSession.audioProcessingGlobalsController.configuration.loudness.enabled,
              let session = appSession.activeLibraryBinding.activeSession else { return nil }
        let ids = session.libraryViewModel.allTracks.map(\.id)
        let progress = session.loudnessService.libraryProgress(trackIDs: ids)
        let status = progress.remaining > 0
            ? "已测量 \(progress.measured.formatted()) 首，剩余 \(progress.remaining.formatted()) 首"
            : "已测量 \(progress.measured.formatted()) 首"
        let reason = session.loudnessService.isIdleScanPausedByListener && progress.remaining > 0
            ? "已暂停"
            : waitNote(.loudness, resources: [.compute, .disk], hasWork: progress.remaining > 0)
        return BackgroundTaskCard(
            id: "loudness", title: "响度测量", systemImage: "waveform",
            status: status, note: reason, controlledDomains: nil
        )
    }

    private var artworkAndColorsCard: BackgroundTaskCard {
        let colors = cacheServices.artworkColorSource?.progress ?? .empty
        let covers = cacheServices.missingPlaylistArtworkSource?.progress ?? .empty
        let remaining = colors.remaining + covers.remaining
        let status = remaining > 0
            ? "已准备 \(colors.completed.formatted()) 首，剩余 \(remaining.formatted()) 项"
            : "已准备 \(colors.completed.formatted()) 首"
        let reason = waitNote(.artworkColors, resources: [.compute, .disk], hasWork: remaining > 0)
        return BackgroundTaskCard(
            id: "covers", title: "封面与颜色", systemImage: "paintpalette",
            status: status, note: reason,
            controlledDomains: [.artworkColors, .missingArtwork]
        )
    }

    private var thumbnailsCard: BackgroundTaskCard {
        let domains: [BackgroundWorkDomain] = [.homeArtwork, .listArtwork, .pageThumbnails]
        let prepared = cacheServices.pageThumbnailSource?.progress ?? .empty
        let activity = combinedActivity(domains)
        let status: String
        if prepared.remaining > 0 {
            status = "已准备 \(prepared.completed.formatted()) 张，剩余 \(prepared.remaining.formatted()) 张"
        } else if prepared.completed > 0 {
            status = "已准备 \(prepared.completed.formatted()) 张"
        } else if activity.running > 0 {
            status = "正在准备"
        } else {
            status = "打开首页后开始准备"
        }
        let pending = !activity.isIdle || prepared.remaining > 0
        return BackgroundTaskCard(
            id: "thumbnails", title: "常用页面缩略图", systemImage: "square.grid.2x2",
            status: status,
            note: waitNote(.pageThumbnails, resources: [.compute, .disk], hasWork: pending),
            controlledDomains: domains
        )
    }

    private var nextSongCard: BackgroundTaskCard {
        let domains: [BackgroundWorkDomain] = [.playbackArtwork, .nextSongLyrics]
        let activity = combinedActivity(domains)
        let status: String
        if activity.running > 0 {
            status = "正在为下一首准备"
        } else if !activity.isIdle {
            status = "等待准备"
        } else {
            status = "已为下一首准备好"
        }
        return BackgroundTaskCard(
            id: "next-song", title: "下一首预加载", systemImage: "forward.end",
            status: status,
            note: waitNote(.playbackArtwork, resources: [.compute, .disk], priority: .upcoming, hasWork: !activity.isIdle),
            controlledDomains: domains
        )
    }

    private var lyricsIndexCard: BackgroundTaskCard {
        let activity = scheduler.activity(of: .lyricsIndex)
        let status: String
        if activity.running > 0 {
            status = "正在更新"
        } else if !activity.isIdle {
            status = "等待更新"
        } else if cacheServices.amllDBRawIndexCache.hasLocalCache() {
            status = "已是最新"
        } else {
            status = "搜索歌词时自动获取"
        }
        return BackgroundTaskCard(
            id: "lyrics-index", title: "歌词库更新", systemImage: "text.quote",
            status: status,
            note: waitNote(.lyricsIndex, resources: [.network, .compute], hasWork: !activity.isIdle),
            controlledDomains: [.lyricsIndex]
        )
    }

    private var appUpdateCard: BackgroundTaskCard? {
        let status: String
        var note: String?
        if updateCoordinator.readyUpdate != nil {
            status = "新版本已下载，退出时安装"
        } else if case .downloading = updateCoordinator.state {
            status = "正在下载新版本"
        } else if case .preparing = updateCoordinator.state {
            status = "正在准备新版本"
        } else if updateCoordinator.isDownloadDeferred {
            status = "发现新版本，等待空闲时下载"
            note = scheduler.waitReason(for: .appUpdate, resources: [.network])?.message
        } else {
            return nil
        }
        return BackgroundTaskCard(
            id: "app-update", title: "应用更新", systemImage: "arrow.down.circle",
            status: status, note: note, controlledDomains: nil
        )
    }

    private var maintenanceCard: BackgroundTaskCard {
        let domains: [BackgroundWorkDomain] = [.cacheMaintenance, .libraryMaintenance]
        let activity = combinedActivity(domains)
        let status: String
        if activity.running > 0 {
            status = "正在整理"
        } else if !activity.isIdle {
            status = "等待整理"
        } else if let date = domains.compactMap({ scheduler.lastCompletion(of: $0) }).max() {
            status = "\(Self.relativeTime(date))已整理"
        } else {
            status = "每次启动后整理一次"
        }
        return BackgroundTaskCard(
            id: "maintenance", title: "缓存整理", systemImage: "externaldrive",
            status: status,
            note: waitNote(.cacheMaintenance, resources: [.disk], hasWork: !activity.isIdle),
            controlledDomains: nil
        )
    }

    private var sourceSyncCard: BackgroundTaskCard? {
        guard let session = appSession.activeLibraryBinding.activeSession,
              session.context.mode == .referenced else { return nil }
        let scanning = appSession.referencedSourceScanStatesSnapshot.values.contains(.scanning)
        let failed = appSession.referencedSourceScanStatesSnapshot.values.filter { $0 == .failed }.count
        let status: String
        if scanning || scheduler.activity(of: .sourceSync).running > 0 {
            status = "正在同步"
        } else if failed > 0 {
            status = "已同步 · \(failed) 个来源未能读取"
        } else {
            status = "已与文件夹保持一致"
        }
        return BackgroundTaskCard(
            id: "source-sync", title: "来源同步", systemImage: "folder",
            status: status, note: nil, controlledDomains: nil
        )
    }

    private func combinedActivity(_ domains: [BackgroundWorkDomain]) -> BackgroundDomainActivity {
        var total = BackgroundDomainActivity()
        for domain in domains {
            let activity = scheduler.activity(of: domain)
            total.running += activity.running
            total.paused += activity.paused
            total.waiting += activity.waiting
        }
        return total
    }

    private static func relativeTime(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "今天 \(time) " }
        if Calendar.current.isDateInYesterday(date) { return "昨天 \(time) " }
        return "\(date.formatted(.dateTime.month().day())) "
    }
}

/// One card's content, assembled from the scheduler and the domain services.
private struct BackgroundTaskCard: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let status: String
    /// Why the task is waiting, when it is.
    let note: String?
    /// Domains the card's switch turns on and off; nil when the task has no
    /// switch of its own.
    let controlledDomains: [BackgroundWorkDomain]?
}

private struct BackgroundTaskCardView: View {
    let card: BackgroundTaskCard
    let isOn: Binding<Bool>?

    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: card.systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(themeStore.accentColor)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(card.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
                Text(card.status)
                    .settingsDescriptionStyle()
                if let note = card.note {
                    Text(note)
                        .settingsDescriptionStyle()
                }
            }

            Spacer(minLength: 12)

            if let isOn {
                Toggle("", isOn: isOn)
                    .toggleStyle(.switch)
                    .tint(themeStore.accentColor)
                    .labelsHidden()
                    .accessibilityLabel(Text(card.title))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}
