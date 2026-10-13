//
//  DSPSpatialRoomView.swift
//  myPlayer2
//
//  Flat 3D room for the spatial-audio card: floor and two walls in one hue
//  at different opacities, the listener's head seen from behind and above,
//  two speakers placed by distance and angle, filled rings spreading from the
//  speakers with the playing level, and first reflections as rows of faint
//  dots. In impulse-response mode the far wall carries the response's decay
//  envelope. No strokes or shadows; depth comes only from fill lightness.
//
//  Geometry is drawn in an oblique projection. Room size, listener and
//  speaker positions follow MotionKit springs (`contentReplacement` for room
//  changes, `control` for the sliders), so a drag can retarget at any time.
//  Paths are rebuilt only while geometry moves; rings change only transform
//  and opacity per frame.
//

import AppKit
import MotionKit
import SwiftUI

struct DSPSpatialRoom: NSViewRepresentable {
    let parameters: DSPSpatialAudioParameters
    let isActive: Bool
    let accentColor: Color

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionPolicy) private var configuredMotionPolicy
    @Environment(\.motionTokens) private var motionTokens

    func makeNSView(context: Context) -> DSPSpatialRoomView {
        DSPSpatialRoomView()
    }

    func updateNSView(_ view: DSPSpatialRoomView, context: Context) {
        view.motionPolicy = configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion)
        view.configure(
            layout: DSPSpatialRoomLayout(parameters: parameters),
            impulseResponseID: parameters.source == .impulseResponse ? parameters.impulseResponseID : nil,
            controlSpec: motionTokens[.control],
            roomSpec: motionTokens[.contentReplacement],
            colors: DSPCardVisualColors(accent: NSColor(accentColor), isDark: colorScheme == .dark),
            isActive: isActive
        )
    }

    static func dismantleNSView(_ view: DSPSpatialRoomView, coordinator: ()) {
        view.stopListening()
    }
}

/// Display geometry in compressed room units: each length is shown as
/// `meters^0.7`, so a hall still reads larger than a studio while the
/// listener and speakers stay legible in both.
struct DSPSpatialRoomLayout: Equatable {
    var width: Double
    var length: Double
    var height: Double
    /// Listener depth from the near wall.
    var listenerDepth: Double
    var speakerDistance: Double
    var speakerAngle: Double
    var showsWalls: Bool

    private static func display(_ meters: Double) -> Double { pow(max(meters, 0), 0.7) }

    init(parameters: DSPSpatialAudioParameters) {
        // An impulse response carries its own room; show a neutral one.
        let preset = parameters.source == .impulseResponse ? DSPRoomPreset.studio : parameters.room
        let angle = min(max(parameters.speakerAngleDeg, 20), 45) * Double.pi / 180
        speakerAngle = angle
        if let room = DSPRoomSynthesis.Room.preset(preset) {
            // Same fitting as the room synthesis, so the picture matches
            // what is heard.
            let margin = 0.4
            var distance = min(parameters.distanceM,
                               (room.length - 2 * margin) / max(cos(angle), 0.1),
                               (room.width / 2 - margin) / max(sin(angle), 0.1))
            distance = max(0.5, distance)
            let listener = max(margin, min(room.length * 0.5, room.length - margin - distance * cos(angle)))
            width = Self.display(room.width)
            length = Self.display(room.length)
            height = Self.display(room.height)
            listenerDepth = length * listener / room.length
            speakerDistance = min(Self.display(distance), (length - listenerDepth - 0.15) / max(cos(angle), 0.1))
            showsWalls = true
        } else {
            width = Self.display(6)
            length = Self.display(6.5)
            height = 0
            listenerDepth = length * 0.3
            speakerDistance = Self.display(parameters.distanceM)
            showsWalls = false
        }
    }
}

final class DSPSpatialRoomView: DSPCardAnimatedView {
    /// Geometry values in drawing order: the room bank's four followers,
    /// then the placement bank's three.
    private enum Slot: Int, CaseIterable {
        case width, length, height, walls, listenerDepth, distance, angle
    }

    /// Oblique projection: depth runs up and to the right.
    private static let depthX = 0.35
    private static let depthY = 0.5
    /// Walls are drawn lower than their true height to leave room for depth.
    private static let wallScale = 0.55
    private static let ringCount = 3
    private static let ringPeriod = 1.6

