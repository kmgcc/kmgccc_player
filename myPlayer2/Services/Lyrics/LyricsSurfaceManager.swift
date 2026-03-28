//
//  LyricsSurfaceManager.swift
//  myPlayer2
//
//  kmgccc_player - Manages WebView instances for different lyrics surfaces
//  Provides isolated WebViews per surface role with unified lifecycle.
//

import Foundation
import SwiftUI
import WebKit

/// Manages WebView instances for different lyrics surface roles.
/// Each independent role gets its own WebView to avoid contention.
@MainActor
final class LyricsSurfaceManager {
    
    static let shared = LyricsSurfaceManager()
    
    private var stores: [LyricsSurfaceRole: LyricsWebViewStore] = [:]
    private var activeRoles: Set<LyricsSurfaceRole> = []
    
    private init() {}
    
    /// Get or create a WebView store for the given role.
    func store(for role: LyricsSurfaceRole) -> LyricsWebViewStore {
        if let existing = stores[role] {
            return existing
        }
        
        // Create new store for this role
        let newStore = LyricsWebViewStore(role: role.rawValue)
        stores[role] = newStore
        return newStore
    }

    /// Return an existing store without creating a new WebView surface.
    func existingStore(for role: LyricsSurfaceRole) -> LyricsWebViewStore? {
        stores[role]
    }
    
    /// Mark a role as active (has a visible surface).
    func activate(role: LyricsSurfaceRole) {
        activeRoles.insert(role)
    }
    
    /// Mark a role as inactive (surface hidden/closed).
    func deactivate(role: LyricsSurfaceRole) {
        activeRoles.remove(role)
        
        // Clean up non-persistent roles
        if !role.persistsState, let store = stores[role] {
            store.shutdown()
            stores.removeValue(forKey: role)
        }
    }
    
    /// Apply track to all active surfaces.
    func applyTrack(ttml: String?, currentTime: Double, isPlaying: Bool) {
        for role in activeRoles {
            guard let store = stores[role] else { continue }
            store.applyTrack(ttml: ttml, currentTime: currentTime, isPlaying: isPlaying)
        }
    }
    
    /// Apply theme to all surfaces (active and pre-created).
    func applyTheme(_ palette: ThemePalette) {
        // Apply to all stores, not just active ones
        for (_, store) in stores {
            store.applyTheme(palette)
        }
    }
    
    /// Shutdown all stores (app termination).
    func shutdownAll() {
        for (_, store) in stores {
            store.shutdown()
        }
        stores.removeAll()
        activeRoles.removeAll()
    }
}

// MARK: - Convenience Extensions

extension LyricsSurfaceManager {
    /// The shared main store (for sidebar and batch preview).
    var mainStore: LyricsWebViewStore {
        store(for: .main)
    }
    
    /// The fullscreen store.
    var fullscreenStore: LyricsWebViewStore {
        store(for: .fullscreen)
    }
    
    /// Check if a role is currently active.
    func isActive(_ role: LyricsSurfaceRole) -> Bool {
        activeRoles.contains(role)
    }
}
