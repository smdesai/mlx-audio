import AVFoundation
import MLX
import SwiftUI
#if os(iOS)
import UIKit
#endif

public class KokoroTTSModel: ObservableObject {
    private var kokoroTTSEngine: KokoroTTS!

    // Streaming support
    private var stream2Sentence: Stream2Sentence?
    @Published public var isStreaming = false
    private var streamingVoice: TTSVoice?
    private var streamingSpeed: Float = 1.0
    
    // Sentence splitting mode
    @Published public var useLegacySentenceSplit = false

    private var audioEngine: AVAudioEngine!
    private var playerNode: AVAudioPlayerNode!
    private var audioFormat: AVAudioFormat!

    private let streamingQueue = DispatchQueue(label: "com.kokoro.streaming", qos: .userInitiated)
    private var sentenceCounter = 0
    private var audioChunkQueue: [(sentenceNum: Int, audioBuffer: MLXArray)] = []
    private var nextExpectedSentence = 1
    private let audioQueueLock = NSLock()
    private let ttsGenerationQueue = DispatchQueue(label: "com.kokoro.tts.generation", qos: .userInitiated)
    private var pendingTTSCount = 0
    private let pendingTTSLock = NSLock()
    private var totalSentencesExpected = 0

    // Buffer tracking for reliable playback completion detection
    private var scheduledBufferCount = 0
    private var completedBufferCount = 0
    private let bufferCountLock = NSLock() // Thread safety for buffer counters

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
                        self.bufferCountLock.lock()
                        let allBuffersCompleted = self.completedBufferCount == self.scheduledBufferCount && self.scheduledBufferCount > 0
                        self.bufferCountLock.unlock()

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

    @Published public var audioGenerationTime: TimeInterval = 0

    public init() {
        kokoroTTSEngine = KokoroTTS()
        setupAudioSystem()
    }

