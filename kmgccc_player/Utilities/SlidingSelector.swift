//
//  SlidingSelector.swift
//  myPlayer2
//
//  kmgccc_player - Generic sliding-knob segmented selector.
//  Extracts the animation mechanism from PlaybackModeSlider for reuse.
//

import SwiftUI
import MotionKit

// MARK: - Layout Anchors

private nonisolated struct SegmentAnchorEntry<ID: Hashable> {
    let id: ID
    let bounds: Anchor<CGRect>
}

private nonisolated struct SegmentAnchorPreferenceKey<ID: Hashable>: PreferenceKey {
    static var defaultValue: [SegmentAnchorEntry<ID>] { [] }
    static func reduce(value: inout [SegmentAnchorEntry<ID>], nextValue: () -> [SegmentAnchorEntry<ID>]) {
        value.append(contentsOf: nextValue())
    }
}

// Animate the contribution of each segment, rather than cached pixel frames.
// The same weights resolve against the CURRENT layout even during a spring.
private nonisolated struct SegmentWeights: VectorArithmetic {
    var values: [CGFloat]

    static var zero: Self { Self(values: []) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Empty and zero-padded vectors represent the same additive zero.
        (0..<max(lhs.values.count, rhs.values.count)).allSatisfy { index in
            (index < lhs.values.count ? lhs.values[index] : 0)
                == (index < rhs.values.count ? rhs.values[index] : 0)
        }
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        combine(lhs, rhs, +)
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        combine(lhs, rhs, -)
    }

    private static func combine(
        _ lhs: Self, _ rhs: Self, _ operation: (CGFloat, CGFloat) -> CGFloat
    ) -> Self {
        Self(values: (0..<max(lhs.values.count, rhs.values.count)).map { index in
            operation(
                index < lhs.values.count ? lhs.values[index] : 0,
                index < rhs.values.count ? rhs.values[index] : 0
            )
        })
    }

    mutating func scale(by rhs: Double) {
        values = values.map { $0 * CGFloat(rhs) }
    }

    var magnitudeSquared: Double {
        values.reduce(0) { $0 + Double($1 * $1) }
    }
}

private nonisolated struct SlidingSelectorKnob<Knob: View>: View, Animatable {
    let frames: [CGRect]
    var weights: SegmentWeights
    var dragOffset: CGFloat
    let knob: Knob

    var animatableData: AnimatablePair<SegmentWeights, CGFloat> {
        get { AnimatablePair(weights, dragOffset) }
        set {
            weights = newValue.first
            dragOffset = newValue.second
        }
    }

    private var frame: CGRect {
        var result = CGRect.zero
        for (frame, weight) in zip(frames, weights.values) {
            result.origin.x += frame.minX * weight
            result.origin.y += frame.minY * weight
            result.size.width += frame.width * weight
            result.size.height += frame.height * weight
        }
        result.origin.x += dragOffset
        return result
    }

    @MainActor var body: some View {
        let frame = self.frame
        knob
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            // Only the weights and drag offset above interpolate. Animating
            // these derived pixels again would make layout changes lag behind.
            .transaction { $0.animation = nil }
            .allowsHitTesting(false)
    }
}

// MARK: - Sliding Selector

/// A generic segmented selector with an animated sliding knob.
///
/// The knob smoothly slides and resizes to match the measured frame of the
/// currently selected segment. Segment widths may vary.
///
/// Layout and appearance are fully caller-controlled:
/// - `background` renders the track behind all segments.
/// - `knob` renders the sliding selection indicator.
/// - `content` renders each segment's label / icon.
/// - This view does not force max width/height, padding, inset, or corner radius.
/// - Each segment reserves the larger of its selected and unselected content
///   footprints, so selection-dependent styling cannot resize the whole track.
///
/// Supports optional drag-to-switch and tap/retap callbacks.
/// Segment IDs must be unique and stable. Content is evaluated for both visual
/// states to reserve its footprint; keep those builders free of side effects.
/// Layout anchors drive rendering; cached frames are only used for drag hit tests.
struct SlidingSelector<Selection: Hashable, Background: View, Knob: View, Content: View>: View {
    let segments: [Selection]
    @Binding var selection: Selection
    let motionToken: MotionToken
    let hSpacing: CGFloat
    let enableDrag: Bool
    let onTap: ((Selection) -> Void)?
    let onDragEnd: ((Selection) -> Void)?
    @ViewBuilder let background: () -> Background
    @ViewBuilder let knob: () -> Knob
    @ViewBuilder let content: (Selection, Bool) -> Content

    @State private var interactionFrames: [Selection: CGRect] = [:]
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging: Bool = false
    @State private var instanceID = UUID()
    @State private var releaseInitialVelocity: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var configuredMotionPolicy

    private var selectedFrame: CGRect? { interactionFrames[selection] }

    private var orderedFrames: [(Selection, CGRect)] {
        segments.compactMap { seg in
            interactionFrames[seg].map { (seg, $0) }
        }
    }

    private var coordinateSpaceName: String {
        "SlidingSelector_\(instanceID)"
    }

