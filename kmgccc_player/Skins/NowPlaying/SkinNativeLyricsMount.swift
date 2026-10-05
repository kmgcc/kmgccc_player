import AppKit
import MelismaKit
import SwiftUI

/// A layout-owned container borrows the single manager-owned view. Removing an outgoing
/// container never detaches a view already moved to the next adaptive branch.
struct SkinNativeLyricsMount: NSViewRepresentable {
    let role: LyricsSurfaceRole
    @Environment(\.skinSceneHitRegions) private var hitRegions

    func makeNSView(context: Context) -> Container { Container() }

    func updateNSView(_ container: Container, context: Context) {
        container.hitRegions = hitRegions
        let lyrics = NativeLyricsSurfaceManager.shared.surface(for: role).view
        if lyrics.superview !== container {
            lyrics.removeFromSuperview()
            container.addSubview(lyrics)
        }
        lyrics.frame = container.bounds
        lyrics.autoresizingMask = [.width, .height]
    }

    static func dismantleNSView(_ container: Container, coordinator: ()) {
        for child in container.subviews { child.removeFromSuperview() }
    }

    final class Container: NSView {
        var hitRegions: SkinSceneHitRegions?
        override func hitTest(_ point: NSPoint) -> NSView? {
            let windowPoint = superview?.convert(point, to: nil) ?? point
            guard hitRegions?.contains(windowPoint) != true else { return nil }
            return super.hitTest(point)
        }
        override func layout() {
            super.layout()
            for child in subviews { child.frame = bounds }
        }
    }
}
