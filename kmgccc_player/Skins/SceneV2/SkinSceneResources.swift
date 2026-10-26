import AppKit
import AVFoundation
import CoreText
import SwiftUI

enum SkinResourceResolver {
    static func resolve(_ path: String, root: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(":"), !path.split(separator: "/").contains("..") else {
            throw SkinPackageError.invalidManifest("资源路径无效：\(path)")
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let target = base.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard target.path.hasPrefix(base.path + "/") else { throw SkinPackageError.invalidManifest("资源超出包目录：\(path)") }
        return target
    }
}

struct SkinPackageImage: View {
    let path: String
    let fit: String
    @Environment(\.skinPackageResources) private var root
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: fit == "fill" ? .fill : .fit) }
        }
        .task(id: "\(root?.path ?? "")/\(path)") {
            image = root.flatMap { try? SkinResourceResolver.resolve(path, root: $0) }.flatMap(NSImage.init(contentsOf:))
        }
    }
}

struct SkinPackageVideo: NSViewRepresentable {
    let path: String
    let active: Bool
    let isPlaying: Bool
    @Environment(\.skinPackageResources) private var root
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeNSView(context: Context) -> PlayerView { PlayerView() }
    func updateNSView(_ view: PlayerView, context: Context) {
        let url = root.flatMap { try? SkinResourceResolver.resolve(path, root: $0) }
        view.update(url: url, playing: active && isPlaying && !reduceMotion)
    }
    static func dismantleNSView(_ view: PlayerView, coordinator: ()) { view.release() }

    final class PlayerView: NSView {
        private let playerLayer = AVPlayerLayer()
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var url: URL?
        override init(frame: NSRect) {
            super.init(frame: frame); wantsLayer = true
            playerLayer.videoGravity = .resizeAspectFill; layer?.addSublayer(playerLayer)
        }
        required init?(coder: NSCoder) { nil }
        override func layout() { super.layout(); playerLayer.frame = bounds }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func update(url: URL?, playing: Bool) {
            if self.url != url {
                release(); self.url = url
                if let url {
                    let queue = AVQueuePlayer(); queue.isMuted = true
                    looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
                    player = queue; playerLayer.player = queue
                }
            }
            if playing { player?.play() } else { player?.pause() }
        }
        func release() {
            player?.pause(); looper?.disableLooping(); player?.removeAllItems()
            playerLayer.player = nil; looper = nil; player = nil; url = nil
        }
    }
}

/// Reference counts prevent one of two visible hosts from unregistering the other's font.
@MainActor
final class SkinFontLease {
    private static var references: [URL: Int] = [:]
    private var urls: [URL] = []
    func load(paths: [String], root: URL?) throws {
        release()
        guard let root else { return }
        for path in paths {
            let url = try SkinResourceResolver.resolve(path, root: root)
            if Self.references[url] == nil {
                var error: Unmanaged<CFError>?
                guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) else {
                    throw SkinPackageError.invalidManifest("字体无法载入：\(path)")
                }
            }
            Self.references[url, default: 0] += 1; urls.append(url)
        }
    }
    func release() {
        for url in urls {
            let remaining = (Self.references[url] ?? 1) - 1
            if remaining <= 0 { CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil); Self.references.removeValue(forKey: url) }
            else { Self.references[url] = remaining }
        }
        urls.removeAll()
    }
}

struct SkinSceneAudioCanvas: View {
    let kind: String
    let data: SkinSceneData
    let values: [String: SkinValue]
    let now: Double
    let color: Color
    var body: some View {
        Canvas { context, size in
            let count = max(1, min(512, values["count"]?.integer(32) ?? 32))
            let gain = values["gain"]?.number(1) ?? 1
            let foreground = values["color"]?.colorValue?.swiftUIColor ?? color
            if kind == "waveform" {
                let points = data.waveform(count: count)
                var path = Path()
                for (index, sample) in points.enumerated() {
                    let point = CGPoint(x: Double(index) / Double(max(1, points.count - 1)) * size.width, y: size.height * (0.5 - sample * gain * 0.5))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(foreground), lineWidth: values["lineWidth"]?.number(2) ?? 2)
            } else {
                let samples = kind == "meter" ? [data.audio.value("audio.level", now: now).number()] : data.spectrum(count: count, lowHz: 20, highHz: 16000, now: now)
                let width = size.width / Double(max(1, samples.count))
                for (index, sample) in samples.enumerated() {
                    let height = max(1, min(size.height, sample * gain * size.height))
                    let rect = CGRect(x: Double(index) * width + 1, y: size.height - height, width: max(1, width - 2), height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: min(width / 2, 4)), with: .color(foreground))
                }
            }
        }.accessibilityHidden(true)
    }
}

