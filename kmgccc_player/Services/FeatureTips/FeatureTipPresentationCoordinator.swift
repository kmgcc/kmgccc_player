//
//  FeatureTipPresentationCoordinator.swift
//  myPlayer2
//
//  kmgccc_player - Serializes Feature Tip presentations so multiple tips do not
//  compete for the user's attention at the same time.
//

import Foundation

/// Coordinates Feature Tip presentation across AppKit popovers and SwiftUI
/// overlays/popovers.
///
/// Only one tip is allowed to be visible at a time. If another tip is already
/// visible, new requests are queued and presented after the active tip is
/// dismissed. Callers must only record a display (through `AppVersionGate`)
/// inside the `present` closure when it actually returns `true`, so queued tips
/// that never become visible do not consume their display budget.
@MainActor
final class FeatureTipPresentationCoordinator {
    static let shared = FeatureTipPresentationCoordinator()

    private struct PendingTip {
        let key: String
        let present: () -> Bool
    }

    private var activeKey: String?
    private var pending: [PendingTip] = []
    private var isSuspended = false

    private init() {}

    /// Requests to present a tip.
    ///
    /// If no tip is active, `present` is invoked immediately. If another tip is
    /// active, the request is queued unless the same key is already pending or
    /// currently active.
    func requestPresentation(key: String, present: @escaping () -> Bool) {
        if activeKey == key {
            return
        }

        if activeKey == nil && !isSuspended {
            if present() {
                activeKey = key
            }
            return
        }

        guard !pending.contains(where: { $0.key == key }) else { return }
        pending.append(PendingTip(key: key, present: present))
    }

    /// Suspends/resumes the queue. While suspended, no queued tip will start even
    /// if the active tip has ended. Used e.g. while the settings sheet is open so
    /// a main-window tip does not appear over it.
    func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
        if !isSuspended && activeKey == nil {
            drainNext()
        }
    }

    /// Ends the active presentation for `key` and starts the next queued tip, if any.
    func endPresentation(key: String) {
        guard activeKey == key else { return }
        activeKey = nil
        drainNext()
    }

    /// Removes a queued presentation for `key`, e.g. when its owning surface disappears.
    func cancelPending(key: String) {
        pending.removeAll { $0.key == key }
    }

    /// Whether any Feature Tip is currently being presented.
    var isPresenting: Bool {
        activeKey != nil
    }

    /// The key of the currently presented tip, if any.
    var currentKey: String? {
        activeKey
    }

    private func drainNext() {
        guard !isSuspended else { return }
        while !pending.isEmpty {
            let next = pending.removeFirst()
            if next.present() {
                activeKey = next.key
                return
            }
        }
    }
}