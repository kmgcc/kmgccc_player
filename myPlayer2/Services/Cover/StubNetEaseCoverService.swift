//
//  StubNetEaseCoverService.swift
//  myPlayer2
//
//  kmgccc_player - Stub NetEase Cover Service
//

import AppKit
import Observation
import Foundation

@Observable
@MainActor
final class StubNetEaseCoverService: NetEaseCoverServiceProtocol {
    func searchAndDownloadCover(artist: String, album: String) async throws -> Data {
        print("🌐 StubNetEaseCoverService: returning placeholder for \(artist) - \(album)")

        let image = NSImage(size: NSSize(width: 512, height: 512))
        image.lockFocus()
        NSColor.systemBlue.withAlphaComponent(0.15).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: image.size)).fill()
        image.unlockFocus()

        guard
            let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData),
            let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            throw NetEaseCoverError.imageDownloadFailed(underlying: CoverDownloadError.invalidImageData)
        }

        return pngData
    }
}