    private var room: DSPFollowerBank
    private var placement: DSPFollowerBank
    private var level: DSPFollowerBank
    private var controlSpec = MotionTokens.standard[.control]
    private var roomSpec = MotionTokens.standard[.contentReplacement]
    private var hasPlaced = false
    private var colors: DSPCardVisualColors?
    private var isActive = false
    private var impulseResponseID: String?
    private var envelope: [Double] = []
    private var currentGeometry = [Double](repeating: 0, count: Slot.allCases.count)
    private var needsGeometry = true
    private var inputBands = [Float](repeating: 0, count: DSPCardSpectrumFeed.bandCount)
    private var holdsFeedLease = false

    private let floorLayer = CAShapeLayer()
    private let leftWallLayer = CAShapeLayer()
    private let farWallLayer = CAShapeLayer()
    private let envelopeLayer = CAShapeLayer()
    private let reflectionLayer = CAShapeLayer()
    private let ringLayers = (0..<(2 * DSPSpatialRoomView.ringCount)).map { _ in CAShapeLayer() }
    private let speakerLayers = (0..<2).map { _ in CAShapeLayer() }
    private let headLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        room = DSPFollowerBank(count: 4, spec: MotionTokens.standard[.contentReplacement], policy: .full)
        placement = DSPFollowerBank(count: 3, spec: MotionTokens.standard[.control], policy: .full)
        level = DSPFollowerBank(count: 1, spec: CapsuleSpectrumDynamics.standard.motionSpec, policy: .full)
        super.init(frame: frameRect)
        for shape in [floorLayer, leftWallLayer, farWallLayer, envelopeLayer, reflectionLayer] {
            layer?.addSublayer(shape)
        }
        for ring in ringLayers {
            ring.fillRule = .evenOdd
            ring.opacity = 0
            layer?.addSublayer(ring)
        }
        for speaker in speakerLayers { layer?.addSublayer(speaker) }
        layer?.addSublayer(headLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        layout: DSPSpatialRoomLayout,
        impulseResponseID: String?,
        controlSpec: MotionSpec,
        roomSpec: MotionSpec,
        colors: DSPCardVisualColors,
        isActive: Bool
    ) {
        self.controlSpec = controlSpec
        self.roomSpec = roomSpec
        let time = CACurrentMediaTime()
        // A room change replaces content; slider moves are direct control.
        room.update(spec: roomSpec, policy: motionPolicy)
        placement.update(spec: controlSpec, policy: motionPolicy)
        let roomTargets = [layout.width, layout.length, layout.height, layout.showsWalls ? 1 : 0]
        for (index, value) in roomTargets.enumerated() {
            room.setTarget(value, at: index, time: time, epsilon: 0.0001)
        }
        let placementTargets = [layout.listenerDepth, layout.speakerDistance, layout.speakerAngle]
        for (index, value) in placementTargets.enumerated() {
            placement.setTarget(value, at: index, time: time, epsilon: 0.0001)
        }
        if !hasPlaced {
            room.snapAll()
            placement.snapAll()
            hasPlaced = true
        }
        if colors != self.colors || isActive != self.isActive {
            self.colors = colors
            self.isActive = isActive
            applyColors()
        }
        if impulseResponseID != self.impulseResponseID {
            self.impulseResponseID = impulseResponseID
            envelope = []
            loadEnvelope()
        }
        needsGeometry = true
        wake()
    }

    func stopListening() {
        DSPCardSpectrumFeed.shared.cancelWake(owner: self)
        releaseFeed()
    }

    override func motionPolicyDidChange() {
        room.update(spec: roomSpec, policy: motionPolicy)
        placement.update(spec: controlSpec, policy: motionPolicy)
        level.update(spec: CapsuleSpectrumDynamics.standard.motionSpec, policy: motionPolicy)
    }

    override func visibilityDidChange(_ isVisible: Bool) {
        if isVisible {
            if !holdsFeedLease {
                holdsFeedLease = true
                DSPCardSpectrumFeed.shared.acquire()
            }
        } else {
            DSPCardSpectrumFeed.shared.cancelWake(owner: self)
            releaseFeed()
        }
    }

    override func boundsDidChange() {
        needsGeometry = true
    }

    private func releaseFeed() {
        guard holdsFeedLease else { return }
        holdsFeedLease = false
        DSPCardSpectrumFeed.shared.release()
    }

    // MARK: Frame

