//
//  MarvisLoadingView.swift
//  MLXAudio
//
//  Created by Claude Code
//

import SwiftUI

/// Beautiful loading view for Marvis model initialization (macOS)
/// Displays clear progress feedback to prevent users from thinking the app has hung
struct MarvisLoadingView: View {
    @ObservedObject var progress: MarvisLoadingProgress

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            // Main loading card
            VStack(spacing: 28) {
                // Circular progress indicator
                ZStack {
                    // Background circle
                    Circle()
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 10)
                        .frame(width: 140, height: 140)

                    // Progress circle with gradient
                    Circle()
                        .trim(from: 0, to: progress.overallProgress)
                        .stroke(
                            LinearGradient(
                                colors: [.blue, .cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 10, lineCap: .round)
                        )
                        .frame(width: 140, height: 140)
                        .rotationEffect(.degrees(-90))
                        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: progress.overallProgress)

                    // Percentage text
                    VStack(spacing: 4) {
                        Text("\(Int(progress.overallProgress * 100))")
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                        Text("%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)

                // Stage information
                VStack(spacing: 12) {
                    Text(progress.currentStage.displayName)
                        .font(.title)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)

                    Text(progress.currentStage.description)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Animated loading dots
                if progress.currentStage != .complete && !progress.currentStage.isFailed {
                    HStack(spacing: 6) {
                        ForEach(0..<3) { index in
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 8, height: 8)
                                .opacity(dotOpacity(for: index))
                                .animation(
                                    .easeInOut(duration: 0.8)
                                    .repeatForever(autoreverses: false)
                                    .delay(Double(index) * 0.2),
                                    value: progress.currentStage
                                )
                        }
                    }
                    .padding(.top, 4)
                }

                // Helpful tip
                if progress.currentStage == .downloadingModel || progress.currentStage == .downloadingCodec {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("First-time setup • Future launches will be instant")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(48)
            .frame(width: 480)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 30, y: 15)
        }
    }

    // MARK: - Animation Helpers

    private func dotOpacity(for index: Int) -> Double {
        // Create a wave animation effect for the dots
        if progress.currentStage == .idle || progress.currentStage == .complete || progress.currentStage.isFailed {
            return 0.5
        }
        // Use a time-based animation to create a loading wave effect
        let phase = (Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4)) / 2.4
        let offset = Double(index) / 3.0
        let adjusted = (phase + offset).truncatingRemainder(dividingBy: 1.0)
        return 0.3 + (sin(adjusted * .pi * 2) * 0.7)
    }
}

// MARK: - Stage Extension for Failed Case Matching

extension MarvisLoadingProgress.Stage {
    var isFailed: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}

// MARK: - Preview

#Preview("Loading") {
    MarvisLoadingView(progress: {
        let progress = MarvisLoadingProgress()
        progress.updateStage(.downloadingCodec)
        progress.updateProgress(0.65)
        return progress
    }())
}

#Preview("Complete") {
    MarvisLoadingView(progress: {
        let progress = MarvisLoadingProgress()
        progress.complete()
        return progress
    }())
}

#Preview("Installing Weights") {
    MarvisLoadingView(progress: {
        let progress = MarvisLoadingProgress()
        progress.updateStage(.installingWeights)
        progress.updateProgress(0.90)
        return progress
    }())
}
