import SwiftUI

struct SettingsSheetView: View {
    @Binding var speed: Double
    @Binding var isStreamingMode: Bool
    @Binding var sentenceSplitThreshold: Float

    @ObservedObject var viewModel: KokoroTTSModel
    @ObservedObject var speakerModel: SpeakerViewModel

    #if DEBUG
    @Binding var debugLAStarted: Bool
    @Binding var debugLAProgress: Int
    @Binding var debugLATotal: Int
    @Binding var debugLAStatus: String
    #endif

    // Engine pool size (1-2), persisted in UserDefaults
    @State private var enginePoolSize: Int = {
        let n = UserDefaults.standard.integer(forKey: "TTSEnginePoolSize")
        return n > 0 ? min(max(n, 1), 2) : 2
    }()

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Playback")) {
                    HStack {
                        Text("Speed")
                        Spacer()
                        Text(String(format: "%.1fx", speed))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
                        Slider(value: $speed, in: 0.5...2.0, step: 0.1)
                            .tint(.accentColor)
                        Image(systemName: "hare.fill").foregroundStyle(.secondary)
                    }
                    .disabled(viewModel.generationInProgress)
                }

                Section(header: Text("Mode")) {
                    Toggle(isOn: $isStreamingMode) {
                        VStack(alignment: .leading) {
                            Text("Streaming Mode")
                            Text("Generate audio in real-time").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tint(.accentColor)
                    .disabled(viewModel.generationInProgress || viewModel.isStreaming)

                    if isStreamingMode && !viewModel.useLegacySentenceSplit {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Sentence Threshold")
                                Spacer()
                                Text(String(format: "%.1f", sentenceSplitThreshold))
                                    .foregroundStyle(.secondary)
                            }
                            HStack {
                                Text("0.1").font(.caption2).foregroundStyle(.secondary)
                                Slider(value: Binding(
                                    get: { Double(sentenceSplitThreshold) },
                                    set: { sentenceSplitThreshold = Float($0) }
                                ), in: 0.1...1.0, step: 0.1)
                                .tint(.accentColor)
                                Text("1.0").font(.caption2).foregroundStyle(.secondary)
                            }
                            Text("Lower values split sentences more aggressively")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .disabled(viewModel.generationInProgress || viewModel.isStreaming)
                    }

                    Toggle(isOn: $viewModel.useLegacySentenceSplit) {
                        VStack(alignment: .leading) {
                            Text("Legacy Sentence Split")
                            Text("Use traditional tokenizer").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tint(.orange)
                    .disabled(viewModel.generationInProgress || viewModel.isStreaming)
                }

                #if os(iOS)
                Section(header: Text("Advanced")) {
                    Toggle(isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "AllowBackgroundTTS") },
                        set: { UserDefaults.standard.set($0, forKey: "AllowBackgroundTTS") }
                    )) {
                        VStack(alignment: .leading) {
                            Text("Allow Background TTS")
                            Text("Requires special capability to submit GPU in background").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tint(.purple)
                    .disabled(viewModel.generationInProgress || viewModel.isStreaming)

                    // Engine Pool Size
                    Stepper("TTS Engine Pool: \(enginePoolSize)", value: $enginePoolSize, in: 1...2)
                        .onChange(of: enginePoolSize) { _, newValue in
                            let clamped = min(max(newValue, 1), 2)
                            UserDefaults.standard.set(clamped, forKey: "TTSEnginePoolSize")
                            // Recreate pool immediately for next jobs
                            viewModel.refreshEnginePoolIfNeeded()
                        }
                        .disabled(viewModel.generationInProgress || viewModel.isStreaming)
                    Text("Higher values may improve speed but increase memory.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                #endif

                #if DEBUG
                Section(header: Text("Live Activity Debug")) {
                        HStack(spacing: 12) {
                            Button("Start") {
                                let speaker = speakerModel.getPrimarySpeaker().first!
                                let voice = TTSVoice.fromIdentifier(speaker.name)?.rawValue ?? "af_heart"
                                TranscriptionActivityManager.shared.start(title: "Test Live Activity", voice: voice, totalUnits: debugLATotal)
                                debugLAStarted = true
                                debugLAProgress = 0
                                debugLAStatus = "Generating…"
                            }
                            .disabled(viewModel.generationInProgress || viewModel.isStreaming)

                            Button("Progress +1") {
                                guard debugLAStarted else { return }
                                debugLAProgress = min(debugLAProgress + 1, debugLATotal)
                                TranscriptionActivityManager.shared.update(completed: debugLAProgress, total: debugLATotal, phase: .generating, message: "Generating…")
                                debugLAStatus = "Generating…"
                            }

                            Button("Transcribing") {
                                TranscriptionActivityManager.shared.updatePhase(.transcribing, message: "Transcribing…")
                                debugLAStatus = "Transcribing…"
                            }

                            Button("End") {
                                TranscriptionActivityManager.shared.end(success: true)
                                debugLAStarted = false
                                debugLAStatus = "Done"
                            }
                        }

                        Stepper("Total Units: \(debugLATotal)", value: $debugLATotal, in: 1...50)
                        Text("Progress: \(debugLAProgress)/\(debugLATotal)").font(.caption).foregroundStyle(.secondary)
                }
                #endif
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
}
