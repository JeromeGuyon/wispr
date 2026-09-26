//
//  JulClient.swift
//  wispr
//
//  Thin async client for a local JuL classify server (`jul serve`, default
//  127.0.0.1:8577). JuL answers typed questions about a piece of text without
//  generating any tokens, in tens of milliseconds. Wispr uses it to classify
//  each transcript sentence as it is recorded.
//
//  The request/response shapes match JuL's own HTTP contract (its AWS Lambda
//  deployment and `jul serve`), so nothing here is Wispr-specific on the wire.
//

import Foundation
import WisprCore
import os

// MARK: - Wire types

/// A single typed question sent to JuL. `criteria` is only meaningful for
/// `choice` (option key → description) and `score` (ordered level descriptions);
/// a `noul` is a plain yes/no and carries none.
nonisolated struct JulQuestion: Encodable, Sendable {
    enum Kind: String, Encodable, Sendable {
        case choice, noul, score
    }

    let type: Kind
    let instructions: String
    let criteria: [String: String]?
    /// Ordered level descriptions for a `score` question, lowest first. Encoded
    /// as a JSON array under `criteria`, which the server reads in order.
    let scoreLevels: [String]?

    init(_ type: Kind, instructions: String, criteria: [String: String]? = nil,
         scoreLevels: [String]? = nil) {
        self.type = type
        self.instructions = instructions
        self.criteria = criteria
        self.scoreLevels = scoreLevels
    }

    /// A yes/no question — the shape both features lean on.
    static func noul(_ instructions: String) -> JulQuestion {
        JulQuestion(.noul, instructions: instructions)
    }

    /// A graded question with ordered levels, lowest first.
    static func score(_ instructions: String, levels: [String]) -> JulQuestion {
        JulQuestion(.score, instructions: instructions, scoreLevels: levels)
    }

    enum CodingKeys: String, CodingKey { case type, instructions, criteria }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(instructions, forKey: .instructions)
        // Score levels take precedence and are encoded as an ordered JSON array;
        // otherwise the criteria dict (choice) is encoded as an object.
        if let scoreLevels {
            try c.encode(scoreLevels, forKey: .criteria)
        } else if let criteria {
            try c.encode(criteria, forKey: .criteria)
        }
    }
}

/// The request body: one text (`state`) and the questions to ask about it. The
/// state is paid once per call and every question continues from it, so asking
/// twenty bingo terms in one request costs one encoding of the sentence.
nonisolated struct JulRequest: Encodable, Sendable {
    let state: String
    let questions: [String: JulQuestion]
    let model: String?
}

/// JuL's response in the Jev HTTP protocol shape: one `answers` map keyed by
/// question name, each entry tagged with its `type`. Wispr keeps reading it
/// through `choices` / `nouls` / `scores`, derived from `answers`, so callers are
/// unchanged.
nonisolated struct JulResponse: Decodable, Sendable {
    struct ChoiceAnswer: Decodable, Sendable {
        let choice: String
        let confidence: Double
        let probabilities: [String: Double]?
    }
    struct NoulAnswer: Decodable, Sendable {
        let noul: Double
    }
    struct ScoreAnswer: Decodable, Sendable {
        let score: Double          // mean level, e.g. 0…(n-1)
        let confidence: Double?
    }

    let model: String?
    let latencyMs: Double?
    let choices: [String: ChoiceAnswer]?
    let nouls: [String: NoulAnswer]?
    let scores: [String: ScoreAnswer]?

    private enum TopKeys: String, CodingKey {
        case model, answers, jul
        // Legacy top-level shape (old #8 server), tolerated as a fallback.
        case choices, nouls, scores
        case latencyMs = "latency_ms"
    }
    private enum JulKeys: String, CodingKey { case latencyMs = "latency_ms" }

    /// One answer entry, decoded by its `type` discriminator.
    private struct Answer: Decodable {
        let type: String
        let choice: String?
        let confidence: Double?
        let probabilities: [String: Double]?
        let noul: Double?
        let score: Double?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: TopKeys.self)
        model = try c.decodeIfPresent(String.self, forKey: .model)

        // Latency lives under `jul.latency_ms` (new) or `latency_ms` (old).
        if let julC = try? c.nestedContainer(keyedBy: JulKeys.self, forKey: .jul) {
            latencyMs = try? julC.decodeIfPresent(Double.self, forKey: .latencyMs)
        } else {
            latencyMs = try? c.decodeIfPresent(Double.self, forKey: .latencyMs)
        }

        if let answers = try? c.decodeIfPresent([String: Answer].self, forKey: .answers) {
            // New Jev shape: split the tagged answers into typed maps.
            var ch: [String: ChoiceAnswer] = [:]
            var no: [String: NoulAnswer] = [:]
            var sc: [String: ScoreAnswer] = [:]
            for (name, a) in answers {
                switch a.type {
                case "choice":
                    if let choice = a.choice {
                        ch[name] = ChoiceAnswer(choice: choice, confidence: a.confidence ?? 0,
                                                probabilities: a.probabilities)
                    }
                case "noul":
                    if let noul = a.noul { no[name] = NoulAnswer(noul: noul) }
                case "score":
                    if let score = a.score { sc[name] = ScoreAnswer(score: score, confidence: a.confidence) }
                default:
                    break
                }
            }
            choices = ch.isEmpty ? nil : ch
            nouls = no.isEmpty ? nil : no
            scores = sc.isEmpty ? nil : sc
        } else {
            // Legacy #8 shape: typed maps at the top level.
            choices = try? c.decodeIfPresent([String: ChoiceAnswer].self, forKey: .choices)
            nouls = try? c.decodeIfPresent([String: NoulAnswer].self, forKey: .nouls)
            scores = try? c.decodeIfPresent([String: ScoreAnswer].self, forKey: .scores)
        }
    }
}

