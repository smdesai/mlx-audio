//
//  TranscriptionLiveActivity.swift
//  Swift-TTS-Widgets (Widget Extension Placeholder)
//
//  IMPORTANT: Add a Widget Extension target in Xcode, include this file,
//  and enable "Supports Live Activities" for the app target. This code
//  provides the Dynamic Island + Lock Screen UI for the Live Activity.
//

import SwiftUI
import WidgetKit
import ActivityKit

@available(iOS 16.1, *)
struct TranscriptionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TranscriptionActivityAttributes.self) { context in
            // Lock Screen / Banner UI
            VStack(alignment: .leading, spacing: 8) {
                Text(context.attributes.title)
                    .font(.headline)
                Text(context.attributes.voice)
                    .font(.caption)
                    .foregroundColor(.secondary)
                ProgressView(value: min(Float(context.state.completed), Float(context.state.total)), total: Float(context.state.total))
                Text(context.state.message ?? phaseText(context.state.phase))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "waveform")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(shortPhaseText(context.state.phase))
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading) {
                        Text(context.attributes.title)
                            .font(.subheadline)
                            .lineLimit(1)
                        ProgressView(value: min(Float(context.state.completed), Float(context.state.total)), total: Float(context.state.total))
                        Text(context.state.message ?? phaseText(context.state.phase))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "waveform")
            } compactTrailing: {
                Text("\(min(context.state.completed, context.state.total))/\(context.state.total)")
                    .font(.caption2)
            } minimal: {
                Image(systemName: "waveform")
            }
        }
    }
}

@available(iOS 16.1, *)
private func phaseText(_ phase: TranscriptionPhase) -> String {
    switch phase {
    case .generating: return "Generating…"
    case .combining: return "Combining…"
    case .transcribing: return "Transcribing…"
    case .done: return "Done"
    }
}

@available(iOS 16.1, *)
private func shortPhaseText(_ phase: TranscriptionPhase) -> String {
    switch phase {
    case .generating: return "Gen"
    case .combining: return "Comb"
    case .transcribing: return "Trans"
    case .done: return "Done"
    }
}

@available(iOS 16.1, *)
struct TranscriptionLiveActivity_Previews: PreviewProvider {
    static var previews: some View {
        let attrs = TranscriptionActivityAttributes(title: "Saving Audio…", voice: "af_heart")
        let state = TranscriptionActivityAttributes.ContentState(phase: .generating, completed: 2, total: 10, message: "Generating…")

        attrs.previewContext(state, viewKind: .dynamicIsland(.expanded))
            .previewDisplayName("Island Expanded")

        attrs.previewContext(state, viewKind: .dynamicIsland(.compact))
            .previewDisplayName("Island Compact")

        attrs.previewContext(state, viewKind: .content)
            .previewDisplayName("Lock Screen")
    }
}

