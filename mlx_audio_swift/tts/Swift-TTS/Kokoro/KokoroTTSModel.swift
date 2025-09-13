//
//  KokoroTTSModel.swift
//  Swift-TTS
//

import AVFoundation
import MLX
import SwiftUI
import Accelerate  // For vDSP optimized vector operations
#if os(iOS)
import UIKit
#endif

private class StreamingInternalState {
    private var pendingTTSCount = 0
    private let semaphore = DispatchSemaphore(value: 1)

    func incrementPending() {
        semaphore.wait()
        pendingTTSCount += 1
        semaphore.signal()
    }

    func decrementPending() -> Int {
        semaphore.wait()
        pendingTTSCount -= 1
        let remaining = pendingTTSCount
        semaphore.signal()
        return remaining
    }

    func getPendingCount() -> Int {
        semaphore.wait()
        let count = pendingTTSCount
        semaphore.signal()
        return count
    }

    func reset() {
        semaphore.wait()
        pendingTTSCount = 0
        semaphore.signal()
    }
}

public class KokoroTTSModel: ObservableObject {
    private var kokoroTTSEngine: KokoroTTS!
    private var enginePool: TTSEnginePool
    // Serialize all engine calls to avoid concurrent use of shared MLX modules
    private let engineQueue = DispatchQueue(label: "com.kokoro.tts.engine", qos: .userInitiated)

    // Streaming support
    private var stream2Sentence: Stream2Sentence?
    @Published public var isStreaming = false
    private var streamingVoice: TTSVoice?
    private var streamingSpeed: Float = 1.0

    private var streamingTextBuffer = ""
    private let streamingBufferLock = DispatchSemaphore(value: 1)
    private let sentenceCounterLock = DispatchSemaphore(value: 1)

    // Sentence splitting mode
    @Published public var useLegacySentenceSplit = false {
        didSet {
            // Prewarm the sentence tokenizer when switching to new mode
            if !useLegacySentenceSplit && oldValue {
                SentenceTokenizer.prewarm()
            }
        }
    }

    private var audioEngine: AVAudioEngine!
    private var playerNode: AVAudioPlayerNode!
    private var audioFormat: AVAudioFormat!

    private let streamingQueue = DispatchQueue(label: "com.kokoro.streaming", qos: .userInitiated)
    private var sentenceCounter = 0
    private var audioChunkQueue: [(sentenceNum: Int, audioBuffer: MLXArray)] = []
    private var nextExpectedSentence = 1
    private let audioQueueLock = DispatchSemaphore(value: 1)
    private let ttsGenerationQueue = DispatchQueue(label: "com.kokoro.tts.generation", qos: .userInitiated)
    private let streamingState = StreamingInternalState()
    private var totalSentencesExpected = 0

    // Buffer tracking for reliable playback completion detection
    private var scheduledBufferCount = 0
    private var completedBufferCount = 0
    private let bufferCountLock = DispatchSemaphore(value: 1) // Thread safety for buffer counters

    // App state tracking
    private var isAppActive = true

    // State management
    private var isGenerating = false

    // Published property for UI updates - indicates system is busy (generating or playing)
    @Published public var generationInProgress = false