    init(
        segments: [Selection],
        selection: Binding<Selection>,
        motionToken: MotionToken = .control,
        hSpacing: CGFloat = 4,
        enableDrag: Bool = true,
        onTap: ((Selection) -> Void)? = nil,
        onDragEnd: ((Selection) -> Void)? = nil,
        @ViewBuilder background: @escaping () -> Background,
        @ViewBuilder knob: @escaping () -> Knob,
        @ViewBuilder content: @escaping (Selection, Bool) -> Content
    ) {
        self.segments = segments
        self._selection = selection
        self.motionToken = motionToken
        self.hSpacing = hSpacing
        self.enableDrag = enableDrag
        self.onTap = onTap
        self.onDragEnd = onDragEnd
        self.background = background
        self.knob = knob
        self.content = content
    }

    private func resolvedAnimation(initialVelocity: Double = 0) -> Animation? {
        let policy = configuredMotionPolicy.resolving(
            accessibilityReduceMotion: reduceMotion
        )
        return policy.animation(
            for: motionTokens[motionToken],
            initialVelocity: initialVelocity
        )
    }

    var body: some View {
        let selector = segmentsLayer
            .backgroundPreferenceValue(SegmentAnchorPreferenceKey<Selection>.self) { entries in
                GeometryReader { geometry in
                    let frames = resolvedFrames(entries, in: geometry)
                    ZStack(alignment: .topLeading) {
                        background()
                            .allowsHitTesting(false)

                        knobLayer(frames: frames)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .onChange(of: frames, initial: true) { _, newFrames in
                        // Geometry never starts an animation or drives rendering
                        // through state. This snapshot is solely for gestures.
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            interactionFrames = newFrames
                        }
                    }
                }
            }
            .coordinateSpace(name: coordinateSpaceName)
            .onChange(of: segments) { _, _ in
                // A new option set has a new weight basis and no old drag.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    isDragging = false
                    dragOffset = 0
                }
            }

        if enableDrag {
            selector.simultaneousGesture(dragGesture)
        } else {
            selector
        }
    }

    // MARK: - Layers

    @ViewBuilder
    private func knobLayer(frames: [Selection: CGRect]) -> some View {
        if let frame = frames[selection] {
            SlidingSelectorKnob(
                frames: segments.map { frames[$0] ?? .zero },
                weights: SegmentWeights(values: segments.map { $0 == selection ? 1 : 0 }),
                dragOffset: isDragging ? draggedFrame(base: frame, frames: frames).minX - frame.minX : 0,
                knob: knob()
            )
            .animation(isDragging ? nil : resolvedAnimation(), value: selection)
            .animation(
                isDragging ? nil : resolvedAnimation(initialVelocity: releaseInitialVelocity),
                value: isDragging
            )
            .id(segments)
            .transition(.identity)
        }
    }

    private var segmentsLayer: some View {
        HStack(spacing: hSpacing) {
            ForEach(segments, id: \.self) { segment in
                Button {
                    onTap?(segment)
                    selection = segment
                } label: {
                    stableContent(for: segment)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .anchorPreference(key: SegmentAnchorPreferenceKey<Selection>.self, value: .bounds) {
                    [SegmentAnchorEntry(id: segment, bounds: $0)]
                }
            }
        }
    }

    private func stableContent(for segment: Selection) -> some View {
        ZStack {
            content(segment, false)
                .hidden()
                .accessibilityHidden(true)

            content(segment, true)
                .hidden()
                .accessibilityHidden(true)

            content(segment, selection == segment)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpaceName))
            .onChanged { value in
                guard selectedFrame != nil else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    isDragging = true
                    dragOffset = value.translation.width
                }
            }
            .onEnded { value in
                guard let frame = selectedFrame else {
                    withAnimation(nil) {
                        isDragging = false
                        dragOffset = 0
                    }
                    return
                }
                let finalX = frame.midX + value.translation.width
                let target = segment(at: finalX) ?? selection
                let destinationFrame = interactionFrames[target] ?? frame
                let initialVelocity = MotionSpec.clampedInitialVelocity(
                    MotionSpec.normalizedInitialVelocity(
                        from: finalX,
                        to: destinationFrame.midX,
                        velocity: Double(value.velocity.width)
                    )
                )
                releaseInitialVelocity = initialVelocity
                if target != selection {
                    onDragEnd?(target)
                }
                isDragging = false
                selection = target
                dragOffset = 0
            }
    }

    // MARK: - Helpers

    private func resolvedFrames(
        _ entries: [SegmentAnchorEntry<Selection>], in geometry: GeometryProxy
    ) -> [Selection: CGRect] {
        var frames: [Selection: CGRect] = [:]
        for entry in entries {
            frames[entry.id] = geometry[entry.bounds]
        }
        return frames
    }

    private func draggedFrame(base: CGRect, frames: [Selection: CGRect]) -> CGRect {
        var result = base
        let rawX = base.minX + dragOffset
        let ordered = segments.compactMap { frames[$0] }
        guard let first = ordered.first, let last = ordered.last else { return base }
        let minX = first.minX
        let maxX = last.maxX - base.width
        result.origin.x = min(max(rawX, minX), maxX)
        return result
    }

    private func segment(at x: CGFloat) -> Selection? {
        let ordered = orderedFrames
        for (seg, frame) in ordered {
            if x >= frame.minX && x < frame.maxX {
                return seg
            }
        }
        if let first = ordered.first, x < first.1.minX {
            return first.0
        }
        if let last = ordered.last, x >= last.1.maxX {
            return last.0
        }
        return nil
    }
}
