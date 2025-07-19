//
//  ContentView.swift
//  Swift-TTS
//
//  Created by Ben Harraway on 13/04/2025.
//

import SwiftUI

struct ContentView: View {

    @State private var kokoroTTSModel: KokoroTTSModel? = nil
    @State private var orpheusTTSModel: OrpheusTTSModel? = nil

    @State private var sayThis : String = "Hello Everybody"
    @State private var status : String = ""
    @State private var useLegacySentenceSplit = false

    private var availableProviders = ["kokoro", "orpheus"]
    @State private var chosenProvider : String = "kokoro"
    @State private var availableVoices: [String] = TTSVoice.allCases.map { $0.rawValue }
    @State private var chosenVoice: String = TTSVoice.bmGeorge.rawValue

    var body: some View {
        VStack {
            Image(systemName: "mouth")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("TTS Examples")
                .font(.headline)
                .padding()

            Picker("Choose a provider", selection: $chosenProvider) {
                ForEach(availableProviders, id: \.self) { provider in
                    Text(provider.capitalized)
                }
            }
            .onChange(of: chosenProvider) { _, newProvider in
                if newProvider == "orpheus" {
                    availableVoices = OrpheusVoice.allCases.map { $0.rawValue }
                    chosenVoice = availableVoices.first ?? "dan"

                    status = "Orpheus is currently quite slow (0.1x on M1).  Working on it!\n\nBut it does support expressions: <laugh>, <chuckle>, <sigh>, <cough>, <sniffle>, <groan>, <yawn>, <gasp>"
                } else {
                    availableVoices = TTSVoice.allCases.map { $0.rawValue }
                    chosenVoice = availableVoices.first ?? TTSVoice.bmGeorge.rawValue

                    status = ""
                }
            }
            .padding()
            .padding(.bottom, 0)

            // Voice picker
            Picker("Choose a voice", selection: $chosenVoice) {
                ForEach(availableVoices, id: \.self) { voice in
                    Text(voice.capitalized)
                }
            }
            .padding()
            .padding(.top, 0)

            TextField("Enter text", text: $sayThis).padding()
            
            // Add toggle for sentence splitting mode
            HStack {
                Text("Legacy Sentence Split")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: $useLegacySentenceSplit)
            }
            .padding(.horizontal)
            .disabled(chosenProvider != "kokoro") // Only enable for Kokoro

            Button(action: {
                Task {
                    status = "Generating..."
                    if chosenProvider == "kokoro" {
                        if kokoroTTSModel == nil {
                            kokoroTTSModel = KokoroTTSModel()
                        }
                        
                        // Set the legacy mode preference
                        kokoroTTSModel!.useLegacySentenceSplit = useLegacySentenceSplit

                        if let kokoroVoice = TTSVoice.fromIdentifier(chosenVoice) ?? TTSVoice(rawValue: chosenVoice) {
                            kokoroTTSModel!.say(sayThis, kokoroVoice)
                        } else {
                            status = "Invalid Kokoro voice selected"
                        }

                    } else if chosenProvider == "orpheus" {
                        if orpheusTTSModel == nil {
                            orpheusTTSModel = OrpheusTTSModel()
                        }

                        if let orpheusVoice = OrpheusVoice(rawValue: chosenVoice) {
                            await orpheusTTSModel!.say(sayThis, orpheusVoice)
                        } else {
                            status = "Invalid Orpheus voice selected"
                        }
                    }

                    status = "Done"
                }
            }, label: {
                Text("Generate")
                    .font(.title2)
                    .padding()
            })
            .buttonStyle(.borderedProminent)

            Text(status)
                .font(.caption)
                .padding()
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
