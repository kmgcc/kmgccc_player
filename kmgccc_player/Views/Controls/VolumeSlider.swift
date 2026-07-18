//
//  VolumeSlider.swift
//  myPlayer2
//
//  Shared volume slider behavior for the window and fullscreen Mini Players.
//

import AppKit
import SwiftUI

enum VolumeControlBehavior {
    static let lastVolumeKey = "_expandableVolume_lastVolume"
    static let defaultSnapTolerance: Double = 0.04

    static func clamped(_ volume: Double) -> Double {
        min(max(volume, 0), 1)
    }

    static func snapped(
        _ volume: Double,
        defaultVolume: Double = AppSettings.defaultVolume,
        tolerance: Double = defaultSnapTolerance
    ) -> (value: Double, isNearDefault: Bool) {
        let clampedVolume = clamped(volume)
        let isNearDefault = abs(clampedVolume - defaultVolume) <= tolerance
        return (isNearDefault ? defaultVolume : clampedVolume, isNearDefault)
    }

    static func volumeAfterMuteToggle(_ volume: Double) -> Double {
        if volume > 0 {
            UserDefaults.standard.set(volume, forKey: lastVolumeKey)
            return 0
        }

        let lastVolume = UserDefaults.standard.double(forKey: lastVolumeKey)
        return lastVolume > 0 ? lastVolume : AppSettings.defaultVolume
    }

    /// AppKit chooses the appropriate performer for the current input device.
    /// On a Force Touch trackpad this produces the alignment pulse; when the
    /// input device cannot provide haptics, AppKit silently suppresses it.
    static func performDefaultSnapFeedback() {
        NSHapticFeedbackManager.defaultPerformer.perform(
            .alignment,
            performanceTime: .drawCompleted
        )
    }
}

struct VolumeSlider: View {
    @Binding var volume: Double

    var onInteraction: () -> Void = {}
    var onAdjustingChanged: (Bool) -> Void = { _ in }
    var snapTolerance: Double = VolumeControlBehavior.defaultSnapTolerance
    var markerColor: Color = .secondary.opacity(0.72)
    var hidesMarkerAtDefault = false

    @State private var isEditing = false
    @State private var movedAwayFromDefault = false
    @State private var hasSnappedDuringEditing = false

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { volume },
            set: { proposedVolume in
                let result = VolumeControlBehavior.snapped(
                    proposedVolume,
                    tolerance: snapTolerance
                )

                if result.isNearDefault {
                    if isEditing,
                       movedAwayFromDefault,
                       !hasSnappedDuringEditing {
                        hasSnappedDuringEditing = true
                        VolumeControlBehavior.performDefaultSnapFeedback()
                    }
                } else {
                    movedAwayFromDefault = true
                    hasSnappedDuringEditing = false
                }

                volume = result.value
            }
        )
    }

    var body: some View {
        // Keep the original compact Slider initializer. The macOS 26 ticked
        // initializer changes the control's intrinsic layout and makes this
        // otherwise horizontal slider unnecessarily tall.
        Slider(
            value: sliderBinding,
            in: 0...1
        ) { editing in
            isEditing = editing
            if editing {
                movedAwayFromDefault = abs(volume - AppSettings.defaultVolume)
                    > snapTolerance
                hasSnappedDuringEditing = false
                onInteraction()
            } else {
                movedAwayFromDefault = false
                hasSnappedDuringEditing = false
            }
            onAdjustingChanged(editing)
        }
        .overlay {
            if shouldShowMarker {
                GeometryReader { geometry in
                    Circle()
                        .fill(markerColor)
                        .frame(width: 4, height: 4)
                        .position(
                            x: defaultMarkerX(in: geometry.size),
                            y: geometry.size.height / 2
                        )
                        .allowsHitTesting(false)
                }
            }
        }
        .accessibilityLabel("Volume")
        .accessibilityValue(Text("\(Int((volume * 100).rounded()))%"))
        .onChange(of: volume) { _, _ in
            onInteraction()
        }
    }

    private var shouldShowMarker: Bool {
        !hidesMarkerAtDefault
            || abs(volume - AppSettings.defaultVolume) > snapTolerance
    }

    private func defaultMarkerX(in size: CGSize) -> CGFloat {
        // NSSlider reserves half of its knob width at both ends. The SwiftUI
        // Slider's control height tracks that knob size, so using half the
        // actual height keeps the marker on the same value-to-position curve
        // for both the small window control and the regular fullscreen one.
        let horizontalInset = min(size.height / 2, size.width / 2)
        return horizontalInset
            + (size.width - horizontalInset * 2) * CGFloat(AppSettings.defaultVolume)
    }
}
