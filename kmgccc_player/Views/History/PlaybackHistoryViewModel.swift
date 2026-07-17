//
//  PlaybackHistoryViewModel.swift
//  myPlayer2
//
//  Shared state for the playback-history page and its AppKit toolbar.
//

import Foundation
import Observation

enum PlaybackHistorySearchRange: String, CaseIterable, Identifiable, Sendable {
    case all
    case today
    case thisWeek
    case last15Days
    case thisMonth
    case thisYear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部记录"
        case .today: return "今天"
        case .thisWeek: return "本周"
        case .last15Days: return "15天内"
        case .thisMonth: return "本月"
        case .thisYear: return "今年内"
        }
    }

    func lowerBound(from date: Date = Date(), calendar: Calendar = .current) -> Date? {
        let startOfToday = calendar.startOfDay(for: date)
        switch self {
        case .all:
            return nil
        case .today:
            return startOfToday
        case .thisWeek:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start
                ?? startOfToday
        case .last15Days:
            return calendar.date(byAdding: .day, value: -14, to: startOfToday)
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: date)?.start
                ?? startOfToday
        case .thisYear:
            return calendar.dateInterval(of: .year, for: date)?.start
                ?? startOfToday
        }
    }
}

@Observable
@MainActor
final class PlaybackHistoryViewModel {
    var items: [PlaybackHistoryItem] = []
    var olderItemsLoaded = false
    var olderItemCount = 0
    var isLoading = true

    var searchText = ""
    var searchRange: PlaybackHistorySearchRange = .all
    var isMultiselectMode = false
    var selectedEventIDs: Set<UUID> = []

    /// Shift-range anchor. Event ID, never a track ID — mirrors
    /// `selectedEventIDs` semantics. Cleared when multiselect exits or when
    /// the anchored event is no longer in the loaded set.
    private(set) var selectionAnchorEventID: UUID?

    /// This is an event ID, never a track ID. Two sessions for the same song
    /// must remain independently selectable and independently highlightable.
    private(set) var activeEventID: UUID?
    private(set) var filterDate: Date?

    var hasActiveSearch: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var visibleItems: [PlaybackHistoryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerBound = filterDate == nil ? searchRange.lowerBound() : nil

        return items.filter { item in
            if let filterDate,
               !Calendar.current.isDate(item.playedAt, inSameDayAs: filterDate) {
                return false
            }

            if let lowerBound, item.playedAt < lowerBound {
                return false
            }

            guard !query.isEmpty else { return true }
            return item.title.localizedCaseInsensitiveContains(query)
                || item.artist.localizedCaseInsensitiveContains(query)
                || item.album.localizedCaseInsensitiveContains(query)
        }
    }

    var hasVisibleItems: Bool { !visibleItems.isEmpty }
    var hasSelectedEvents: Bool { !selectedEventIDs.isEmpty }

    func load(using store: PlaybackHistoryStore, filterDate: Date?) {
        isLoading = true
        self.filterDate = filterDate.map { Calendar.current.startOfDay(for: $0) }

        if let filterDate = self.filterDate {
            items = store.fetchItems(on: filterDate)
            olderItemCount = 0
        } else if olderItemsLoaded || hasActiveSearch || searchRange != .all {
            if let lowerBound = searchRange.lowerBound() {
                items = store.fetchItems(from: lowerBound)
            } else {
                items = store.fetchItems()
            }
            olderItemCount = 0
        } else {
            let calendar = Calendar.current
            let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: Date())?.start
                ?? calendar.startOfDay(for: Date())
            let previousWeekStart = calendar.date(
                byAdding: .weekOfYear,
                value: -1,
                to: currentWeekStart
            ) ?? currentWeekStart
            items = store.fetchItems(from: previousWeekStart)
            olderItemCount = store.countItems(before: previousWeekStart)
        }

