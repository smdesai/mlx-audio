//
//  AudioFileModel.swift
//  Swift-TTS-iOS
//
//  Created by Sachin Desai on 8/21/25.
//

import Foundation
import AVFoundation

struct AudioFileInfo: Codable, Identifiable {
    let id: UUID
    let filename: String
    let displayName: String
    let dateCreated: Date
    let fileSize: Int64
    let duration: TimeInterval
    let voiceUsed: String
    let speed: Float
    let generationTime: TimeInterval
    let completionTime: TimeInterval

    var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }

    var formattedDuration: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: duration) ?? "0:00"
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: dateCreated)
    }
}

class AudioFileManager: ObservableObject {
    @Published var audioFiles: [AudioFileInfo] = []
    private let documentsDirectory: URL
    private let metadataFile = "audio_metadata.json"

    init() {
        documentsDirectory = FileManager.default.urls(for: .documentDirectory,
                                                     in: .userDomainMask).first!
        loadMetadata()
    }

    private var metadataURL: URL {
        documentsDirectory.appendingPathComponent(metadataFile)
    }

    func saveAudioFile(audioData: Data,
                      displayName: String,
                      voiceUsed: String,
                      speed: Float,
                      generationTime: TimeInterval,
                      completionTime: TimeInterval) throws -> AudioFileInfo {

        let id = UUID()
        let filename = "\(id.uuidString).wav"
        let fileURL = documentsDirectory.appendingPathComponent(filename)

        // Save audio data to file
        try audioData.write(to: fileURL)

        // Get file size
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0

        // Get audio duration
        let asset = AVURLAsset(url: fileURL)
        let duration = CMTimeGetSeconds(asset.duration)

        // Create file info
        let fileInfo = AudioFileInfo(
            id: id,
            filename: filename,
            displayName: displayName,
            dateCreated: Date(),
            fileSize: fileSize,
            duration: duration,
            voiceUsed: voiceUsed,
            speed: speed,
            generationTime: generationTime,
            completionTime: completionTime
        )

        // Add to list and save metadata
        audioFiles.append(fileInfo)
        audioFiles.sort { $0.dateCreated > $1.dateCreated } // Most recent first
        saveMetadata()

        return fileInfo
    }

    func deleteAudioFile(_ fileInfo: AudioFileInfo) {
        let fileURL = documentsDirectory.appendingPathComponent(fileInfo.filename)

        // Delete the audio file
        try? FileManager.default.removeItem(at: fileURL)

        // Remove from list and save metadata
        audioFiles.removeAll { $0.id == fileInfo.id }
        saveMetadata()
    }

    func getFileURL(for fileInfo: AudioFileInfo) -> URL {
        documentsDirectory.appendingPathComponent(fileInfo.filename)
    }

    private func loadMetadata() {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else { return }

        do {
            let data = try Data(contentsOf: metadataURL)
            audioFiles = try JSONDecoder().decode([AudioFileInfo].self, from: data)

            // Remove entries for files that no longer exist
            audioFiles = audioFiles.filter { fileInfo in
                let fileURL = documentsDirectory.appendingPathComponent(fileInfo.filename)
                return FileManager.default.fileExists(atPath: fileURL.path)
            }

            audioFiles.sort { $0.dateCreated > $1.dateCreated }
        } catch {
            print("Failed to load metadata: \(error)")
        }
    }

    private func saveMetadata() {
        do {
            let data = try JSONEncoder().encode(audioFiles)
            try data.write(to: metadataURL)
        } catch {
            print("Failed to save metadata: \(error)")
        }
    }
}