/// Deterministic particles: every position is a function of time and the particle's index, so
/// nothing is simulated or stored. Without `lifetime` they drift upward as dust; with `lifetime`
/// each particle is emitted at a random point, travels along `angle` ± `spread` degrees at
/// `speed` points per second, fades in and out over its life, and draws a tail of `trail` seconds.
struct SkinSceneParticles: View {
    let data: SkinSceneData
    let values: [String: SkinValue]
    let now: Double
    let reduceMotion: Bool
    var body: some View {
        Canvas { context, size in
            if let lifetime = values["lifetime"]?.numberValue, lifetime > 0 {
                emit(in: &context, size: size, lifetime: lifetime)
                return
            }
            let count = max(1, min(1024, values["count"]?.integer(80) ?? 80))
            let time = data.time(at: now) * (values["speed"]?.number(0.1) ?? 0.1)
            let color = values["color"]?.colorValue?.swiftUIColor ?? .white
            let radius = values["size"]?.number(2) ?? 2
            let seed = values["seed"]?.number() ?? 0
            for index in 0..<count {
                let n = Double(index) + seed
                let x = fract(sin(n * 127.1 + 4) * 43758.5453)
                let y = fract(sin(n * 311.7 + 7) * 96321.912 + time * (0.2 + x))
                let rect = CGRect(x: x * size.width, y: (1 - y) * size.height, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.2 + x * 0.7)))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private func emit(in context: inout GraphicsContext, size: CGSize, lifetime: Double) {
        let count = max(1, min(512, values["count"]?.integer(12) ?? 12))
        let time = data.time(at: now)
        let colors = (values["colors"]?.listValue ?? []).compactMap { $0.colorValue?.swiftUIColor }
        let palette = colors.isEmpty ? [values["color"]?.colorValue?.swiftUIColor ?? .white] : colors
        let radius = values["size"]?.number(2) ?? 2
        let seed = values["seed"]?.number() ?? 0
        let angle = (values["angle"]?.number(-90) ?? -90) * .pi / 180
        let spread = (values["spread"]?.number(20) ?? 20) * .pi / 180
        let speed = values["speed"]?.number(120) ?? 120
        let trail = max(0, values["trail"]?.number() ?? 0)
        for index in 0..<count {
            let n = Double(index) + seed * 101
            let local = time / lifetime + hash(n, 1)
            let cycle = floor(local), t = local - cycle
            let x0 = hash(n + cycle * 7.13, 2) * size.width, y0 = hash(n + cycle * 7.13, 3) * size.height
            let direction = angle + (hash(n + cycle * 7.13, 4) - 0.5) * spread
            let velocity = speed * (0.6 + 0.8 * hash(n + cycle * 7.13, 5))
            func point(_ t: Double) -> CGPoint {
                CGPoint(x: x0 + cos(direction) * velocity * t * lifetime, y: y0 + sin(direction) * velocity * t * lifetime)
            }
            let head = point(t)
            let alpha = sin(.pi * t)
            let color = palette[Int(hash(n, 6) * Double(palette.count)) % palette.count]
            let dot = radius * (0.6 + 0.8 * hash(n, 7))
            if trail > 0 {
                let tail = point(max(0, t - trail / lifetime))
                var line = Path(); line.move(to: tail); line.addLine(to: head)
                context.stroke(line, with: .linearGradient(Gradient(colors: [color.opacity(0), color.opacity(alpha)]), startPoint: tail, endPoint: head),
                               style: StrokeStyle(lineWidth: dot * 1.2, lineCap: .round))
            }
            context.fill(Path(ellipseIn: CGRect(x: head.x - dot, y: head.y - dot, width: dot * 2, height: dot * 2)), with: .color(color.opacity(alpha)))
        }
    }

    private func hash(_ n: Double, _ salt: Double) -> Double { fract(sin(n * 127.1 + salt * 311.7) * 43758.5453) }
    private func fract(_ value: Double) -> Double { value - floor(value) }
}
