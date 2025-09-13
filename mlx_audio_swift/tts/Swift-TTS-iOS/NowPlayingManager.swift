//
//  NowPlayingManager.swift
//  Swift-TTS-iOS
//

import Foundation
import MediaPlayer
import AVFoundation

final class NowPlayingManager {
    static let shared = NowPlayingManager()
    private init() {}

    private var timer: Timer?
    private var startDate: Date?
    private var elapsedBeforeStart: TimeInterval = 0
    private var isActive = false

    func configure(title: String, artist: String?, duration: TimeInterval?) {
        DispatchQueue.main.async {
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: title
            ]
            if let artist = artist {
                info[MPMediaItemPropertyArtist] = artist
            }
            if let duration = duration, duration > 0 {
                info[MPMediaItemPropertyPlaybackDuration] = duration
            }
            info[MPNowPlayingInfoPropertyIsLiveStream] = false
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    func startProgress() {
        DispatchQueue.main.async {
            self.isActive = true
            self.startDate = Date()
            self.updatePlaybackRate(1.0)
            self.startTimer()
        }
    }

    func pause() {
        DispatchQueue.main.async {
            guard self.isActive else { return }
            if let start = self.startDate {
                self.elapsedBeforeStart += Date().timeIntervalSince(start)
            }
            self.startDate = nil
            self.updatePlaybackRate(0.0)
            self.stopTimer()
        }
    }

    func stop() {
        DispatchQueue.main.async {
            self.isActive = false
            self.startDate = nil
            self.elapsedBeforeStart = 0
            self.updatePlaybackRate(0.0)
            self.stopTimer()
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.tick()
        }
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard isActive else { return }
        var elapsed = elapsedBeforeStart
        if let start = startDate {
            elapsed += Date().timeIntervalSince(start)
        }
        updateElapsed(elapsed)
    }

    private func updateElapsed(_ elapsed: TimeInterval) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updatePlaybackRate(_ rate: Float) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
