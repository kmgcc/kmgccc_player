//
//  EasterEggSFXService.swift
//  myPlayer2
//
//  Lightweight one-shot SFX player for hidden interactions.
//

import AppKit
import AVFoundation
import Foundation

@MainActor
final class EasterEggSFXService {

    private let assetNames = ["youdowhat", "youdowhatr"]
    private let cooldown: TimeInterval = 1.8
    private var lastPlayTimestamp: TimeInterval = 0
    private var player: AVAudioPlayer?

    func playRandomIfAllowed() {
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastPlayTimestamp >= cooldown else { return }
        guard player?.isPlaying != true else { return }
        guard let assetName = assetNames.randomElement() else { return }
        guard let dataAsset = NSDataAsset(name: assetName) else {
            print("[EasterEggSFX] Missing data asset: \(assetName)")
            return
        }

        do {
            let soundPlayer = try AVAudioPlayer(data: dataAsset.data)
            soundPlayer.volume = 1.0
            soundPlayer.prepareToPlay()
            soundPlayer.play()
            player = soundPlayer
            lastPlayTimestamp = now
        } catch {
            print("[EasterEggSFX] Failed to play \(assetName): \(error)")
        }
    }
}
