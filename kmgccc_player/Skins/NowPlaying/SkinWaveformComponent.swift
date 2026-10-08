import SwiftUI

/// An official component also serves as a working example of the author PCM reader.
struct SkinWaveformComponent: View {
    let configuration: SkinComponentConfiguration
    var body: some View {
        SkinAudioReader { feed in
            Canvas { context, size in
                guard let samples = feed.frame?.pcmSamples, !samples.isEmpty else { return }
                var path = Path()
                let count = min(samples.count, max(2, Int(size.width)))
                let gain = configuration.number("gain", fallback: 1)
                for index in 0..<count {
                    let sample = samples[index * (samples.count - 1) / (count - 1)]
                    let point = CGPoint(x: Double(index) / Double(count - 1) * size.width,
                                        y: size.height * (0.5 - Double(sample) * gain * 0.5))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(configuration.color(fallback: .primary)),
                               lineWidth: configuration.number("lineWidth", fallback: 1.5))
            }
        }
    }
}
