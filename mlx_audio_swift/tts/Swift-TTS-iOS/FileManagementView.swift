//
//  FileManagementView.swift
//  Swift-TTS-iOS
//
//  Created by Sachin Desai on 8/21/25.
//

import SwiftUI
import AVFoundation

// Audio player manager class to handle delegate
    class AudioPlayerManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
        @Published var playingFileId: UUID?
        private var audioPlayer: AVAudioPlayer?

        func playFile(_ file: AudioFileInfo, fileURL: URL) {
            stopPlayback()

            do {
                audioPlayer = try AVAudioPlayer(contentsOf: fileURL)
                audioPlayer?.delegate = self
                audioPlayer?.play()
                playingFileId = file.id

                // Configure Now Playing for island/lock screen
                NowPlayingManager.shared.configure(title: file.displayName, artist: "Saved Audio", duration: file.duration)
                NowPlayingManager.shared.startProgress()
            } catch {
                print("Failed to play audio file: \(error)")
            }
        }

        func stopPlayback() {
            audioPlayer?.stop()
            audioPlayer = nil
            playingFileId = nil
            NowPlayingManager.shared.stop()
        }

    // AVAudioPlayerDelegate
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playingFileId = nil
    }
}

struct FileManagementView: View {
    @StateObject private var fileManager = AudioFileManager.shared
    @StateObject private var playerManager = AudioPlayerManager()
    @State private var showDeleteAlert = false
    @State private var fileToDelete: AudioFileInfo?

    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        NavigationStack {
            ZStack {
                // Background gradient
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(.systemBackground),
                        Color(.systemBackground).opacity(0.95)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                if fileManager.audioFiles.isEmpty {
                    emptyStateView
                } else {
                    fileListView
                }
            }
            .navigationTitle("Saved Audio")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .alert("Delete Audio File", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let file = fileToDelete {
                    deleteFile(file)
                }
            }
        } message: {
            Text("Are you sure you want to delete this audio file? This action cannot be undone.")
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 80))
                .foregroundStyle(.secondary)

            Text("No Saved Audio")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Audio files you save will appear here")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private var fileListView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(fileManager.audioFiles) { file in
                    fileCard(for: file)
                }
            }
            .padding()
        }
    }

    private func fileCard(for file: AudioFileInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with name and play button
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.displayName)
                        .font(.headline)
                        .lineLimit(1)

                    Text(file.formattedDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Play/Stop button
                Button(action: {
                    if playerManager.playingFileId == file.id {
                        playerManager.stopPlayback()
                    } else {
                        let fileURL = fileManager.getFileURL(for: file)
                        playerManager.playFile(file, fileURL: fileURL)
                    }
                }) {
                    Image(systemName: playerManager.playingFileId == file.id ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.tint)
                }
            }

            Divider()

            // File details grid
            VStack(spacing: 8) {
                HStack(spacing: 16) {
                    detailItem(icon: "clock", label: "Duration", value: file.formattedDuration)
                    detailItem(icon: "doc", label: "Size", value: file.formattedFileSize)
                }

                HStack(spacing: 16) {
                    detailItem(icon: "person.wave.2", label: "Voice", value: formatVoiceName(file.voiceUsed))
                    let rtf = file.generationTime > 0 ? (file.duration / file.generationTime) : 0
                    let rtfStr = rtf > 0 ? String(format: "%.2fx", rtf) : "-"
                    detailItem(icon: "bolt.badge.clock", label: "RTF", value: rtfStr)
                }

                HStack(spacing: 16) {
                    detailItem(icon: "timer", label: "Generation", value: String(format: "%.2fs", file.generationTime))
                    detailItem(icon: "checkmark.circle", label: "Completion", value: String(format: "%.2fs", file.completionTime))
                }

                
            }

            // Transcript
            if let transcript = file.transcript, !transcript.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "text.quote")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Transcript")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(transcript)
                        .font(.footnote)
                        .lineLimit(3)
                        .foregroundStyle(.primary)
                }
            }

            // Delete button
            Button(action: {
                fileToDelete = file
                showDeleteAlert = true
            }) {
                HStack {
                    Image(systemName: "trash")
                        .font(.caption)
                    Text("Delete")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.red.opacity(0.1))
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 8, y: 4)
        )
    }

    private func detailItem(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption)
                    .fontWeight(.medium)
            }

            Spacer()
        }
    }

    private func formatVoiceName(_ voiceName: String) -> String {
        guard voiceName.count > 3 else { return voiceName }
        return voiceName.dropFirst(3).capitalized
    }

    private func deleteFile(_ file: AudioFileInfo) {
        if playerManager.playingFileId == file.id {
            playerManager.stopPlayback()
        }
        fileManager.deleteAudioFile(file)
    }
}