    deinit {
         NotificationCenter.default.removeObserver(self)
         cleanupAudioSystem()
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

    public func say(_ text: String, _ voice: TTSVoice, speed: Float = 1.0) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
         guard !trimmedText.isEmpty else {
             return
         }

         // Reset timing metrics
         audioGenerationTime = 0.0

         // Set state at start
         DispatchQueue.main.async {
             self.generationInProgress = true
             self.isGenerating = true
             self.objectWillChange.send()
         }

         // Stop any ongoing playback
         if isGenerating || playerNode.isPlaying {
             stopPlayback()

             // We need to give the audio system time to reset
             // This is necessary for the AVAudioEngine to properly shut down
             Task {
                 // Wait briefly for audio system to fully reset
                 try? await Task.sleep(nanoseconds: 100_000_000) // 100ms - reduced from 300ms

                 // Now start the new generation
                 self.startSpeechGeneration(text: trimmedText, voice: voice, speed: speed)
             }
             return
         }

         // No existing playback, start immediately
         startSpeechGeneration(text: trimmedText, voice: voice, speed: speed)
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
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            self.kokoroTTSEngine.resetModel()
        }
    }

    // MARK: - Buffer Tracking

     private func resetBufferCounters() {
         bufferCountLock.lock()
         defer { bufferCountLock.unlock() }

         scheduledBufferCount = 0
         completedBufferCount = 0
     }

     private func incrementScheduledBufferCount() {
         bufferCountLock.lock()
         defer { bufferCountLock.unlock() }

         scheduledBufferCount += 1
     }

     private func incrementCompletedBufferCount() {
         bufferCountLock.lock()
         defer { bufferCountLock.unlock() }

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

    // MARK: - Audio Generation and Playback

    private func startSpeechGeneration(text: String, voice: TTSVoice, speed: Float) {
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

        let generationStartTime = Date()
        do {
            // Use streaming by sentence approach
            try kokoroTTSEngine.generateAudio(
                voice: voice,
                text: text,
                speed: speed,
                useLegacySentenceSplit: useLegacySentenceSplit
            ) { [weak self] audioBuffer in
                guard let self = self else { return }

                // Update generation time on first chunk
                if self.audioGenerationTime == 0.0 {
                    self.audioGenerationTime = Date().timeIntervalSince(generationStartTime)
                }

                DispatchQueue.main.async {
                    self.playAudioChunk(audioBuffer)
                }
            }

            // After all sentences are processed, update the generation state
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                // Mark generation (but not playback) as complete
                // We do this regardless of whether chunks were received yet
                self.isGenerating = false

                // Buffer completion callbacks will handle generationInProgress = false
                // when all audio is done playing
            }
        } catch {
            // Stop any active monitoring
            stopPlaybackMonitoring()

            isGenerating = false

            // Reset UI state with proper notification
            DispatchQueue.main.async {
                // First notify observers of impending change
                self.objectWillChange.send()

                // Reset all UI state flags
                self.isAudioPlaying = false
                self.generationInProgress = false

                // Final notification
                self.objectWillChange.send()
            }

            // Also reset the audio system to ensure clean state
            resetAudioSystem()
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
                    self.bufferCountLock.lock()
                    let allBuffersCompleted = self.completedBufferCount == self.scheduledBufferCount
                    self.bufferCountLock.unlock()

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

        // Start monitoring playback immediately if not already monitoring
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.playbackMonitorTimer == nil {
                self.startPlaybackMonitoring()
            }
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
        bufferCountLock.lock()
        let buffersScheduled = scheduledBufferCount
        let buffersCompleted = completedBufferCount
        let allBuffersCompleted = buffersCompleted == buffersScheduled && buffersScheduled > 0
        bufferCountLock.unlock()

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

            // No more buffers are playing, mark playback as complete
            self.isAudioPlaying = false  // This will trigger generationInProgress update

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

        // Copy data
        let channels = buffer.floatChannelData!
        let chunkSize = 32768 // 32K samples at a time

        for startIdx in stride(from: 0, to: min(frameCount, audioData.count), by: chunkSize) {
            autoreleasepool {
                let endIdx = min(startIdx + chunkSize, min(frameCount, audioData.count))

                // Copy with volume boost
                for i in startIdx..<endIdx {
                    if i < audioData.count && i < Int(buffer.frameCapacity) {
                        // Apply volume boost (25%) with clipping prevention
                        channels[0][i] = min(max(audioData[i] * 1.25, -0.98), 0.98)
                    }
                }
            }
        }
        return buffer
    }

    // MARK: - Streaming Support

    /// Start a streaming text-to-speech session
    public func startStreaming(voice: TTSVoice, speed: Float = 1.0) {
        guard !isStreaming else {
            print("Streaming already in progress")
            return
        }

        print("Starting streaming session with voice: \(voice.rawValue), speed: \(speed)")

        // Stop any ongoing playback monitoring from previous sessions
        stopPlaybackMonitoring()

        // Initialize stream2sentence with configuration
        var config = Stream2Sentence.Configuration()
        config.minimumSentenceLength = 10  // Lower threshold to ensure last sentences aren't skipped
        config.minimumFirstFragmentLength = 10
        config.contextSize = 20  // Less context needed
        config.contextSizeLookOverhead = 20
        config.quickYieldSingleSentenceFragment = false  // Don't yield fragments
        config.quickYieldEveryFragment = false
        config.sentenceFragmentDelimiters = ".?!;:\\n…)]}。"  // Removed comma to avoid splitting at commas
        config.fullSentenceDelimiters = ".?!\\n…。"
        config.logLevel = .info  // Reduce logging

        stream2Sentence = Stream2Sentence(configuration: config)

        isStreaming = true
        streamingVoice = voice
        streamingSpeed = speed
        sentenceCounter = 0
        audioChunkQueue.removeAll()
        nextExpectedSentence = 1
        pendingTTSCount = 0
        totalSentencesExpected = 0

        // Reset buffer counters to ensure proper tracking
        resetBufferCounters()

        // Reset audio generation time
        audioGenerationTime = 0.0

        // Set state at start of streaming
        DispatchQueue.main.async {
            self.generationInProgress = true
            self.isGenerating = true
            self.objectWillChange.send()
        }
    }

    /// Add streaming text chunks
    public func addStreamingText(_ text: String) {
        guard isStreaming, let stream2Sentence = stream2Sentence else {
            print("No active streaming session")
            return
        }

        // Process text through stream2sentence
        stream2Sentence.addText(text) { [weak self] sentence in
            guard let self = self else { return }

            // Process sentences with tracking
            self.streamingQueue.async {
                self.sentenceCounter += 1
                let sentenceNum = self.sentenceCounter
                print("[STREAMING] Received sentence #\(sentenceNum): '\(sentence)'")

                // Track pending TTS
                self.pendingTTSLock.lock()
                self.pendingTTSCount += 1
                self.pendingTTSLock.unlock()

                // Queue for TTS generation - serialized to avoid mixing
                self.ttsGenerationQueue.async {
                    self.processSentenceForStreaming(sentence, sentenceNum: sentenceNum)

                    // Decrement pending count
                    self.pendingTTSLock.lock()
                    self.pendingTTSCount -= 1
                    let remaining = self.pendingTTSCount
                    self.pendingTTSLock.unlock()

                    print("[STREAMING] Completed TTS for sentence #\(sentenceNum), remaining: \(remaining)")
                }
            }
        }
    }

    /// End the streaming session
    public func endStreaming() {
        guard isStreaming, let stream2Sentence = stream2Sentence else {
            print("No active streaming session to end")
            return
        }

        print("[STREAMING] Ending streaming session")

        // Mark that we're about to flush - this prevents voice from being cleared too early
        let flushStarted = DispatchSemaphore(value: 0)

        // Flush any remaining text
        stream2Sentence.flush { [weak self] sentence in
            guard let self = self else {
                flushStarted.signal()
                return
            }
            self.streamingQueue.async {
                self.sentenceCounter += 1
                let sentenceNum = self.sentenceCounter
                print("[STREAMING] Flushed sentence #\(sentenceNum): '\(sentence)'")

                // Update total expected sentences
                self.totalSentencesExpected = sentenceNum

                // Track pending TTS
                self.pendingTTSLock.lock()
                self.pendingTTSCount += 1
                self.pendingTTSLock.unlock()

                // Signal that flush has been processed
                flushStarted.signal()

                // Queue for TTS generation - serialized
                self.ttsGenerationQueue.async {
                    self.processSentenceForStreaming(sentence, sentenceNum: sentenceNum)

                    // Decrement pending count
                    self.pendingTTSLock.lock()
                    self.pendingTTSCount -= 1
                    let remaining = self.pendingTTSCount
                    self.pendingTTSLock.unlock()

                    print("[STREAMING] Completed TTS for sentence #\(sentenceNum), remaining: \(remaining)")
                }
            }
        }

        // Wait for flush to be processed before continuing
        let flushResult = flushStarted.wait(timeout: .now() + 1.0)
        if flushResult == .timedOut {
            print("[STREAMING] Warning: Flush timed out - no sentence in buffer")
            // Update total expected to current count if no flush happened
            totalSentencesExpected = sentenceCounter
        }

        // Don't clear state immediately - sentences might still be processing
        self.stream2Sentence = nil

        // Wait for all sentences to be processed before cleanup
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }

            // Wait for all pending TTS to complete
            var waitCount = 0
            while waitCount < 100 { // Max 10 seconds wait
                self.pendingTTSLock.lock()
                let pending = self.pendingTTSCount
                self.pendingTTSLock.unlock()

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
                self.audioQueueLock.lock()
                let queueSize = self.audioChunkQueue.count
                let nextExpected = self.nextExpectedSentence
                self.audioQueueLock.unlock()

                if queueSize == 0 {
                    print("[STREAMING] Audio queue empty, next expected: \(nextExpected)")
                    break
                }

                if waitCount % 10 == 0 {
                    print("[STREAMING] Waiting for \(queueSize) audio chunks to play...")
                }

                Thread.sleep(forTimeInterval: 0.1)
                waitCount += 1
            }

            // This will execute after all queued TTS generations complete
            DispatchQueue.main.async {
                // Now safe to clear streaming state
                self.isStreaming = false

                // Mark generation as complete since all TTS processing is done
                self.isGenerating = false

                // Clean up immediately
                self.streamingVoice = nil

                // Force check playback state
                let isPlaying = self.playerNode.isPlaying

                // If no audio is playing, clear generationInProgress immediately
                if !isPlaying {
                    self.isAudioPlaying = false
                    self.generationInProgress = false
                    self.objectWillChange.send()
                } else {
                    // Audio is still playing, ensure monitoring is active
                    if self.playbackMonitorTimer == nil {
                        self.startPlaybackMonitoring()
                    }
                }
                // Audio completion callbacks will handle setting generationInProgress = false
            }
        }
    }

    /// Stop streaming immediately
    public func stopStreaming() {
        if isStreaming {
            print("Stopping streaming session")
            isStreaming = false
            streamingVoice = nil
            stream2Sentence = nil

            stopPlayback()
        }
    }

    private func processSentenceForStreaming(_ sentence: String, sentenceNum: Int) {
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

        // Track when we start generating the first sentence
        let generationStartTime = Date()

        // We keep isGenerating = true until all audio is done

        // Use a semaphore to ensure generateAudio completes before moving to next sentence
        let semaphore = DispatchSemaphore(value: 0)
        var generationError: Error?

        do {
            // Generate audio for the sentence
            try kokoroTTSEngine.generateAudio(
                voice: voice,
                text: trimmedSentence,
                speed: streamingSpeed,
                useLegacySentenceSplit: useLegacySentenceSplit
            ) { [weak self] audioBuffer in
                guard let self = self else {
                    semaphore.signal()
                    return
                }

                print("[STREAMING] AUDIO Received for sentence #\(sentenceNum): '\(trimmedSentence)'")

                // Update generation time on first audio chunk
                if self.audioGenerationTime == 0.0 {
                    self.audioGenerationTime = Date().timeIntervalSince(generationStartTime)
                    print("First audio chunk received after: \(self.audioGenerationTime)s")
                }

                // Queue the audio chunk with its sentence number
                self.queueAudioChunk(audioBuffer, sentenceNum: sentenceNum)

                // Signal completion
                semaphore.signal()
            }

            // Wait for generation to complete
            _ = semaphore.wait(timeout: .now() + 10.0)

            print("Successfully completed audio generation for sentence #\(sentenceNum): '\(trimmedSentence)'")

        } catch {
            generationError = error
        }

        if let error = generationError {
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
        } else if generationError != nil {
            print("ERROR: Timeout or other error in audio generation")
        }
    }

    private func queueAudioChunk(_ audioBuffer: MLXArray, sentenceNum: Int) {
        audioQueueLock.lock()
        defer { audioQueueLock.unlock() }

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
