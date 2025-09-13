//
//  TranscriptionActivity.swift
//  Swift-TTS (shared) — iOS-only code gated by availability
//

import Foundation

#if os(iOS)
import UIKit

import ActivityKit

public enum TranscriptionPhase: String, Codable, Hashable {
    case generating
    case combining
    case transcribing
    case done
}

public struct TranscriptionActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var phase: TranscriptionPhase
        public var completed: Int
        public var total: Int
        public var message: String?
    }

    public var title: String
    public var voice: String
}

public final class TranscriptionActivityManager {
    public static let shared = TranscriptionActivityManager()
    private init() {}

    private var currentActivity: Any?

    public func start(title: String, voice: String, totalUnits: Int) {
        let attrs = TranscriptionActivityAttributes(title: title, voice: voice)
        let state = TranscriptionActivityAttributes.ContentState(phase: .generating, completed: 0, total: max(totalUnits, 1), message: "Generating…")
        do {
            let content = ActivityContent(state: state, staleDate: nil)
            let activity = try Activity<TranscriptionActivityAttributes>.request(attributes: attrs, content: content, pushType: nil)
            currentActivity = activity
        } catch {
            print("Live Activity start failed: \(error)")
        }
    }

    public func update(completed: Int, total: Int? = nil, phase: TranscriptionPhase? = nil, message: String? = nil) {
        guard let activity = currentActivity as? Activity<TranscriptionActivityAttributes> else { return }
        let old = activity.content.state
        let newState = TranscriptionActivityAttributes.ContentState(
            phase: phase ?? old.phase,
            completed: max(completed, 0),
            total: total ?? old.total,
            message: message ?? old.message
        )
        let content = ActivityContent(state: newState, staleDate: nil)
        Task { await activity.update(content) }
    }

    public func updatePhase(_ phase: TranscriptionPhase, message: String? = nil) {
        guard let activity = currentActivity as? Activity<TranscriptionActivityAttributes> else { return }
        let old = activity.content.state
        let newState = TranscriptionActivityAttributes.ContentState(
            phase: phase,
            completed: old.completed,
            total: old.total,
            message: message ?? old.message
        )
        let content = ActivityContent(state: newState, staleDate: nil)
        Task { await activity.update(content) }
    }

    public func end(success: Bool) {
        guard let activity = currentActivity as? Activity<TranscriptionActivityAttributes> else { return }
        let total = activity.content.state.total
        let finalState = TranscriptionActivityAttributes.ContentState(
            phase: .done,
            completed: total,
            total: total,
            message: success ? "Completed" : "Canceled"
        )
        let content = ActivityContent(state: finalState, staleDate: nil)
        Task { await activity.end(content, dismissalPolicy: .immediate) }
        currentActivity = nil
    }
}

#else

public final class TranscriptionActivityManager {
    public static let shared = TranscriptionActivityManager()
    private init() {}
    public func start(title: String, voice: String, totalUnits: Int) {}
    public func update(completed: Int, total: Int? = nil, phase: Any? = nil, message: String? = nil) {}
    public func updatePhase(_ phase: Any, message: String? = nil) {}
    public func end(success: Bool) {}
}

#endif
