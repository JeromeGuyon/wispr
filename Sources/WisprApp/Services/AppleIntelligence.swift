//
//  AppleIntelligence.swift
//  wispr
//
//  A thin shared wrapper around Apple's on-device language model
//  (FoundationModels / SystemLanguageModel), used by every feature that needs
//  local generation — text correction and the meeting-awareness summary — so
//  availability checks and generation live in one place.
//
//  Everything runs on-device: no network, no data leaves the Mac.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Availability of the on-device model, with a human-readable reason when off.
enum AppleIntelligenceAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)

    var isAvailable: Bool { if case .available = self { return true } else { return false } }
    var reason: String? { if case .unavailable(let r) = self { return r } else { return nil } }
}

/// Shared entry point to Apple Intelligence generation.
@MainActor
enum AppleIntelligence {

    /// Current availability of the on-device model.
    static var availability: AppleIntelligenceAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(.deviceNotEligible):
                return .unavailable(reason: "This Mac does not support Apple Intelligence.")
            case .unavailable(.appleIntelligenceNotEnabled):
                return .unavailable(reason: "Turn on Apple Intelligence in System Settings.")
            case .unavailable(.modelNotReady):
                return .unavailable(reason: "The on-device model is still downloading.")
            case .unavailable:
                return .unavailable(reason: "The on-device model is unavailable.")
            @unknown default:
                return .unavailable(reason: "The on-device model is unavailable.")
            }
        }
        #endif
        return .unavailable(reason: "Requires macOS 26 or later with Apple Intelligence.")
    }

    static var isAvailable: Bool { availability.isAvailable }

    /// Generates text from instructions + a prompt, racing a timeout. Returns nil
    /// when the model is unavailable, times out, or errors — callers fall back.
    static func generate(instructions: String, prompt: String,
                         temperature: Double? = nil, timeout: TimeInterval = 8) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *), isAvailable else { return nil }
        do {
            return try await withThrowingTimeout(seconds: timeout) {
                let session = LanguageModelSession(model: .default, instructions: instructions)
                let options = temperature.map { GenerationOptions(temperature: $0) }
                let response = options != nil
                    ? try await session.respond(to: prompt, options: options!)
                    : try await session.respond(to: prompt)
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}

// MARK: - Timeout helper

/// Races an async operation against a timeout, throwing `CancellationError` if it
/// does not finish in time. Shared by callers of Apple Intelligence.
func withThrowingTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw CancellationError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
