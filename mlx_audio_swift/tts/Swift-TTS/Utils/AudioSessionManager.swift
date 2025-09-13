//
//  AudioSessionManager.swift
//   Swift-TTS
//
//  Created by Sachin Desai on 5/17/25.
//

import Foundation
import AVFoundation
#if os(iOS)
import UIKit
#endif

/// A platform-agnostic audio session manager that handles platform differences between iOS and macOS
public class AudioSessionManager {

    /// Singleton instance
    public static let shared = AudioSessionManager()

    /// Private initializer for singleton pattern
    private init() {}

    /// Set up the audio session with appropriate categories
    public func setupAudioSession() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            // Use spokenAudio mode for TTS; avoid unsupported options with .playback
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("Audio session setup failed: \(error)")
        }
        #endif
        // No equivalent action needed for macOS
    }

    /// Reset the audio session
    public func resetAudioSession() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            // Reapply category before reactivating
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("Failed to reset audio session: \(error)")
        }
        #endif
        // No equivalent action needed for macOS
    }

    // Removed: registerForMemoryWarnings (unused)

    /// Deactivate the audio session
    public func deactivateAudioSession() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
        #endif
        // No equivalent action needed for macOS
    }
}
