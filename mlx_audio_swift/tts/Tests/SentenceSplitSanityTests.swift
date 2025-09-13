import XCTest
@testable import Swift_TTS

final class SentenceSplitSanityTests: XCTestCase {

    func testSentenceTokenizerLatin() {
        let text = "Dr. Smith went to Washington. He said, \"Hello world.\" Then left."
        // Use legacy splitter in tests to avoid external model/bundle dependency
        let sentences = SentenceTokenizer.splitIntoSentencesLegacy(text: text)
        XCTAssertFalse(sentences.isEmpty, "Expected non-empty sentences")
        print("Latin sentences (\(sentences.count)):")
        for s in sentences { print("- \(s)") }
        // Expect at least 2 sentences
        XCTAssertGreaterThanOrEqual(sentences.count, 2)
    }

    func testSentenceTokenizerCJK() {
        let text = "你好。這是一個測試！再見？"
        let sentences = SentenceTokenizer.splitIntoSentencesLegacy(text: text)
        print("CJK sentences (\(sentences.count)):")
        for s in sentences { print("- \(s)") }
        XCTAssertEqual(sentences.count, 3, "Should detect three CJK sentences")
    }

    func testStream2SentenceCJK() {
        var config = Stream2Sentence.Configuration()
        config.fullSentenceDelimiters = ".?!\n…。！？"
        config.sentenceFragmentDelimiters = ".?!;:,\n…)]}。！？-"
        config.logLevel = .none
        let s2s = Stream2Sentence(configuration: config)

        let text = "你好。這是一個測試！再見？"
        let chunks = ["你好。這是", "一個測試！再", "見？"]
        var results: [String] = []

        let expect = expectation(description: "stream-cjk")

        for c in chunks {
            s2s.addText(c) { sent in
                results.append(sent)
                if results.count >= 2 { expect.fulfill() }
            }
        }

        s2s.flush { sent in results.append(sent) }
        wait(for: [expect], timeout: 2.0)

        print("Stream2Sentence CJK results (\(results.count)):")
        for s in results { print("- \(s)") }
        XCTAssertEqual(results.count, 3)
    }

    func testStream2SentenceQuotes() {
        var config = Stream2Sentence.Configuration()
        config.logLevel = .none
        let s2s = Stream2Sentence(configuration: config)

        let text = "He said, \"Hello world.\" Then left."
        let chunks = ["He said, \"Hello", " world.\" Then", " left."]
        var results: [String] = []
        let expect = expectation(description: "stream-quotes")

        for c in chunks {
            s2s.addText(c) { sent in
                results.append(sent)
                if results.count >= 1 { expect.fulfill() }
            }
        }
        s2s.flush { sent in results.append(sent) }
        wait(for: [expect], timeout: 2.0)

        print("Stream2Sentence quotes results (\(results.count)):")
        for s in results { print("- \(s)") }
        XCTAssertGreaterThanOrEqual(results.count, 2)
    }
}
