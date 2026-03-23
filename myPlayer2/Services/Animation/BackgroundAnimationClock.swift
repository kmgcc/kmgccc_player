//
//  BackgroundAnimationClock.swift
//  myPlayer2
//
//  kmgccc_player - Master clock for background animations
//  Consolidates 6 separate timers into one 60Hz timer with phase gates.
//

import Foundation
import Combine

/// Master clock for background animations.
/// Replaces 6 separate timers in BKArtBackgroundView with a single 60Hz timer
/// and phase-based gates for different animation rates.
@MainActor
final class BackgroundAnimationClock: ObservableObject {
    
    static let shared = BackgroundAnimationClock()
    
    // MARK: - Phase Gates
    
    /// Gate for background cycling (0.7 fps ≈ every 1.43s)
    var backgroundGate = AnimationPhaseGate(interval: 90)  // 60/90 = 0.67Hz
    
    /// Gate for shape animations (12 fps)
    var shapeGate = AnimationPhaseGate(interval: 5)  // 60/5 = 12Hz
    
    /// Gate for dot animations (15 fps)
    var dotGate = AnimationPhaseGate(interval: 4)  // 60/4 = 15Hz
    
    /// Gate for transitions (6 fps)
    var transitionGate = AnimationPhaseGate(interval: 10)  // 60/10 = 6Hz
    
    /// Gate for speed ramping (60 fps)
    var speedRampGate = AnimationPhaseGate(interval: 1)  // 60/1 = 60Hz
    
    // MARK: - State
    
    private var timer: Timer?
    private var tickCount: UInt64 = 0
    private var isRunning = false
    
    /// Publishers for each phase
    let backgroundPublisher = PassthroughSubject<Void, Never>()
    let shapePublisher = PassthroughSubject<Void, Never>()
    let dotPublisher = PassthroughSubject<Void, Never>()
    let transitionPublisher = PassthroughSubject<Void, Never>()
    let speedRampPublisher = PassthroughSubject<Void, Never>()
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Control
    
    /// Start the master clock.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        
        // Single 60Hz timer (16.67ms interval)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        
        print("[BackgroundAnimationClock] Started at 60Hz")
    }
    
    /// Stop the master clock.
    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        tickCount = 0
        print("[BackgroundAnimationClock] Stopped")
    }
    
    /// Pause when app is backgrounded.
    func pause() {
        timer?.invalidate()
        timer = nil
        print("[BackgroundAnimationClock] Paused")
    }
    
    /// Resume after pause.
    func resume() {
        guard isRunning else { return }
        start()
    }
    
    // MARK: - Private
    
    private func tick() {
        tickCount += 1
        
        // Check each gate and fire if needed
        if backgroundGate.tick() {
            backgroundPublisher.send()
        }
        
        if shapeGate.tick() {
            shapePublisher.send()
        }
        
        if dotGate.tick() {
            dotPublisher.send()
        }
        
        if transitionGate.tick() {
            transitionPublisher.send()
        }
        
        if speedRampGate.tick() {
            speedRampPublisher.send()
        }
    }
}

// MARK: - Phase Gate

/// Tracks when a specific animation phase should fire.
struct AnimationPhaseGate {
    let interval: UInt64  // Number of master clock ticks between fires
    private var counter: UInt64 = 0
    
    init(interval: UInt64) {
        self.interval = interval
    }
    
    /// Returns true if this phase should fire on this tick.
    mutating func tick() -> Bool {
        counter += 1
        if counter >= interval {
            counter = 0
            return true
        }
        return false
    }
    
    /// Reset the gate.
    mutating func reset() {
        counter = 0
    }
}
