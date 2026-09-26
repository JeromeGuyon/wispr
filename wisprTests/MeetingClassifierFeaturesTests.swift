//
//  MeetingClassifierFeaturesTests.swift
//  wisprTests
//
//  Unit tests for the pure decision logic of the live-meeting features: how a
//  JuL response is turned into a wake decision, marked bingo squares, and
//  context tags. No network — responses are decoded from JSON fixtures shaped
//  exactly like the JuL server's output.
//

import Testing
import Foundation
@testable import WisprApp

@Suite("Live meeting features — decision logic")
struct MeetingClassifierFeaturesTests {

    /// Decodes a `JulResponse` from a JSON string, as if returned by the server.
    private func response(_ json: String) throws -> JulResponse {
        try JSONDecoder().decode(JulResponse.self, from: Data(json.utf8))
    }

    // MARK: - Awareness

    @Test("Wakes when addressed and solicited above thresholds")
    func wakesWhenAddressedAndSolicited() throws {
        let config = AwarenessConfig(monitoredNames: ["Jerome"])
        let r = try response(#"""
        {"nouls": {"addressed_to_me": {"noul": 0.99}, "is_solicitation": {"noul": 0.80}}}
        """#)
        #expect(config.shouldWake(r) == true)
    }

    @Test("Does not wake on a neutral sentence")
    func noWakeOnNeutral() throws {
        let config = AwarenessConfig(monitoredNames: ["Jerome"])
        let r = try response(#"""
        {"nouls": {"addressed_to_me": {"noul": 0.28}, "is_solicitation": {"noul": 0.14}}}
        """#)
        #expect(config.shouldWake(r) == false)
    }

    @Test("Softer solicitation threshold catches a request phrased without a question mark")
    func softSolicitationThreshold() throws {
        // Measured real case: "Dis Jérôme, tu peux regarder." → addressed 0.99, solicits 0.62.
        let config = AwarenessConfig(monitoredNames: ["Jerome"])
        let r = try response(#"""
        {"nouls": {"addressed_to_me": {"noul": 0.99}, "is_solicitation": {"noul": 0.62}}}
        """#)
        #expect(config.shouldWake(r) == true)  // 0.62 >= 0.5
    }

    @Test("Does not wake when addressed but not solicited")
    func noWakeWhenOnlyAddressed() throws {
        let config = AwarenessConfig(monitoredNames: ["Jerome"])
        let r = try response(#"""
        {"nouls": {"addressed_to_me": {"noul": 0.99}, "is_solicitation": {"noul": 0.20}}}
        """#)
        #expect(config.shouldWake(r) == false)
    }

    @Test("Awareness is not configured without names")
    func awarenessConfigured() {
        #expect(AwarenessConfig(monitoredNames: []).isConfigured == false)
        #expect(AwarenessConfig(monitoredNames: ["Jerome"]).isConfigured == true)
    }

    // MARK: - Bingo

    @Test("Marks only terms above the bingo threshold, by grid index")
    func bingoMarksAboveThreshold() throws {
        let config = BingoConfig(terms: ["synergy", "leverage", "deep dive"])
        // Questions are keyed by grid index (bingo_0, bingo_1, …).
        let r = try response(#"""
        {"nouls": {"bingo_0": {"noul": 0.93}, "bingo_1": {"noul": 0.10}, "bingo_2": {"noul": 0.90}}}
        """#)
        let marked = Set(config.marked(in: r))
        #expect(marked == ["bingo_0", "bingo_2"])
    }

    @Test("Bingo question keys are unique per position even for colliding terms")
    func bingoKeysAreUnique() {
        // "double-click" and "double click" slug identically, yet each gets its
        // own question key by index.
        let q = BingoConfig(terms: ["double-click", "double click", "synergy"]).questions()
        #expect(q.count == 3)
        #expect(Set(q.keys) == ["bingo_0", "bingo_1", "bingo_2"])
    }

    @Test("Slug is JuL-safe (letters, digits, underscores)")
    func slugIsSafe() {
        #expect(BingoSquare.slug("low-hanging fruit") == "low_hanging_fruit")
        #expect(BingoSquare.slug("double-click") == "double_click")
        #expect(BingoSquare.slug("synergy") == "synergy")
    }

    @Test("Grid side is always 4 (strict 4×4 board)")
    func gridSide() {
        #expect(BingoConfig(terms: Array(repeating: "x", count: 16)).side == 4)
        #expect(BingoConfig(terms: Array(repeating: "x", count: 9)).side == 4)
        #expect(BingoConfig.cellCount == 16)
    }

    // MARK: - Context summary

    @Test("Top tags are the highest-probability taxonomy entries, mapped to labels")
    func topTags() throws {
        let r = try response(#"""
        {"choices": {"context_topic": {"choice": "budget", "confidence": 0.75,
          "probabilities": {"budget": 0.75, "technical": 0.13, "task": 0.07, "deadline": 0.03}}}}
        """#)
        let tags = ContextSummary.topTags(r, n: 3, minProbability: 0.05)
        // budget, technical, task clear 0.05; deadline (0.03) is dropped.
        #expect(tags == ["budget", "technical", "task"])
    }

    @Test("Top tags fall back to the single choice when probabilities are absent")
    func topTagsFallback() throws {
        let r = try response(#"""
        {"choices": {"context_topic": {"choice": "planning", "confidence": 0.5}}}
        """#)
        #expect(ContextSummary.topTags(r) == ["planning"])
    }

    @Test("Top tags are empty when there are no choices")
    func topTagsEmpty() throws {
        let r = try response(#"{"nouls": {}}"#)
        #expect(ContextSummary.topTags(r).isEmpty)
    }

    // MARK: - Jev protocol `answers` format (the official response shape)

    @Test("Decodes a noul from the answers map")
    func answersNoul() throws {
        let r = try response(#"""
        {"model": "wemm-4b",
         "answers": {"is_bug": {"type": "noul", "noul": 0.98}},
         "jul": {"latency_ms": 42.0}}
        """#)
        #expect(r.nouls?["is_bug"]?.noul == 0.98)
        #expect(r.latencyMs == 42.0)
        #expect(r.model == "wemm-4b")
    }

    @Test("Decodes a choice from the answers map")
    func answersChoice() throws {
        let r = try response(#"""
        {"answers": {"team": {"type": "choice", "choice": "billing", "confidence": 0.93,
                              "probabilities": {"billing": 0.93, "tech": 0.07}}}}
        """#)
        #expect(r.choices?["team"]?.choice == "billing")
        #expect(r.choices?["team"]?.confidence == 0.93)
        #expect(r.choices?["team"]?.probabilities?["tech"] == 0.07)
    }

    @Test("Decodes a score from the answers map")
    func answersScore() throws {
        let r = try response(#"""
        {"answers": {"tone": {"type": "score", "score": 3.1, "confidence": 0.8}}}
        """#)
        #expect(r.scores?["tone"]?.score == 3.1)
    }

    @Test("Mixed answers split into the typed maps")
    func answersMixed() throws {
        let r = try response(#"""
        {"answers": {
          "addressed_to_me": {"type": "noul", "noul": 0.99},
          "team": {"type": "choice", "choice": "billing", "confidence": 0.9, "probabilities": {"billing": 0.9}},
          "tone": {"type": "score", "score": 1.0}
        }}
        """#)
        #expect(r.nouls?["addressed_to_me"]?.noul == 0.99)
        #expect(r.choices?["team"]?.choice == "billing")
        #expect(r.scores?["tone"]?.score == 1.0)
    }

    @Test("Legacy top-level shape still decodes")
    func legacyShape() throws {
        let r = try response(#"{"model": "m", "latency_ms": 10, "nouls": {"q": {"noul": 0.5}}}"#)
        #expect(r.nouls?["q"]?.noul == 0.5)
        #expect(r.latencyMs == 10)
    }
}
