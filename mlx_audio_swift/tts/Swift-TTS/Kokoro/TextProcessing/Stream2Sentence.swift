//
//  Stream2Sentence.swift
//  Swift-TTS
//

import Foundation
import NaturalLanguage

public class Stream2Sentence {
    // Configuration
    public struct Configuration {
        public var minimumSentenceLength: Int = 10
        public var minimumFirstFragmentLength: Int = 10
        public var contextSize: Int = 12
        public var contextSizeLookOverhead: Int = 12
        public var sentenceFragmentDelimiters: String = ".?!;:,\n…)]}。-"
        public var fullSentenceDelimiters: String = ".?!\n…。"
        public var quickYieldSingleSentenceFragment: Bool = false
        public var quickYieldEveryFragment: Bool = false
        public var cleanupTextLinks: Bool = false
        public var cleanupTextEmojis: Bool = false
        public var tokenizer: SentenceTokenizer = .nlTokenizer
        public var language: NLLanguage = .english
        public var logLevel: LogLevel = .warning
        
        public init() {}
        
        public enum SentenceTokenizer {
            case nlTokenizer
            case simple
        }
        
        public enum LogLevel {
            case debug
            case info
            case warning
            case error
            case none
        }
    }
    
    // State management
    private var configuration: Configuration
    private var buffer: String = ""
    private var firstSentence: Bool = true
    private let queue = DispatchQueue(label: "com.stream2sentence.processing", qos: .userInitiated)
    private let bufferLock = NSLock()
    
