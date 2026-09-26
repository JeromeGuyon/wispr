//
//  MeetingClassifierFeatures.swift
//  wispr
//
//  The two live-meeting features that ride on JuL classification, and the
//  question sets that drive them. Both share one mechanism — each transcript
//  sentence is sent to JuL — and differ only in the questions asked, so they
//  live side by side here.
//

import Foundation

/// How the awareness feature shows context when the user is woken.
/// - `lastMessages`: show the last N transcript lines verbatim (no model, default).
/// - `generative`: a one-line summary generated on-device by Apple Intelligence,
///   over a configurable time window. Opt-in.
enum AwarenessSummaryMode: String, Sendable, CaseIterable, Codable {
    case lastMessages
    case generative
}

// MARK: - "Someone is talking about you"

/// Configuration for the awareness feature ("on parle de toi, réveille-toi").
///
/// When a sentence both names the user and carries a question or a task, the Mac
/// wakes the user (notification + haptic) with the last few seconds summarised.
struct AwarenessConfig: Sendable, Equatable {
    /// Names the user answers to, e.g. ["Jerome", "Jé"]. Matched by JuL against
    /// the sentence, so misspellings and phonetic variants still fire.
    var monitoredNames: [String]

    /// The sentence must clearly name the user to wake them: this is the strong,
    /// distinctive signal (measured ~0.98 when addressed, <0.06 otherwise).
    var addressedThreshold: Double = 0.75

    /// It must also be a question or a task — but this signal is softer. Measured
    /// on real dictation: "tu peux regarder ?" scores 0.75, "tu peux regarder."
    /// only 0.62, both genuine requests. A lower bar catches these without false
    /// positives (neutral statements score 0.05–0.17).
    var solicitationThreshold: Double = 0.5

    /// How context is presented on a wake, and its sizing.
    var summaryMode: AwarenessSummaryMode = .lastMessages
    var lastMessages: Int = 3
    var summaryMinutes: Int = 5

    /// Minimum seconds between two wakes (anti-spam). A meeting where you are
    /// addressed repeatedly should buzz once, not on every sentence.
    var cooldownSeconds: Int = 45

    var isConfigured: Bool { !monitoredNames.isEmpty }

    /// Builds a config from the persisted settings values.
    static func from(names: [String], mode: AwarenessSummaryMode,
                     lastMessages: Int, summaryMinutes: Int, cooldownSeconds: Int) -> AwarenessConfig {
        var c = AwarenessConfig(monitoredNames: names)
        c.summaryMode = mode
        c.lastMessages = max(1, lastMessages)
        c.summaryMinutes = max(1, summaryMinutes)
        c.cooldownSeconds = max(0, cooldownSeconds)
        return c
    }

    /// The questions asked about each sentence. Language-agnostic: JuL is
    /// multilingual, so the same set works whether the meeting is in French or
    /// English (the sentence itself carries the language).
    func questions() -> [String: JulQuestion] {
        let names = monitoredNames.joined(separator: ", ")
        return [
            Keys.addressed: .noul(
                "Does this sentence address, name or refer to \(names)? "
                + "Cette phrase s'adresse-t-elle à, nomme-t-elle ou évoque-t-elle \(names) ?"),
            Keys.solicits: .noul(
                "Is this sentence a question being asked or a task being assigned to someone? "
                + "Est-ce une question posée ou une tâche confiée à quelqu'un ?"),
            Keys.urgent: .noul(
                "Does this call for an immediate response, as opposed to something that can wait? "
                + "Est-ce que cela demande une réponse immédiate, par opposition à quelque chose qui peut attendre ?"),
            Keys.needsAction: .noul(
                "Is \(names) expected to personally do something or answer, rather than merely being mentioned? "
                + "Attend-on de \(names) une action ou une réponse personnelle, plutôt qu'une simple mention ?"),
            Keys.deadline: .noul(
                "Does this mention a deadline, a date, or a time by which something must happen? "
                + "Est-ce que cela mentionne une échéance, une date ou un délai ?"),
            Keys.tone: .score(
                "What is the emotional tone of this sentence? "
                + "Quel est le ton émotionnel de cette phrase ?",
                // Ordered low → high tension, 5 levels for nuance.
                levels: [
                    "Calm and positive",
                    "Neutral, matter-of-fact",
                    "Slightly pressing or impatient",
                    "Tense or frustrated",
                    "Angry or confrontational",
                ]),
        ]
    }

    /// Whether the solicitation needs an answer now (drives the notification's
    /// interruption level and the ⚡ marker). A soft signal — read at 0.6.
    func isUrgent(_ response: JulResponse) -> Bool {
        (response.nouls?[Keys.urgent]?.noul ?? 0) >= 0.6
    }

    /// Whether the user is personally expected to act or answer.
    func needsMyAction(_ response: JulResponse) -> Bool {
        (response.nouls?[Keys.needsAction]?.noul ?? 0) >= 0.6
    }

