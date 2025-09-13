//
//  TTSEnginePool.swift
//  Swift-TTS
//

import Foundation

/// A simple fixed-size pool of KokoroTTS engines to enable parallel inference
/// without sharing a single engine instance across threads.
///
/// The pool limits concurrent engine usage and reuses engines to avoid repeated
/// model initialization. Use `withEngine` to lease an engine for the duration of
/// a generation task. This class is thread-safe.
final class TTSEnginePool {
    private let engines: [KokoroTTS]
    private var inUse: [Bool]
    private let accessLock = DispatchSemaphore(value: 1)
    private let gate: DispatchSemaphore

    var size: Int { engines.count }

    init(size: Int) {
        let n = max(1, size)
        self.engines = (0..<n).map { _ in KokoroTTS() }
        self.inUse = Array(repeating: false, count: n)
        self.gate = DispatchSemaphore(value: n)
    }

    /// Execute body while holding a lease on an engine.
    /// Execution is limited by the pool size.
    @discardableResult
    func withEngine<T>(_ body: (KokoroTTS) throws -> T) rethrows -> T {
        // Wait for an available engine slot
        gate.wait()

        // Find a free engine index
        var idx = -1
        accessLock.wait()
        for i in 0..<engines.count {
            if !inUse[i] {
                inUse[i] = true
                idx = i
                break
            }
        }
        accessLock.signal()

        precondition(idx >= 0, "TTSEnginePool internal error: no engine available after gate wait")
        let engine = engines[idx]

        defer {
            accessLock.wait()
            inUse[idx] = false
            accessLock.signal()
            gate.signal()
        }

        return try body(engine)
    }

    /// Optionally prewarm all engines to reduce first-use latency.
    func prewarmAll(voice: TTSVoice = .afHeart) {
        let group = DispatchGroup()
        for engine in engines {
            group.enter()
            DispatchQueue.global(qos: .background).async {
                engine.prewarm(voice: voice) {
                    group.leave()
                }
            }
        }
        _ = group.wait(timeout: .now() + 30) // Best-effort; don't block indefinitely
    }
}

