//
//  SpeechTranscriber.swift
//  Swift-TTS-iOS
//

import Foundation
import Speech
import AVFoundation
import UIKit

final class SpeechTranscriber: NSObject {
    static let shared = SpeechTranscriber()
    private override init() {}

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }

    /// Transcribe a WAV file URL using on-device recognition if available. Runs under a background task when app goes to background.
    func transcribe(url: URL, locale: Locale = Locale(identifier: "en_US"), completion: @escaping (String?) -> Void) {
        // Start background task to continue if the app is backgrounded.
        // Use a constant task ID to avoid mutating after capture in Sendable contexts.
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "Transcription", expirationHandler: nil)

        let finish: (String?) -> Void = { text in
            if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
            completion(text)
        }

        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            finish(nil)
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        if #available(iOS 13.0, *) {
            request.requiresOnDeviceRecognition = true
        }
        request.shouldReportPartialResults = false

        recognizer.recognitionTask(with: request) { result, error in
            if let error = error {
                print("Transcription error: \(error)")
                finish(nil)
                return
            }
            if let r = result, r.isFinal {
                finish(r.bestTranscription.formattedString)
            }
        }
    }
}