    /// Whether a deadline/date is mentioned.
    func hasDeadline(_ response: JulResponse) -> Bool {
        (response.nouls?[Keys.deadline]?.noul ?? 0) >= 0.6
    }

    /// The emotional tone as a 0…4 level (nil if not scored). 0 = calm, 4 = angry.
    func tone(_ response: JulResponse) -> Int? {
        guard let s = response.scores?[Keys.tone]?.score else { return nil }
        return Int(s.rounded())
    }

    /// Whether a JuL response clears the bar to wake the user.
    func shouldWake(_ response: JulResponse) -> Bool {
        guard let addressed = response.nouls?[Keys.addressed]?.noul,
              let solicits = response.nouls?[Keys.solicits]?.noul else { return false }
        return addressed >= addressedThreshold && solicits >= solicitationThreshold
    }

    enum Keys {
        static let addressed = "addressed_to_me"
        static let solicits = "is_solicitation"
        static let urgent = "is_urgent"
        static let needsAction = "needs_my_action"
        static let deadline = "has_deadline"
        static let tone = "tone"
    }
}

// MARK: - Context summary ("the last 30 seconds in three tags")

/// Summarises the recent conversation into a few tags when the user is woken.
///
/// JuL never generates text, so the tags come from a fixed taxonomy of
/// meeting topics: a single `Choice` over that taxonomy returns a probability per
/// tag, and we keep the top few. This is fully within the existing JuL API — no
/// generation, no server change — and multilingual because JuL is.
enum ContextSummary {
    /// The tag taxonomy. Keys are the identifiers returned; descriptions are what
    /// JuL actually compares the conversation against, so they are written to be
    /// discriminative.
    static let taxonomy: [(key: String, label: String, description: String)] = [
        ("question", "question", "a direct question is being asked, someone wants an answer"),
        ("task", "task", "a task, action item or assignment is being handed out"),
        ("decision", "decision", "a decision is being made or confirmed"),
        ("deadline", "deadline", "a date, deadline or schedule is discussed"),
        ("budget", "budget", "money, cost, budget, pricing or revenue"),
        ("technical", "technical", "code, bug, architecture, deployment or other engineering detail"),
        ("planning", "planning", "roadmap, priorities, planning or next steps"),
        ("blocker", "blocker", "a problem, risk, blocker or something going wrong"),
        ("feedback", "feedback", "review, opinion, feedback or critique"),
        ("status", "status update", "a progress or status update on ongoing work"),
        ("customer", "customer", "a client, customer or user is discussed"),
        ("hiring", "people", "hiring, team, roles or people matters"),
    ]

    static let questionKey = "context_topic"

    /// A single Choice over the taxonomy. Asked on the concatenated recent
    /// sentences to characterise what was just being discussed.
    static func question() -> [String: JulQuestion] {
        var criteria: [String: String] = [:]
        for t in taxonomy { criteria[t.key] = t.description }
        return [questionKey: JulQuestion(.choice,
            instructions: "What is this passage of a meeting mainly about?",
            criteria: criteria)]
    }

    /// The top `n` tags (human labels) from a summary response, most likely first,
    /// keeping only those with a meaningful probability.
    static func topTags(_ response: JulResponse, n: Int = 3, minProbability: Double = 0.08) -> [String] {
        guard let probs = response.choices?[questionKey]?.probabilities else {
            // Fall back to the single top choice if probabilities are absent.
            if let key = response.choices?[questionKey]?.choice { return [label(for: key)] }
            return []
        }
        return probs
            .filter { $0.value >= minProbability }
            .sorted { $0.value > $1.value }
            .prefix(n)
            .map { label(for: $0.key) }
    }

    private static func label(for key: String) -> String {
        taxonomy.first { $0.key == key }?.label ?? key
    }
}

// MARK: - Bullshit bingo

/// One square on the bingo grid: a corporate-jargon term and whether it has been
/// heard yet this meeting.
struct BingoSquare: Identifiable, Sendable, Equatable {
    let id: String        // grid-position-unique key, also the JuL question key
    let term: String      // shown on the grid, e.g. "synergy"
    var isMarked: Bool = false
    /// A padding cell used to fill a 4×4 grid when there are fewer than 16 terms.
    /// Free cells are pre-marked and never queried against JuL.
    var isFree: Bool = false

    /// `index` makes the key unique per grid position, so two terms that slug to
    /// the same string (or a term colliding with an awareness key) never clash.
    init(term: String, index: Int, isFree: Bool = false) {
        self.term = term
        self.isFree = isFree
        self.isMarked = isFree
        self.id = isFree ? "free_\(index)" : "bingo_\(index)"
    }

