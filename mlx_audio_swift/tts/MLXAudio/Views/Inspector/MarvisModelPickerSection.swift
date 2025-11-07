//
//  MarvisModelPickerSection.swift
//  MLXAudio
//
//  Created by Claude Code
//

import SwiftUI

struct MarvisModelPickerSection: View {
    @Binding var selectedModel: MarvisSession.Model
    let loadedModel: MarvisSession.Model?
    let onModelChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Marvis Model")
                .font(.headline)
                .foregroundColor(.secondary)

            VStack(spacing: 12) {
                ForEach(MarvisSession.Model.allCases) { model in
                    modelCard(model: model)
                }
            }

            if let loaded = loadedModel, loaded != selectedModel {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("Switching models will reload the session")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            }
        }
    }

    private func modelCard(model: MarvisSession.Model) -> some View {
        Button {
            if selectedModel != model {
                selectedModel = model
                onModelChange()
            }
        } label: {
            HStack(spacing: 12) {
                // Selection indicator
                Image(systemName: selectedModel == model ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(selectedModel == model ? .blue : .secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(model.displayName)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)

                        Spacer()

                        Text(model.sizeDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(4)
                    }

                    Text(model.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selectedModel == model ? Color.blue.opacity(0.08) : Color(.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selectedModel == model ? Color.blue : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}
