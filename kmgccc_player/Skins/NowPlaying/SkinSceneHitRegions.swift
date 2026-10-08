import AppKit
import SwiftUI

/// Authors can mark arbitrary SwiftUI controls with .skinControlRegion(). The native
/// lyric mount yields the hit to the hosting view only in these measured rectangles.
struct SkinControlRegionKey: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    func skinControlRegion() -> some View {
        anchorPreference(key: SkinControlRegionKey.self, value: .bounds) { [$0] }
    }
}

@MainActor
final class SkinSceneHitRegions {
    var windowRects: [CGRect] = []
    func contains(_ point: CGPoint) -> Bool { windowRects.contains { $0.contains(point) } }
}

extension EnvironmentValues {
    @Entry var skinSceneHitRegions: SkinSceneHitRegions?
}

struct SkinSceneHitRegionBridge: NSViewRepresentable {
    let regions: SkinSceneHitRegions
    let rectangles: [CGRect]
    func makeNSView(context: Context) -> RegionView { RegionView() }
    func updateNSView(_ view: RegionView, context: Context) {
        view.regions = regions
        view.rectangles = rectangles
        view.publish()
    }
    final class RegionView: NSView {
        override var isFlipped: Bool { true }
        var regions: SkinSceneHitRegions?
        var rectangles: [CGRect] = []
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() { super.layout(); publish() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); publish() }
        func publish() {
            guard window != nil else { return }
            regions?.windowRects = rectangles.map { convert($0, to: nil) }
        }
    }
}
