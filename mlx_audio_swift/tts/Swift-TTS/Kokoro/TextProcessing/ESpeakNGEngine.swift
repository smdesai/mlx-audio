//  Kokoro-tts-lib
//

import Foundation
import ESpeakNG

// ESpeakNG wrapper for phonemizing the text strings
final class ESpeakNGEngine {
  private static var sharedInstance: ESpeakNGEngine?
  private static let lock = DispatchSemaphore(value: 1)
  private static let espeakLock = DispatchSemaphore(value: 1)

  private var language: LanguageDialect = .none

  enum ESpeakNGEngineError: Error {
    case dataBundleNotFound
    case couldNotInitialize
    case languageNotFound
    case internalError
    case languageNotSet
    case couldNotPhonemize
  }

  // Available languages
  public enum LanguageDialect: String, CaseIterable {
    case none = ""
    case enUS = "en-us"
    case enGB = "en-gb"
    case jaJP = "ja"
    case znCN = "yue"
    case frFR = "fr-fr"
    case hiIN = "hi"
    case itIT = "it"
    case esES = "es"
    case ptBR = "pt-br"
  }

  // After constructing the wrapper, call setLanguage() before phonemizing any text
  // Use shared() to obtain a singleton instance. The underlying C library has global state
  // and is not designed for concurrent multiple initializations.
  private init() throws {
    if let bundleURLStr = findDataBundlePath() {
      let initOK = espeak_Initialize(AUDIO_OUTPUT_SYNCHRONOUS, 0, bundleURLStr, 0)

      if initOK != Constants.successAudioSampleRate {
        print("Internal espseak-ng error, could not initialize")
        throw ESpeakNGEngineError.couldNotInitialize
      }
      // Skip exhaustive voice list scanning; set voices by language code directly in setLanguage
    } else {
      print("Couldn't find the espeak-ng data bundle, cannot initialize")
      throw ESpeakNGEngineError.dataBundleNotFound
    }
  }

  // Destructor
  deinit {
    let terminateOK = espeak_Terminate()
    print("ESpeakNGEngine termination OK: \(terminateOK == EE_OK)")
  }

  static func shared() throws -> ESpeakNGEngine {
    lock.wait()
    defer { lock.signal() }
    if let inst = sharedInstance { return inst }
    let engine = try ESpeakNGEngine()
    sharedInstance = engine
    return engine
  }

  // Sets the language that will be used for phonemizing
  // If the function returns without throwing an exception then consider new language set!
  func setLanguage(for voice: TTSVoice) throws {
    guard let language = Constants.voice2Language[voice] else {
      throw ESpeakNGEngineError.languageNotFound
    }

    // Set by language code directly (e.g., "en-us"); avoids scanning large voice lists
    Self.espeakLock.wait()
    let result = espeak_SetVoiceByName((language.rawValue as NSString).utf8String)
    Self.espeakLock.signal()

    if result == EE_NOT_FOUND {
      throw ESpeakNGEngineError.languageNotFound
    } else if result != EE_OK {
      throw ESpeakNGEngineError.internalError
    }

    self.language = language
  }

  public func languageForVoice(voice: TTSVoice) throws -> LanguageDialect {
    guard let language = Constants.voice2Language[voice] else {
      throw ESpeakNGEngineError.languageNotFound
    }
    return language
  }

  // Phonemizes the text string that can then be passed to the next stage
  func phonemize(text: String) throws -> String {
    guard language != .none else {
      throw ESpeakNGEngineError.languageNotSet
    }

    guard !text.isEmpty else {
      return ""
    }

    let textCopy = text as NSString
    var textPtr = UnsafeRawPointer(textCopy.utf8String)
    let phonemes_mode = Int32((Int32(Character("_").asciiValue!) << 8) | 0x02)

    // Use autoreleasepool to ensure memory is managed properly
    let result = autoreleasepool { () -> [String] in
      withUnsafeMutablePointer(to: &textPtr) { ptr in
        var resultWords: [String] = []
        while ptr.pointee != nil {
          var result: UnsafePointer<CChar>?
          Self.espeakLock.wait()
          result = ESpeakNG.espeak_TextToPhonemes(ptr, espeakCHARS_UTF8, phonemes_mode)
          Self.espeakLock.signal()
          if let result {
            // Create a copy of the returned string to ensure we own the memory
            resultWords.append(String(cString: result, encoding: .utf8)!)
          }
        }
        return resultWords
      }
    }

    if !result.isEmpty {
      return postProcessPhonemes(result.joined(separator: " "))
    } else {
      throw ESpeakNGEngineError.couldNotPhonemize
    }
  }