        let itemIDs = Set(items.map(\.id))
        selectedEventIDs.formIntersection(itemIDs)
        if let activeEventID, !itemIDs.contains(activeEventID) {
            self.activeEventID = nil
        }
        if let selectionAnchorEventID, !itemIDs.contains(selectionAnchorEventID) {
            self.selectionAnchorEventID = nil
        }
        isLoading = false
    }

    func setOlderItemsLoaded(_ isLoaded: Bool) {
        olderItemsLoaded = isLoaded
    }

    func toggleMultiselectMode() {
        isMultiselectMode.toggle()
        if !isMultiselectMode {
            selectedEventIDs.removeAll()
            selectionAnchorEventID = nil
        }
    }

    func clearMultiselectState() {
        isMultiselectMode = false
        selectedEventIDs.removeAll()
        selectionAnchorEventID = nil
    }

    func toggleSelection(for eventID: UUID, extendingRange: Bool) {
        guard isMultiselectMode else { return }

        if extendingRange,
           let anchorID = selectionAnchorEventID {
            let ordered = visibleItems.map(\.id)
            if let anchorIndex = ordered.firstIndex(of: anchorID),
               let currentIndex = ordered.firstIndex(of: eventID) {
                let bounds = anchorIndex <= currentIndex
                    ? anchorIndex...currentIndex
                    : currentIndex...anchorIndex
                selectedEventIDs.formUnion(ordered[bounds])
                return
            }
        }

        if selectedEventIDs.contains(eventID) {
            selectedEventIDs.remove(eventID)
        } else {
            selectedEventIDs.insert(eventID)
        }
        selectionAnchorEventID = eventID
    }

    func setActiveEvent(_ eventID: UUID) {
        activeEventID = eventID
    }

    func clearActiveEvent() {
        activeEventID = nil
    }

    @discardableResult
    func delete(eventIDs: some Collection<UUID>, using store: PlaybackHistoryStore) -> Bool {
        let ids = Set(eventIDs)
        guard !ids.isEmpty else { return true }

        let didDelete = store.delete(itemIDs: ids)
        guard didDelete else { return false }

        items.removeAll { ids.contains($0.id) }
        selectedEventIDs.subtract(ids)
        if let activeEventID, ids.contains(activeEventID) {
            self.activeEventID = nil
        }
        if let selectionAnchorEventID, ids.contains(selectionAnchorEventID) {
            self.selectionAnchorEventID = nil
        }
        if selectedEventIDs.isEmpty {
            isMultiselectMode = false
        }
        return true
    }

    @discardableResult
    func delete(eventID: UUID, using store: PlaybackHistoryStore) -> Bool {
        let didDelete = store.delete(itemID: eventID)
        guard didDelete else { return false }
        selectedEventIDs.remove(eventID)
        if activeEventID == eventID {
            activeEventID = nil
        }
        if selectionAnchorEventID == eventID {
            selectionAnchorEventID = nil
        }
        items.removeAll { $0.id == eventID }
        return true
    }

    @discardableResult
    func deleteSelected(using store: PlaybackHistoryStore) -> Bool {
        let ids = selectedEventIDs
        guard !ids.isEmpty else { return true }
        let didDelete = store.delete(itemIDs: ids)
        guard didDelete else { return false }
        items.removeAll { ids.contains($0.id) }
        if let activeEventID, ids.contains(activeEventID) {
            self.activeEventID = nil
        }
        selectionAnchorEventID = nil
        selectedEventIDs.removeAll()
        isMultiselectMode = false
        return true
    }

    func notePlaybackTrackChanged(to trackID: UUID?) {
        guard let activeEventID,
              let activeItem = items.first(where: { $0.id == activeEventID })
        else { return }
        if trackID != activeItem.trackID {
            self.activeEventID = nil
        }
    }

    func playRandom(
        using playbackCoordinator: PlaybackCoordinator,
        libraryVM: LibraryViewModel
    ) {
        let tracksByID = Dictionary(uniqueKeysWithValues: libraryVM.allTracks.map { ($0.id, $0) })
        let queue = uniquePlayableTracks(from: visibleItems, tracksByID: tracksByID)
        guard !queue.isEmpty else { return }

        let startTrack = PlaybackCoordinator.smartRandomPick(from: queue) ?? queue[0]
        let startIndex = queue.firstIndex(where: { $0.id == startTrack.id }) ?? 0
        activeEventID = visibleItems.first(where: { $0.trackID == startTrack.id })?.id
        playbackCoordinator.playTracks(
            queue,
            startingAt: startIndex,
            libraryQueueSource: .librarySelection("playback-history"),
            startPolicy: .forceShuffleTemporary
        )
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
}
