//
//  EasterEggSFXService.swift
//  myPlayer2
//
//  Lightweight one-shot SFX player for hidden interactions.
//

import AVFoundation
import Foundation

@MainActor
final class EasterEggSFXService {
    static let shared = EasterEggSFXService()

    private struct SoundAsset {
        let resourceName: String
        let fileExtension: String

        var fileName: String {
            "\(resourceName).\(fileExtension)"
        }
    }

    private let assets = [
        SoundAsset(resourceName: "youdowhat", fileExtension: "wav"),
        SoundAsset(resourceName: "youdowhatreversed", fileExtension: "wav")
    ]
    private let cooldown: TimeInterval = 1.8
    private var lastPlayTimestamp: TimeInterval = 0
    private var player: AVAudioPlayer?

    private init() {}

    func playRandomIfAllowed() {
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastPlayTimestamp >= cooldown else { return }
        guard player?.isPlaying != true else { return }
        guard let asset = assets.randomElement() else { return }
        guard let url = url(for: asset) else {
            Log.warning(
                missingResourceMessage(for: asset),
                category: .audio
            )
            return
        }

        do {
            let soundPlayer = try AVAudioPlayer(contentsOf: url)
            soundPlayer.volume = 1.0
            soundPlayer.prepareToPlay()
            guard soundPlayer.play() else {
                Log.warning(
                    "[EasterEggSFX] AVAudioPlayer refused playback for \(asset.fileName) url=\(url.path)",
                    category: .audio
                )
                return
            }
            player = soundPlayer
            lastPlayTimestamp = now
        } catch {
            Log.error(
                "[EasterEggSFX] failed to initialize player for \(asset.fileName) url=\(url.path) error=\(error)",
                category: .audio
            )
        }
    }

    private func url(for asset: SoundAsset) -> URL? {
        Bundle.main.url(
            forResource: asset.resourceName,
            withExtension: asset.fileExtension
        ) ?? Bundle.main.url(
            forResource: asset.resourceName,
            withExtension: asset.fileExtension,
            subdirectory: "Audio"
        )
    }

    private func candidateURLs(for asset: SoundAsset) -> [URL] {
        guard let resourceURL = Bundle.main.resourceURL else { return [] }
        return [
            resourceURL.appendingPathComponent(asset.fileName),
            resourceURL.appendingPathComponent("Audio").appendingPathComponent(asset.fileName)
        ]
    }

    private func missingResourceMessage(for asset: SoundAsset) -> String {
        let resourceURL = Bundle.main.resourceURL?.path ?? "nil"
        let candidates = candidateURLs(for: asset).map(\.path)
        return "[EasterEggSFX] missing resource name=\(asset.fileName) bundle=\(Bundle.main.bundleURL.path) resourceURL=\(resourceURL) candidates=\(candidates)"
    }
}
