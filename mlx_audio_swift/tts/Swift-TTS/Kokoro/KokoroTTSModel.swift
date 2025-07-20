import AVFoundation
import MLX
import SwiftUI
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

    // Streaming support
    private var stream2Sentence: Stream2Sentence?
    @Published public var isStreaming = false
    private var streamingVoice: TTSVoice?
    private var streamingSpeed: Float = 1.0

    private var streamingTextBuffer = ""
    private var processedSentenceCount = 0
    private let streamingBufferLock = DispatchSemaphore(value: 1)

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

    @Published public var audioGenerationTime: TimeInterval = 0

    public init() {
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)

        kokoroTTSEngine = KokoroTTS()
        setupAudioSystem()

        // Setup app lifecycle notifications
        setupAppLifecycleObservers()

        // Prewarm the model in the background
        prewarmModel()
    }

    // Prewarm the TTS engine to reduce initial latency
    private func prewarmModel() {
        kokoroTTSEngine.prewarm(voice: .afHeart) {
            print("Kokoro TTS model prewarmed successfully")
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

    @objc private func appWillResignActive() {
        // App is about to become inactive (user switching apps, receiving call, etc)
        // Stop any ongoing TTS generation and playback
        print("App will resign active - stopping TTS operations")

        isAppActive = false

        // Stop streaming if active
        if isStreaming {
            stopStreamingV2()
        }

        // Stop any ongoing playback
        stopPlayback()

        // Clear GPU cache to prevent background GPU operations
        MLX.GPU.clearCache()
    }

    @objc private func appDidEnterBackground() {
        print("App entered background - clearing GPU resources")

        // Force clear any remaining GPU operations
        MLX.GPU.clearCache()

        // Reset the TTS engine to free GPU resources
        kokoroTTSEngine.resetModel(preserveTextProcessing: true)
    }

    @objc private func appDidBecomeActive() {
        // App became active again
        print("App became active - ready for TTS operations")

        isAppActive = true

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

    public func say(_ text: String, _ voice: TTSVoice, speed: Float = 1.0) {
        // Check if app is active
        guard isAppActive else {
            print("App is not active - ignoring TTS request")
            return
        }

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
        streamingState.reset()
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
                self.streamingState.incrementPending()

                // Queue for TTS generation - serialized to avoid mixing
                self.ttsGenerationQueue.async {
                    self.processSentenceForStreaming(sentence, sentenceNum: sentenceNum)

                    let remaining = self.streamingState.decrementPending()

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
                self.streamingState.incrementPending()

                // Signal that flush has been processed
                flushStarted.signal()

                // Queue for TTS generation - serialized
                self.ttsGenerationQueue.async {
                    self.processSentenceForStreaming(sentence, sentenceNum: sentenceNum)

                    let remaining = self.streamingState.decrementPending()

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
                let nextExpected = self.nextExpectedSentence
                self.audioQueueLock.signal()

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

        // Track when we start generating the first sentence
        let generationStartTime = Date()

        // We keep isGenerating = true until all audio is done

        do {
            // Generate audio for the single sentence (no re-splitting)
            let audioBuffer = try kokoroTTSEngine.generateAudioForSingleSentence(
                voice: voice,
                text: trimmedSentence,
                speed: streamingSpeed
            )

            print("[STREAMING] AUDIO Generated for sentence #\(sentenceNum): '\(trimmedSentence)'")

            // Update generation time on first audio chunk
            if self.audioGenerationTime == 0.0 {
                self.audioGenerationTime = Date().timeIntervalSince(generationStartTime)
                print("First audio chunk received after: \(self.audioGenerationTime)s")
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
    public func startStreamingV2(voice: TTSVoice, speed: Float = 1.0) {
        guard !isStreaming else {
            print("Streaming already in progress")
            return
        }

        print("Starting streaming session V2 with voice: \(voice.rawValue), speed: \(speed)")

        // Stop any ongoing playback monitoring from previous sessions
        stopPlaybackMonitoring()

        // Initialize streaming state
        isStreaming = true
        streamingVoice = voice
        streamingSpeed = speed
        streamingTextBuffer = ""
        processedSentenceCount = 0
        sentenceCounter = 0
        audioChunkQueue.removeAll()
        nextExpectedSentence = 1
        streamingState.reset()
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

    /// Add text chunks and process complete sentences
    public func addStreamingTextV2(_ text: String) {
        guard isStreaming else {
            print("No active streaming session")
            return
        }

        // Thread-safe append to buffer
        streamingBufferLock.wait()
        streamingTextBuffer += text
        streamingBufferLock.signal()

        // Try to extract complete sentences
        processBufferedText()
    }

    /// Process buffered text to extract complete sentences
    private func processBufferedText() {
        streamingBufferLock.wait()
        let fullBuffer = streamingTextBuffer
        let currentProcessedCount = processedSentenceCount
        streamingBufferLock.signal()

        // Use SentenceTokenizer to split the entire buffer
        let sentences = useLegacySentenceSplit ?
            SentenceTokenizer.splitIntoSentencesLegacy(text: fullBuffer) :
            SentenceTokenizer.splitIntoSentences(text: fullBuffer)

        // If we have no sentences or haven't received new sentences, wait
        if sentences.isEmpty || sentences.count <= currentProcessedCount {
            return
        }

        // Helper function to check if a sentence ends with valid punctuation
        func isCompleteSentence(_ sentence: String) -> Bool {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasSuffix(".") ||
                   trimmed.hasSuffix("!") ||
                   trimmed.hasSuffix("?") ||
                   trimmed.hasSuffix("。") ||
                   trimmed.hasSuffix("！") ||
                   trimmed.hasSuffix("？")
        }

        // Determine how many sentences to process
        let lastSentence = sentences.last!
        let lastSentenceIsComplete = isCompleteSentence(lastSentence)

        let sentencesToProcessCount: Int
        if lastSentenceIsComplete {
            // All sentences are complete
            sentencesToProcessCount = sentences.count
        } else {
            // Last sentence is incomplete
            if sentences.count == 1 {
                // Only one incomplete sentence - don't process anything yet
                return
            } else {
                // Process all but the last incomplete sentence
                sentencesToProcessCount = sentences.count - 1
            }
        }

        // Process only new sentences (those after processedSentenceCount)
        let newSentences = Array(sentences[currentProcessedCount..<sentencesToProcessCount])

        // Process new complete sentences
        for sentence in newSentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                streamingQueue.async {
                    self.sentenceCounter += 1
                    let sentenceNum = self.sentenceCounter
                    print("[STREAMING V2] Processing sentence #\(sentenceNum): '\(trimmed)'")

                    // Track pending TTS
                    self.streamingState.incrementPending()

                    // Queue for TTS generation
                    self.ttsGenerationQueue.async {
                        self.processSentenceForStreaming(trimmed, sentenceNum: sentenceNum)

                        // Decrement pending count
                        let remaining = self.streamingState.decrementPending()

                        print("[STREAMING V2] Completed TTS for sentence #\(sentenceNum), remaining: \(remaining)")
                    }
                }
            }
        }

        // Update the processed count
        streamingBufferLock.wait()
        processedSentenceCount = sentencesToProcessCount
        streamingBufferLock.signal()
    }

    /// End the streaming session V2
    public func endStreamingV2() {
        guard isStreaming else {
            print("No active streaming session to end")
            return
        }

        print("[STREAMING V2] Ending streaming session")

        // Process any remaining text in buffer as final sentence
        streamingBufferLock.wait()
        let fullBuffer = streamingTextBuffer
        let currentProcessedCount = processedSentenceCount
        streamingBufferLock.signal()

        // Get all sentences including any incomplete final one
        let sentences = useLegacySentenceSplit ?
            SentenceTokenizer.splitIntoSentencesLegacy(text: fullBuffer) :
            SentenceTokenizer.splitIntoSentences(text: fullBuffer)

        // Process any remaining unprocessed sentences
        let remainingText = sentences.count > currentProcessedCount ?
            sentences[currentProcessedCount...].joined(separator: " ") : ""

        if !remainingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            streamingQueue.async {
                self.sentenceCounter += 1
                let sentenceNum = self.sentenceCounter
                let finalSentence = remainingText.trimmingCharacters(in: .whitespacesAndNewlines)

                print("[STREAMING V2] Processing final sentence #\(sentenceNum): '\(finalSentence)'")

                // Update total expected sentences
                self.totalSentencesExpected = sentenceNum

                // Track pending TTS
                self.streamingState.incrementPending()

                // Queue for TTS generation
                self.ttsGenerationQueue.async {
                    self.processSentenceForStreaming(finalSentence, sentenceNum: sentenceNum)

                    // Decrement pending count
                    let remaining = self.streamingState.decrementPending()

                    print("[STREAMING V2] Completed TTS for final sentence #\(sentenceNum), remaining: \(remaining)")
                }
            }
        } else {
            // No final sentence to process
            totalSentencesExpected = sentenceCounter
        }

        // Clear buffer and reset index
        streamingBufferLock.wait()
        streamingTextBuffer = ""
        processedSentenceCount = 0
        streamingBufferLock.signal()

        // Wait for all sentences to be processed before cleanup
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }

            // Wait for all pending TTS to complete
            var waitCount = 0
            while waitCount < 100 { // Max 10 seconds wait
                let pending = self.streamingState.getPendingCount()

                if pending == 0 {
                    print("[STREAMING V2] All TTS generation complete")
                    break
                }

                if waitCount % 10 == 0 {
                    print("[STREAMING V2] Waiting for \(pending) TTS generations to complete...")
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
                    print("[STREAMING V2] Audio queue empty")
                    break
                }

                if waitCount % 10 == 0 {
                    print("[STREAMING V2] Waiting for \(queueSize) audio chunks to play...")
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
                    self.objectWillChange.send()
                } else if self.playbackMonitorTimer == nil {
                    self.startPlaybackMonitoring()
                }
            }
        }
    }

    /// Stop streaming immediately V2
    public func stopStreamingV2() {
        if isStreaming {
            print("Stopping streaming session V2")
            isStreaming = false
            streamingVoice = nil

            streamingBufferLock.wait()
            streamingTextBuffer = ""
            processedSentenceCount = 0
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
