import AppKit
import SwiftUI
import XCTest
@testable import kmgccc_player

@MainActor
final class MusicSettingsRenderTests: XCTestCase {
    func testLongPathContentRendersNonblankAt500Points() throws {
        let size = NSSize(width: 500, height: 620)
        let root = MusicSettingsContent(model: MusicSettingsContent.longPathFixture)
            .frame(width: size.width)
            .padding(16)
            .environmentObject(ThemeStore.shared)
            .foregroundStyle(Color.black)
            .background(Color.white)
        let hosting = NSHostingView(rootView: root.preferredColorScheme(.light))
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let bitmap = try XCTUnwrap(rep.bitmapData)
        let byteCount = rep.bytesPerRow * rep.pixelsHigh
        let bytes = UnsafeBufferPointer(start: bitmap, count: byteCount)
        let samplingStride = max(1, byteCount / 20_000)
        let sampledBytes = stride(from: 0, to: byteCount, by: samplingStride).map { bytes[$0] }

        XCTAssertEqual(hosting.bounds.width, 500)
        XCTAssertEqual(rep.pixelsWide, 500 * Int(NSScreen.main?.backingScaleFactor ?? 2))
        XCTAssertGreaterThan(Set(sampledBytes).count, 8)
        XCTAssertGreaterThan(png.count, 10_000)

        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "music-settings-500pt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
