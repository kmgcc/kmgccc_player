//
//  StubCoverDownloadService.swift
//  myPlayer2
//
//  kmgccc_player - Stub Cover Download Service
//

import AppKit
import Observation
import Foundation

@Observable
@MainActor
final class StubCoverDownloadService: CoverDownloadServiceProtocol {
    func downloadCover(artist: String, album: String, size: Int) async throws -> Data {
        print("🖼️ StubCoverDownloadService: returning placeholder for \(artist) - \(album)")

        let image = NSImage(size: NSSize(width: max(size, 256), height: max(size, 256)))
        image.lockFocus()
        NSColor.systemGray.withAlphaComponent(0.2).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: image.size)).fill()
        image.unlockFocus()

        guard
            let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData),
            let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            throw CoverDownloadError.invalidImageData
        }

        return pngData
    }
}