    override func renderFrame(at time: CFTimeInterval) -> Bool {
        let pulses = motionPolicy == .full && isActive
        let input = pulses ? DSPCardSpectrumFeed.shared.read(into: &inputBands) : 0
        level.setTarget(Double(input), at: 0, time: time, epsilon: 0.002)
        let roomMoving = room.advance(to: time, epsilon: 0.0005)
        let placementMoving = placement.advance(to: time, epsilon: 0.0005)
        let geometryMoving = roomMoving || placementMoving
        let levelMoving = level.advance(to: time, epsilon: 0.002)

        var changed = needsGeometry
        for index in 0..<4 where currentGeometry[index] != room.value(index) {
            currentGeometry[index] = room.value(index)
            changed = true
        }
        for index in 0..<3 where currentGeometry[4 + index] != placement.value(index) {
            currentGeometry[4 + index] = placement.value(index)
            changed = true
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if changed {
            drawGeometry(currentGeometry)
            needsGeometry = false
        }
        let ringLevel = min(1, max(0, level.value(0)))
        drawRings(at: time, level: pulses ? ringLevel : 0, geometry: currentGeometry)
        CATransaction.commit()

        let ringsVisible = pulses && (ringLevel > 0.01 || input > 0)
        let keepRunning = geometryMoving || levelMoving || ringsVisible
        if !keepRunning, pulses, isVisibleOnScreen {
            DSPCardSpectrumFeed.shared.wakeOnNextUpdate(owner: self) { [weak self] in self?.wake() }
        }
        return keepRunning
    }

    // MARK: Projection

    private struct Projection {
        var scale: Double
        var origin: CGPoint
        var width: Double

        /// World point (x lateral from centre, y depth from near wall, z up).
        func point(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
            CGPoint(x: origin.x + (x + width / 2 + y * DSPSpatialRoomView.depthX) * scale,
                    y: origin.y - (y * DSPSpatialRoomView.depthY + z) * scale)
        }
    }

    private func projection(for values: [Double]) -> Projection {
        let width = values[Slot.width.rawValue]
        let length = values[Slot.length.rawValue]
        let wallHeight = values[Slot.height.rawValue] * Self.wallScale * values[Slot.walls.rawValue]
        let extentX = width + length * Self.depthX
        let extentY = length * Self.depthY + max(wallHeight, 0.3)
        let inset = 8.0
        let scale = max(1, min((Double(bounds.width) - inset * 2) / max(extentX, 0.1),
                               (Double(bounds.height) - inset * 2) / max(extentY, 0.1)))
        let originX = (Double(bounds.width) - extentX * scale) / 2
        let originY = Double(bounds.height) - (Double(bounds.height) - extentY * scale) / 2
        return Projection(scale: scale, origin: CGPoint(x: originX, y: originY), width: width)
    }

    private func speakerPositions(_ values: [Double]) -> [(x: Double, y: Double)] {
        let depth = values[Slot.listenerDepth.rawValue]
        let distance = values[Slot.distance.rawValue]
        let angle = values[Slot.angle.rawValue]
        return [(-distance * sin(angle), depth + distance * cos(angle)),
                (distance * sin(angle), depth + distance * cos(angle))]
    }

    private func drawGeometry(_ values: [Double]) {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let projection = projection(for: values)
        let width = values[Slot.width.rawValue]
        let length = values[Slot.length.rawValue]
        let walls = min(1, max(0, values[Slot.walls.rawValue]))
        let wallHeight = values[Slot.height.rawValue] * Self.wallScale * walls
        let half = width / 2

        floorLayer.path = polygon([
            projection.point(-half, 0, 0), projection.point(half, 0, 0),
            projection.point(half, length, 0), projection.point(-half, length, 0),
        ])
        farWallLayer.path = polygon([
            projection.point(-half, length, 0), projection.point(half, length, 0),
            projection.point(half, length, wallHeight), projection.point(-half, length, wallHeight),
        ])
        leftWallLayer.path = polygon([
            projection.point(-half, 0, 0), projection.point(-half, length, 0),
            projection.point(-half, length, wallHeight), projection.point(-half, 0, wallHeight),
        ])
        farWallLayer.opacity = Float(walls)
        leftWallLayer.opacity = Float(walls)

        // Decay envelope of an imported response, rising from the far wall's floor.
        if envelope.count > 1, wallHeight > 0 {
            let path = CGMutablePath()
            path.move(to: projection.point(-half, length, 0))
            for (index, value) in envelope.enumerated() {
                let x = -half + width * Double(index) / Double(envelope.count - 1)
                path.addLine(to: projection.point(x, length, wallHeight * 0.85 * value))
            }
            path.addLine(to: projection.point(half, length, 0))
            path.closeSubpath()
            envelopeLayer.path = path
            envelopeLayer.isHidden = false
        } else {
            envelopeLayer.isHidden = true
        }

        let depth = values[Slot.listenerDepth.rawValue]
        let head = projection.point(0, depth, 0)
        let headRadius = max(6, min(10, projection.scale * 0.22))
        headLayer.path = headPath(center: head, radius: headRadius)

        let speakers = speakerPositions(values)
        let speakerSize = max(7, min(12, projection.scale * 0.26))
        for (index, speaker) in speakers.enumerated() {
            let center = projection.point(speaker.x, speaker.y, 0)
            let rect = CGRect(x: center.x - speakerSize / 2, y: center.y - speakerSize,
                              width: speakerSize, height: speakerSize * 1.3)
            speakerLayers[index].path = CGPath(roundedRect: rect, cornerWidth: speakerSize * 0.28,
                                               cornerHeight: speakerSize * 0.28, transform: nil)
        }

        // First reflections off the side and far walls, as fine dotted
        // paths on the floor. They stop short of the speakers and the head,
        // which stand on top of them.
        let dots = CGMutablePath()
        if walls > 0.5 {
            let dotRadius = 0.7
            let spacing = 4.5
            // Around each shape's drawn centre: speakers rise from their
            // floor point, the head sits just above its own.
            var clearings: [(center: CGPoint, radius: CGFloat)] = speakers.map { speaker in
                let base = projection.point(speaker.x, speaker.y, 0)
                return (CGPoint(x: base.x, y: base.y - speakerSize * 0.35), CGFloat(speakerSize * 0.95))
            }
            clearings.append((CGPoint(x: head.x, y: head.y - headRadius * 0.9), CGFloat(headRadius * 1.45)))
            clearings.append((head, CGFloat(headRadius * 0.9)))
            for speaker in speakers {
                let mirrored: [(x: Double, y: Double)] = [
                    (-2 * half - speaker.x, speaker.y),
                    (2 * half - speaker.x, speaker.y),
                    (speaker.x, 2 * length - speaker.y),
                ]
                for image in mirrored {
                    guard let bounce = reflectionPoint(from: (0, depth), toward: image, half: half, length: length)
                    else { continue }
                    for (from, to) in [((speaker.x, speaker.y), bounce), (bounce, (0.0, depth))] {
                        let start = projection.point(from.0, from.1, 0)
                        let end = projection.point(to.0, to.1, 0)
                        let count = max(2, Int(hypot(end.x - start.x, end.y - start.y) / spacing))
                        for step in 1..<count {
                            let t = CGFloat(step) / CGFloat(count)
                            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                            guard !clearings.contains(where: { hypot(point.x - $0.center.x, point.y - $0.center.y) < $0.radius })
                            else { continue }
                            dots.addEllipse(in: CGRect(x: point.x - dotRadius, y: point.y - dotRadius,
                                                       width: dotRadius * 2, height: dotRadius * 2))
                        }
                    }
                }
            }
        }
        reflectionLayer.path = dots
    }

    /// Where the straight line from the listener to an image source crosses
    /// the room boundary.
    private func reflectionPoint(from listener: (x: Double, y: Double), toward image: (x: Double, y: Double),
                                 half: Double, length: Double) -> (Double, Double)? {
        let dx = image.x - listener.x
        let dy = image.y - listener.y
        var best: Double?
        if dx < 0 { best = min(best ?? .infinity, (-half - listener.x) / dx) }
        if dx > 0 { best = min(best ?? .infinity, (half - listener.x) / dx) }
        if dy > 0 { best = min(best ?? .infinity, (length - listener.y) / dy) }
        guard let t = best, t > 0, t < 1 else { return nil }
        return (listener.x + dx * t, listener.y + dy * t)
    }

    private func drawRings(at time: CFTimeInterval, level: Double, geometry values: [Double]) {
        guard level > 0.005, bounds.width > 1 else {
            for ring in ringLayers where ring.opacity != 0 { ring.opacity = 0 }
            return
        }
        let projection = projection(for: values)
        let speakers = speakerPositions(values)
        let baseRadius = max(10, min(18, projection.scale * 0.4))
        for (speakerIndex, speaker) in speakers.enumerated() {
            let center = projection.point(speaker.x, speaker.y, 0)
            for ringIndex in 0..<Self.ringCount {
                let ring = ringLayers[speakerIndex * Self.ringCount + ringIndex]
                if ring.path == nil || ring.bounds.width != CGFloat(baseRadius * 2) {
                    ring.bounds = CGRect(x: 0, y: 0, width: baseRadius * 2, height: baseRadius * 2)
                    ring.path = ringPath(radius: baseRadius)
                }
                var phase = (time / Self.ringPeriod + Double(ringIndex) / Double(Self.ringCount))
                    .truncatingRemainder(dividingBy: 1)
                if phase < 0 { phase += 1 }
                let scale = 0.35 + 2.1 * phase
                ring.position = center
                // Rings lie on the floor: squash them to the projection.
                ring.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale * Self.depthY * 1.2))
                ring.opacity = Float((1 - phase) * (1 - phase) * level * 0.55)
            }
        }
    }

    // MARK: Paths and colours

    private func polygon(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }

    /// Head seen from behind and above: the skull with two ears.
    private func headPath(center: CGPoint, radius: Double) -> CGPath {
        let path = CGMutablePath()
        let headCenter = CGPoint(x: center.x, y: center.y - radius * 0.9)
        path.addEllipse(in: CGRect(x: headCenter.x - radius, y: headCenter.y - radius,
                                   width: radius * 2, height: radius * 2))
        let earWidth = radius * 0.42
        let earHeight = radius * 0.7
        for side in [-1.0, 1.0] {
            let earX = headCenter.x + side * radius * 0.98
            path.addEllipse(in: CGRect(x: earX - earWidth / 2, y: headCenter.y - earHeight / 2,
                                       width: earWidth, height: earHeight))
        }
        return path
    }

    private func ringPath(radius: Double) -> CGPath {
        let path = CGMutablePath()
        let outer = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        path.addEllipse(in: outer)
        path.addEllipse(in: outer.insetBy(dx: radius * 0.16, dy: radius * 0.16))
        return path
    }

    private func applyColors() {
        guard let colors else { return }
        let emphasis: CGFloat = isActive ? 1 : 0.55
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        floorLayer.fillColor = colors.accent(alpha: (colors.isDark ? 0.12 : 0.09) * emphasis)
        farWallLayer.fillColor = colors.accent(alpha: (colors.isDark ? 0.2 : 0.15) * emphasis)
        leftWallLayer.fillColor = colors.accent(alpha: (colors.isDark ? 0.07 : 0.05) * emphasis)
        envelopeLayer.fillColor = colors.accent(alpha: 0.32 * emphasis)
        reflectionLayer.fillColor = colors.accent(alpha: 0.32 * emphasis)
        for ring in ringLayers { ring.fillColor = colors.accent(alpha: 1) }
        for speaker in speakerLayers { speaker.fillColor = colors.accent(alpha: 0.9 * emphasis) }
        headLayer.fillColor = colors.ink(alpha: (colors.isDark ? 0.7 : 0.6) * emphasis)
        CATransaction.commit()
    }

    private func loadEnvelope() {
        guard let id = impulseResponseID, !id.isEmpty else { return }
        Task { [weak self] in
            let envelope = await Task.detached(priority: .utility) {
                DSPSpatialRoomView.decayEnvelope(id: id)
            }.value
            guard let self, self.impulseResponseID == id else { return }
            self.envelope = envelope
            self.needsGeometry = true
            self.wake()
        }
    }

    /// Smoothed energy of the response over 48 slices, 60 dB mapped to 0…1.
    nonisolated private static func decayEnvelope(id: String) -> [Double] {
        guard let channels = DSPImpulseResponseStore.responses(id: id, sampleRate: 48_000),
              let frames = channels.first?.count, frames > 0 else { return [] }
        let slices = 48
        let sliceLength = max(1, frames / slices)
        var levels: [Double] = []
        for slice in 0..<slices {
            let start = slice * sliceLength
            guard start < frames else { break }
            let end = min(frames, start + sliceLength)
            var energy = 0.0
            for channel in channels {
                for frame in start..<end { energy += channel[frame] * channel[frame] }
            }
            levels.append(10 * log10(max(energy / Double(end - start), 1e-12)))
        }
        guard let peak = levels.max() else { return [] }
        return levels.map { min(1, max(0, ($0 - peak + 60) / 60)) }
    }
}
