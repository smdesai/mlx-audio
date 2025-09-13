//
//  BGTaskManager.swift
//  Swift-TTS-iOS
//

import Foundation
import BackgroundTasks
import UIKit

final class BGTaskManager {
    static let shared = BGTaskManager()
    private init() {}

    // Identifier must be added to Info.plist under BGTaskSchedulerPermittedIdentifiers
    static let transcriptionTaskId = "com.sdesai.lumen-digital.tts.transcription"

    private let pendingKey = "pendingTranscriptions"

    struct PendingTranscription: Codable {
        let id: UUID
        let filePath: String
        let locale: String
    }

    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.transcriptionTaskId, using: nil) { task in
            self.handleTranscriptionTask(task: task as! BGProcessingTask)
        }
    }

    func scheduleTranscription(id: UUID, fileURL: URL, locale: Locale = Locale(identifier: "en_US")) {
        var items = loadPending()
        items.append(PendingTranscription(id: id, filePath: fileURL.path, locale: locale.identifier))
        savePending(items)

        let request = BGProcessingTaskRequest(identifier: Self.transcriptionTaskId)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date().addingTimeInterval(15) // small delay to batch
        do {
            try BGTaskScheduler.shared.submit(request)
            print("[BGTask] Scheduled transcription for \(id)")
        } catch {
            print("[BGTask] Failed to schedule: \(error)")
        }
    }

    private func handleTranscriptionTask(task: BGProcessingTask) {
        print("[BGTask] Transcription task started")

        let semaphore = DispatchSemaphore(value: 0)
        var success = true

        // Consume pending list
        let items = loadPending()
        if items.isEmpty {
            task.setTaskCompleted(success: true)
            return
        }

        // Work through items serially
        let workQueue = DispatchQueue(label: "com.kokoro.bg.transcription")

        task.expirationHandler = {
            print("[BGTask] Expired before completion")
            success = false
            semaphore.signal()
        }

        workQueue.async {
            let group = DispatchGroup()

            for item in items {
                group.enter()
                let url = URL(fileURLWithPath: item.filePath)
                let locale = Locale(identifier: item.locale)
                SpeechTranscriber.shared.transcribe(url: url, locale: locale) { transcript in
                    if let t = transcript {
                        DispatchQueue.main.async {
                            AudioFileManager.shared.updateTranscript(for: item.id, transcript: t)
                        }
                    } else {
                        success = false
                    }
                    group.leave()
                }
            }

            group.notify(queue: workQueue) {
                // Clear the processed items
                self.savePending([])
                // End Live Activity if active
                TranscriptionActivityManager.shared.end(success: success)
                semaphore.signal()
            }
        }

        // Wait until done or expiration
        _ = semaphore.wait(timeout: .now() + 25 * 60) // up to 25 minutes
        task.setTaskCompleted(success: success)
        print("[BGTask] Transcription task completed: \(success)")
    }

    private func loadPending() -> [PendingTranscription] {
        guard let data = UserDefaults.standard.data(forKey: pendingKey) else { return [] }
        if let items = try? JSONDecoder().decode([PendingTranscription].self, from: data) {
            return items
        }
        return []
    }

    private func savePending(_ items: [PendingTranscription]) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: pendingKey)
        }
    }
}
