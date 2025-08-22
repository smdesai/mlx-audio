//
//  ContentView.swift
//   Swift-TTS-iOS
//
//  Created by Sachin Desai on 5/17/25.
//

import SwiftUI
import MLX

struct ContentView: View {
    @State private var speed = 1.0
    @State public var text = ""
    @State private var showAlert = false
    @State private var isStreamingMode = false
    @State private var streamingTimer: Timer?
    @State private var showSettings = false
    @State private var isModelReady = false
    @State private var showFileManager = false
    @State private var isSavingAudio = false
    @State private var showSaveSuccess = false
    @State private var lastSavedFileName = ""

    @FocusState private var isTextEditorFocused: Bool
    @ObservedObject var viewModel: KokoroTTSModel
    @StateObject private var speakerModel = SpeakerViewModel()
    @StateObject private var audioFileManager = AudioFileManager()

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        NavigationStack {
            ZStack {
                // Gradient background
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(.systemBackground),
                        Color(.systemBackground).opacity(0.95)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        // Header card
                        headerCard

                        VStack(spacing: 8) {
                            // Speaker selection card
                            speakerCard

                            // Settings card
                            settingsCard

                            // Text input card
                            textInputCard

                            // Action buttons
                            actionButtonsView
                        }
                        .padding(.horizontal)
                    }
                    .padding(.bottom, 16)
                }
                .scrollContentBackground(.hidden)
                .alert("Empty Text", isPresented: $showAlert) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text("Please enter some text before generating audio.")
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if isTextEditorFocused {
                        dismissKeyboard()
                        isTextEditorFocused = false
                    }
                }
            }
        }
        .tint(.accentColor)
        // Sync viewModel.generationInProgress to speakerModel.isGenerating
        .onChange(of: viewModel.generationInProgress) { _, newValue in
            speakerModel.isGenerating = newValue
        }
        .onAppear {
            // Model is prewarming in the background
            // Set ready after a short delay to avoid showing loading state if it's fast
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation {
                    isModelReady = true
                }
            }
        }
        .sheet(isPresented: $showFileManager) {
            FileManagementView()
        }
        .overlay {
            if showSaveSuccess {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Audio saved successfully!")
                    }
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .padding()
                    .background(
                        Capsule()
                            .fill(Color.green)
                            .shadow(radius: 4)
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 100)
                }
                .animation(.spring(), value: showSaveSuccess)
            }
        }
    }

    // MARK: - Header Card

    private var headerCard: some View {
        VStack(spacing: 12) {
            // Top bar with file manager button
            HStack {
                Spacer()
                Button(action: {
                    showFileManager = true
                }) {
                    Label("Saved", systemImage: "folder.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color(.tertiarySystemBackground))
                        )
                }
            }
            .padding(.horizontal)

            // Logo/Icon
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: viewModel.isAudioPlaying)

            HStack(spacing: 8) {
                Text("Kokoro TTS")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                if !isModelReady {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.opacity)
                }
            }

            // Performance metrics
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "timer")
                        .font(.caption)
                    Text("Time to first audio: \(viewModel.audioGenerationTime > 0 ? String(format: "%.2f", viewModel.audioGenerationTime) : "--")s")
                        .font(.caption)
                }

                if viewModel.totalGenerationTime > 0 {
                    HStack {
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .font(.caption)
                        Text("Total generation: \(String(format: "%.2f", viewModel.totalGenerationTime))s")
                            .font(.caption)
                    }
                }

                if viewModel.totalCompletionTime > 0 {
                    HStack {
                        Image(systemName: "checkmark.circle")
                            .font(.caption)
                        Text("Total completion: \(String(format: "%.2f", viewModel.totalCompletionTime))s")
                            .font(.caption)
                    }
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.tertiarySystemBackground))
            )
        }
        .padding(.vertical)
    }

    // MARK: - Speaker Card

    private var speakerCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Voice Selection", systemImage: "person.wave.2")
                .font(.headline)

            Menu {
                ForEach(speakerModel.speakers) { speaker in
                    Button(action: {
                        withAnimation(.spring(response: 0.3)) {
                            speakerModel.selectedSpeakerId = speaker.id
                        }
                    }) {
                        HStack {
                            Text("\(speaker.flag) \(speaker.displayName)")
                            if speakerModel.selectedSpeakerId == speaker.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack {
                    if let speaker = speakerModel.getSpeaker(id: speakerModel.selectedSpeakerId) {
                        // Voice icon with flag
                        ZStack {
                            Circle()
                                .fill(Color(.tertiarySystemBackground))
                                .frame(width: 40, height: 40)
                            Text(speaker.flag)
                                .font(.title2)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(speaker.displayName)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("Tap to change")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Image(systemName: "chevron.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(.secondarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(.separator), lineWidth: 0.5)
                )
            }
            .disabled(viewModel.generationInProgress)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 10, y: 5)
        )
    }

    // MARK: - Settings Card

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with expandable button
            Button(action: {
                withAnimation(.spring(response: 0.3)) {
                    showSettings.toggle()
                }
            }) {
                HStack {
                    Label("Settings", systemImage: "slider.horizontal.3")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(showSettings ? 90 : 0))
                }
            }
            .foregroundStyle(.primary)

            if showSettings {
                VStack(spacing: 20) {
                    // Speed control
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Speed", systemImage: "speedometer")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.1fx", speed))
                                .font(.headline)
                                .foregroundStyle(.tint)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(Color(.tertiarySystemBackground))
                                )
                        }

                        HStack(spacing: 8) {
                            Image(systemName: "tortoise.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Slider(value: $speed, in: 0.5...2.0, step: 0.1)
                                .tint(.accentColor)

                            Image(systemName: "hare.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .disabled(viewModel.generationInProgress)
                    }

                    Divider()

                    // Streaming mode toggle
                    Toggle(isOn: $isStreamingMode) {
                        HStack {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Streaming Mode")
                                    .font(.subheadline)
                                Text("Generate audio in real-time")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tint(.accentColor)
                    .disabled(viewModel.generationInProgress || viewModel.isStreaming)

                    // Sentence threshold slider (only shown when streaming mode is on and not using legacy split)
                    if isStreamingMode && !viewModel.useLegacySentenceSplit {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("Sentence Threshold", systemImage: "text.badge.checkmark")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "%.1f", viewModel.streamingSentenceThreshold))
                                    .font(.headline)
                                    .foregroundStyle(.tint)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule()
                                            .fill(Color(.tertiarySystemBackground))
                                    )
                            }

                            HStack(spacing: 8) {
                                Text("0.1")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)

                                Slider(value: $viewModel.streamingSentenceThreshold, in: 0.1...1.0, step: 0.1)
                                    .tint(.accentColor)

                                Text("1.0")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .disabled(viewModel.generationInProgress || viewModel.isStreaming)

                            Text("Lower values split sentences more aggressively")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // Legacy sentence split toggle
                    Toggle(isOn: $viewModel.useLegacySentenceSplit) {
                        HStack {
                            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Legacy Sentence Split")
                                    .font(.subheadline)
                                Text("Use traditional tokenizer")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tint(.orange)
                    .disabled(viewModel.generationInProgress || viewModel.isStreaming)
                }
                .padding(.top, 8)
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 10, y: 5)
        )
        .clipped()
    }

    // MARK: - Text Input Card

    private var textInputCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Text Input", systemImage: "text.quote")
                    .font(.headline)
                Spacer()
                if !text.isEmpty {
                    HStack(spacing: 12) {
                        Text("\(text.count) characters")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                text = ""
                            }
                        }) {
                            Text("Clear")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.tint)
                        }
                        .disabled(viewModel.generationInProgress)
                    }
                }
            }

            ScrollView {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(.body)
                        .frame(minHeight: 180, maxHeight: 250)
                        .scrollContentBackground(.hidden)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color(.secondarySystemBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(isTextEditorFocused ? Color.accentColor : Color(.separator), lineWidth: isTextEditorFocused ? 2 : 0.5)
                        )
                        .focused($isTextEditorFocused)
                        .disabled(viewModel.generationInProgress)
                        .animation(.easeInOut(duration: 0.2), value: isTextEditorFocused)

                    if text.isEmpty && !isTextEditorFocused {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Enter your text here...")
                                .foregroundStyle(.secondary)
                            Text("Tip: Try different voices and speeds!")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 20)
                        .allowsHitTesting(false)
                    }
                }
            }
            .frame(maxHeight: 250)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 10, y: 5)
        )
    }

    // MARK: - Action Buttons

    private var actionButtonsView: some View {
        HStack(spacing: 12) {
            // Generate/Play button
            generateButton

            // Save to File button
            saveButton
        }
        .padding(.horizontal, 16)
    }

    private var generateButton: some View {
        Button {
            withAnimation(.spring(response: 0.3)) {
                if viewModel.generationInProgress || viewModel.isStreaming || viewModel.isAudioPlaying {
                    // Stop action
                    if viewModel.isStreaming {
                        stopStreaming()
                    } else {
                        viewModel.stopPlayback()
                    }
                } else {
                    // Generate action
                    if isTextEditorFocused {
                        dismissKeyboard()
                        isTextEditorFocused = false
                    }

                    if isStreamingMode {
                        startStreaming()
                    } else {
                        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else {
                            showAlert = true
                            return
                        }
                        let speaker = speakerModel.getPrimarySpeaker().first!
                        viewModel.say(t, TTSVoice.fromIdentifier(speaker.name) ?? .afHeart, speed: Float(speed))
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                if viewModel.generationInProgress || viewModel.isStreaming {
                    if viewModel.isAudioPlaying {
                        Image(systemName: "stop.fill")
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                } else if viewModel.isAudioPlaying {
                    Image(systemName: "stop.fill")
                } else {
                    Image(systemName: isStreamingMode ? "dot.radiowaves.left.and.right" : "play.fill")
                }

                Text(buttonText)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundColor(.white)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: buttonGradientColors),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: buttonShadowColor, radius: 8, y: 4)
            )
        }
        .disabled(!buttonEnabled)
        .opacity(buttonEnabled ? 1.0 : 0.6)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isAudioPlaying)
    }

    private var saveButton: some View {
        Button {
            withAnimation(.spring(response: 0.3)) {
                if isSavingAudio || viewModel.generationInProgress {
                    // Already saving or generating, do nothing
                    return
                }

                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else {
                    showAlert = true
                    return
                }

                // Start saving
                isSavingAudio = true
                let speaker = speakerModel.getPrimarySpeaker().first!
                let voice = TTSVoice.fromIdentifier(speaker.name) ?? .afHeart

                // Generate and save to file
                viewModel.generateAndSaveToFile(t, voice, speed: Float(speed)) { [weak audioFileManager] fileURL, generationTime, completionTime in
                    guard let fileURL = fileURL else {
                        // Handle error
                        DispatchQueue.main.async {
                            self.isSavingAudio = false
                        }
                        return
                    }

                    // Move file to permanent location and save metadata
                    do {
                        let fileData = try Data(contentsOf: fileURL)

                        // Create display name from first few words of text
                        let displayName = String(t.prefix(50))

                        let savedFile = try audioFileManager?.saveAudioFile(
                            audioData: fileData,
                            displayName: displayName,
                            voiceUsed: speaker.name,
                            speed: Float(self.speed),
                            generationTime: generationTime,
                            completionTime: completionTime
                        )

                        // Clean up temp file
                        try? FileManager.default.removeItem(at: fileURL)

                        DispatchQueue.main.async {
                            self.isSavingAudio = false
                            self.lastSavedFileName = savedFile?.displayName ?? "Audio"
                            self.showSaveSuccess = true

                            // Hide success message after 2 seconds
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                self.showSaveSuccess = false
                            }
                        }
                    } catch {
                        print("Failed to save audio file: \(error)")
                        DispatchQueue.main.async {
                            self.isSavingAudio = false
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                if isSavingAudio || (viewModel.generationInProgress && !viewModel.isAudioPlaying) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "square.and.arrow.down")
                }

                Text(saveButtonText)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundColor(.white)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.green, Color.green.opacity(0.8)]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: Color.green.opacity(0.3), radius: 8, y: 4)
            )
        }
        .disabled(!saveButtonEnabled)
        .opacity(saveButtonEnabled ? 1.0 : 0.6)
        .animation(.easeInOut(duration: 0.2), value: isSavingAudio)
    }

    // Helper computed properties for button state
    private var buttonText: String {
        if viewModel.isAudioPlaying || viewModel.isStreaming {
            return "Stop"
        } else if viewModel.generationInProgress {
            return "Generating..."
        } else if isStreamingMode {
            return "Start Stream"
        } else {
            return "Generate"
        }
    }

    private var buttonGradientColors: [Color] {
        if viewModel.isAudioPlaying || viewModel.isStreaming {
            return [Color.red, Color.red.opacity(0.8)]
        } else {
            return [Color.accentColor, Color.accentColor.opacity(0.8)]
        }
    }

    private var buttonShadowColor: Color {
        if viewModel.isAudioPlaying || viewModel.isStreaming {
            return Color.red.opacity(0.3)
        } else {
            return Color.accentColor.opacity(0.3)
        }
    }

    private var buttonEnabled: Bool {
        if viewModel.isAudioPlaying || viewModel.isStreaming {
            return true // Always enabled when playing/streaming so user can stop
        } else {
            return !viewModel.generationInProgress && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var saveButtonText: String {
        if isSavingAudio {
            return "Saving..."
        } else if showSaveSuccess {
            return "Saved"
        } else {
            return "Save Audio"
        }
    }

    private var saveButtonEnabled: Bool {
        !isSavingAudio && !viewModel.generationInProgress && !viewModel.isAudioPlaying && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Streaming Methods

    private func startStreaming() {
        let fullText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullText.isEmpty else {
            showAlert = true
            return
        }

        let speaker = speakerModel.getPrimarySpeaker().first!
        let voice = TTSVoice.fromIdentifier(speaker.name) ?? .afHeart

        viewModel.startStreamingV2(voice: voice, speed: Float(speed))

        // Simulate text arrival in chunks
        var currentIndex = fullText.startIndex
        streamingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            if currentIndex >= fullText.endIndex {
                // End streaming when all text is sent
                viewModel.endStreamingV2()
                timer.invalidate()
                return
            }

            // Send next chunk (5-20 characters at a time)
            let chunkSize = Int.random(in: 5...20)
            let endIndex = fullText.index(currentIndex, offsetBy: chunkSize, limitedBy: fullText.endIndex) ?? fullText.endIndex
            let chunk = String(fullText[currentIndex..<endIndex])

            viewModel.addStreamingTextV2(chunk)
            currentIndex = endIndex
        }
    }

    private func stopStreaming() {
        streamingTimer?.invalidate()
        streamingTimer = nil
        viewModel.stopStreamingV2()
    }
}

// MARK: - Speaker Model

struct Speaker: Identifiable {
    let id: Int
    let name: String

    var flag: String {
        if name.lowercased() == "none" {
            return "⚪️"
        }

        guard name.count >= 2 else { return "🏳️" }
        let country = name.prefix(1)

        let countryFlag: String
        switch country {
        case "a": countryFlag = "🇺🇸" // USA
        case "b": countryFlag = "🇬🇧" // British
        case "e": countryFlag = "🇪🇸" // Spain
        case "f": countryFlag = "🇫🇷" // French
        case "h": countryFlag = "🇮🇳" // Hindi
        case "i": countryFlag = "🇮🇹" // Italian
        case "j": countryFlag = "🇯🇵" // Japanese
        case "p": countryFlag = "🇧🇷" // Brazil
        case "z": countryFlag = "🇨🇳" // Chinese
        default: countryFlag = "🏳️"
        }

        return countryFlag
    }

    var displayName: String {
        if name.lowercased() == "none" {
            return "None"
        }

        guard name.count >= 2 else { return name }
        let cleanName = name.dropFirst(3).capitalized
        return "\(cleanName)"
    }
}

class SpeakerViewModel: ObservableObject {
    @Published var selectedSpeakerId: Int = 3 // Default to af_heart
    @Published var selectedSpeakerId2: Int = -1
    @Published var isGenerating: Bool = false

    let speakers: [Speaker] = [
        Speaker(id: 0, name: "af_alloy"),
        Speaker(id: 1, name: "af_aoede"),
        Speaker(id: 2, name: "af_bella"),
        Speaker(id: 3, name: "af_heart"),
        Speaker(id: 4, name: "af_jessica"),
        Speaker(id: 5, name: "af_kore"),
        Speaker(id: 6, name: "af_nicole"),
        Speaker(id: 7, name: "af_nova"),
        Speaker(id: 8, name: "af_river"),
        Speaker(id: 9, name: "af_sarah"),
        Speaker(id: 10, name: "af_sky"),
        Speaker(id: 11, name: "am_adam"),
        Speaker(id: 12, name: "am_echo"),
        Speaker(id: 13, name: "am_eric"),
        Speaker(id: 14, name: "am_fenrir"),
        Speaker(id: 15, name: "am_liam"),
        Speaker(id: 16, name: "am_michael"),
        Speaker(id: 17, name: "am_onyx"),
        Speaker(id: 18, name: "am_puck"),
        Speaker(id: 19, name: "am_santa"),
        Speaker(id: 20, name: "bf_alice"),
        Speaker(id: 21, name: "bf_emma"),
        Speaker(id: 22, name: "bf_isabella"),
        Speaker(id: 23, name: "bf_lily"),
        Speaker(id: 24, name: "bm_daniel"),
        Speaker(id: 25, name: "bm_fable"),
        Speaker(id: 26, name: "bm_george"),
        Speaker(id: 27, name: "bm_lewis"),
        Speaker(id: 28, name: "ef_dora"),
        Speaker(id: 29, name: "em_alex"),
        Speaker(id: 30, name: "ff_siwis"),
        Speaker(id: 31, name: "hf_alpha"),
        Speaker(id: 32, name: "hf_beta"),
        Speaker(id: 33, name: "hm_omega"),
        Speaker(id: 34, name: "hm_psi"),
        Speaker(id: 35, name: "if_sara"),
        Speaker(id: 36, name: "im_nicola"),
        Speaker(id: 37, name: "jf_alpha"),
        Speaker(id: 38, name: "jf_gongitsune"),
        Speaker(id: 39, name: "jf_nezumi"),
        Speaker(id: 40, name: "jf_tebukuro"),
        Speaker(id: 41, name: "jm_kumo"),
        Speaker(id: 42, name: "pf_dora"),
        Speaker(id: 43, name: "pm_alex"),
        Speaker(id: 44, name: "pm_santa"),
        Speaker(id: 45, name: "zf_xiaobei"),
        Speaker(id: 46, name: "zf_xiaoni"),
        Speaker(id: 47, name: "zf_xiaoxiao"),
        Speaker(id: 48, name: "zf_xiaoyi"),
        Speaker(id: 49, name: "zm_yunjian"),
        Speaker(id: 50, name: "zm_yunxi"),
        Speaker(id: 51, name: "zm_yunxia"),
        Speaker(id: 52, name: "zm_yunyang"),
    ]

   func getPrimarySpeaker() -> [Speaker] {
        speakers.filter { $0.id == selectedSpeakerId }
    }

    func getSecondarySpeaker() -> [Speaker] {
        speakers.filter { $0.id == selectedSpeakerId2 }
    }

    func getSpeaker(id: Int) -> Speaker? {
        speakers.first { $0.id == id }
    }
}

extension View {
    func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil,
                                        from: nil,
                                        for: nil)
    }
}

#Preview {
  ContentView(viewModel: KokoroTTSModel())
}
