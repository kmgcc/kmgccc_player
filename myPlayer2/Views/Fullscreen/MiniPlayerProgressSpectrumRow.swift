//
//  MiniPlayerProgressSpectrumRow.swift
//  myPlayer2
//
//  kmgccc_player - Unified progress bar + spectrum row with single hover state
//  Fixes hover fragmentation, state jitter, and hit-testing issues.
//

import Foundation
import SwiftUI

/// Unified row containing progress bar and optional spectrum visualizer.
/// Uses a single hover state source to drive both components' animations.
/// When hovered: spectrum collapses to minimum width + fades out, progress bar expands to fill.
/// When not hovered: spectrum expands to full width + fades in, progress bar contracts to make room.
@MainActor
struct MiniPlayerProgressSpectrumRow: View {
    let scale: CGFloat
    let isSpectrumEnabled: Bool
    let isPlaying: Bool
    let accentColor: Color?
    
    // Progress bar state
    let progress: Double
    let duration: Double
    let onSeek: (Double) -> Void
    let onDragStart: () -> Void
    let onDragEnd: () -> Void
    
    // Layout constants
    private var spectrumExpandedWidth: CGFloat { 100 * scale }
    private var spectrumCollapsedWidth: CGFloat { 14 * scale }
    private var spectrumHeight: CGFloat { 52 * scale }
    private var barHeight: CGFloat { 6 * scale }
    private var timeFontSize: CGFloat { 10.5 * scale }
    private var progressYOffset: CGFloat { 13 * scale }
    private var hPadding: CGFloat { 8 * scale }
    private var timeSpacing: CGFloat { 10 * scale }
    
    /// Unified hover state for the entire row
    @State private var isRowHovered = false
    
    var body: some View {
        // Single unified hover region covering the entire progress+spectrum area
        HStack(spacing: 2 * scale) {
            // Progress bar section - expands when spectrum collapses
            progressBarSection
                .layoutPriority(isRowHovered && isSpectrumEnabled ? 1 : 0)
            
            // Spectrum section - only if enabled
            if isSpectrumEnabled {
                spectrumSection
            }
        }
        .frame(maxHeight: .infinity)
        // CRITICAL: Single hover handler for the entire row
        .onHover { hovering in
            isRowHovered = hovering
        }
    }
    
    // MARK: - Progress Bar Section
    
    private var progressBarSection: some View {
        ZStack {
            // The actual progress bar
            GeometryReader { geometry in
                let filledWidth = progressWidth(in: geometry.size.width)
                
                ZStack(alignment: .leading) {
                    // Track - full width capsule
                    Capsule()
                        .fill(progressTrackColor)
                        .frame(height: barHeight)
                    
                    // Fill - always a full capsule, masked to filled width
                    Capsule()
                        .fill(progressFillColor)
                        .frame(height: barHeight)
                        .mask(
                            Rectangle()
                                .frame(width: max(barHeight, filledWidth))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 2 * scale)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            onDragStart()
                            let progress = max(0, min(1, value.location.x / geometry.size.width))
                            onSeek(progress * duration)
                        }
                        .onEnded { value in
                            let progress = max(0, min(1, value.location.x / geometry.size.width))
                            onSeek(progress * duration)
                            onDragEnd()
                        }
                )
            }
            
            // Time labels overlay - show only on hover
            HStack(spacing: timeSpacing) {
                Text(formattedTime(progress))
                    .font(.system(size: timeFontSize, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(timeColor)
                
                Spacer(minLength: 18 * scale)
                
                Text(formattedTime(duration))
                    .font(.system(size: timeFontSize, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(timeColor)
            }
            .padding(.horizontal, hPadding)
            .offset(y: progressYOffset)
            .opacity(isRowHovered ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: isRowHovered)
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal, hPadding)
        .animation(.spring(response: 0.35, dampingFraction: 0.75, blendDuration: 0.1), value: isRowHovered)
    }
    
    // MARK: - Spectrum Section
    
    private var spectrumSection: some View {
        MiniPlayerSpectrumView(
            isPlaying: isPlaying,
            accentColor: accentColor,
            scale: scale,
            isHovered: isRowHovered,
            pausedBehavior: .minimalDots
        )
        // Width animates between expanded and collapsed
        .frame(width: isRowHovered ? spectrumCollapsedWidth : spectrumExpandedWidth, height: spectrumHeight)
        // Opacity fades out when collapsed
        .opacity(isRowHovered ? 0 : 1)
        // CRITICAL: Disable hit testing when collapsed/hidden to not block progress bar
        .allowsHitTesting(!isRowHovered)
        // Single animation for all properties
        .animation(.spring(response: 0.35, dampingFraction: 0.75, blendDuration: 0.1), value: isRowHovered)
    }
    
    // MARK: - Helpers
    
    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        let p = progress / duration
        return totalWidth * CGFloat(max(0, min(1, p)))
    }
    
    private func formattedTime(_ time: Double) -> String {
        guard time.isFinite, time > 0 else { return "0:00" }
        let total = Int(time.rounded(.down))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private var progressFillColor: Color {
        Color.primary.opacity(0.9)
    }
    
    private var progressTrackColor: Color {
        Color.secondary.opacity(0.32)
    }
    
    private var timeColor: Color {
        Color.primary
    }
}

// MARK: - Preview

#Preview("Progress + Spectrum Row") { @MainActor in
    VStack(spacing: 40) {
        // With spectrum
        MiniPlayerProgressSpectrumRow(
            scale: 1.0,
            isSpectrumEnabled: true,
            isPlaying: true,
            accentColor: .blue,
            progress: 45,
            duration: 180,
            onSeek: { _ in },
            onDragStart: {},
            onDragEnd: {}
        )
        .frame(height: 60)
        .background(Color.gray.opacity(0.1))
        
        // Without spectrum
        MiniPlayerProgressSpectrumRow(
            scale: 1.0,
            isSpectrumEnabled: false,
            isPlaying: true,
            accentColor: .blue,
            progress: 45,
            duration: 180,
            onSeek: { _ in },
            onDragStart: {},
            onDragEnd: {}
        )
        .frame(height: 60)
        .background(Color.gray.opacity(0.1))
    }
    .padding(40)
    .frame(width: 800)
}
