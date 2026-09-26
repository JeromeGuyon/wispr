//
//  TextCorrectionService.swift
//  wispr
//
//  On-device AI text correction using Apple's FoundationModels framework.
//  Wraps SystemLanguageModel to correct grammar and improve spoken-to-written fluency.
//

import Foundation
import Observation

/// Protocol for text correction, enabling dependency injection in tests.
@MainActor
protocol TextCorrecting: Sendable {
    var availability: TextCorrectionAvailability { get }
    func checkAvailability()
    func correctText(_ text: String, style: CorrectionStyle) async -> String
}

enum TextCorrectionAvailability: Sendable, Equatable {
    case available
    case notAvailable(reason: String)
    case checking
}

@MainActor
@Observable
final class TextCorrectionService: TextCorrecting {
    private(set) var availability: TextCorrectionAvailability = .checking

    func checkAvailability() {
        switch AppleIntelligence.availability {
        case .available:
            availability = .available
        case .unavailable(let reason):
            availability = .notAvailable(reason: reason)
        }
    }

    func correctText(_ text: String, style: CorrectionStyle) async -> String {
        checkAvailability()
        guard case .available = availability else { return text }
        guard !text.isEmpty else { return text }

        // Generation goes through the shared AppleIntelligence service (same
        // on-device model as the meeting-awareness summary). nil on timeout/error
        // → keep the original text.
        let corrected = await AppleIntelligence.generate(
            instructions: style.systemInstructions,
            prompt: style.userPrompt(for: text),
            timeout: 5)
        return corrected ?? text
    }

}

