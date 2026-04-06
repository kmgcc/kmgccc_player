//
//  NumericTimeText.swift
//  myPlayer2
//
//  kmgccc_player - Numeric Transition Time Label
//  Provides smooth numeric rolling transitions for playback time labels.
//

import SwiftUI

/// A time label with smooth numeric text transitions.
/// Uses Apple's official `.contentTransition(.numericText())` API.
///
/// Requirements:
/// - Stable identity (no recreation on each tick)
/// - `.monospacedDigit()` for stable width
/// - `.contentTransition(.numericText())` for rolling effect
/// - `.animation(.smooth, value:)` for implicit animation context
struct NumericTimeText: View {
    /// The raw time value in seconds
    let time: Double
    
    /// Font size for the text
    let fontSize: CGFloat
    
    /// Font weight
    let fontWeight: Font.Weight
    
    /// Foreground color
    let color: Color
    
    /// Animation duration for the numeric transition (default: 0.3s)
    let animationDuration: Double
    
    /// Whether to enable the numeric transition (default: true)
    let enableTransition: Bool
    
    /// Optional id for stable identity when used in dynamic contexts
    let id: String?
    
    init(
        time: Double,
        fontSize: CGFloat = 12,
        fontWeight: Font.Weight = .medium,
        color: Color = .secondary,
        animationDuration: Double = 0.3,
        enableTransition: Bool = true,
        id: String? = nil
    ) {
        self.time = time
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.color = color
        self.animationDuration = animationDuration
        self.enableTransition = enableTransition
        self.id = id
    }
    
    var body: some View {
        Text(formattedTime)
            .font(.system(size: fontSize, weight: fontWeight, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(color)
            .ifLet(id) { view, idValue in
                view.id(idValue)
            }
            .if(enableTransition) { view in
                view
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: animationDuration), value: time)
            }
    }
    
    /// Formats time as "m:ss" or "mm:ss"
    private var formattedTime: String {
        guard time.isFinite, time > 0 else { return "0:00" }
        let total = Int(time.rounded(.down))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - View Extension Helpers

extension View {
    /// Conditional modifier helper
    @ViewBuilder
    func `if`(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
    
    /// Conditional modifier helper with optional value
    @ViewBuilder
    func ifLet<T, Content: View>(_ value: T?, transform: (Self, T) -> Content) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}

// MARK: - Preview

#Preview("Numeric Time Text") {
    VStack(spacing: 20) {
        // Standard usage
        NumericTimeText(time: 45, fontSize: 12)
        
        // Longer time
        NumericTimeText(time: 125, fontSize: 12)
        
        // With custom color
        NumericTimeText(time: 203, fontSize: 14, color: .primary)
        
        // Transition disabled
        NumericTimeText(time: 89, fontSize: 12, enableTransition: false)
        
        // Animation test container
        TimePreviewContainer()
    }
    .padding(40)
}

/// Preview container to demonstrate animation
struct TimePreviewContainer: View {
    @State private var currentTime: Double = 0
    @State private var isPlaying = false
    
    var body: some View {
        VStack(spacing: 10) {
            NumericTimeText(time: currentTime, fontSize: 16, color: .primary)
            
            HStack {
                Button("Play") {
                    isPlaying = true
                    startTimer()
                }
                
                Button("Pause") {
                    isPlaying = false
                }
                
                Button("Reset") {
                    currentTime = 0
                    isPlaying = false
                }
            }
            
            Text("Current: \(Int(currentTime))s")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    
    func startTimer() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] timer in
            // Perform checks on MainActor and schedule timer invalidation
            // Timer is not Sendable, so we use MainActor.assumeIsolated for the callback
            MainActor.assumeIsolated {
                if !isPlaying {
                    timer.invalidate()
                    return
                }
                currentTime += 0.5
                if currentTime >= 300 {
                    currentTime = 300
                    isPlaying = false
                    timer.invalidate()
                }
            }
        }
    }
}