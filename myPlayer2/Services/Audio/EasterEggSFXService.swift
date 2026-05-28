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

    private struct SoundAsset {
        let resourceName: String
        let fileExtension: String
    }

    private let assets = [
        SoundAsset(resourceName: "youdowhat", fileExtension: "wav"),
        SoundAsset(resourceName: "youdowhatreversed", fileExtension: "wav")
    ]
    private let cooldown: TimeInterval = 1.8
    private var lastPlayTimestamp: TimeInterval = 0
    private var player: AVAudioPlayer?

    func playRandomIfAllowed() {
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastPlayTimestamp >= cooldown else { return }
        guard player?.isPlaying != true else { return }
        guard let asset = assets.randomElement() else { return }
        guard let url = url(for: asset) else {
            Log.warning(
                "[EasterEggSFX] missing resource name=\(asset.resourceName) ext=\(asset.fileExtension)",
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
                    "[EasterEggSFX] AVAudioPlayer refused playback for \(asset.resourceName).\(asset.fileExtension)",
                    category: .audio
                )
                return
            }
            player = soundPlayer
            lastPlayTimestamp = now
            Log.debug(
                "[EasterEggSFX] played \(asset.resourceName).\(asset.fileExtension)",
                category: .audio
            )
        } catch {
            Log.error(
                "[EasterEggSFX] failed to initialize player for \(asset.resourceName).\(asset.fileExtension): \(error)",
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
}
