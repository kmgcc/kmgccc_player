//
//  AudioDSPEqualLoudnessNodeCard.swift
//  myPlayer2
//
//  Response preview for the equal-loudness stage shown in the effect rack.
//

import SwiftUI

struct AudioDSPEqualLoudnessResponseCurve: View, Equatable {
    let stage: DSPEqualLoudnessStage
    let context: DSPEqualLoudnessContext
    let sampleRate: Double
    let accentColor: Color

    private let dbSpan = 12.0

    var body: some View {
        GeometryReader { geometry in
            let plot = CGRect(
                x: 4,
                y: 4,
                width: max(1, geometry.size.width - 8),
                height: max(1, geometry.size.height - 8)
            )
            Canvas { canvas, _ in
                drawGrid(in: &canvas, plot: plot)
                drawResponse(in: &canvas, plot: plot)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("等响补偿频率响应曲线")
            .accessibilityValue(curveAccessibilityValue)
        }
        .frame(height: 96)
    }

    private var curveAccessibilityValue: String {
        let gains = DSPEqualLoudnessMath.gains(stage: stage, context: context)
        return "低音补偿 \(gains.bassDB.formatted(.number.precision(.fractionLength(1)))) dB，高音补偿 \(gains.trebleDB.formatted(.number.precision(.fractionLength(1)))) dB"
    }

    private func drawGrid(in context: inout GraphicsContext, plot: CGRect) {
        for value in stride(from: -12.0, through: 12.0, by: 6.0) {
            let y = plot.midY - plot.height * CGFloat(value / (dbSpan * 2))
            let line = Path(CGRect(x: plot.minX, y: y, width: plot.width, height: 0.6))
            context.fill(line, with: .color(.secondary.opacity(value == 0 ? 0.45 : 0.18)))
        }
    }

    private func drawResponse(in canvas: inout GraphicsContext, plot: CGRect) {
        guard sampleRate.isFinite, sampleRate > 0 else { return }
        let highFrequency = min(20_000, sampleRate * 0.49)
        let lowLog = log10(20.0)
        let highLog = log10(max(20.1, highFrequency))
        let pointCount = max(80, Int(plot.width))
        let coefficients = (DSPEqualLoudnessMath.bands(stage: stage, context: context) ?? [])
            .filter(\.enabled)
            .compactMap { DSPParametricEQMath.coefficients(for: $0, sampleRate: sampleRate) }
        var path = Path()
        for index in 0...pointCount {
            let position = Double(index) / Double(pointCount)
            let frequency = pow(10, lowLog + (highLog - lowLog) * position)
            let response = coefficients.reduce(0.0) {
                $0 + $1.responseDB(at: frequency, sampleRate: sampleRate)
            }
            let x = plot.minX + plot.width * CGFloat(position)
            let boundedResponse = min(dbSpan, max(-dbSpan, response))
            let y = plot.midY - plot.height * CGFloat(boundedResponse / (dbSpan * 2))
            let point = CGPoint(x: x, y: y)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        let responseLine = path.strokedPath(
            StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
        )
        canvas.fill(responseLine, with: .color(accentColor))
    }
}
