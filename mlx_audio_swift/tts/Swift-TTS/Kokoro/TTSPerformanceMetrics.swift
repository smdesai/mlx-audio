//
//  TTSPerformanceMetrics.swift
//  Swift-TTS
//

import Foundation

/// Encapsulates all performance metrics for TTS operations
public struct TTSPerformanceMetrics {
    
    // MARK: - Timing Metrics
    
    /// Time from start of generation to first audio chunk (seconds)
    public var timeToFirstAudio: TimeInterval = 0
    
    /// Total time for all audio generation to complete (seconds)
    public var totalGenerationTime: TimeInterval = 0
    
    /// Total time from start to all audio playback complete (seconds)
    public var totalCompletionTime: TimeInterval = 0

    /// Total audio duration generated (seconds)
    public var audioDurationSeconds: TimeInterval = 0
    
    // MARK: - Timestamps
    
    /// When generation started
    public var generationStartTime: Date?
    
    /// When all audio generation completed
    public var allAudioGeneratedTime: Date?
    
    /// When all audio playback completed
    public var playbackCompletionTime: Date?
    
    // MARK: - Statistics
    
    /// Number of sentences processed
    public var sentencesProcessed: Int = 0
    
    /// Number of audio chunks generated
    public var audioChunksGenerated: Int = 0
    
    /// Total characters processed
    public var charactersProcessed: Int = 0
    
    /// Average time per sentence (computed property)
    public var averageTimePerSentence: TimeInterval {
        guard sentencesProcessed > 0 else { return 0 }
        return totalGenerationTime / Double(sentencesProcessed)
    }
    
    /// Characters per second (computed property)
    public var charactersPerSecond: Double {
        guard totalGenerationTime > 0 else { return 0 }
        return Double(charactersProcessed) / totalGenerationTime
    }
    
    /// Real-time factor (audio duration divided by generation time).
    /// Values > 1.0 indicate faster-than-real-time generation.
    public var realTimeFactor: Double {
        guard totalGenerationTime > 0 && audioDurationSeconds > 0 else { return 0 }
        return audioDurationSeconds / totalGenerationTime
    }
    
    // MARK: - Methods
    
    /// Reset all metrics to initial state
    public mutating func reset() {
        timeToFirstAudio = 0
        totalGenerationTime = 0
        totalCompletionTime = 0
        audioDurationSeconds = 0
        generationStartTime = nil
        allAudioGeneratedTime = nil
        playbackCompletionTime = nil
        sentencesProcessed = 0
        audioChunksGenerated = 0
        charactersProcessed = 0
    }
    
    /// Start timing a new generation
    public mutating func startGeneration() {
        reset()
        generationStartTime = Date()
    }
    
    /// Record first audio chunk received
    public mutating func recordFirstAudio() {
        guard timeToFirstAudio == 0, let startTime = generationStartTime else { return }
        timeToFirstAudio = Date().timeIntervalSince(startTime)
    }
    
    /// Record audio generation progress
    public mutating func recordGenerationProgress() {
        guard let startTime = generationStartTime else { return }
        allAudioGeneratedTime = Date()
        totalGenerationTime = allAudioGeneratedTime!.timeIntervalSince(startTime)
    }
    
    /// Record playback completion
    public mutating func recordPlaybackCompletion() {
        guard let startTime = generationStartTime else { return }
        playbackCompletionTime = Date()
        totalCompletionTime = playbackCompletionTime!.timeIntervalSince(startTime)
    }
    
    /// Add processed text for statistics
    public mutating func addProcessedText(_ text: String) {
        charactersProcessed += text.count
        sentencesProcessed += 1
    }
    
    /// Add audio chunk for statistics
    public mutating func addAudioChunk() {
        audioChunksGenerated += 1
    }

    /// Add to total audio duration (in seconds)
    public mutating func addAudioDuration(_ seconds: TimeInterval) {
        audioDurationSeconds += seconds
    }
    
    // MARK: - Description
    
    /// Human-readable summary of metrics
    public var summary: String {
        var lines: [String] = []
        
        if timeToFirstAudio > 0 {
            lines.append(String(format: "Time to first audio: %.2fs", timeToFirstAudio))
        }
        
        if totalGenerationTime > 0 {
            lines.append(String(format: "Total generation: %.2fs", totalGenerationTime))
        }
        
        if totalCompletionTime > 0 {
            lines.append(String(format: "Total completion: %.2fs", totalCompletionTime))
        }
        
        if sentencesProcessed > 0 {
            lines.append("Sentences: \(sentencesProcessed)")
            if averageTimePerSentence > 0 {
                lines.append(String(format: "Avg per sentence: %.2fs", averageTimePerSentence))
            }
        }
        
        if charactersPerSecond > 0 {
            lines.append(String(format: "Speed: %.0f chars/sec", charactersPerSecond))
        }
        
        if realTimeFactor > 0 {
            lines.append(String(format: "Real-time factor (dur/gen): %.2fx", realTimeFactor))
        }
        
        return lines.joined(separator: "\n")
    }
}

// MARK: - ObservableObject Wrapper

/// Observable wrapper for use in SwiftUI
// (Removed) Observable wrapper was unused; metrics are consumed directly from the model