    /// A JuL-safe fragment: letters, digits and underscores only. (Kept for
    /// tests and any display need; question keys are index-based, see `id`.)
    static func slug(_ term: String) -> String {
        let allowed = term.lowercased().map { ch -> Character in
            ch.isLetter || ch.isNumber ? ch : "_"
        }
        return String(allowed)
    }
}

/// Configuration for the live bingo grid.
struct BingoConfig: Sendable, Equatable {
    /// The jargon terms on the grid. A sentence is asked one yes/no per term.
    var terms: [String]

    /// A term is marked when JuL's yes-probability clears this. A little lower
    /// than awareness: a wrong square is harmless fun, a missed one is a letdown.
    var threshold: Double = 0.6

    var isConfigured: Bool { !terms.isEmpty }

    /// A default grid that reliably produces bingo in any all-hands.
    static let defaultTerms = [
        "synergy", "leverage", "circle back", "low-hanging fruit",
        "move the needle", "double-click", "boil the ocean", "north star",
        "iterate on the roadmap", "bandwidth", "paradigm shift", "disruptive",
        "value proposition", "growth hacking", "deep dive", "ecosystem",
    ]

    /// A larger curated pool of genuine corporate buzzwords to draw a random grid
    /// from. Chosen to be distinctive enough that JuL reads them reliably and that
    /// no two are easily confused; a mix of terms heard in French meetings too
    /// (the English forms are used verbatim as anglicisms).
    static let buzzwordPool = [
        // classics
        "synergy", "leverage", "circle back", "low-hanging fruit", "move the needle",
        "double-click", "boil the ocean", "north star", "iterate on the roadmap",
        "bandwidth", "paradigm shift", "disruptive", "value proposition",
        "growth hacking", "deep dive", "ecosystem",
        // alignment & strategy
        "align", "on the same page", "single source of truth", "mission critical",
        "strategic", "holistic", "big picture", "moving forward", "game changer",
        "best practice", "core competency", "value add", "quick win", "table stakes",
        // action & delivery
        "actionable", "take offline", "touch base", "loop in", "drill down",
        "run it up the flagpole", "ballpark", "streamline", "optimize", "scalable",
        "agile", "sprint", "backlog", "blocker", "deliverable", "milestone",
        "low effort high impact", "MVP", "proof of concept", "pipeline",
        // people & culture
        "empower", "wear many hats", "rockstar", "ninja", "culture fit",
        "think outside the box", "push the envelope", "hit the ground running",
        // buzzy tech
        "AI-powered", "cloud-native", "data-driven", "machine learning",
        "digital transformation", "next-gen", "seamless", "frictionless",
        "customer-centric", "future-proof",
    ]

    /// A random grid of `count` distinct buzzwords drawn from the pool.
    static func randomTerms(count: Int = BingoConfig.cellCount) -> [String] {
        Array(buzzwordPool.shuffled().prefix(count))
    }

    /// The bingo grid is a strict 4×4. The first 16 terms fill it; fewer terms
    /// leave the remaining cells as free "★" squares (pre-marked), so
    /// rows/columns/diagonals stay well-defined.
    static let gridSide = 4
    static let cellCount = gridSide * gridSide

    var side: Int { BingoConfig.gridSide }

    /// One yes/no per term, keyed by the term's slug.
    ///
    /// The wording is deliberate. A naive "does this sentence use the concept X?"
    /// makes the model answer on the *register* of the sentence — a jargon-dense
    /// line lights up terms it never contained (measured: precision ~50%, F1 0.67
    /// on wemm-4b). Anchoring on the term being *actually said*, in English even
    /// for non-English sentences, disciplines it to the specific phrase:
    /// measured precision 96% / recall 100% (F1 0.98) on a mixed FR+EN set, and a
    /// perfect 1.00 on English-only — full-JuL, using only the existing API.
    /// Measured with the eval scripts in the JuL repo (usejul/jul).
    func questions() -> [String: JulQuestion] {
        var q: [String: JulQuestion] = [:]
        // Only the terms that fill the 4×4 grid are asked. Keyed by grid index
        // (`bingo_<i>`), which is unique per position: two terms that slug to the
        // same string, or a term that collides with an awareness key, never clash.
        for (i, term) in terms.prefix(BingoConfig.cellCount).enumerated() {
            q["bingo_\(i)"] = .noul(
                "Is the specific business buzzword \"\(term)\" actually said in this sentence? "
                + "Answer yes only if that exact phrase (or a near-identical form) appears, "
                + "not just because the sentence is jargon-heavy.")
        }
        return q
    }

    /// The `bingo_<i>` keys whose yes-probability cleared the threshold. They map
    /// directly onto the grid squares' `id`.
    func marked(in response: JulResponse) -> [String] {
        guard let nouls = response.nouls else { return [] }
        return nouls.compactMap { key, answer in
            key.hasPrefix("bingo_") && answer.noul >= threshold ? key : nil
        }
    }
}
