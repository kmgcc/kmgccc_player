//
//  AudioSpectrumProviding.swift
//  myPlayer2
//
//  Thin provider protocol used by skins to subscribe to audio spectrum data.
//

import Foundation

protocol AudioSpectrumProviding: AnyObject {
    func start()
    func stop()
    func addConsumer(queue: DispatchQueue, consumer: @escaping ([Float]) -> Void) -> UUID
    func removeConsumer(id: UUID)
    func updatePlaybackState(isPlaying: Bool)
}

extension AudioVisualizationService: AudioSpectrumProviding {
    func addConsumer(queue: DispatchQueue, consumer: @escaping ([Float]) -> Void) -> UUID {
        addConsumer { values in
            queue.async {
                consumer(values)
            }
        }
    }

    func removeConsumer(id: UUID) {
        removeConsumer(id)
    }
}
