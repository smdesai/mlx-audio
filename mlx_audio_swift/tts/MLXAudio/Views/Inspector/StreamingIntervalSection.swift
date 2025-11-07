//
//  StreamingIntervalSection.swift
//  MLXAudio
//
//  Created by Rudrank Riyam on 6/11/25.
//

import SwiftUI

struct StreamingIntervalSection: View {
    @Binding var streamingInterval: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Streaming Interval")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Spacer()

                Text(String(format: "%.1fs", streamingInterval))
                    .font(.subheadline)
                    .bold()
            }

            Slider(value: $streamingInterval, in: 0.5...2.0, step: 0.1)

            Text("Chunk duration: \(recommendationText)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var recommendationText: String {
        if streamingInterval < 0.8 {
            return "Fast response (best for low quality)"
        } else if streamingInterval < 1.2 {
            return "Balanced (recommended for medium quality)"
        } else {
            return "Efficient (recommended for high/maximum quality)"
        }
    }
}
