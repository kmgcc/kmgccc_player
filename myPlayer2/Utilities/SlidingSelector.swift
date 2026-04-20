//
//  SlidingSelector.swift
//  myPlayer2
//
//  kmgccc_player - Generic sliding-knob segmented selector.
//  Extracts the animation mechanism from PlaybackModeSlider for reuse.
//

import SwiftUI

// MARK: - Frame Measurement

private struct SegmentFrameEntry<ID: Hashable>: Equatable {
    let id: ID
    let frame: CGRect
}

private struct SegmentFramePreferenceKey<ID: Hashable>: PreferenceKey {
    static var defaultValue: [SegmentFrameEntry<ID>] { [] }
    static func reduce(value: inout [SegmentFrameEntry<ID>], nextValue: () -> [SegmentFrameEntry<ID>]) {
        value.append(contentsOf: nextValue())
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
///
/// Supports optional drag-to-switch and tap/retap callbacks.
struct SlidingSelector<Selection: Hashable, Background: View, Knob: View, Content: View>: View {
    let segments: [Selection]
    @Binding var selection: Selection
    let animation: Animation
    let hSpacing: CGFloat
    let enableDrag: Bool
    let onTap: ((Selection) -> Void)?
    let onDragEnd: ((Selection) -> Void)?
    @ViewBuilder let background: () -> Background
    @ViewBuilder let knob: () -> Knob
    @ViewBuilder let content: (Selection, Bool) -> Content

    @State private var frames: [Selection: CGRect] = [:]
    @State private var knobFrame: CGRect = .zero
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging: Bool = false
    @State private var instanceID = UUID()

    private var selectedFrame: CGRect? { frames[selection] }

    private var orderedFrames: [(Selection, CGRect)] {
        segments.compactMap { seg in
            frames[seg].map { (seg, $0) }
        }
    }

    private var coordinateSpaceName: String {
        "SlidingSelector_\(instanceID)"
    }

    init(
        segments: [Selection],
        selection: Binding<Selection>,
        animation: Animation = .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08),
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
        self.animation = animation
        self.hSpacing = hSpacing
        self.enableDrag = enableDrag
        self.onTap = onTap
        self.onDragEnd = onDragEnd
        self.background = background
        self.knob = knob
        self.content = content
    }

    var body: some View {
        let selector = segmentsLayer
            .background(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    background()
                        .allowsHitTesting(false)

                    knobLayer
                }
            }
            .coordinateSpace(name: coordinateSpaceName)
            .onPreferenceChange(SegmentFramePreferenceKey<Selection>.self) { entries in
                var newFrames: [Selection: CGRect] = [:]
                for entry in entries {
                    newFrames[entry.id] = entry.frame
                }
                frames = newFrames
            }

        if enableDrag {
            selector.simultaneousGesture(dragGesture)
        } else {
            selector
        }
    }

    // MARK: - Layers

    @ViewBuilder
    private var knobLayer: some View {
        if let frame = selectedFrame {
            let targetFrame = isDragging ? draggedFrame(base: frame) : frame
            knob()
                .frame(width: knobFrame.width, height: knobFrame.height)
                .offset(x: knobFrame.minX, y: knobFrame.minY)
                .allowsHitTesting(false)
                .onAppear {
                    if knobFrame == .zero {
                        knobFrame = targetFrame
                    }
                }
                .onChange(of: targetFrame) { oldValue, newValue in
                    guard oldValue != newValue else { return }
                    withAnimation(isDragging ? .none : animation) {
                        knobFrame = newValue
                    }
                }
        }
    }

    private var segmentsLayer: some View {
        HStack(spacing: hSpacing) {
            ForEach(segments, id: \.self) { segment in
                Button {
                    onTap?(segment)
                    selection = segment
                } label: {
                    content(segment, selection == segment)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .preference(
                                key: SegmentFramePreferenceKey<Selection>.self,
                                value: [SegmentFrameEntry(id: segment, frame: geo.frame(in: .named(coordinateSpaceName)))]
                            )
                    }
                )
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard selectedFrame != nil else { return }
                isDragging = true
                dragOffset = value.translation.width
            }
            .onEnded { value in
                guard let frame = selectedFrame else {
                    isDragging = false
                    dragOffset = 0
                    return
                }
                isDragging = false
                let finalX = frame.midX + value.translation.width
                if let target = segment(at: finalX), target != selection {
                    onDragEnd?(target)
                    withAnimation(animation) {
                        selection = target
                    }
                }
                dragOffset = 0
            }
    }

    // MARK: - Helpers

    private func draggedFrame(base: CGRect) -> CGRect {
        var result = base
        let rawX = base.minX + dragOffset
        let ordered = orderedFrames
        guard let first = ordered.first?.1, let last = ordered.last?.1 else { return base }
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
