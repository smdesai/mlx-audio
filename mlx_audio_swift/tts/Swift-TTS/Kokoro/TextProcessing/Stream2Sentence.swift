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
    private var lastDelimiterIndices: [Int] = []
    private var wordCount: Int = 0
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
            self.lastDelimiterIndices.removeAll()
            self.wordCount = 0
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
    
    private func findDelimiterPositions(in text: String) -> [(index: Int, delimiter: Character, isFull: Bool)] {
        var positions: [(index: Int, delimiter: Character, isFull: Bool)] = []
        
        for (index, char) in text.enumerated() {
            if configuration.sentenceFragmentDelimiters.contains(char) {
                let isFull = configuration.fullSentenceDelimiters.contains(char)
                positions.append((index: index, delimiter: char, isFull: isFull))
            }
        }
        
        return positions
    }
    
    private func processStandardYield(delimiterPositions: [(index: Int, delimiter: Character, isFull: Bool)], 
                                     sentenceCallback: @escaping SentenceCallback) {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        
        var sentencesToYield: [String] = []
        var lastProcessedIndex = 0
        
        for position in delimiterPositions {
            // Only process full sentence delimiters for standard yield
            guard position.isFull else { continue }
            
            // Check context to determine if this is a real sentence boundary
            if isValidSentenceBoundary(at: position.index, in: buffer) {
                let sentenceEndIndex = buffer.index(buffer.startIndex, offsetBy: position.index + 1)
                let sentence = String(buffer[buffer.startIndex..<sentenceEndIndex])
                
                // Check minimum length requirements
                let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                let minLength = firstSentence ? configuration.minimumFirstFragmentLength : configuration.minimumSentenceLength
                
                if trimmedSentence.count >= minLength {
                    sentencesToYield.append(trimmedSentence)
                    lastProcessedIndex = position.index + 1
                }
            }
        }
        
        // Update buffer and state
        if lastProcessedIndex > 0 && lastProcessedIndex < buffer.count {
            let startIndex = buffer.index(buffer.startIndex, offsetBy: lastProcessedIndex)
            // Don't trim leading whitespace - it might be important
            buffer = String(buffer[startIndex...])
        } else if lastProcessedIndex >= buffer.count {
            buffer = ""
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
    
    private func processQuickYieldEveryFragment(delimiterPositions: [(index: Int, delimiter: Character, isFull: Bool)], 
                                               sentenceCallback: @escaping SentenceCallback) {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        
        var lastProcessedIndex = 0
        
        for position in delimiterPositions {
            let sentenceEndIndex = buffer.index(buffer.startIndex, offsetBy: position.index + 1)
            let fragment = String(buffer[buffer.startIndex..<sentenceEndIndex])
            
            let trimmedFragment = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedFragment.isEmpty {
                let cleanedFragment = cleanupText(trimmedFragment)
                if !cleanedFragment.isEmpty {
                    log("Quick yielding fragment: '\(cleanedFragment)'", level: .info)
                    sentenceCallback(cleanedFragment)
                }
            }
            
            lastProcessedIndex = position.index + 1
        }
        
        // Update buffer
        if lastProcessedIndex > 0 && lastProcessedIndex < buffer.count {
            let startIndex = buffer.index(buffer.startIndex, offsetBy: lastProcessedIndex)
            // Don't trim whitespace - it might be important
            buffer = String(buffer[startIndex...])
        } else if lastProcessedIndex >= buffer.count {
            buffer = ""
        }
    }
    
    private func isValidSentenceBoundary(at index: Int, in text: String) -> Bool {
        // Get the delimiter position
        let delimiterIndex = text.index(text.startIndex, offsetBy: index)
        let delimiter = text[delimiterIndex]
        
        // Only process clear sentence endings for now
        guard ".!?".contains(delimiter) else { return false }
        
        // Need at least 2 more characters after delimiter to check
        guard index < text.count - 2 else { return false }
        
        // Get context before the delimiter
        let beforeStart = max(0, index - 10)
        let beforeStartIndex = text.index(text.startIndex, offsetBy: beforeStart)
        let beforeContext = String(text[beforeStartIndex..<delimiterIndex])
        
        // Check for common abbreviations that shouldn't end sentences
        let abbreviations = ["Mr", "Mrs", "Ms", "Dr", "St", "Ave", "Inc", "Ltd", "Jr", "Sr", 
                           "Co", "Corp", "Ph.D", "M.D", "B.A", "M.A", "D.D.S", "Ph", 
                           "U.S", "U.K", "E.U", "A.M", "P.M", "i.e", "e.g", "vs", "etc"]
        
        for abbr in abbreviations {
            if beforeContext.hasSuffix(abbr) {
                log("Skipping boundary after abbreviation: \(abbr)", level: .debug)
                return false
            }
        }
        
        // Check what follows the delimiter
        let nextIndex = text.index(after: delimiterIndex)
        guard nextIndex < text.endIndex else { return false }
        
        // Must be followed by space
        guard text[nextIndex] == " " else { return false }
        
        // Skip any additional spaces
        var checkIndex = text.index(after: nextIndex)
        while checkIndex < text.endIndex && text[checkIndex] == " " {
            checkIndex = text.index(after: checkIndex)
        }
        
        // If we've reached the end, not a complete sentence yet
        guard checkIndex < text.endIndex else { return false }
        
        // Strong indicator: uppercase letter after space
        if text[checkIndex].isUppercase {
            return true
        }
        
        // Weak boundary - only return true if we have substantial text after
        let remainingText = String(text[checkIndex...])
        return remainingText.count > 20  // Need more context to be sure
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

extension Stream2Sentence {
    /// Process a text stream with default configuration
    public static func processStream(textStream: AsyncStream<String>, 
                                   sentenceCallback: @escaping SentenceCallback) async {
        let processor = Stream2Sentence()
        
        for await text in textStream {
            processor.addText(text, sentenceCallback: sentenceCallback)
        }
        
        processor.flush(sentenceCallback: sentenceCallback)
    }
}