// MARK: - Client

/// Errors surfaced by `JulClient`. Kept small: callers treat any failure as
/// "JuL is unavailable, skip this sentence" rather than branching on the cause.
enum JulClientError: Error {
    case notReachable(underlying: Error)
    case badStatus(Int)
    case decoding(Error)
}

/// Talks to a local JuL server over HTTP. An actor so concurrent calls (one per
/// transcript sentence) share one `URLSession` without data races.
///
/// Every call has a short timeout: the classifier is best-effort decoration on
/// top of transcription, and must never wedge on a stalled server.
actor JulClient {

    private let endpoint: URL
    private let healthEndpoint: URL
    private let model: String?
    private let apiKey: String?
    private let session: URLSession

    /// Builds a client for a base URL like "http://127.0.0.1:8577". Falls back to
    /// the default endpoint if the string cannot be parsed. `apiKey`, when set, is
    /// sent as `Authorization: Bearer` (and `x-api-key`) on every request.
    init(baseURL: String = JulClient.defaultBaseURL, model: String? = nil,
         apiKey: String? = nil, timeout: TimeInterval = 3.0) {
        let base = JulClient.normalizedBase(baseURL) ?? JulClient.defaultBaseURL
        // Jev HTTP protocol endpoint (jul serve >= #10). `/v1/classify` remains an
        // alias server-side, but /v1/systemone is the canonical route.
        self.endpoint = URL(string: base + "/v1/systemone")!
        self.healthEndpoint = URL(string: base + "/health")!
        self.model = model
        self.apiKey = (apiKey?.isEmpty == false) ? apiKey : nil

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    static let defaultBaseURL = "http://127.0.0.1:8577"

    /// Trims trailing slashes and validates the URL has a scheme + host.
    static func normalizedBase(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let u = URL(string: s), u.scheme != nil, u.host != nil else { return nil }
        return s
    }

    /// Whether the server answers `/health`. Used once when the feature is
    /// enabled, to warn the user early rather than failing silently per sentence.
    func isReachable() async -> Bool {
        await health() != nil
    }

    /// Queries `/health`, returning the loaded model name (or "" if unknown) when
    /// the server responds 200, or nil when unreachable.
    func health() async -> String? {
        var request = URLRequest(url: healthEndpoint)
        request.httpMethod = "GET"
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let model = json["model"] as? String {
            return model
        }
        return ""
    }

    /// Ask JuL every question about one sentence.
    func classify(state: String, questions: [String: JulQuestion]) async throws -> JulResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        request.httpBody = try JSONEncoder().encode(
            JulRequest(state: state, questions: questions, model: model))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw JulClientError.notReachable(underlying: error)
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw JulClientError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        do {
            return try JSONDecoder().decode(JulResponse.self, from: data)
        } catch {
            throw JulClientError.decoding(error)
        }
    }
}