    // A separate property to track if audio is currently playing
    @Published public var isAudioPlaying: Bool = false {
        didSet {
            // Avoid redundant operations for repeated identical values
            if oldValue != isAudioPlaying {
                // Whenever audio playing state changes, update generationInProgress
                // to ensure UI elements stay active during playback
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if self.isAudioPlaying {
                        // Starting playback
                        self.generationInProgress = true
                    } else {
                        // Stopping playback
                        // Check if we're truly done with all audio
                        self.bufferCountLock.wait()
                        let allBuffersCompleted = self.completedBufferCount == self.scheduledBufferCount && self.scheduledBufferCount > 0
                        self.bufferCountLock.signal()

                        // Only clear generationInProgress if we're not actively generating and all buffers are done
                        if !self.isGenerating && allBuffersCompleted {
                            // All audio is done, update state
                            self.generationInProgress = false
                            self.objectWillChange.send()
                        }
                    }
                }
            }
        }
    }

    // Performance metrics
    @Published public var performanceMetrics = TTSPerformanceMetrics()

    // Keep existing properties for backward compatibility
    @Published public var audioGenerationTime: TimeInterval = 0
    @Published public var totalGenerationTime: TimeInterval = 0
    @Published public var totalCompletionTime: TimeInterval = 0

    private var generationStartTime: Date?
    private var allAudioGeneratedTime: Date?

    public typealias CompletionCallback = (TimeInterval, TimeInterval) -> Void
    private var completionCallback: CompletionCallback?

    // New callback with metrics
    public typealias MetricsCompletionCallback = (TTSPerformanceMetrics) -> Void
    private var metricsCompletionCallback: MetricsCompletionCallback?

    public init() {
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)

        // Single engine for streaming/low-latency sequential paths
        kokoroTTSEngine = KokoroTTS()

        // Pool of engines for parallel sentence processing on large texts
        enginePool = TTSEnginePool(size: Self.recommendedPoolSize())
        setupAudioSystem()

        // Setup app lifecycle notifications
        setupAppLifecycleObservers()

        // Prewarm the model in the background
        prewarmModel()
    }

    // MARK: - Background TTS Support (optional)
    // Enable this only if the app has a valid entitlement/capability to submit GPU work in background.
    // Otherwise, iOS will reject GPU submission and crash the app.
    // This flag can be toggled via UserDefaults (key: "AllowBackgroundTTS").
    private var allowBackgroundTTS: Bool {
        UserDefaults.standard.bool(forKey: "AllowBackgroundTTS")
    }

    #if os(iOS)
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    private func beginBackgroundTaskIfNeeded(name: String = "KokoroTTSGeneration") {
        guard allowBackgroundTTS else { return }
        if backgroundTaskId == .invalid {
            backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
                // Expiration handler
                self?.endBackgroundTaskIfNeeded()
            }
        }
    }

    private func endBackgroundTaskIfNeeded() {
        if backgroundTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskId)
            backgroundTaskId = .invalid
        }
    }
    #endif

    // Prewarm the TTS engine to reduce initial latency
    private func prewarmModel() {
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            self.kokoroTTSEngine.prewarm(voice: .afHeart) {
                print("Kokoro TTS model prewarmed successfully")
            }
            // Prewarm pooled engines best-effort
            self.enginePool.prewarmAll(voice: .afHeart)
        }

        // Also prewarm the sentence tokenizer if using the new mode
        if !useLegacySentenceSplit {
            SentenceTokenizer.prewarm()
        }
    }

    deinit {
         NotificationCenter.default.removeObserver(self)
         cleanupAudioSystem()
     }

    // MARK: - App Lifecycle Management

    private func setupAppLifecycleObservers() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    #endif
    }

    // MARK: - Engine Pool sizing

    private static func recommendedPoolSize() -> Int {
        let user = UserDefaults.standard.integer(forKey: "TTSEnginePoolSize")
        if user > 0 { return max(1, min(user, 2)) }
        #if targetEnvironment(simulator)
        return 1 // Simulators often have limited or incompatible slices
        #else
        return 2 // Conservative default; balance speed vs memory
        #endif
    }

    @objc private func appWillResignActive() {
        // App is about to become inactive (user switching apps, receiving call, etc)
        print("App will resign active")

        isAppActive = false

        // If background TTS is not allowed, stop operations to avoid GPU submission in background
        if !allowBackgroundTTS {
            // Stop streaming if active
            if isStreaming {
                stopStreaming()
            }
            // Stop any ongoing playback
            stopPlayback()
            // Clear GPU cache to prevent background GPU operations
            MLX.GPU.clearCache()
        } else {
            // Attempt to extend runtime for background TTS if capability present
            #if os(iOS)
            beginBackgroundTaskIfNeeded(name: "KokoroTTSBG")
            #endif
        }
    }

    @objc private func appDidEnterBackground() {
        print("App entered background")

        if !allowBackgroundTTS {
            // Force clear any remaining GPU operations
            MLX.GPU.clearCache()
            // Reset the TTS engine to free GPU resources
            kokoroTTSEngine.resetModel(preserveTextProcessing: true)
        } else {
            // Keep engine alive; begin background task to allow continuation
            #if os(iOS)
            beginBackgroundTaskIfNeeded(name: "KokoroTTSBG")
            #endif
        }
    }

    @objc private func appDidBecomeActive() {
        // App became active again
        print("App became active - ready for TTS operations")

        isAppActive = true

        #if os(iOS)
        endBackgroundTaskIfNeeded()
        #endif

        // The model will be re-initialized on demand when needed
    }

    // MARK: - Audio System Setup

    private func setupAudioSystem() {
        print("Setting up audio system")

        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()

        audioFormat = AVAudioFormat(standardFormatWithSampleRate: Double(KokoroTTS.Constants.sampleRate), channels: 1)
        guard audioFormat != nil else {
            print("Failed to create audio format")
            return
        }

        // Use dedicated audio processing queue to avoid QoS inversions
        let audioQueue = DispatchQueue(label: "com.mlx.audio.processing", qos: .userInteractive)
        audioQueue.sync {
            // Use platform-agnostic AudioSessionManager
            AudioSessionManager.shared.setupAudioSession()

            audioEngine.attach(playerNode)
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: audioFormat)

            do {
                try audioEngine.start()
                print("Audio system started successfully")
            } catch {
                print("Failed to start audio engine: \(error)")
            }
        }
    }

    private func cleanupAudioSystem() {
        // Stop player node first, which is the likely source of QoS inversion
        if playerNode.isPlaying {
            playerNode.pause() // Use pause instead of stop to avoid blocking
        }

        if audioEngine.isRunning {
            audioEngine.pause() // Use pause instead of stop to avoid blocking
        }

        AudioSessionManager.shared.deactivateAudioSession()
    }

    private func resetAudioSystem() {
        print("Resetting audio system")

        stopPlaybackMonitoring()

        // Stop player node first to avoid QoS inversion
        if playerNode.isPlaying {
            playerNode.pause() // Use pause instead of stop to avoid blocking
        }

        // Then stop the audio engine
        if audioEngine.isRunning {
            audioEngine.pause() // Use pause instead of stop to avoid blocking
        }

        // Reset audio session using platform-agnostic manager
        AudioSessionManager.shared.resetAudioSession()

        // Reconnect components with proper error handling
        if playerNode.engine != nil {
            audioEngine.detach(playerNode)
        }
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: audioFormat)

        // Restart engine
        do {
            try audioEngine.start()
            print("Audio engine restarted")
        } catch {
            print("Failed to restart audio engine: \(error)")
        }
    }

    public func setCompletionCallback(_ callback: CompletionCallback?) {
        self.completionCallback = callback
    }

    public func setMetricsCompletionCallback(_ callback: MetricsCompletionCallback?) {
        self.metricsCompletionCallback = callback
    }

    // Allow runtime tuning of engine pool size (1..2). Recreate and prewarm if changed.
    public func refreshEnginePoolIfNeeded(voice: TTSVoice = .afHeart) {
        let desired = Self.recommendedPoolSize()
        if enginePool.size != desired {
            enginePool = TTSEnginePool(size: desired)
            engineQueue.async { [weak self] in
                self?.enginePool.prewarmAll(voice: voice)
            }
        }
    }

    // MARK: - Parallel Playback API (non-streaming)

    /// Generate and play a large block of text using a fixed-size engine pool.
    /// Ensures playback order by sentence while generating audio in parallel.
    public func speakParallel(_ text: String, _ voice: TTSVoice, speed: Float = 1.0, sentenceSplitThreshold: Float) {
        guard isAppActive else { return }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        // Stop any ongoing work first
        if isGenerating || playerNode.isPlaying { stopPlayback() }

        // Reset metrics and state
        DispatchQueue.main.async {
            self.audioGenerationTime = 0.0
            self.totalGenerationTime = 0.0
            self.totalCompletionTime = 0.0
            self.performanceMetrics.startGeneration()
            self.performanceMetrics.addProcessedText(trimmedText)
            self.generationStartTime = Date()
            self.allAudioGeneratedTime = nil
            self.generationInProgress = true
            self.isGenerating = true
            self.objectWillChange.send()
        }

        // Ensure engine pool aligns with current preference
        refreshEnginePoolIfNeeded(voice: voice)

        // Configure Now Playing
        let displayTitle = String(trimmedText.prefix(50))
        NowPlayingManager.shared.configure(title: displayTitle, artist: voice.rawValue, duration: nil)

        // Prepare audio playback system and ordered queue
        resetBufferCounters()
        resetAudioSystem()
        audioQueueLock.wait()
        audioChunkQueue.removeAll()
        nextExpectedSentence = 1
        audioQueueLock.signal()

        // Split into sentences once
        let sentences = useLegacySentenceSplit ?
            SentenceTokenizer.splitIntoSentencesLegacy(text: trimmedText) :
            SentenceTokenizer.splitIntoSentences(text: trimmedText, threshold: sentenceSplitThreshold)
        guard !sentences.isEmpty else {
            DispatchQueue.main.async {
                self.isGenerating = false
                self.generationInProgress = false
                self.objectWillChange.send()
            }
            return
        }

        let generationStartTime = Date()
        let total = sentences.count
        let group = DispatchGroup()

        // Dispatch sentences; pool limits concurrency and memory by gating leases
        for (idx, sentence) in sentences.enumerated() {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                defer { group.leave() }
                guard let self = self else { return }
                let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }

                let audioBuffer: MLXArray
                do {
                    audioBuffer = try self.enginePool.withEngine { engine in
                        try engine.generateAudioForSingleSentence(
                            voice: voice,
                            text: trimmed,
                            speed: speed
                        )
                    }
                } catch {
                    print("[ParallelSpeak] Error generating sentence #\(idx): \(error)")
                    return
                }

                // Update metrics on main
                DispatchQueue.main.async {
                    if self.audioGenerationTime == 0.0 {
                        self.audioGenerationTime = Date().timeIntervalSince(generationStartTime)
                    }
                    if let startTime = self.generationStartTime {
                        self.allAudioGeneratedTime = Date()
                        self.totalGenerationTime = self.allAudioGeneratedTime!.timeIntervalSince(startTime)
                    }
                    if self.performanceMetrics.timeToFirstAudio == 0.0 {
                        self.performanceMetrics.recordFirstAudio()
                    }
                    self.performanceMetrics.recordGenerationProgress()
                    self.performanceMetrics.addAudioChunk()
                }

                // Enqueue for ordered playback
                self.queueAudioChunk(audioBuffer, sentenceNum: idx + 1)

                #if os(iOS)
                TranscriptionActivityManager.shared.update(
                    completed: min(idx + 1, total),
                    total: total,
                    phase: .generating,
                    message: "Generating…"
                )
                #endif
            }
        }

        // After scheduling, mark generation finished when all sentences queued
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            _ = group.wait(timeout: .now() + .seconds(max(120, Int(Double(total) * 1.5))))
            DispatchQueue.main.async { self.isGenerating = false }
        }
    }
    public func say(_ text: String, _ voice: TTSVoice, speed: Float = 1.0, sentenceSplitTheshold: Float) {
        // Check if app is active
        guard isAppActive else {
            print("App is not active - ignoring TTS request")
            return
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
         guard !trimmedText.isEmpty else {
             return
         }

         // Reset timing metrics (both old and new)
         audioGenerationTime = 0.0
         totalGenerationTime = 0.0
         totalCompletionTime = 0.0
         generationStartTime = Date()
         allAudioGeneratedTime = nil

         // Also update new metrics
         performanceMetrics.startGeneration()
         performanceMetrics.addProcessedText(trimmedText)

         // Decide if we need to stop existing playback before starting
         let hadActive = isGenerating || playerNode.isPlaying

         // Set state at start
         DispatchQueue.main.async {
             self.generationInProgress = true
             self.isGenerating = true
             self.objectWillChange.send()
         }

         // Stop any ongoing playback
         if hadActive {
             stopPlayback()

             // We need to give the audio system time to reset
             // This is necessary for the AVAudioEngine to properly shut down
             Task {
                 // Wait briefly for audio system to fully reset
                 try? await Task.sleep(nanoseconds: 100_000_000) // 100ms - reduced from 300ms

                 // Now start the new generation
                 self.startSpeechGeneration(text: trimmedText, voice: voice, speed: speed, sentenceSplitThreshold: sentenceSplitTheshold)
             }
             return
         }

         // Configure Now Playing metadata for Dynamic Island/lock screen
         let displayTitle = String(trimmedText.prefix(50))
         NowPlayingManager.shared.configure(title: displayTitle, artist: voice.rawValue, duration: nil)

         // No existing playback, start immediately
         startSpeechGeneration(text: trimmedText, voice: voice, speed: speed, sentenceSplitThreshold: sentenceSplitTheshold)
    }

    public func stopPlayback() {
        stopPlaybackMonitoring()
        resetBufferCounters()

        // Reset audio system with proper error handling
        do {
            playerNode.stop()
            playerNode.reset()

            // Additionally reset engine if running
            if audioEngine.isRunning {
                audioEngine.stop()
                try audioEngine.start()
            }
        } catch {
            print("Error resetting audio engine: \(error)")
        }

        // Reset all internal state flags
        isGenerating = false

        // Clear timing data
        generationStartTime = nil
        allAudioGeneratedTime = nil
        DispatchQueue.main.async {
            self.performanceMetrics.reset()
        }

        // Force UI update on main thread with proper sequencing
        DispatchQueue.main.async {
            // First notify observers of impending change
            self.objectWillChange.send()

            // Then update state properties in the correct order
            self.isAudioPlaying = false
            self.generationInProgress = false

            // Send another notification after state is updated
            self.objectWillChange.send()
        }

        // Reset TTS model in background with proper QoS
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            self.kokoroTTSEngine.resetModel()
        }

        // Clear Now Playing center
        NowPlayingManager.shared.stop()
    }

    // MARK: - Buffer Tracking

     private func resetBufferCounters() {
         bufferCountLock.wait()
         defer { bufferCountLock.signal() }

         scheduledBufferCount = 0
         completedBufferCount = 0
     }

     private func incrementScheduledBufferCount() {
         bufferCountLock.wait()
         defer { bufferCountLock.signal() }

         scheduledBufferCount += 1
     }

     private func incrementCompletedBufferCount() {
         bufferCountLock.wait()
         defer { bufferCountLock.signal() }

         completedBufferCount += 1

         // Check if all buffers completed
         if completedBufferCount == scheduledBufferCount && scheduledBufferCount > 0 {

             // Use main thread for UI updates
             DispatchQueue.main.async { [weak self] in
                 guard let self = self else { return }

                 // Only update if we're not generating new content
                 if !self.isGenerating {
                     self.isAudioPlaying = false
                     self.objectWillChange.send()
                 }
             }
         }
     }

    // MARK: - Save to File Support

    // Helper structure to track chunk metadata
    private struct ChunkMetadata {
        let chunkNum: Int
        let sampleCount: Int
        let fileName: String
        let audioData: Data?  // Optional: store in memory for small files
    }

    public func generateAndSaveToFile(_ text: String, _ voice: TTSVoice, speed: Float = 1.0, sentenceSplitThreshold: Float, transcribeInBackground: Bool = true, completion: @escaping (URL?, TimeInterval, TimeInterval) -> Void) {
        // Check if app is active
        guard isAppActive else {
            print("App is not active - ignoring TTS request")
            completion(nil, 0, 0)
            return
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            completion(nil, 0, 0)
            return
        }

        // Reset timing metrics
        audioGenerationTime = 0.0
        totalGenerationTime = 0.0
        totalCompletionTime = 0.0
        generationStartTime = Date()
        allAudioGeneratedTime = nil

        // Also update new metrics
        performanceMetrics.startGeneration()
        performanceMetrics.addProcessedText(trimmedText)

        // Set state at start
        DispatchQueue.main.async {
            self.generationInProgress = true
            self.isGenerating = true
            self.objectWillChange.send()
        }

        // Create temporary directory for chunk files
        let tempDirectory = FileManager.default.temporaryDirectory
        let sessionID = UUID().uuidString
        let chunkDirectory = tempDirectory.appendingPathComponent("audio_chunks_\(sessionID)")

        // Create the chunk directory
        do {
            try FileManager.default.createDirectory(at: chunkDirectory, withIntermediateDirectories: true)
            print("[Save] Created chunk directory: \(chunkDirectory.path)")
        } catch {
            print("[Save] Failed to create chunk directory: \(error)")
            DispatchQueue.main.async {
                self.isGenerating = false
                self.generationInProgress = false
                self.objectWillChange.send()
            }
            completion(nil, 0, 0)
            return
        }

        // Final output file
        let finalFileName = UUID().uuidString + ".wav"
        let finalFileURL = tempDirectory.appendingPathComponent(finalFileName)

        let generationStartTime = Date()
        var totalSampleCount = 0

        // Track chunk metadata instead of storing data
        var chunkMetadata: [ChunkMetadata] = []
        let metadataLock = DispatchSemaphore(value: 1)

        // First, split text into sentences to know how many chunks to expect
        let sentences = useLegacySentenceSplit ?
            SentenceTokenizer.splitIntoSentencesLegacy(text: trimmedText) :
            SentenceTokenizer.splitIntoSentences(text: trimmedText, threshold: sentenceSplitThreshold)

        guard !sentences.isEmpty else {
            print("[Save] No sentences to process")
            try? FileManager.default.removeItem(at: chunkDirectory)
            DispatchQueue.main.async {
                self.isGenerating = false
                self.generationInProgress = false
                self.objectWillChange.send()
            }
            completion(nil, 0, 0)
            return
        }

        print("[Save] Processing \(sentences.count) sentences")

        // Start Live Activity for progress (iOS)
        #if os(iOS)
        let displayTitle = String(trimmedText.prefix(50))
        TranscriptionActivityManager.shared.start(title: displayTitle, voice: voice.rawValue, totalUnits: sentences.count)
        #endif

        // Track how many chunks we've received - protected by lock for thread safety
        var chunksReceived = 0
        let chunksReceivedLock = DispatchSemaphore(value: 1)
        let totalExpectedChunks = sentences.count
        var isTimedOut = false  // Flag to prevent writes after timeout

        // Decide on storage strategy based on file size
        let useInMemoryStorage = sentences.count <= 30  // Keep small files in memory

        // Ensure engine pool aligns with current preference
        refreshEnginePoolIfNeeded(voice: voice)

        // Process everything on a background queue to avoid blocking main thread
        engineQueue.async {
            #if os(iOS)
            if self.allowBackgroundTTS { self.beginBackgroundTaskIfNeeded(name: "KokoroTTSSave") }
            #endif
            // Parallel generation using engine pool with fixed concurrency
            let group = DispatchGroup()
            for (idx, sentence) in sentences.enumerated() {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { group.leave() }
                    if isTimedOut { return }
                    let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }

                    // Generate audio for this sentence using an engine lease
                    let audioBuffer: MLXArray
                    do {
                        audioBuffer = try self.enginePool.withEngine { engine in
                            try engine.generateAudioForSingleSentence(
                                voice: voice,
                                text: trimmed,
                                speed: speed
                            )
                        }
                    } catch {
                        print("[Save] Error generating chunk #\(idx): \(error)")
                        return
                    }

                    // Update timing + metrics on main
                    DispatchQueue.main.async {
                        if self.audioGenerationTime == 0.0 {
                            self.audioGenerationTime = Date().timeIntervalSince(generationStartTime)
                        }
                        if let startTime = self.generationStartTime {
                            self.allAudioGeneratedTime = Date()
                            self.totalGenerationTime = self.allAudioGeneratedTime!.timeIntervalSince(startTime)
                        }
                        if self.performanceMetrics.timeToFirstAudio == 0.0 {
                            self.performanceMetrics.recordFirstAudio()
                        }
                        self.performanceMetrics.recordGenerationProgress()
                        self.performanceMetrics.addAudioChunk()
                    }

                    if isTimedOut { return }

                    // Extract and convert audio data
                    let (frameCount, audioData) = self.extractAudioData(from: audioBuffer)
                    guard frameCount > 0, let chunkData = self.convertSamplesToData(audioData) else { return }
                    let chunkSampleCount = audioData.count

                    if useInMemoryStorage {
                        metadataLock.wait()
                        chunkMetadata.append(ChunkMetadata(
                            chunkNum: idx,
                            sampleCount: chunkSampleCount,
                            fileName: "",
                            audioData: chunkData
                        ))
                        totalSampleCount += chunkSampleCount
                        metadataLock.signal()
                    } else {
                        let chunkFileName = String(format: "chunk_%03d.raw", idx)
                        let chunkFileURL = chunkDirectory.appendingPathComponent(chunkFileName)
                        do {
                            try chunkData.write(to: chunkFileURL)
                            metadataLock.wait()
                            chunkMetadata.append(ChunkMetadata(
                                chunkNum: idx,
                                sampleCount: chunkSampleCount,
                                fileName: chunkFileName,
                                audioData: nil
                            ))
                            totalSampleCount += chunkSampleCount
                            metadataLock.signal()
                        } catch {
                            print("[Save] Failed to write chunk #\(idx): \(error)")
                        }
                    }

                    // Update progress counters
                    chunksReceivedLock.wait()
                    chunksReceived += 1
                    let currentChunksReceived = chunksReceived
                    chunksReceivedLock.signal()

                    // Live Activity progress
                    #if os(iOS)
                    TranscriptionActivityManager.shared.update(completed: currentChunksReceived, total: totalExpectedChunks, phase: .generating, message: "Generating…")
                    #endif
                }
            }

            // Wait for generation to complete with timeout (~1.5s per chunk, min 120s)
            let timeoutSeconds = max(120, Int(Double(totalExpectedChunks) * 1.5))
            print("[Save] Waiting for audio generation to complete (expecting \(totalExpectedChunks) chunks, timeout: \(timeoutSeconds)s)...")
            let waitResult = group.wait(timeout: .now() + .seconds(timeoutSeconds))
            if waitResult == .timedOut {
                print("[Save] ERROR: Parallel generation timed out after \(timeoutSeconds)s")
                isTimedOut = true
                chunksReceivedLock.wait()
                let finalChunksReceived = chunksReceived
                chunksReceivedLock.signal()
                print("[Save] Chunks received: \(finalChunksReceived)/\(totalExpectedChunks)")
            }

            print("[Save] Semaphore signaled successfully - generation complete")

            print("[Save] Audio generation completed - proceeding to combine chunks")

            // Sort metadata by chunk number to ensure correct order
            metadataLock.wait()
            chunkMetadata.sort { $0.chunkNum < $1.chunkNum }
            let actualChunksWritten = chunkMetadata.count
            let actualSampleCount = totalSampleCount
            metadataLock.signal()

            print("[Save] Total chunks written: \(actualChunksWritten), Total samples: \(actualSampleCount)")
            // Update total audio duration in metrics based on final sample count
            let audioSeconds = Double(actualSampleCount) / Double(KokoroTTS.Constants.sampleRate)
            DispatchQueue.main.async {
                self.performanceMetrics.addAudioDuration(audioSeconds)
            }

            // Check if we have any chunks
            guard actualChunksWritten > 0 && actualSampleCount > 0 else {
                print("[Save] No audio data to save!")
                try? FileManager.default.removeItem(at: chunkDirectory)
                DispatchQueue.main.async {
                    self.isGenerating = false
                    self.generationInProgress = false
                    self.objectWillChange.send()
                }
                completion(nil, 0, 0)
                return
            }

            // If we have a partial file due to timeout, warn but continue
            if isTimedOut && actualChunksWritten < totalExpectedChunks {
                print("[Save] WARNING: Creating partial audio file with \(actualChunksWritten)/\(totalExpectedChunks) chunks")
            }

            print("[Save] Combining \(actualChunksWritten) chunk files into final WAV...")

            // Verify chunk directory exists
            if !FileManager.default.fileExists(atPath: chunkDirectory.path) {
                print("[Save] ERROR: Chunk directory does not exist at: \(chunkDirectory.path)")
            } else {
                print("[Save] Chunk directory exists, checking for files...")
                let contents = try? FileManager.default.contentsOfDirectory(at: chunkDirectory, includingPropertiesForKeys: nil)
                print("[Save] Found \(contents?.count ?? 0) files in chunk directory")
            }

            // Combine chunks into final WAV file
            do {
                // Create the final file
                guard FileManager.default.createFile(atPath: finalFileURL.path, contents: nil) else {
                    print("[Save] ERROR: Failed to create final audio file")
                    try? FileManager.default.removeItem(at: chunkDirectory)
                    DispatchQueue.main.async {
                        self.isGenerating = false
                        self.generationInProgress = false
                        self.objectWillChange.send()
                    }
                    completion(nil, 0, 0)
                    return
                }

                let fileHandle = try FileHandle(forWritingTo: finalFileURL)

                // Write WAV header with actual sample count
                let headerData = self.createWAVHeader(sampleCount: actualSampleCount, sampleRate: KokoroTTS.Constants.sampleRate)
                fileHandle.write(headerData)
                print("[Save] WAV header written: \(headerData.count) bytes for \(actualSampleCount) samples")

                // Read and write chunks - check if we have in-memory data first
                var chunksProcessed = 0
                var totalBytesWritten = 0
                for metadata in chunkMetadata {
                    autoreleasepool {
                        if let audioData = metadata.audioData {
                            // Use in-memory data if available (faster)
                            fileHandle.write(audioData)
                            chunksProcessed += 1
                            totalBytesWritten += audioData.count
                            print("[Save] Wrote in-memory chunk \(metadata.chunkNum): \(audioData.count) bytes")
                        } else if !metadata.fileName.isEmpty {
                            // Fall back to reading from file
                            let chunkFileURL = chunkDirectory.appendingPathComponent(metadata.fileName)
                            do {
                                let chunkData = try Data(contentsOf: chunkFileURL)
                                fileHandle.write(chunkData)
                                chunksProcessed += 1
                                totalBytesWritten += chunkData.count
                                if chunksProcessed <= 3 || chunksProcessed == chunkMetadata.count {
                                    print("[Save] Wrote file chunk \(metadata.chunkNum) from \(metadata.fileName): \(chunkData.count) bytes")
                                }
                            } catch {
                                print("[Save] ERROR: Could not read chunk file \(metadata.fileName): \(error)")
                            }
                        } else {
                            print("[Save] WARNING: Chunk \(metadata.chunkNum) has no data and no filename!")
                        }

                        if chunksProcessed % 10 == 0 {
                            print("[Save] Progress: \(chunksProcessed)/\(chunkMetadata.count) chunks combined, \(totalBytesWritten) bytes written")
                        }

                        // Update Live Activity progress (combining)
                        #if os(iOS)
                        TranscriptionActivityManager.shared.update(completed: chunksProcessed, total: chunkMetadata.count, phase: .combining, message: "Combining…")
                        #endif
                    }
                }

                print("[Save] Total bytes written to file: \(totalBytesWritten)")

                fileHandle.closeFile()
                print("[Save] All chunks combined successfully")

                // Verify final file
                let fileAttributes = try FileManager.default.attributesOfItem(atPath: finalFileURL.path)
                let fileSize = fileAttributes[.size] as? Int64 ?? 0
                print("[Save] Final file size: \(fileSize) bytes")

                // Clean up chunk directory if it exists
                if FileManager.default.fileExists(atPath: chunkDirectory.path) {
                    print("[Save] Cleaning up temporary chunk files...")
                    try? FileManager.default.removeItem(at: chunkDirectory)
                    print("[Save] Cleanup complete")
                }

            } catch {
                print("[Save] ERROR combining chunks: \(error)")
                try? FileManager.default.removeItem(at: chunkDirectory)
                DispatchQueue.main.async {
                    self.isGenerating = false
                    self.generationInProgress = false
                    self.objectWillChange.send()
                }
                completion(nil, 0, 0)
                return
            }

            // Mark completion time
            let completionTime: TimeInterval
            if let startTime = self.generationStartTime {
                completionTime = Date().timeIntervalSince(startTime)
            } else {
                completionTime = 0
            }

            // Cache generation time for callback
            let generationTime = self.totalGenerationTime

            // Reset state and return file URL
            print("[Save] Calling completion callback with file: \(finalFileURL.path)")
            print("[Save] Generation time: \(generationTime), Completion time: \(completionTime)")

            DispatchQueue.main.async {
                // Update published properties on main thread
                self.totalCompletionTime = completionTime
                self.isGenerating = false
                self.generationInProgress = false
                self.objectWillChange.send()

                // Call completion with file URL and timing metrics
                print("[Save] Executing completion callback on main thread")
                completion(finalFileURL, generationTime, completionTime)

                // If not transcribing in background, end Live Activity here
                #if os(iOS)
                // The caller will trigger transcribing phase separately in ContentView.
                self.endBackgroundTaskIfNeeded()
                #endif
            }
        }  // End of background queue async block
    }


    private func createWAVHeader(sampleCount: Int, sampleRate: Int) -> Data {
        // Pre-allocate exact size (44 bytes for standard WAV header)
        var data = Data(capacity: 44)

        let dataSize = sampleCount * 2 // 16-bit samples
        let fileSize = dataSize + 36

        // Build header more efficiently
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        withUnsafeBytes(of: Int32(fileSize).littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        withUnsafeBytes(of: Int32(16).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: Int16(1).littleEndian) { data.append(contentsOf: $0) } // PCM
        withUnsafeBytes(of: Int16(1).littleEndian) { data.append(contentsOf: $0) } // Mono
        withUnsafeBytes(of: Int32(sampleRate).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: Int32(sampleRate * 2).littleEndian) { data.append(contentsOf: $0) } // Byte rate
        withUnsafeBytes(of: Int16(2).littleEndian) { data.append(contentsOf: $0) } // Block align
        withUnsafeBytes(of: Int16(16).littleEndian) { data.append(contentsOf: $0) } // Bits per sample

        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        withUnsafeBytes(of: Int32(dataSize).littleEndian) { data.append(contentsOf: $0) }

        return data
    }

    private func convertSamplesToData(_ samples: [Float]) -> Data? {
        // Pre-allocate exact size needed (2 bytes per sample)
        let byteCount = samples.count * 2
        var data = Data(count: byteCount)  // Use count, not capacity!

        // Use unsafe buffer for batch conversion (much faster)
        data.withUnsafeMutableBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for (index, sample) in samples.enumerated() {
                let clampedSample = max(-1.0, min(1.0, sample))
                int16Buffer.baseAddress!.advanced(by: index).pointee = Int16(clampedSample * Float(Int16.max)).littleEndian
            }
        }

        return data
    }

    // MARK: - Audio Generation and Playback

    private func startSpeechGeneration(text: String, voice: TTSVoice, speed: Float, sentenceSplitThreshold: Float) {
        // Update internal state
        isGenerating = true

        // Reset buffer counters for the new generation
        resetBufferCounters()

        // Make sure the UI state is also set
        DispatchQueue.main.async {
            self.objectWillChange.send()
            self.generationInProgress = true
        }

        resetAudioSystem()

        // If allowed, hold a background task while generating (to avoid suspension);
        // note: this does not override iOS GPU policy — requires proper capability.
        #if os(iOS)
        if allowBackgroundTTS { beginBackgroundTaskIfNeeded(name: "KokoroTTSGenerateStream") }
        #endif

        let generationStartTime = Date()
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.kokoroTTSEngine.generateAudio(
                    voice: voice,
                    text: text,
                    speed: speed,
                    useLegacySentenceSplit: self.useLegacySentenceSplit,
                    sentenceSplitThreshold: sentenceSplitThreshold
                ) { [weak self] audioBuffer in
                    guard let self = self else { return }

                    // Update generation time on first chunk (old style) on main
                    DispatchQueue.main.async {
                        if self.audioGenerationTime == 0.0 {
                            self.audioGenerationTime = Date().timeIntervalSince(generationStartTime)
                        }
                        // Update total generation time on each chunk (will be accurate on last chunk)
                        if let startTime = self.generationStartTime {
                            self.allAudioGeneratedTime = Date()
                            self.totalGenerationTime = self.allAudioGeneratedTime!.timeIntervalSince(startTime)
                        }
                        // Also update new metrics
                        if self.performanceMetrics.timeToFirstAudio == 0.0 {
                            self.performanceMetrics.recordFirstAudio()
                        }
                        self.performanceMetrics.recordGenerationProgress()
                        self.performanceMetrics.addAudioChunk()
                    }

                    DispatchQueue.main.async {
                        self.playAudioChunk(audioBuffer)
                    }
                }

                // After scheduling generation, mark generation completion when sentences are processed
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.isGenerating = false
                }
            } catch {
                // Stop any active monitoring
                self.stopPlaybackMonitoring()
                self.isGenerating = false
                #if os(iOS)
                self.endBackgroundTaskIfNeeded()
                #endif
                // Reset UI state with proper notification
                DispatchQueue.main.async {
                    self.objectWillChange.send()
                    self.isAudioPlaying = false
                    self.generationInProgress = false
                    self.objectWillChange.send()
                }
                // Also reset the audio system to ensure clean state
                self.resetAudioSystem()
            }
        }
    }

    private func playAudioChunk(_ audioBuffer: MLXArray) {
        // Skip empty chunks
        let audioShape = audioBuffer.shape
        guard !isAudioEmpty(shape: audioShape) else {
            print("Skipping empty audio chunk")
            return
        }

        // Extract audio data
        let (frameCount, audioData) = extractAudioData(from: audioBuffer)

        // Create PCM buffer
        guard let buffer = createAudioBuffer(frameCount: frameCount, audioData: audioData) else {
            print("Failed to create audio buffer")
            return
        }

        // Ensure audio engine is running
        if !audioEngine.isRunning {
            resetAudioSystem()
        }

        incrementScheduledBufferCount()

        // Update metrics with audio duration for this chunk
        if frameCount > 0 {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let seconds = Double(frameCount) / Double(KokoroTTS.Constants.sampleRate)
                self.performanceMetrics.addAudioDuration(seconds)
            }
        }

        // Schedule buffer playback with enhanced completion handling and buffer tracking
        playerNode.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self = self else { return }

            // Increment completed buffer count (thread-safe)
            self.incrementCompletedBufferCount()

            // Dispatch to main thread for UI updates
            DispatchQueue.main.async {
                // First verify if player is actually still playing anything
                let isActuallyPlaying = self.playerNode.isPlaying

                if !isActuallyPlaying {
                    // Check buffer counts for more accurate completion detection
                    self.bufferCountLock.wait()
                    let allBuffersCompleted = self.completedBufferCount == self.scheduledBufferCount
                    self.bufferCountLock.signal()

                    if allBuffersCompleted && !self.isGenerating {
                        // All buffers completed and no more generation happening
                        // Update playback state which will trigger the didSet observer
                        self.isAudioPlaying = false
                    }
                } else if !self.isGenerating {
                    // Generation is complete but audio is still playing
                    // Make sure our monitoring timer is active
                    if self.playbackMonitorTimer == nil {
                        self.startPlaybackMonitoring()
                    }
                }
            }
        }

        // Track audio playback state
        isAudioPlaying = true

        // Start playback if needed
        if !playerNode.isPlaying {
            playerNode.play()

            // Retry once immediately if player didn't start
            if !playerNode.isPlaying {
                // One immediate retry without delay
                playerNode.play()

                // If still not playing, ensure state is set correctly
                if playerNode.isPlaying {
                    self.isAudioPlaying = true
                }
            }
        }

        // Ensure Now Playing is configured and started for Dynamic Island/Lock Screen
        NowPlayingManager.shared.configure(title: "Kokoro TTS", artist: streamingVoice?.rawValue ?? "TTS", duration: nil)
        NowPlayingManager.shared.startProgress()

        // Start monitoring playback immediately if not already monitoring
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.playbackMonitorTimer == nil {
                self.startPlaybackMonitoring()
            }
            #if os(iOS)
            // End background task when playback has begun and we no longer need to protect generation time
            self.endBackgroundTaskIfNeeded()
            #endif
        }
    }

    // MARK: - Helper Methods

    // Maintain a reference to the monitoring timer
    private var playbackMonitorTimer: Timer?
    private var monitoringTimeoutWorkItem: DispatchWorkItem?

    private func startPlaybackMonitoring() {
        // Ensure we're on main thread for timer operations
        if Thread.isMainThread {
            // Cancel any existing timer first
            stopPlaybackMonitoring()

            // Create a repeating timer that checks playback state every 0.2 seconds
            self.playbackMonitorTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
                guard let self = self else {
                    timer.invalidate()
                    return
                }

                self.checkIfPlaybackComplete()
            }

            // Make sure timer fires even during scrolling and user interaction
            if let timer = self.playbackMonitorTimer {
                RunLoop.current.add(timer, forMode: .common)
            }

            // Initial check for early detection
            self.checkIfPlaybackComplete()

            // Cancel any existing timeout work item
            monitoringTimeoutWorkItem?.cancel()

            // Set a fallback timer to ensure monitoring stops eventually
            // This prevents monitoring from continuing indefinitely if playback state detection fails
            let timeoutWork = DispatchWorkItem { [weak self] in
                guard let self = self, self.playbackMonitorTimer != nil else { return }

                self.stopPlaybackMonitoring()

                // Ensure playback state is reset
                if self.isAudioPlaying {
                    self.isAudioPlaying = false
                    self.objectWillChange.send()
                }
            }
            monitoringTimeoutWorkItem = timeoutWork
            DispatchQueue.main.asyncAfter(deadline: .now() + 30.0, execute: timeoutWork)
        } else {
            DispatchQueue.main.sync {
                self.startPlaybackMonitoring()
            }
        }
    }

    private func stopPlaybackMonitoring() {
        // Check if timer exists before invalidating
        if playbackMonitorTimer != nil {
            playbackMonitorTimer?.invalidate()
            playbackMonitorTimer = nil
        }

        // Cancel any pending timeout work
        monitoringTimeoutWorkItem?.cancel()
        monitoringTimeoutWorkItem = nil
    }

    private func checkIfPlaybackComplete() {
        // Double-check player state with a more reliable method
        let isActuallyPlaying = self.playerNode.isPlaying
        let hasScheduledBuffers = playerNode.engine?.isRunning ?? false

        // Check buffer counts for better completion detection
        bufferCountLock.wait()
        let buffersScheduled = scheduledBufferCount
        let buffersCompleted = completedBufferCount
        let allBuffersCompleted = buffersCompleted == buffersScheduled && buffersScheduled > 0
        bufferCountLock.signal()

        // Additional check: if we have scheduled buffers but none completed after some time, assume completion
        let possibleStuckBuffers = buffersScheduled > 0 && buffersCompleted == 0 && !isActuallyPlaying

        // Use multiple conditions for reliable detection
        if (!isActuallyPlaying && allBuffersCompleted) ||
           (!isActuallyPlaying && !hasScheduledBuffers) ||
           (allBuffersCompleted && !self.isGenerating) ||  // All buffers done and not generating more
           possibleStuckBuffers {

            // Stop the monitoring timer immediately
            stopPlaybackMonitoring()

            // Stop the player node since it's just idling
            if isActuallyPlaying && allBuffersCompleted {
                playerNode.stop()
            }

            // Calculate total completion time
            if let startTime = self.generationStartTime {
                self.totalCompletionTime = Date().timeIntervalSince(startTime)

                // Call completion callback if set
                if let callback = self.completionCallback {
                    callback(self.totalGenerationTime, self.totalCompletionTime)
                }
            }

            // No more buffers are playing, mark playback as complete
            self.isAudioPlaying = false
            // Explicitly clear generation flag to avoid UI getting stuck
            self.generationInProgress = false

            // Clear Now Playing
            NowPlayingManager.shared.stop()

            // Force UI update to refresh buttons state
            self.objectWillChange.send()
        }
    }

    private func isAudioEmpty(shape: [Int]) -> Bool {
        if shape.count == 1 {
            return shape[0] <= 1
        } else if shape.count == 2 {
            return shape[1] <= 1
        }
        return true
    }

    private func extractAudioData(from audioBuffer: MLXArray) -> (frameCount: Int, audioData: [Float]) {
        let audioShape = audioBuffer.shape

        // Handle different tensor shapes
        if audioShape.count == 1 {
            // 1D array [samples]
            let frameCount = audioShape[0]
            audioBuffer.eval()
            return (frameCount, audioBuffer.asArray(Float.self))
        } else if audioShape.count == 2 {
            // 2D array [1, samples]
            let frameCount = audioShape[1]
            let firstBatch = audioBuffer[0]
            firstBatch.eval()
            return (frameCount, firstBatch.asArray(Float.self))
        }

        // Fallback for unexpected shape
        return (0, [])
    }

    private func createAudioBuffer(frameCount: Int, audioData: [Float]) -> AVAudioPCMBuffer? {
        // Create buffer
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }

        // Set frame length
        buffer.frameLength = buffer.frameCapacity

        // Use unsafe buffer pointer for faster memory copy
        let channels = buffer.floatChannelData!
        let destPointer = channels[0]
        let volumeBoost: Float = 1.25

        // Use vDSP for vectorized operations (much faster for large arrays)
        audioData.withUnsafeBufferPointer { sourceBuffer in
            // Apply volume boost and clipping in a single vectorized operation
            var scale = volumeBoost
            vDSP_vsmul(sourceBuffer.baseAddress!, 1, &scale, destPointer, 1, vDSP_Length(frameCount))

            // Clip to [-0.98, 0.98] using vDSP
            var lower: Float = -0.98
            var upper: Float = 0.98
            vDSP_vclip(destPointer, 1, &lower, &upper, destPointer, 1, vDSP_Length(frameCount))
        }

        return buffer
    }

    // MARK: - Streaming Support

    private func processSentenceForStreaming(_ sentence: String, sentenceNum: Int) {
        // Check if app is active before processing
        guard isAppActive else {
            print("App is not active - skipping TTS generation for sentence #\(sentenceNum)")
            return
        }

        guard let voice = streamingVoice else {
            print("ERROR: No streaming voice set for sentence #\(sentenceNum): '\(sentence)'")
            return
        }

        // Don't process empty sentences
        let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSentence.isEmpty else {
            print("Skipping empty sentence")
            return
        }

        print("[STREAMING] START Processing sentence #\(sentenceNum): '\(trimmedSentence)'")
        print("Voice: \(voice.rawValue), Speed: \(streamingSpeed)")

        // Ensure audio system is ready
        if !audioEngine.isRunning {
            print("WARNING: Audio engine not running, attempting to start...")
            do {
                try audioEngine.start()
            } catch {
                print("ERROR: Failed to start audio engine: \(error)")
                return
            }
        }

        // We keep isGenerating = true until all audio is done

        do {
            // Generate audio for the single sentence (no re-splitting) on the engine queue
            var audioBuffer: MLXArray!
            var genError: Error?
            let sema = DispatchSemaphore(value: 0)
            engineQueue.async { [weak self] in
                guard let self = self else { sema.signal(); return }
                do {
                    audioBuffer = try self.kokoroTTSEngine.generateAudioForSingleSentence(
                        voice: voice,
                        text: trimmedSentence,
                        speed: self.streamingSpeed
                    )
                } catch {
                    genError = error
                }
                sema.signal()
            }
            sema.wait()
            if let err = genError { throw err }

            print("[STREAMING] AUDIO Generated for sentence #\(sentenceNum): '\(trimmedSentence)'")

            // Update generation time on first audio chunk
            if self.audioGenerationTime == 0.0, let startTime = self.generationStartTime {
                DispatchQueue.main.async {
                    self.audioGenerationTime = Date().timeIntervalSince(startTime)
                }
                print("First audio chunk received after: \(self.audioGenerationTime)s")
            }

            // Update total generation time on each sentence (will be accurate on last sentence)
            if let startTime = self.generationStartTime {
                DispatchQueue.main.async {
                    self.allAudioGeneratedTime = Date()
                    self.totalGenerationTime = self.allAudioGeneratedTime!.timeIntervalSince(startTime)
                }
            }

            // Queue the audio chunk with its sentence number
            self.queueAudioChunk(audioBuffer, sentenceNum: sentenceNum)

            print("Successfully completed audio generation for sentence #\(sentenceNum): '\(trimmedSentence)'")

        } catch let error {
            print("ERROR generating audio for streaming sentence: \(error)")

            // Log the error type
            if let ttsError = error as? KokoroTTS.KokoroTTSError {
                switch ttsError {
                case .modelNotInitialized:
                    print("ERROR: Model not initialized")
                case .sentenceSplitError:
                    print("ERROR: Sentence split error")
                case .tooManyTokens:
                    print("ERROR: Too many tokens in sentence")
                }
            }
        }
    }

    private func queueAudioChunk(_ audioBuffer: MLXArray, sentenceNum: Int) {
        audioQueueLock.wait()
        defer { audioQueueLock.signal() }

        // Add to queue
        audioChunkQueue.append((sentenceNum: sentenceNum, audioBuffer: audioBuffer))
        audioChunkQueue.sort { $0.sentenceNum < $1.sentenceNum }

        print("[STREAMING] Queued audio for sentence #\(sentenceNum), queue size: \(audioChunkQueue.count)")

        // Process any chunks that are ready
        processQueuedAudioChunks()
    }

    private func processQueuedAudioChunks() {
        // Must be called with audioQueueLock held

        while !audioChunkQueue.isEmpty && audioChunkQueue.first!.sentenceNum == nextExpectedSentence {
            let chunk = audioChunkQueue.removeFirst()
            let sentenceNum = chunk.sentenceNum
            let audioBuffer = chunk.audioBuffer

            print("[STREAMING] Playing audio for sentence #\(sentenceNum) (expected: \(nextExpectedSentence))")

            // Check if this is the last expected sentence
            let isLastSentence = (sentenceNum == totalSentencesExpected) || (audioChunkQueue.isEmpty && !isStreaming)

            // Schedule on main thread
            DispatchQueue.main.async { [weak self] in
                self?.playAudioChunk(audioBuffer)

                if isLastSentence {
                    print("[STREAMING] Scheduled last audio chunk for playback")
                    // Audio completion callbacks will handle the cleanup
                }
            }

            nextExpectedSentence += 1
        }

        if !audioChunkQueue.isEmpty {
            print("[STREAMING] Waiting for sentence #\(nextExpectedSentence), have: \(audioChunkQueue.map { $0.sentenceNum })")
        }
    }

    // MARK: - New Streaming Implementation using SentenceTokenizer

    /// Start a streaming session using SentenceTokenizer for better sentence detection
    public func startStreaming(voice: TTSVoice, speed: Float = 1.0) {
        guard !isStreaming else {
            print("Streaming already in progress")
            return
        }

        print("Starting streaming session with voice: \(voice.rawValue), speed: \(speed)")

        // Stop any ongoing playback monitoring from previous sessions
        stopPlaybackMonitoring()

        // Initialize streaming state
        isStreaming = true
        streamingVoice = voice
        streamingSpeed = speed
        streamingTextBuffer = ""
        sentenceCounter = 0
        audioChunkQueue.removeAll()
        nextExpectedSentence = 1
        streamingState.reset()
        totalSentencesExpected = 0

        // Reset buffer counters to ensure proper tracking
        resetBufferCounters()

        // Reset timing metrics (both old and new)
        audioGenerationTime = 0.0
        totalGenerationTime = 0.0
        totalCompletionTime = 0.0
        generationStartTime = Date()
        allAudioGeneratedTime = nil

        // Also update new metrics
        performanceMetrics.startGeneration()

        // Set state at start of streaming
        DispatchQueue.main.async {
            self.generationInProgress = true
            self.isGenerating = true
            self.objectWillChange.send()
        }

        // Configure Now Playing metadata for Dynamic Island/lock screen
        NowPlayingManager.shared.configure(title: "Streaming TTS", artist: voice.rawValue, duration: nil)
    }

    /// Add text chunks and process complete sentences
    public func addStreamingText(_ text: String, sentenceSplitThreshold: Float) {
        guard isStreaming else {
            print("No active streaming session")
            return
        }

        // Try to extract complete sentences using incremental windowing
        processBufferedText(newText: text, sentenceSplitThreshold: sentenceSplitThreshold)
    }

    /// Process buffered text to extract complete sentences
    private func processBufferedText(newText: String, sentenceSplitThreshold: Float) {
        // Build the window = tail + new chunk
        streamingBufferLock.wait()
        let tail = streamingTextBuffer
        streamingBufferLock.signal()
        let window = tail + newText

        guard !window.isEmpty else { return }

        // Clamp threshold for stability
        let th = min(max(sentenceSplitThreshold, 0.1), 1.0)

        // Split only the window text
        let sentences = useLegacySentenceSplit ?
            SentenceTokenizer.splitIntoSentencesLegacy(text: window) :
            SentenceTokenizer.splitIntoSentences(text: window, threshold: th, optimizeChunks: false)

        guard !sentences.isEmpty else { return }

        // Helper: does a sentence end with a terminal punctuation (allow trailing closers)
        func endsWithSentencePunct(_ s: String) -> Bool {
            let closers = ")]}»”’』」》】）"
            var idx = s.endIndex
            while idx > s.startIndex {
                idx = s.index(before: idx)
                let ch = s[idx]
                if ch == " " || ch == "\n" || ch == "\t" { continue }
                if closers.contains(ch) { continue }
                return ".!?…。！？".contains(ch)
            }
            return false
        }

        var toEmit: [String] = []
        var newTail: String = ""

        if sentences.count == 1 {
            // Single fragment - emit only if it's complete, else keep as tail
            if endsWithSentencePunct(sentences[0]) {
                toEmit = sentences
                newTail = ""
            } else {
                newTail = sentences[0]
            }
        } else {
            // Emit all but the last if last appears incomplete
            if let last = sentences.last, !endsWithSentencePunct(last) {
                toEmit = Array(sentences.dropLast())
                newTail = last
            } else {
                toEmit = sentences
                newTail = ""
            }
        }

        // Update the tail buffer
        streamingBufferLock.wait()
        streamingTextBuffer = newTail
        streamingBufferLock.signal()

        // Emit sentences
        for sentence in toEmit {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            // Increment safely to maintain order
            sentenceCounterLock.wait()
            self.sentenceCounter += 1
            let sentenceNum = self.sentenceCounter
            sentenceCounterLock.signal()

            streamingQueue.async {
                print("[STREAMING] Processing sentence #\(sentenceNum): '\(trimmed)'")

                // Track in metrics on main
                DispatchQueue.main.async {
                    self.performanceMetrics.addProcessedText(trimmed)
                }

                // Track pending TTS
                self.streamingState.incrementPending()

                // Queue for TTS generation
                self.ttsGenerationQueue.async {
                    self.processSentenceForStreaming(trimmed, sentenceNum: sentenceNum)

                    // Decrement pending count
                    let remaining = self.streamingState.decrementPending()

                    print("[STREAMING] Completed TTS for sentence #\(sentenceNum), remaining: \(remaining)")
                }
            }
        }
    }

    /// End the streaming session
    public func endStreaming() {
        guard isStreaming else {
            print("No active streaming session to end")
            return
        }

        print("[STREAMING] Ending streaming session")

        // Process any remaining text in buffer as final sentence
        streamingBufferLock.wait()
        let remainingText = streamingTextBuffer
        streamingTextBuffer = ""  // Clear the buffer
        streamingBufferLock.signal()

        if !remainingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let finalSentence = remainingText.trimmingCharacters(in: .whitespacesAndNewlines)

            // Increment counter synchronously to ensure correct ordering
            sentenceCounterLock.wait()
            self.sentenceCounter += 1
            let sentenceNum = self.sentenceCounter
            sentenceCounterLock.signal()

            // Update total expected sentences
            self.totalSentencesExpected = sentenceNum

            streamingQueue.async {
                print("[STREAMING] Processing final sentence #\(sentenceNum): '\(finalSentence)'")

                // Track pending TTS
                self.streamingState.incrementPending()

                // Queue for TTS generation
                self.ttsGenerationQueue.async {
                    self.processSentenceForStreaming(finalSentence, sentenceNum: sentenceNum)

                    // Decrement pending count
                    let remaining = self.streamingState.decrementPending()

                    print("[STREAMING] Completed TTS for final sentence #\(sentenceNum), remaining: \(remaining)")
                }
            }
        } else {
            // No final sentence to process
            totalSentencesExpected = sentenceCounter
        }

        // Wait for all sentences to be processed before cleanup
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }

            // Wait for all pending TTS to complete
            var waitCount = 0
            while waitCount < 100 { // Max 10 seconds wait
                let pending = self.streamingState.getPendingCount()

                if pending == 0 {
                    print("[STREAMING] All TTS generation complete")
                    break
                }

                if waitCount % 10 == 0 {
                    print("[STREAMING] Waiting for \(pending) TTS generations to complete...")
                }

                Thread.sleep(forTimeInterval: 0.1)
                waitCount += 1
            }

            // Now wait for audio queue to empty
            waitCount = 0
            while waitCount < 50 { // Max 5 seconds wait
                self.audioQueueLock.wait()
                let queueSize = self.audioChunkQueue.count
                self.audioQueueLock.signal()

                if queueSize == 0 {
                    print("[STREAMING] Audio queue empty")
                    break
                }

                if waitCount % 10 == 0 {
                    print("[STREAMING] Waiting for \(queueSize) audio chunks to play...")
                }

                Thread.sleep(forTimeInterval: 0.1)
                waitCount += 1
            }

            // Clean up on main thread
            DispatchQueue.main.async {
                self.isStreaming = false
                self.isGenerating = false
                self.streamingVoice = nil

                // Check playback state
                let isPlaying = self.playerNode.isPlaying

                if !isPlaying {
                    self.isAudioPlaying = false
                    self.generationInProgress = false

                    // Calculate total completion time if not playing
                    if let startTime = self.generationStartTime {
                        self.totalCompletionTime = Date().timeIntervalSince(startTime)

                        // Call completion callback
                        if let callback = self.completionCallback {
                            callback(self.totalGenerationTime, self.totalCompletionTime)
                        }
                    }

                    self.objectWillChange.send()
                } else if self.playbackMonitorTimer == nil {
                    self.startPlaybackMonitoring()
                }
            }
        }
    }

    /// Stop streaming immediately
    public func stopStreaming() {
        if isStreaming {
            print("Stopping streaming session")
            isStreaming = false
            streamingVoice = nil

            streamingBufferLock.wait()
            streamingTextBuffer = ""
            streamingBufferLock.signal()

            stopPlayback()
        }
    }
}

extension AVAudioPCMBuffer {
    func saveToWavFile(at url: URL) throws {
        let audioFile = try AVAudioFile(forWriting: url,
                                      settings: format.settings,
                                      commonFormat: .pcmFormatFloat32,
                                      interleaved: false)
        try audioFile.write(from: self)
    }
}