    // Sentence callback
    public typealias SentenceCallback = (String) -> Void
    
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }
    
    // MARK: - Public API
    
    /// Add text to the buffer and process sentences
    public func addText(_ text: String, sentenceCallback: @escaping SentenceCallback) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            self.bufferLock.lock()
            self.buffer += text
            self.bufferLock.unlock()
            
            self.log("Added text: '\(text)'", level: .debug)
            self.log("Buffer size: \(self.buffer.count)", level: .debug)
            
            self.processBuffer(sentenceCallback: sentenceCallback)
        }
    }
    
    /// Flush any remaining text in the buffer
    public func flush(sentenceCallback: @escaping SentenceCallback) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            self.bufferLock.lock()
            let remainingText = self.buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            self.buffer = ""
            self.bufferLock.unlock()
            
            if !remainingText.isEmpty {
                self.log("Flushing remaining text: '\(remainingText)'", level: .info)
                sentenceCallback(remainingText)
            } else {
                self.log("No text to flush in buffer", level: .info)
            }
            
            // Reset state
            self.firstSentence = true
        }
    }
    
    // MARK: - Private Methods
    
    private func processBuffer(sentenceCallback: @escaping SentenceCallback) {
        bufferLock.lock()
        let currentBuffer = buffer
        bufferLock.unlock()
        
        // Find all delimiter positions
        let delimiterPositions = findDelimiterPositions(in: currentBuffer)
        
        // Process based on configuration
        if configuration.quickYieldEveryFragment {
            processQuickYieldEveryFragment(delimiterPositions: delimiterPositions, sentenceCallback: sentenceCallback)
        } else {
            processStandardYield(delimiterPositions: delimiterPositions, sentenceCallback: sentenceCallback)
        }
    }
    
    private func findDelimiterPositions(in text: String) -> [(idx: String.Index, delimiter: Character, isFull: Bool)] {
        var positions: [(idx: String.Index, delimiter: Character, isFull: Bool)] = []
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if configuration.sentenceFragmentDelimiters.contains(ch) {
                let isFull = configuration.fullSentenceDelimiters.contains(ch)
                positions.append((idx: i, delimiter: ch, isFull: isFull))
            }
            i = text.index(after: i)
        }
        return positions
    }
    
    private func processStandardYield(delimiterPositions: [(idx: String.Index, delimiter: Character, isFull: Bool)], 
                                     sentenceCallback: @escaping SentenceCallback) {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        
        var sentencesToYield: [String] = []
        var lastProcessedIndex: String.Index? = nil
        
        for position in delimiterPositions {
            // Only process full sentence delimiters for standard yield
            guard position.isFull else { continue }
            
            // Check context to determine if this is a real sentence boundary
            if isValidSentenceBoundary(at: position.idx, in: buffer) {
                let endAfterDelim = buffer.index(after: position.idx)
                let sentence = String(buffer[buffer.startIndex..<endAfterDelim])
                
                // Check minimum length requirements
                let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                let minLength = firstSentence ? configuration.minimumFirstFragmentLength : configuration.minimumSentenceLength
                
                if trimmedSentence.count >= minLength {
                    sentencesToYield.append(trimmedSentence)
                    lastProcessedIndex = endAfterDelim
                }
            }
        }
        
        // Update buffer and state
        if let lastIdx = lastProcessedIndex {
            if lastIdx < buffer.endIndex {
                // Don't trim leading whitespace - it might be important
                buffer = String(buffer[lastIdx...])
            } else {
                buffer = ""
            }
        }
        
        // Yield sentences
        for sentence in sentencesToYield {
            if firstSentence {
                firstSentence = false
            }
            
            let cleanedSentence = cleanupText(sentence)
            if !cleanedSentence.isEmpty {
                log("Yielding sentence: '\(cleanedSentence)'", level: .info)
                sentenceCallback(cleanedSentence)
            }
        }
    }
    
    private func processQuickYieldEveryFragment(delimiterPositions: [(idx: String.Index, delimiter: Character, isFull: Bool)], 
                                               sentenceCallback: @escaping SentenceCallback) {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        
        var lastProcessedIndex: String.Index? = nil
        
        for position in delimiterPositions {
            let endAfterDelim = buffer.index(after: position.idx)
            let fragment = String(buffer[buffer.startIndex..<endAfterDelim])
            
            let trimmedFragment = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedFragment.isEmpty {
                let cleanedFragment = cleanupText(trimmedFragment)
                if !cleanedFragment.isEmpty {
                    log("Quick yielding fragment: '\(cleanedFragment)'", level: .info)
                    sentenceCallback(cleanedFragment)
                }
            }
            
            lastProcessedIndex = endAfterDelim
        }
        
        // Update buffer
        if let lastIdx = lastProcessedIndex {
            if lastIdx < buffer.endIndex {
                // Don't trim whitespace - it might be important
                buffer = String(buffer[lastIdx...])
            } else {
                buffer = ""
            }
        }
    }
    
    private func isValidSentenceBoundary(at delimiterIndex: String.Index, in text: String) -> Bool {
        let delimiter = text[delimiterIndex]

        // Accept configured delimiters including CJK and newlines
        guard configuration.fullSentenceDelimiters.contains(delimiter) || "。！？…".contains(delimiter) else {
            return false
        }

        // Abbreviation guard (ASCII contexts)
        let contextWindow = 12
        let beforeStart = text.index(delimiterIndex, offsetBy: -min(contextWindow, text.distance(from: text.startIndex, to: delimiterIndex)), limitedBy: text.startIndex) ?? text.startIndex
        let beforeContext = String(text[beforeStart..<delimiterIndex])
        let abbreviations = [
            "Mr", "Mrs", "Ms", "Dr", "St", "Ave", "Inc", "Ltd", "Jr", "Sr",
            "Co", "Corp", "Ph.D", "M.D", "B.A", "M.A", "D.D.S", "U.S", "U.K", "E.U",
            "A.M", "P.M", "i.e", "e.g", "vs", "etc"
        ]
        for abbr in abbreviations {
            if beforeContext.hasSuffix(abbr) { return false }
        }

        // After the delimiter: allow spaces and closing quotes/brackets
        var checkIndex = text.index(after: delimiterIndex)
        while checkIndex < text.endIndex {
            let ch = text[checkIndex]
            if ch == " " || ch == "\n" || ch == "\t" || ")]}»”’』」》】）".contains(ch) {
                checkIndex = text.index(after: checkIndex)
                continue
            }
            break
        }

        // If at end of text, treat as complete sentence
        if checkIndex >= text.endIndex { return true }

        // For CJK, no need to require space/uppercase; accept punctuation end
        if "。！？…".contains(delimiter) { return true }

        // For Latin, accept boundary even if next is lowercase (e.g., quotes, proper nouns, etc.)
        return true
    }
    
    private func cleanupText(_ text: String) -> String {
        var cleaned = text
        
        // Remove links if configured
        if configuration.cleanupTextLinks {
            let linkPattern = #"https?://[^\s]+"#
            if let regex = try? NSRegularExpression(pattern: linkPattern, options: []) {
                cleaned = regex.stringByReplacingMatches(in: cleaned, 
                                                        options: [], 
                                                        range: NSRange(location: 0, length: cleaned.count), 
                                                        withTemplate: "")
            }
        }
        
        // Remove emojis if configured
        if configuration.cleanupTextEmojis {
            cleaned = cleaned.unicodeScalars
                .filter { !$0.properties.isEmoji }
                .map { String($0) }
                .joined()
        }
        
        // Remove excessive whitespace
        cleaned = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func log(_ message: String, level: Configuration.LogLevel) {
        guard shouldLog(level: level) else { return }
        
        let prefix: String
        switch level {
        case .debug: prefix = "[DEBUG]"
        case .info: prefix = "[INFO]"
        case .warning: prefix = "[WARNING]"
        case .error: prefix = "[ERROR]"
        case .none: return
        }
        
        print("\(prefix) Stream2Sentence: \(message)")
    }
    
    private func shouldLog(level: Configuration.LogLevel) -> Bool {
        switch configuration.logLevel {
        case .debug: return true
        case .info: return level != .debug
        case .warning: return level == .warning || level == .error
        case .error: return level == .error
        case .none: return false
        }
    }
}

// MARK: - Convenience Extensions

// Removed: Unused AsyncStream convenience wrapper
