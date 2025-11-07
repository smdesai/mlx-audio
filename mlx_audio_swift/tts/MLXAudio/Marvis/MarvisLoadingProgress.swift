//
//  MarvisLoadingProgress.swift
//  MLXAudio
//
//  Created by Claude Code
//

import Foundation
import Combine

/// Observable class that tracks the detailed loading progress of MarvisSession
/// Breaks down the loading process into distinct stages with clear messaging
@MainActor
public class MarvisLoadingProgress: ObservableObject {

    // MARK: - Loading Stages

    public enum Stage: Equatable {
        case idle
        case downloadingModel
        case loadingTokenizer
        case downloadingCodec
        case installingWeights
        case complete
        case failed(String)

        var displayName: String {
            switch self {
            case .idle:
                return "Preparing..."
            case .downloadingModel:
                return "Downloading Marvis Model"
            case .loadingTokenizer:
                return "Loading Text Tokenizer"
            case .downloadingCodec:
                return "Downloading Audio Codec"
            case .installingWeights:
                return "Installing Model Weights"
            case .complete:
                return "Ready!"
            case .failed(let error):
                return "Failed: \(error)"
            }
        }

        var description: String {
            switch self {
            case .idle:
                return "Initializing model components..."
            case .downloadingModel:
                return "This is a one-time download. Future launches will be instant."
            case .loadingTokenizer:
                return "Preparing text processing components..."
            case .downloadingCodec:
                return "Loading high-quality audio codec..."
            case .installingWeights:
                return "Finalizing model initialization..."
            case .complete:
                return "Model loaded successfully!"
            case .failed(let error):
                return error
            }
        }

        /// Progress range for this stage (0.0 to 1.0)
        var progressRange: (start: Double, end: Double) {
            switch self {
            case .idle:
                return (0.0, 0.0)
            case .downloadingModel:
                return (0.0, 0.50)  // 0-50%: Main model download (usually longest)
            case .loadingTokenizer:
                return (0.50, 0.60) // 50-60%: Quick tokenizer load
            case .downloadingCodec:
                return (0.60, 0.85) // 60-85%: Mimi codec download
            case .installingWeights:
                return (0.85, 1.0)  // 85-100%: Weight installation
            case .complete:
                return (1.0, 1.0)
            case .failed:
                return (0.0, 0.0)
            }
        }
    }

    // MARK: - Published Properties

    @Published public private(set) var currentStage: Stage = .idle
    @Published public private(set) var overallProgress: Double = 0.0
    @Published public private(set) var stageProgress: Double = 0.0

    // MARK: - Initialization

    public init() {}

    // MARK: - Public Methods

    /// Updates the current loading stage
    public func updateStage(_ stage: Stage) {
        currentStage = stage
        stageProgress = 0.0
        overallProgress = stage.progressRange.start
    }

    /// Updates progress within the current stage
    /// - Parameter progress: Progress from 0.0 to 1.0 for the current stage
    public func updateProgress(_ progress: Double) {
        let clamped = min(max(progress, 0.0), 1.0)
        stageProgress = clamped

        let range = currentStage.progressRange
        let stageWidth = range.end - range.start
        overallProgress = range.start + (stageWidth * clamped)
    }

    /// Resets all progress to initial state
    public func reset() {
        currentStage = .idle
        overallProgress = 0.0
        stageProgress = 0.0
    }

    /// Marks loading as complete
    public func complete() {
        currentStage = .complete
        overallProgress = 1.0
        stageProgress = 1.0
    }

    /// Marks loading as failed with an error message
    public func fail(with error: String) {
        currentStage = .failed(error)
    }

    // MARK: - Convenience Methods

    /// Creates a progress handler closure for Hub downloads
    /// - Parameter stage: The stage this download belongs to
    /// - Returns: A progress handler that updates this tracker
    public func makeProgressHandler(for stage: Stage) -> (Progress) -> Void {
        return { [weak self] progress in
            Task { @MainActor in
                guard let self = self else { return }
                if self.currentStage != stage {
                    self.updateStage(stage)
                }
                self.updateProgress(progress.fractionCompleted)
            }
        }
    }
}
