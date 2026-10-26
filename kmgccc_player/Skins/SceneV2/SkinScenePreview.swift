#if DEBUG
import AppKit
import MotionKit
import SwiftUI

/// Xcode canvas fixture. It has no library, playback transport, analysis lease or network.
struct SkinScenePreview: View {
    @State private var data = SkinSceneData()
    private let size = CGSize(width: 900, height: 600)
    private var snapshot: SkinSceneSnapshot {
        .init(context: .init(track: nil, playback: .init(isPlaying: true),
            theme: .init(accentColor: .orange, colorScheme: .dark, artworkAccentColor: .orange,
                artworkPalette: [.systemOrange, .systemPink], artworkAverageColor: .darkGray,
                artBackgroundIsUltraDark: false, spectrumArtworkColors: [.systemOrange], spectrumUsesDarkForeground: false),
            motionTokens: .standard, motionPolicy: .full, windowSize: size, contentBounds: CGRect(origin: .zero, size: size),
            fullscreenScale: 1, lyricsVisible: true, presentationMode: .nowPlaying, fullscreenHostMode: .none))
    }
    var body: some View {
        Group {
            if let program = try? SkinSceneCompiler.compile(Self.document) {
                SkinSceneNodeV2View(node: program.root, data: data, components: .init(catalog: SkinComponentCatalog(), snapshot: snapshot), size: size)
                    .background { SyntheticFeed(data: data) }
                    .onAppear {
                        data.set(.track, ["track.title": .text("夜航"), "track.artist": .text("Scene Preview")])
                        data.set(.theme, ["theme.globalAccent": .color(.rgb(0.95, 0.58, 0.25)), "theme.ambientSurface": .color(.rgb(0.06, 0.065, 0.09))])
                        data.set(.viewport, ["viewport.width": .number(size.width), "viewport.height": .number(size.height)])
                    }
            }
        }.frame(width: size.width, height: size.height).background(.black)
    }

    private static let document = SkinSceneV2Document(root: .object([
        "type": .text("layer"), "children": .array([
            .object(["type": .text("gradient"), "colors": .array([.text("=theme.ambientSurface"), .text("#251C33")]),
                     "frame": .object(["width": .text("100%"), "height": .text("100%")])]),
            .object(["type": .text("shape"), "shape": .text("circle"), "color": .text("=theme.globalAccent"),
                     "scale": .text("=1 + audio.bass * 0.15"), "opacity": .number(0.3),
                     "frame": .object(["x": .text("50%"), "y": .text("40%"), "size": .number(220)])]),
            .object(["type": .text("text"), "text": .text("=track.title"), "fontSize": .number(40), "color": .text("#FFFFFF"),
                     "frame": .object(["x": .text("50%"), "y": .text("40%"), "width": .number(400), "height": .number(80)]), "alignment": .text("center")]),
            .object(["type": .text("spectrum"), "count": .number(32), "color": .text("=theme.globalAccent"),
                     "frame": .object(["x": .text("50%"), "y": .text("80%"), "width": .number(650), "height": .number(70)])]),
        ])
    ]))

    private struct SyntheticFeed: View {
        let data: SkinSceneData
        var body: some View {
            TimelineView(.animation(minimumInterval: nil)) { timeline in
                Color.clear.onChange(of: timeline.date, initial: true) { _, date in
                    let now = date.timeIntervalSinceReferenceDate
                    let time = data.time(at: now)
                    data.clock.update(position: time.truncatingRemainder(dividingBy: 180), isPlaying: true, duration: 180, now: now)
                    let magnitudes: [Float] = (0..<1024).map { index in Float(0.15 + 0.1 * sin(time * 2 + Double(index) * 0.2)) }
                    data.audio.receiveSynthetic(magnitudes: magnitudes, pcm: [], level: (sin(time * 2) + 1) * 0.35)
                }
            }.allowsHitTesting(false)
        }
    }
}

#Preview("Native scene v2") { SkinScenePreview() }
#endif
