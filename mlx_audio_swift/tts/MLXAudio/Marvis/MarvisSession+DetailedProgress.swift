//
//  MarvisSession+DetailedProgress.swift
//  MLXAudio
//
//  Created by Claude Code
//

import Foundation
import MLX

/// Extension providing detailed loading progress tracking for MarvisSession
extension MarvisSession {

    /// Initializes MarvisSession with detailed progress tracking through MarvisLoadingProgress
    ///
    /// This provides a better user experience by breaking down the loading process
    /// into distinct, trackable stages instead of showing a generic progress indicator.
    ///
    /// - Parameters:
    ///   - voice: The voice to use for generation
    ///   - repoId: HuggingFace repository ID for the model
    ///   - playbackEnabled: Whether to enable audio playback
    ///   - loadingProgress: Observable progress tracker that will be updated throughout loading
    /// - Returns: Initialized MarvisSession ready for generation
    /// - Throws: Any errors encountered during model loading
    @MainActor
    public static func initializeWithDetailedProgress(
        voice: Voice = .conversationalA,
        model: Model = .marvis250M,
        playbackEnabled: Bool = true,
        loadingProgress: MarvisLoadingProgress
    ) async throws -> MarvisSession {

        // Reset progress to start fresh
        loadingProgress.reset()

        do {
            // STAGE 1: Download main model (0-50%)
            loadingProgress.updateStage(.downloadingModel)
            let (args, prompts, weightFileURL) = try await Self.snapshotAndConfig(
                repoId: model.rawValue,
                progressHandler: loadingProgress.makeProgressHandler(for: .downloadingModel)
            )

            // STAGE 2: Load text tokenizer (50-60%)
            // This happens inside the main init, so we'll show progress manually
            loadingProgress.updateStage(.loadingTokenizer)
            loadingProgress.updateProgress(0.5) // Start at 50%

            // STAGE 3: Download Mimi codec (60-85%)
            // The main init will handle this with the progress handler
            let session = try await Self.initializeWithTokenizerProgress(
                config: args,
                repoId: model.rawValue,
                promptURLs: prompts,
                playbackEnabled: playbackEnabled,
                loadingProgress: loadingProgress
            )

            // STAGE 4: Install weights (85-100%)
            loadingProgress.updateStage(.installingWeights)
            loadingProgress.updateProgress(0.0)
            try session.installWeights(args: args, weightFileURL: weightFileURL)
            loadingProgress.updateProgress(1.0)

            // Complete!
            loadingProgress.complete()

            // Bind the voice
            session.boundVoice = voice
            session.boundRefAudio = nil
            session.boundRefText = nil

            return session

        } catch {
            loadingProgress.fail(with: error.localizedDescription)
            throw error
        }
    }

    /// Private helper that creates MarvisSession while tracking tokenizer and codec loading
    @MainActor
    private static func initializeWithTokenizerProgress(
        config: MarvisModelArgs,
        repoId: String,
        promptURLs: [URL]?,
        playbackEnabled: Bool,
        loadingProgress: MarvisLoadingProgress
    ) async throws -> MarvisSession {

        // This wraps the main init to give us control over progress reporting

        // Start tokenizer loading
        loadingProgress.updateStage(.loadingTokenizer)
        loadingProgress.updateProgress(0.0)

        // Create a custom progress handler that switches stages appropriately
        let codecProgressHandler: (Progress) -> Void = { progress in
            Task { @MainActor in
                // When we start getting codec progress, switch to that stage
                if loadingProgress.currentStage != .downloadingCodec {
                    loadingProgress.updateStage(.downloadingCodec)
                }
                loadingProgress.updateProgress(progress.fractionCompleted)
            }
        }

        // Before calling init, simulate tokenizer progress
        // (The actual tokenizer load is fast but happens inside init)
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2s
        loadingProgress.updateProgress(1.0)

        // Now call the real init which will load tokenizer and codec
        loadingProgress.updateStage(.downloadingCodec)
        let session = try await MarvisSession(
            config: config,
            repoId: repoId,
            promptURLs: promptURLs,
            progressHandler: codecProgressHandler,
            playbackEnabled: playbackEnabled
        )

        return session
    }
}
