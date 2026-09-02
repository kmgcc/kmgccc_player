//
//  PlaybackHistoryView.swift
//  myPlayer2
//
//  Timeline view for effective local-library playback sessions.
//

import AppKit
import SwiftUI

private struct PlaybackHistoryDeletionRequest: Identifiable {
    let eventIDs: Set<UUID>
    let id = UUID()

    var message: String {
        String(
            format: NSLocalizedString("context.delete_history_confirm_message", comment: ""),
            eventIDs.count
        )
    }
}

struct PlaybackHistoryView: View {
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(PlaybackHistoryStore.self) private var historyStore
    @Environment(PlaybackHistoryViewModel.self) private var historyVM
    @Environment(UIStateViewModel.self) private var uiState
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var toolbarTopInset: CGFloat = 0
    @State private var trackToEdit: Track?
    @State private var deletionRequest: PlaybackHistoryDeletionRequest?

    var body: some View {
        let filterDate = uiState.playbackHistoryDate
        let visibleItems = historyVM.visibleItems
        let tracksByID = Dictionary(uniqueKeysWithValues: libraryVM.allTracks.map { ($0.id, $0) })
        let queueTracks = uniquePlayableTracks(from: visibleItems, tracksByID: tracksByID)
        let sections = makeSections(visibleItems, filteredTo: filterDate)

        Group {
            if historyVM.isLoading {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sections.isEmpty {
                VStack(spacing: 18) {
                    emptyState(filterDate: filterDate)
                    olderHistoryControl(filterDate: filterDate)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                historyList(
                    sections: sections,
                    tracksByID: tracksByID,
                    queueTracks: queueTracks,
                    filterDate: filterDate
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            PlaylistTopChromeInsetReader(topInset: $toolbarTopInset)
                .allowsHitTesting(false)
        )
        .sheet(item: $trackToEdit) { track in
            TrackEditSheet(track: track)
        }
        .alert(
            NSLocalizedString("context.delete_history_confirm_title", comment: ""),
            isPresented: Binding(
                get: { deletionRequest != nil },
                set: { if !$0 { deletionRequest = nil } }
            ),
            presenting: deletionRequest
        ) { request in
            Button(
                NSLocalizedString("context.delete_confirm", comment: ""),
                role: .destructive
            ) {
                let eventIDs = request.eventIDs
                deletionRequest = nil
                historyVM.delete(eventIDs: eventIDs, using: historyStore)
            }
            Button(
                NSLocalizedString("edit.track.cancel", comment: ""),
                role: .cancel
            ) {
                deletionRequest = nil
            }
        } message: { request in
            Text(request.message)
        }
        .task(id: loadToken(filterDate: filterDate)) {
            historyVM.load(using: historyStore, filterDate: filterDate)
        }
        .onReceive(NotificationCenter.default.publisher(for: .playbackTrackDidChange)) { _ in
            historyVM.notePlaybackTrackChanged(to: playerVM.currentTrack?.id)
        }
        .onChange(of: uiState.playbackHistoryDate) { _, _ in
            historyVM.clearMultiselectState()
        }
        .onDisappear {
            historyVM.clearMultiselectState()
        }
        .background(
            MultiselectExitKeyMonitor(
                isEnabled: historyVM.isMultiselectMode,
                onEscape: {
                    historyVM.clearMultiselectState()
                },
                onReturn: {
                    historyVM.clearMultiselectState()
                }
            )
        )
        .onExitCommand {
            if historyVM.isMultiselectMode {
                historyVM.clearMultiselectState()
            }
        }
    }

    private func historyList(
        sections: [PlaybackHistorySection],
        tracksByID: [UUID: Track],
        queueTracks: [Track],
        filterDate: Date?
    ) -> some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                historyRow(
                                    item,
                                    tracksByID: tracksByID,
                                    queueTracks: queueTracks
                                )
                            }
                        } header: {
                            sectionHeader(
                                section,
                                addsTopSpacing: section.id != sections.first?.id
                            )
                        }
                    }

                    olderHistoryControl(filterDate: filterDate)
                        .padding(.top, 24)
                }
                // This is intentionally a blank chrome placeholder. The
                // toolbar is AppKit-owned and overlays the center pane just as
                // it does for All Songs, so rows must start below that inset.
                .padding(.top, 16 + toolbarTopInset)
                .padding(.horizontal)
                .padding(.bottom, 160)
            }
            .frame(width: proxy.size.width, height: proxy.size.height + toolbarTopInset)
            .offset(y: -toolbarTopInset)
            .scrollIndicators(.automatic)
        }
    }

    private func sectionHeader(
        _ section: PlaybackHistorySection,
        addsTopSpacing: Bool
    ) -> some View {
        Text(section.title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
            .padding(.horizontal, 4)
            .padding(.top, addsTopSpacing ? 24 : 0)
            .padding(.bottom, 8)
    }

    private func historyRow(
        _ item: PlaybackHistoryItem,
        tracksByID: [UUID: Track],
        queueTracks: [Track]
    ) -> some View {
        let play = {
            guard let track = tracksByID[item.trackID], track.availability != .missing else {
                return
            }
            historyVM.setActiveEvent(item.id)
            playbackCoordinator.playTrack(
                track,
                inQueueFrom: queueTracks,
                libraryQueueSource: .librarySelection("playback-history")
            )
        }

        // Keep this shell identical to the All Songs row shell: no lyric
        // snippet and no extra divider inserted into the row height.
        return PlaybackHistoryTrackRow(
            item: item,
            track: tracksByID[item.trackID],
            isPlaying: historyVM.activeEventID == item.id
                && playerVM.currentTrack?.id == item.trackID,
            isSelected: historyVM.selectedEventIDs.contains(item.id),
            isMultiselectMode: historyVM.isMultiselectMode,
            hasSelectedEvents: historyVM.hasSelectedEvents,
            playbackCoordinator: playbackCoordinator,
            onTap: { isShiftPressed in
                // Read the shared model at event time. The row can outlive the
                // render pass that created its gesture closure, especially
                // across an AppKit toolbar action that enables multiselect.
                if historyVM.isMultiselectMode {
                    historyVM.toggleSelection(for: item.id, extendingRange: isShiftPressed)
                    return
                }
                play()
            },
            onPlay: play,
            onDelete: {
                let eventIDs = historyVM.isMultiselectMode
                    ? historyVM.selectedEventIDs
                    : Set([item.id])
                guard !eventIDs.isEmpty else { return }
                deletionRequest = PlaybackHistoryDeletionRequest(eventIDs: eventIDs)
            },
            onEditTrack: { trackToEdit = $0 },
            rowPrimaryColor: themeStore.appForegroundPalette.primaryColor,
            rowSecondaryColor: themeStore.appForegroundPalette.secondaryColor,
            rowTertiaryColor: themeStore.appForegroundPalette.tertiaryColor
        )
    }

    @ViewBuilder
    private func olderHistoryControl(filterDate: Date?) -> some View {
        let canShow = filterDate == nil
            && !historyVM.hasActiveSearch
            && historyVM.searchRange == .all
            && (historyVM.olderItemsLoaded || historyVM.olderItemCount > 0)
        if canShow {
            Button {
                historyVM.setOlderItemsLoaded(!historyVM.olderItemsLoaded)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: historyVM.olderItemsLoaded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                    Text(historyVM.olderItemsLoaded ? "收起更早记录" : "加载更早记录")
                    if !historyVM.olderItemsLoaded {
                        Text("· (historyVM.olderItemCount) 条")
                            .foregroundStyle(themeStore.appForegroundPalette.tertiaryColor)
                    }
                    Spacer()
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func emptyState(filterDate: Date?) -> some View {
        let hasOlderRecords = filterDate == nil
            && !historyVM.hasActiveSearch
            && historyVM.olderItemCount > 0
        return VStack(spacing: 10) {
            Image(systemName: filterDate == nil ? "clock.arrow.circlepath" : "calendar.badge.exclamationmark")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(
                filterDate == nil
                    ? (hasOlderRecords ? "最近没有播放记录" : "还没有播放记录")
                    : "这一天没有播放记录"
            )
                .font(.headline)
                .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
            Text(
                filterDate == nil
                    ? (hasOlderRecords ? "更早的记录已折叠在下面" : "")
                    : " "
            )
                .font(.callout)
                .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
        }
        .frame(maxWidth: .infinity)
    }

    private func loadToken(filterDate: Date?) -> String {
        let dateToken = filterDate.map { String($0.timeIntervalSince1970) } ?? "all"
        return [
            String(historyStore.revision),
            dateToken,
            historyVM.olderItemsLoaded ? "expanded" : "collapsed",
            historyVM.searchRange.rawValue,
            historyVM.hasActiveSearch ? "search" : "idle"
        ].joined(separator: "-")
    }

    private func uniquePlayableTracks(
        from items: [PlaybackHistoryItem],
        tracksByID: [UUID: Track]
    ) -> [Track] {
        var seen = Set<UUID>()
        return items.compactMap { item in
            guard let track = tracksByID[item.trackID], track.availability != .missing else {
                return nil
            }
            guard seen.insert(track.id).inserted else { return nil }
            return track
        }
    }

    private func makeSections(
        _ items: [PlaybackHistoryItem],
        filteredTo date: Date?
    ) -> [PlaybackHistorySection] {
        let calendar = Calendar.current
        if let date {
            let day = calendar.startOfDay(for: date)
            return items.isEmpty
                ? []
                : [PlaybackHistorySection(
                    id: "day-\(day.timeIntervalSince1970)",
                    title: HistoryDateFormatting.fullDate.string(from: day),
                    sortDate: day,
                    items: items
                )]
        }

        let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: Date())?.start
            ?? calendar.startOfDay(for: Date())
        let previousWeekStart = calendar.date(
            byAdding: .weekOfYear,
            value: -1,
            to: currentWeekStart
        ) ?? currentWeekStart

        var grouped: [PlaybackHistoryBucket: [PlaybackHistoryItem]] = [:]
        for item in items {
            let day = calendar.startOfDay(for: item.playedAt)
            let bucket: PlaybackHistoryBucket
            if day >= currentWeekStart {
                bucket = .day(day)
            } else if day >= previousWeekStart {
                bucket = .week(previousWeekStart)
            } else {
                bucket = .month(calendar.date(
                    from: calendar.dateComponents([.year, .month], from: day)
                ) ?? day)
            }
            grouped[bucket, default: []].append(item)
        }

        return grouped
            .map { bucket, bucketItems in
                PlaybackHistorySection(
                    id: bucket.id,
                    title: bucket.title,
                    sortDate: bucket.sortDate,
                    items: bucketItems.sorted { $0.playedAt > $1.playedAt }
                )
            }
            .sorted { $0.sortDate > $1.sortDate }
    }
}

private struct PlaybackHistoryTrackRow: View {
    let item: PlaybackHistoryItem
    let track: Track?
    let isPlaying: Bool
    let isSelected: Bool
    let isMultiselectMode: Bool
    let hasSelectedEvents: Bool
    let playbackCoordinator: PlaybackCoordinator
    let onTap: (Bool) -> Void
    let onPlay: () -> Void
    let onDelete: () -> Void
    let onEditTrack: (Track) -> Void
    let rowPrimaryColor: Color
    let rowSecondaryColor: Color
    let rowTertiaryColor: Color

    private var rowModel: TrackRowModel {
        let title = track?.title ?? item.title
        let artist = track?.artist ?? item.artist
        let duration = track?.duration ?? item.duration
        let artworkData = track?.artworkData
        let artworkFileURL = track?.resolvedArtworkURL()
        return TrackRowModel(
            id: item.id,
            title: title,
            artist: artist,
            lyricSnippetLine: nil,
            lyricSnippetStartTime: nil,
            lyricHighlightRanges: [],
            durationText: Self.formatDuration(duration),
            artworkData: artworkData,
            artworkFileURL: artworkFileURL,
            artworkIdentity: PlaylistArtworkPipeline.rowSourceIdentity(
                trackID: item.trackID,
                artworkData: artworkData,
                artworkFileURL: artworkFileURL
            ),
            isMissing: track == nil || track?.availability == .missing,
            artworkTrackID: item.trackID
        )
    }

    var body: some View {
        TrackRowView(
            model: rowModel,
            isPlaying: isPlaying,
            isSelected: isSelected,
            enableSecondaryInteractions: true,
            allowsMissingRowTap: true,
            onTap: { isShiftPressed in onTap(isShiftPressed) },
            rowPrimaryColor: rowPrimaryColor,
            rowSecondaryColor: rowSecondaryColor,
            rowTertiaryColor: rowTertiaryColor
        ) {
            if isMultiselectMode {
                Button(role: .destructive, action: onDelete) {
                    Label("删除选中的播放历史", systemImage: "trash")
                }
                .disabled(!hasSelectedEvents)
            } else {
                if let track, track.availability != .missing {
                    TrackActionMenuContent(
                        track: track,
                        onPlay: onPlay,
                        onPlayNext: playbackCoordinator.canInsertTracksAfterCurrent
                            ? { playbackCoordinator.insertTracksAfterCurrent([track]) }
                            : nil,
                        onEditTrack: onEditTrack,
                        onDeleteFromLibraryRequest: { _ in },
                        showsDeleteFromLibrary: false,
                        diagnosticSurface: "PlaybackHistory"
                    )
                    Divider()
                }

                Button(role: .destructive, action: onDelete) {
                    Label("从播放历史删除", systemImage: "trash")
                }
            }
        }
    }

    private static func formatDuration(_ duration: Double) -> String {
        let totalSeconds = max(0, Int(duration))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

private struct PlaybackHistorySection: Identifiable {
    let id: String
    let title: String
    let sortDate: Date
    let items: [PlaybackHistoryItem]
}

private enum PlaybackHistoryBucket: Hashable {
    case day(Date)
    case week(Date)
    case month(Date)

    var id: String {
        switch self {
        case .day(let date): return "day-\(date.timeIntervalSince1970)"
        case .week(let date): return "week-\(date.timeIntervalSince1970)"
        case .month(let date): return "month-\(date.timeIntervalSince1970)"
        }
    }

    var sortDate: Date {
        switch self {
        case .day(let date), .week(let date), .month(let date): return date
        }
    }

    var title: String {
        switch self {
        case .day(let date): return HistoryDateFormatting.relativeSectionTitle(for: date)
        case .week: return "上周"
        case .month(let date):
            let calendar = Calendar.current
            let currentMonth = calendar.dateInterval(of: .month, for: Date())?.start
                ?? calendar.startOfDay(for: Date())
            if let previousMonth = calendar.date(byAdding: .month, value: -1, to: currentMonth),
               calendar.isDate(date, equalTo: previousMonth, toGranularity: .month) {
                return "上个月"
            }
            return HistoryDateFormatting.month.string(from: date)
        }
    }
}

private enum HistoryDateFormatting {
    static let fullDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()

    static let month: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月"
        return formatter
    }()

    static func relativeSectionTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨日" }

        let today = calendar.startOfDay(for: Date())
        let days = calendar.dateComponents([.day], from: date, to: today).day ?? 0
        if days > 1, days < 7 {
            return "\(days)天前"
        }
        return fullDate.string(from: date)
    }
}
