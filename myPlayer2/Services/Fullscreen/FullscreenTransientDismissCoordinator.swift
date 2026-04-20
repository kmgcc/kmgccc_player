//
//  FullscreenTransientDismissCoordinator.swift
//  myPlayer2
//
//  kmgccc_player - Fullscreen transient overlay dismissal routing.
//

import Foundation

@MainActor
final class FullscreenTransientDismissCoordinator {
    static let shared = FullscreenTransientDismissCoordinator()

    private var handlers: [(id: UUID, dismiss: () -> Bool)] = []

    private init() {}

    func register(_ dismiss: @escaping () -> Bool) -> UUID {
        let id = UUID()
        handlers.append((id, dismiss))
        return id
    }

    func unregister(_ id: UUID) {
        handlers.removeAll { $0.id == id }
    }

    func dismissTopmost() -> Bool {
        for handler in handlers.reversed() {
            if handler.dismiss() {
                return true
            }
        }
        return false
    }
}
