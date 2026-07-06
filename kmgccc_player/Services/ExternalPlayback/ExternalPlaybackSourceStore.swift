//
//  ExternalPlaybackSourceStore.swift
//  myPlayer2
//
//  Keeps stable user preferences separate from transient MediaRemote observations.
//

import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class ExternalPlaybackSourceStore {
    static let shared = ExternalPlaybackSourceStore()

    private struct RuntimeState: Equatable {
        var playbackState: ExternalPlaybackSourcePlaybackState
        var lastDetectedAt: Date
        var lastActiveAt: Date?
    }

    private let settings: AppSettings
    private var preferences: [ExternalPlaybackSourcePreference]
    private var runtimeStates: [String: RuntimeState] = [:]
    private var currentSourceID: String?

    private(set) var snapshots: [ExternalPlaybackSourceSnapshot] = []

    private init(settings: AppSettings = .shared) {
        self.settings = settings
        self.preferences = settings.externalPlaybackSourcePreferences
        rebuildSnapshots()
    }

    @discardableResult
    func recordDetection(
        bundleIdentifier rawBundleIdentifier: String?,
        isPlaying: Bool?,
        hasTrack: Bool,
        displayName explicitDisplayName: String? = nil,
        detectedAt: Date = Date()
    ) -> ExternalPlaybackSourceSnapshot? {
        guard let id = normalizedSourceID(rawBundleIdentifier),
              !isAppleMusicSource(id) else { return nil }

        let displayName = cleanedDisplayName(explicitDisplayName)
            ?? displayName(forBundleIdentifier: id)
            ?? id
        ensurePreference(id: id, bundleIdentifier: id, displayName: displayName)

        let playbackState: ExternalPlaybackSourcePlaybackState
        if isPlaying == true {
            playbackState = .playing
        } else if isPlaying == false, hasTrack {
            playbackState = .paused
        } else if hasTrack {
            playbackState = .idle
        } else {
            playbackState = .unknown
        }

        var runtime = runtimeStates[id] ?? RuntimeState(
            playbackState: .unknown,
            lastDetectedAt: detectedAt,
            lastActiveAt: nil
        )
        runtime.playbackState = playbackState
        runtime.lastDetectedAt = detectedAt
        if hasTrack || isPlaying == true {
            runtime.lastActiveAt = detectedAt
        }
        runtimeStates[id] = runtime
        rebuildSnapshots()
        return snapshots.first { $0.id == id }
    }

    func setCurrentSourceID(_ id: String?) {
        let normalized = normalizedSourceID(id)
        guard currentSourceID != normalized else { return }
        currentSourceID = normalized
        rebuildSnapshots()
    }

    func reloadPreferences() {
        preferences = settings.externalPlaybackSourcePreferences
        rebuildSnapshots()
    }

    func updateSourceSections(activeIDs: [String], disabledIDs: [String]) {
        var orderedIDs: [String] = []
        var seen = Set<String>()
        for rawID in activeIDs + disabledIDs {
            guard let id = normalizedSourceID(rawID), seen.insert(id).inserted else { continue }
            orderedIDs.append(id)
        }
        for preference in preferences where seen.insert(preference.id).inserted {
            orderedIDs.append(preference.id)
        }

        let disabledSet = Set(disabledIDs.compactMap { normalizedSourceID($0) })
        let byID = Dictionary(uniqueKeysWithValues: preferences.map { ($0.id, $0) })
        let updated = orderedIDs.compactMap { id -> ExternalPlaybackSourcePreference? in
            guard var preference = byID[id] else { return nil }
            preference.isDisabled = disabledSet.contains(id)
            return preference
        }
        preferences = updated
        settings.externalPlaybackSourcePreferences = updated
        rebuildSnapshots()
    }

    func isDisabled(_ rawID: String?) -> Bool {
        guard let id = normalizedSourceID(rawID),
              let preference = preferences.first(where: { $0.id == id }) else {
            return false
        }
        return preference.isDisabled
    }

    func priorityIndex(for rawID: String?) -> Int {
        guard let id = normalizedSourceID(rawID),
              let index = preferences.firstIndex(where: { $0.id == id }) else {
            return Int.max
        }
        return index
    }

    func hasHigherPriority(_ challengerID: String?, than incumbentID: String?) -> Bool {
        priorityIndex(for: challengerID) < priorityIndex(for: incumbentID)
    }

    func preference(for rawID: String?) -> ExternalPlaybackSourcePreference? {
        guard let id = normalizedSourceID(rawID) else { return nil }
        return preferences.first { $0.id == id }
    }

    func normalizedSourceID(_ rawID: String?) -> String? {
        guard let rawID else { return nil }
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    private func ensurePreference(id: String, bundleIdentifier: String, displayName: String) {
        if let index = preferences.firstIndex(where: { $0.id == id }) {
            let current = preferences[index]
            guard current.displayName == current.id || current.displayName.isEmpty else { return }
            preferences[index].displayName = displayName
            settings.externalPlaybackSourcePreferences = preferences
            return
        }

        preferences.append(
            ExternalPlaybackSourcePreference(
                id: id,
                bundleIdentifier: bundleIdentifier,
                displayName: displayName,
                isDisabled: false
            )
        )
        settings.externalPlaybackSourcePreferences = preferences
    }

    private func rebuildSnapshots() {
        snapshots = preferences.map { preference in
            let runtime = runtimeStates[preference.id]
            return ExternalPlaybackSourceSnapshot(
                id: preference.id,
                bundleIdentifier: preference.bundleIdentifier,
                displayName: preference.displayName,
                isDisabled: preference.isDisabled,
                playbackState: runtime?.playbackState ?? .unknown,
                isCurrent: currentSourceID == preference.id,
                lastDetectedAt: runtime?.lastDetectedAt,
                lastActiveAt: runtime?.lastActiveAt
            )
        }
    }

    private func cleanedDisplayName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func displayName(forBundleIdentifier bundleIdentifier: String) -> String? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
              let bundle = Bundle(url: appURL) else {
            return nil
        }
        let localized = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.localizedInfoDictionary?["CFBundleName"] as? String
            ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.infoDictionary?["CFBundleName"] as? String
        return cleanedDisplayName(localized)
            ?? appURL.deletingPathExtension().lastPathComponent
    }

    private func isAppleMusicSource(_ id: String) -> Bool {
        id == "com.apple.music" || id == "com.apple.itunes"
    }
}
