//
//  HomePerfOverlay.swift
//  myPlayer2
//
//  DEBUG-only live performance overlay for the Home page.
//  Displays body invalidation counters and image-task metrics.
//  Gated by HomeDebugFlags.showPerfOverlay; file only compiles in DEBUG.
//

#if DEBUG
import SwiftUI
import Combine

struct HomePerfOverlay: View {
    @State private var bodySnapshot: [String: Int] = [:]
    @State private var previousBodySnapshot: [String: Int] = [:]
    @State private var imageSnapshot: HomePerfImageMetrics.Snapshot = .init(
        inflight: 0, totalStarted: 0, totalEnded: 0, totalCancelled: 0
    )
    @State private var timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text("Home Perf")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)

            ForEach(sortedBodyKeys, id: \.self) { key in
                let current = bodySnapshot[key] ?? 0
                let previous = previousBodySnapshot[key] ?? 0
                let delta = current - previous
                HStack(spacing: 4) {
                    Text(key)
                        .font(.system(size: 9, design: .monospaced))
                    Text("\(current)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                    if delta != 0 {
                        Text("(+\(delta))")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(delta > 5 ? .red : .yellow)
                    }
                }
            }

            Divider()
                .overlay(.white.opacity(0.3))

            HStack(spacing: 4) {
                Text("img inflight")
                    .font(.system(size: 9, design: .monospaced))
                Text("\(imageSnapshot.inflight)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(imageSnapshot.inflight > 10 ? .red : .green)
            }
            HStack(spacing: 4) {
                Text("img started")
                    .font(.system(size: 9, design: .monospaced))
                Text("\(imageSnapshot.totalStarted)")
                    .font(.system(size: 9, design: .monospaced))
            }
        }
        .padding(8)
        .background(.black.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onReceive(timer) { _ in
            previousBodySnapshot = bodySnapshot
            bodySnapshot = HomePerf.bodyCounters.snapshot()
            imageSnapshot = HomePerf.imageMetrics.snapshot()
        }
    }

    private var sortedBodyKeys: [String] {
        bodySnapshot.keys.sorted()
    }
}
#endif