  // Post processes manually phonemes before returning them
  // NOTE: This is currently only for English, handling other langauges requires different kind of postproccessing
  private func postProcessPhonemes(_ phonemes: String) -> String {
    var result = phonemes.trimmingCharacters(in: .whitespacesAndNewlines)
    for (old, new) in Constants.E2M {
      result = result.replacingOccurrences(of: old, with: new)
    }

    result = result.replacingOccurrences(of: "(\\S)\u{0329}", with: "ᵊ$1", options: .regularExpression)
    result = result.replacingOccurrences(of: "\u{0329}", with: "")

    if language == .enGB {
      result = result.replacingOccurrences(of: "e^ə", with: "ɛː")
      result = result.replacingOccurrences(of: "iə", with: "ɪə")
      result = result.replacingOccurrences(of: "ə^ʊ", with: "Q")
    } else {
      result = result.replacingOccurrences(of: "o^ʊ", with: "O")
      result = result.replacingOccurrences(of: "ɜːɹ", with: "ɜɹ")
      result = result.replacingOccurrences(of: "ɜː", with: "ɜɹ")
      result = result.replacingOccurrences(of: "ɪə", with: "iə")
      result = result.replacingOccurrences(of: "ː", with: "")
    }

    // For espeak < 1.52
    result = result.replacingOccurrences(of: "o", with: "ɔ")
    return result.replacingOccurrences(of: "^", with: "")
  }

  // Find the data bundle that is inside the framework
  private func findDataBundlePath() -> String? {
    // Resolve the inner "espeak-ng-data" directory within the bundle
    if let frameworkBundle = Bundle(identifier: "com.kokoro.espeakng"),
       let dataBundleURL = frameworkBundle.url(forResource: "espeak-ng-data", withExtension: "bundle") {
      let dataDir = dataBundleURL.appendingPathComponent("espeak-ng-data")
      return FileManager.default.fileExists(atPath: dataDir.path) ? dataDir.path : dataBundleURL.path
    }
    return nil
  }

  private enum Constants {
    static let successAudioSampleRate = 22050
    static let E2M: [(String, String)] = [
      ("ʔˌn\u{0329}", "tn"), ("ʔn\u{0329}", "tn"), ("ʔn", "tn"), ("ʔ", "t"),
      ("a^ɪ", "I"), ("a^ʊ", "W"),
      ("d^ʒ", "ʤ"),
      ("e^ɪ", "A"), ("e", "A"),
      ("t^ʃ", "ʧ"),
      ("ɔ^ɪ", "Y"),
      ("ə^l", "ᵊl"),
      ("ʲo", "jo"), ("ʲə", "jə"), ("ʲ", ""),
      ("ɚ", "əɹ"),
      ("r", "ɹ"),
      ("x", "k"), ("ç", "k"),
      ("ɐ", "ə"),
      ("ɬ", "l"),
      ("\u{0303}", ""),
    ].sorted(by: { $0.0.count > $1.0.count })
    static let voice2Language: [TTSVoice: LanguageDialect] = [
      .afAlloy: .enUS,
      .afAoede: .enUS,
      .afBella: .enUS,
      .afHeart: .enUS,
      .afJessica: .enUS,
      .afKore: .enUS,
      .afNicole: .enUS,
      .afNova: .enUS,
      .afRiver: .enUS,
      .afSarah: .enUS,
      .afSky: .enUS,
      .amAdam: .enUS,
      .amEcho: .enUS,
      .amEric: .enUS,
      .amFenrir: .enUS,
      .amLiam: .enUS,
      .amMichael: .enUS,
      .amOnyx: .enUS,
      .amPuck: .enUS,
      .amSanta: .enUS,
      .bfAlice: .enGB,
      .bfEmma: .enGB,
      .bfIsabella: .enGB,
      .bfLily: .enGB,
      .bmDaniel: .enGB,
      .bmFable: .enGB,
      .bmGeorge: .enGB,
      .bmLewis: .enGB,
      .efDora: .esES,
      .emAlex: .esES,
      .ffSiwis: .frFR,
      .hfAlpha: .hiIN,
      .hfBeta: .hiIN,
      .hfOmega: .hiIN,
      .hmPsi: .hiIN,
      .ifSara: .itIT,
      .imNicola: .itIT,
      .jfAlpha: .jaJP,
      .jfGongitsune: .jaJP,
      .jfNezumi: .jaJP,
      .jfTebukuro: .jaJP,
      .jmKumo: .jaJP,
      .pfDora: .ptBR,
      .pmSanta: .ptBR,
      .zfZiaobei: .znCN,
      .zfXiaoni: .znCN,
      .zfXiaoxiao: .znCN,
      .zfZiaoyi: .znCN,
      .zmYunjian: .znCN,
      .zmYunxi: .znCN,
      .zmYunxia: .znCN,
      .zmYunyang: .znCN
    ]
  }
}
