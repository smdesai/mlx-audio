//
//  MarvisLoadingView.swift
//  MLXAudio-iOS
//
//  Created by Claude Code
//

import SwiftUI

/// Beautiful full-screen loading view for Marvis model initialization
/// Displays clear progress feedback to prevent users from thinking the app has hung
struct MarvisLoadingView: View {
    @ObservedObject var progress: MarvisLoadingProgress

    var body: some View {
        ZStack {
            // Frosted glass background
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .blur(radius: 20)

            VStack(spacing: 32) {
                Spacer()

                // Main content card
                VStack(spacing: 24) {
                    // Circular progress indicator
                    ZStack {
                        // Background circle
                        Circle()
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 8)
                            .frame(width: 120, height: 120)

                        // Progress circle
                        Circle()
                            .trim(from: 0, to: progress.overallProgress)
                            .stroke(
                                LinearGradient(
                                    colors: [.blue, .cyan],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                style: StrokeStyle(lineWidth: 8, lineCap: .round)
                            )
                            .frame(width: 120, height: 120)
                            .rotationEffect(.degrees(-90))
                            .animation(.spring(response: 0.6, dampingFraction: 0.8), value: progress.overallProgress)

                        // Percentage text
                        VStack(spacing: 2) {
                            Text("\(Int(progress.overallProgress * 100))")
                                .font(.system(size: 36, weight: .bold, design: .rounded))
                                .contentTransition(.numericText())
                            Text("%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Stage information
                    VStack(spacing: 8) {
                        Text(progress.currentStage.displayName)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .multilineTextAlignment(.center)

                        Text(progress.currentStage.description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 280)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Animated loading indicator
                    if progress.currentStage != .complete && !progress.currentStage.isFailed {
                        HStack(spacing: 4) {
                            ForEach(0..<3) { index in
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 6, height: 6)
                                    .scaleEffect(pulseScale(for: index))
                                    .animation(
                                        .easeInOut(duration: 0.6)
                                        .repeatForever(autoreverses: true)
                                        .delay(Double(index) * 0.2),
                                        value: progress.currentStage
                                    )
                            }
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(40)
                .background(
                    RoundedRectangle(cornerRadius: 24)
                        .fill(.ultraThinMaterial)
                )
                .shadow(color: .black.opacity(0.1), radius: 20, y: 10)

                Spacer()

                // Helpful tip at the bottom
                if progress.currentStage == .downloadingModel || progress.currentStage == .downloadingCodec {
                    VStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .font(.caption)
                        Text("First-time setup • Future launches will be instant")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 40)
                }
            }
            .padding()
        }
    }

    // MARK: - Animation Helpers

    private func pulseScale(for index: Int) -> CGFloat {
        // Create a pulsing animation effect
        if progress.currentStage == .idle || progress.currentStage == .complete || progress.currentStage.isFailed {
            return 1.0
        }
        return 1.0 + (sin(Date().timeIntervalSinceReferenceDate + Double(index) * 0.5) * 0.3)
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
        progress.updateStage(.downloadingModel)
        progress.updateProgress(0.45)
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
