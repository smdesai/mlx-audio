//
//  SentenceTokenizer.swift
//   Swift-TTS
//

import Foundation
import NaturalLanguage

public final class SentenceTokenizer {

    // Lazy initialization to avoid startup delay
    private static var _segmenter: SentenceSegmentKit?
    private static let segmenterQueue = DispatchQueue(label: "com.sentencetokenizer.init", attributes: .concurrent)
    
    private static var segmenter: SentenceSegmentKit {
        return segmenterQueue.sync(flags: .barrier) {
            if let existing = _segmenter {
                return existing
            }
            do {
                let segmenter = try SentenceSegmentKit()
                _segmenter = segmenter
                return segmenter
            } catch {
                fatalError("Failed to initialize SentenceSegmentKit: \(error)")
            }
        }
    }
    
    private init() {}
    
    /// Pre-warm the sentence segmenter model to avoid delays on first use
    public static func prewarm() {
        DispatchQueue.global(qos: .background).async {
            _ = segmenter
            // Optionally run a test sentence to fully warm up the model
            _ = segmenter.splitSentences("Test sentence.")
        }
    }

    // MARK: - Initial Split

    public static func splitIntoSentences(text: String, threshold: Float? = nil) -> [String] {
        guard !text.isEmpty else { return [] }

        let detectedLanguage = detectLanguage(text: text)
        let initialSentences = performInitialSplit(text: text, language: detectedLanguage, threshold: threshold)
        let refinedSentences = applyTTSRefinements(sentences: initialSentences, originalText: text)
        
        return refinedSentences
    }
    
    public static func splitIntoSentencesLegacy(text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        let detectedLanguage = detectLanguage(text: text)
        let initialSentences = performInitialSplitLegacy(text: text, language: detectedLanguage)
        let refinedSentences = applyTTSRefinements(sentences: initialSentences, originalText: text)
        
        return optimizeTTSChunks(sentences: refinedSentences, language: detectedLanguage)
    }

    private static func performInitialSplit(text: String, language: NLLanguage?, threshold: Float? = nil) -> [String] {
        let sentences = Self.segmenter.splitSentences(text, threshold: threshold)
        print("Sentences (threshold: \(threshold ?? 0.5)):")
        for (i, sentence) in sentences.enumerated() {
            print("  \(i + 1): \(sentence)")
        }
        return sentences.isEmpty ? [text] : sentences
        
    }
    
    private static func performInitialSplitLegacy(text: String, language: NLLanguage?) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text

        if let language = language {
            tokenizer.setLanguage(language)
        }

        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { tokenRange, _ in
            let sentence = String(text[tokenRange])
            sentences.append(sentence)
            return true
        }
        
        print("Sentences (legacy):")
        for (i, sentence) in sentences.enumerated() {
            print("  \(i + 1): \(sentence)")
        }
        
        return sentences.isEmpty ? [text] : sentences
    }

    // MARK: - TTS-Specific Refinements

    private static func applyTTSRefinements(sentences: [String], originalText: String) -> [String] {
        var result: [String] = []
        result.reserveCapacity(sentences.count) // Pre-allocate capacity

        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result.append(trimmed)
            }
        }

        return result
    }

    // MARK: - TTS Chunk Optimization

    private static func optimizeTTSChunks(sentences: [String], language: NLLanguage?) -> [String] {
        guard !sentences.isEmpty else { return [] }

        let scriptType = detectScriptType(language: language)

        switch scriptType {
        case .cjk:
            return optimizeCJKChunks(sentences: sentences)
        case .indic:
            return optimizeIndicChunks(sentences: sentences)
        case .latin, .other:
            return optimizeLatinChunks(sentences: sentences)
        }
    }

    private static func optimizeLatinChunks(sentences: [String]) -> [String] {
        let minLength = 50
        return optimizeChunks(
            sentences: sentences,
            config: ChunkConfig(
                minLength: minLength,
                maxLength: 300,
                separator: " ",
                shouldMerge: { chunk in
                    chunk.count < minLength || !hasStrongSentenceEnding(chunk)
                }
            )
        )
    }

    private static func optimizeCJKChunks(sentences: [String]) -> [String] {
        let minLength = 30
        return optimizeChunks(
            sentences: sentences,
            config: ChunkConfig(
                minLength: minLength,
                maxLength: 200,
                separator: "",
                shouldMerge: { chunk in
                    chunk.count < minLength || !hasCJKSentenceEnding(chunk)
                }
            )
        )
    }

    private static func optimizeIndicChunks(sentences: [String]) -> [String] {
        let minLength = 40
        return optimizeChunks(
            sentences: sentences,
            config: ChunkConfig(
                minLength: minLength,
                maxLength: 250,
                separator: " ",
                shouldMerge: { chunk in
                    chunk.count < minLength || !hasIndicSentenceEnding(chunk)
                }
            )
        )
    }

    private struct ChunkConfig {
        let minLength: Int
        let maxLength: Int
        let separator: String
        let shouldMerge: (String) -> Bool
    }

    private static func optimizeChunks(sentences: [String], config: ChunkConfig) -> [String] {
        guard !sentences.isEmpty else { return [] }

        var result: [String] = []
        result.reserveCapacity(sentences.count) // Pre-allocate capacity
        var currentChunk = ""

        for sentence in sentences {
            if currentChunk.isEmpty {
                currentChunk = sentence
            } else {
                let separatorLength = config.separator.isEmpty ? 0 : config.separator.count
                let potentialLength = currentChunk.count + sentence.count + separatorLength

                if potentialLength <= config.maxLength && config.shouldMerge(currentChunk) {
                    if !config.separator.isEmpty {
                        currentChunk += config.separator
                    }
                    currentChunk += sentence
                } else {
                    result.append(currentChunk)
                    currentChunk = sentence
                }
            }
        }

        if !currentChunk.isEmpty {
            result.append(currentChunk)
        }

        return result
    }

    // MARK: - Helper Methods

    private static let languageRecognizer = NLLanguageRecognizer()

    private static func detectLanguage(text: String) -> NLLanguage? {
        languageRecognizer.reset()
        languageRecognizer.processString(text)
        return languageRecognizer.dominantLanguage
    }

    private enum ScriptType {
        case latin, cjk, indic, other
    }

    private static func detectScriptType(language: NLLanguage?) -> ScriptType {
        guard let language = language else { return .other }

        // The languages supoorted by Kokoro 1.0
        switch language {
        case .simplifiedChinese, .traditionalChinese, .japanese:
            return .cjk
        case .english, .french, .spanish, .italian, .portuguese:
            return .latin
        case .hindi:
            return .indic
        default:
            return .other
        }
    }

    private static func hasSentenceEnding(_ text: String, endings: Set<Character>) -> Bool {
        guard let lastChar = text.last else { return false }
        return endings.contains(lastChar) && !text.hasSuffix(" ")
    }

    private static func hasStrongSentenceEnding(_ text: String) -> Bool {
        return hasSentenceEnding(text, endings: [".", "!", "?"])
    }

    private static func hasCJKSentenceEnding(_ text: String) -> Bool {
        return hasSentenceEnding(text, endings: ["。", "！", "？", "…"])
    }

    private static func hasIndicSentenceEnding(_ text: String) -> Bool {
        return hasSentenceEnding(text, endings: ["।", "॥", ".", "!", "?"])
    }
}
