//
//  MeetingClassifier.swift
//  wispr
//
//  Rides on top of meeting transcription: each finalized sentence is sent to a
//  local JuL server and classified, without ever blocking the transcription
//  path. Drives two features from the same stream (see MeetingClassifierFeatures):
//    - awareness ("someone is talking about you") → wakes the user
//    - bullshit bingo → marks squares on a live grid
//
//  Wired as an optional dependency of MeetingStateManager, exactly like
//  MeetingDiarizer: absent, Wispr behaves exactly as before.
//

import Foundation
import Observation
import WisprCore
import os

/// Coordinates per-sentence JuL classification for the live-meeting features.
///
/// `@MainActor @Observable` so the bingo grid (SwiftUI) can bind to `bingoSquares`
/// directly. The network call itself hops off the main actor inside `JulClient`
/// (an actor), and each sentence is classified in its own detached task so a slow
/// or dead server never stalls recording.
@MainActor
@Observable
final class MeetingClassifier {

    // MARK: - Observable state (read by the UI)

    /// The live bingo grid. Empty until a bingo-enabled meeting starts.
    private(set) var bingoSquares: [BingoSquare] = []

    /// Side length of the square grid (0 when no bingo). Drives the UI layout and
    /// the winning-line detection.
    private(set) var gridSide: Int = 0

    /// The indices forming the first completed bingo line (row, column or
    /// diagonal), or empty if none yet. The UI highlights these and celebrates.
    private(set) var winningLine: [Int] = []

    /// True once a full line is complete. Latches for the session so the
    /// celebration fires once.
    private(set) var hasBingo = false

    /// Record of finished/reset bingo games this session, newest first: how many
    /// squares were marked and whether a line was completed.
    private(set) var bingoGames: [BingoGame] = []

    struct BingoGame: Identifiable, Sendable, Equatable {
        let id = UUID()
        let endedAt: Date
        let marked: Int
        let total: Int
        let completed: Bool
    }

    /// Whether the JuL server answered `/health` at the last check. Surfaced so
    /// the UI can show "JuL not running" instead of silently doing nothing.
    private(set) var isServerReachable = false

    /// The model name the server reports (for the status badge), or nil.
    private(set) var serverModel: String?

    /// History of the moments the user was addressed this session, newest first.
    /// Lets the user catch up on what they were pulled in for.
    private(set) var solicitations: [Solicitation] = []

    /// One recorded wake: what was said, by whom, when, the context tags, the
    /// highlights (urgency, action-needed, deadline, tone 0…4), and an optional
    /// one-line generated summary.
    struct Solicitation: Identifiable, Sendable, Equatable {
        let id = UUID()
        let date: Date
        let speaker: String
        let sentence: String
        let tags: [String]
        var urgent: Bool = false
        var needsAction: Bool = false
        var hasDeadline: Bool = false
        var tone: Int? = nil          // 0 calm … 4 angry
        var summary: String? = nil    // generative one-liner (mode .generative)
        var recentMessages: [String] = []   // last N lines (mode .lastMessages)
    }

    // MARK: - Configuration

    var awareness: AwarenessConfig?
    var bingo: BingoConfig? {
        didSet { rebuildBingoSquares() }
    }

    /// Optional source of fresh configuration, read at the start of each meeting.
    /// Lets a Settings change apply to the next meeting without relaunching the
    /// app. Returns the awareness config and bingo config to use for the session.
    var configProvider: (@MainActor () -> (awareness: AwarenessConfig?, bingo: BingoConfig?))?

    // MARK: - Dependencies

    private var client: JulClient

    /// Recent sentences with their arrival time. Kept for up to `contextWindow`
    /// (5 min) to feed the generative summary; the tag summary uses only the last
    /// `tagWindow` (30 s).
    private var recentSentences: [(date: Date, text: String)] = []
    private let tagWindow: TimeInterval = 30
    private let contextWindow: TimeInterval = 300     // 5 minutes
    /// The recent portion given verbatim to the summary; older context is condensed.
    private let recentVerbatimWindow: TimeInterval = 45

    /// Optional on-device generative summary (Apple Foundation Models). Used
    /// opportunistically; nil-tolerant everywhere.
    private let summarizer = AwarenessSummarizer()

    /// The name that matched for the current wake, for the generated summary.
    private var primaryName: String { awareness?.monitoredNames.first ?? "you" }

    /// Anti-spam: after a wake, suppress further wakes for this long. A meeting
    /// where you are addressed repeatedly should buzz once, not every sentence.
    /// Anti-spam: after a wake, suppress further wakes for the awareness config's
    /// cooldown. `lastWakeAt` tracks the last time we woke the user.
    private var lastWakeAt: Date?

    /// Invoked on the main actor when a sentence both names the user and asks
    /// something of them. Carries the full solicitation (sentence, speaker, tags,
    /// urgency, and an optional generated one-line summary). Wired to notification
    /// + haptic by the app.
    var onWake: (@MainActor (_ solicitation: Solicitation) -> Void)?

    /// Invoked when the optional generated brief arrives after a wake, so the app
    /// can enrich the already-shown notification/history. Same solicitation id.
    var onSummaryReady: (@MainActor (_ solicitation: Solicitation) -> Void)?

    /// Invoked when one or more bingo squares are newly marked, e.g. to flash the
    /// menu-bar grid.
    var onBingoUpdate: (@MainActor (_ newlyMarked: [String]) -> Void)?

    /// Invoked once when a full line (row, column or diagonal) completes.
    var onBingo: (@MainActor () -> Void)?

    /// Invoked at meeting start when awareness is configured, so the app can
    /// request notification authorization up front (otherwise the first wake is
    /// dropped silently because the app never asked for permission).
    var onAwarenessArmed: (@MainActor () async -> Void)?

    // MARK: - Init

    init(client: JulClient) {
        self.client = client
    }

    /// Convenience: build the client for a base URL (default local server).
    convenience init(baseURL: String = JulClient.defaultBaseURL) {
        self.init(client: JulClient(baseURL: baseURL))
    }

    /// The base URL the client currently targets, so the poll can be rebuilt when
    /// Settings change.
    private(set) var endpoint: String = JulClient.defaultBaseURL
    private var apiKey: String?

    /// Points the classifier at a different JuL endpoint (from Settings), rebuilds
    /// the client and immediately re-probes health.
    func setEndpoint(_ baseURL: String, apiKey: String? = nil) {
        endpoint = JulClient.normalizedBase(baseURL) ?? JulClient.defaultBaseURL
        self.apiKey = (apiKey?.isEmpty == false) ? apiKey : nil
        client = JulClient(baseURL: endpoint, apiKey: self.apiKey)
        Task { await probeHealthOnce() }
    }

    /// Starts a background loop that keeps `isServerReachable` / `serverModel` in
    /// sync with the server, so the status badge is accurate even outside a
    /// meeting. Idempotent — safe to call repeatedly.
    func startHealthMonitoring() {
        guard healthTask == nil else { return }
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.probeHealthOnce()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Stops the health poll and marks the server unreachable. Called when the
    /// feature is turned off, so no request is made while it is disabled.
    func stopHealthMonitoring() {
        healthTask?.cancel()
        healthTask = nil
        isServerReachable = false
        serverModel = nil
    }

    private var healthTask: Task<Void, Never>?

    private func probeHealthOnce() async {
        let model = await client.health()
        isServerReachable = (model != nil)
        serverModel = model
    }

    // MARK: - Lifecycle

    /// Called when a meeting starts. Checks the server is up and resets the grid.
    func meetingWillStart() async {
        // Pull fresh configuration so a Settings change since the last meeting
        // takes effect now, without an app relaunch.
        if let configProvider {
            let cfg = configProvider()
            awareness = cfg.awareness
            bingo = cfg.bingo
        }
        rebuildBingoSquares()
        recentSentences.removeAll()
        lastWakeAt = nil
        solicitations.removeAll()
        bingoGames.removeAll()
        await probeHealthOnce()
        if !isServerReachable {
            Log.stateManager.warning(
                "MeetingClassifier — JuL server not reachable; live features disabled this session. Start it with `jul serve`.")
        }
        // Ask for notification permission now if awareness is on, so the first
        // wake actually shows a banner.
        if awareness?.isConfigured == true {
            await onAwarenessArmed?()
        }
    }

    /// Whether there is anything to ask. When both features are off (or nothing
    /// is configured), the classifier is inert and adds no per-sentence cost.
    private var hasActiveQuestions: Bool {
        (awareness?.isConfigured ?? false) || (bingo?.isConfigured ?? false)
    }

    // MARK: - The hook

    /// The sentence waiting to be classified, if any. Only the most recent is
    /// kept: with a slow server, older pending sentences are dropped rather than
    /// piling up unbounded.
    private var pendingEntry: MeetingTranscriptEntry?
    /// Whether a classification is currently in flight (serial: one at a time).
    private var isClassifying = false

    /// Classify one finalized transcript sentence. **Non-blocking**: returns
    /// immediately. Work is serialized — at most one JuL call in flight, and only
    /// the latest queued sentence is kept — so a slow server cannot make tasks
    /// accumulate. The caller (MeetingStateManager.record) never waits on JuL.
    nonisolated func classify(_ entry: MeetingTranscriptEntry) {
        Task { @MainActor in
            self.pendingEntry = entry     // newest wins; older backlog is dropped
            self.pump()
        }
    }

    /// Drains the single-slot queue serially.
    private func pump() {
        guard !isClassifying, let entry = pendingEntry else { return }
        pendingEntry = nil
        isClassifying = true
        Task { @MainActor in
            await self.handle(entry)
            self.isClassifying = false
            self.pump()               // process whatever arrived meanwhile
        }
    }

    private func handle(_ entry: MeetingTranscriptEntry) async {
        // Only skip when there is genuinely nothing to ask. Do NOT gate on a
        // frozen `isServerReachable`: the server may come up after the meeting
        // started, so we attempt each sentence and update reachability from the
        // actual result. A failed call is cheap and simply skips that sentence.
        guard hasActiveQuestions else { return }

        // Skip trivially short utterances ("Yeah.", "Hello.", "Sr."). On a near-
        // empty sentence the vector reading is unstable and lights up almost every
        // question at ~0.9 — a measured, reproducible false-positive storm. A real
        // address or buzzword needs more than a couple of words to be meaningful.
        let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = trimmed.split { $0 == " " || $0 == "\n" }.count
        guard trimmed.count >= 12, wordCount >= 3 else { return }

        // Keep this sentence in the rolling 30-second buffer used to summarise the
        // recent context when the user is woken.
        recentSentences.append((entry.timestamp, trimmed))
        let cutoff = Date().addingTimeInterval(-contextWindow)
        recentSentences.removeAll { $0.date < cutoff }

        // Merge both features' questions into one request: the sentence is
        // encoded once and every question continues from it (JuL pays the state
        // once per call), so two features cost barely more than one.
        var questions: [String: JulQuestion] = [:]
        if let awareness, awareness.isConfigured {
            questions.merge(awareness.questions()) { a, _ in a }
        }
        if let bingo, bingo.isConfigured {
            questions.merge(bingo.questions()) { a, _ in a }
        }
        guard !questions.isEmpty else { return }

        // The ASR often mis-transcribes buzzwords, especially English ones inside
        // another language ("growth hacking" → "gross hacking"). JuL only matches
        // what is actually written, so we first fold the sentence back toward the
        // grid terms with Wispr's phonetic/edit-distance corrector. This keeps
        // JuL's strict "was it literally said" wording (and its precision) while
        // repairing the transcription upstream. Awareness reads the same
        // corrected text, which is harmless (proper-noun spelling only).
        var state = trimmed
        if let bingo, bingo.isConfigured {
            state = VocabularyCorrector.correct(state, vocabulary: bingo.terms)
        }

        let response: JulResponse
        do {
            response = try await client.classify(state: state, questions: questions)
            isServerReachable = true
        } catch {
            isServerReachable = false
            Log.stateManager.debug(
                "MeetingClassifier — classify failed: \(error.localizedDescription)")
            return
        }

        if let awareness, awareness.isConfigured {
            let a = response.nouls?[AwarenessConfig.Keys.addressed]?.noul ?? -1
            let s = response.nouls?[AwarenessConfig.Keys.solicits]?.noul ?? -1
            let wake = awareness.shouldWake(response)
            let ta = awareness.addressedThreshold
            let ts = awareness.solicitationThreshold
            // Privacy: log only the decision metadata, never the transcribed text
            // (see CLAUDE.md — transcribed text is never logged).
            Log.stateManager.debug(
                "MeetingClassifier — awareness: addressed=\(a, format: .fixed(precision: 2)) solicits=\(s, format: .fixed(precision: 2)) thresholds=\(ta, format: .fixed(precision: 2))/\(ts, format: .fixed(precision: 2)) wake=\(wake)")
            if wake {
                // Anti-spam: honour the configured cooldown since the last wake.
                let now = Date()
                if let last = lastWakeAt, now.timeIntervalSince(last) < TimeInterval(awareness.cooldownSeconds) {
                    Log.stateManager.debug("MeetingClassifier — wake suppressed (cooldown)")
                } else {
                    lastWakeAt = now
                    // A: highlights from the same JuL call.
                    let urgent = awareness.isUrgent(response)
                    let needsAction = awareness.needsMyAction(response)
                    let hasDeadline = awareness.hasDeadline(response)
                    let tone = awareness.tone(response)
                    let tags = await summariseRecentContext()
                    // C: the last N transcript lines, always available instantly.
                    let recentMessages = Array(recentSentences.suffix(max(1, awareness.lastMessages)).map(\.text))

                    // Wake NOW with everything we already have — the generated
                    // brief (if any) is fetched afterwards and folded in, so the
                    // notification is never delayed by model generation.
                    let solicitation = Solicitation(
                        date: now, speaker: entry.speaker.displayName,
                        sentence: entry.text, tags: tags, urgent: urgent,
                        needsAction: needsAction, hasDeadline: hasDeadline,
                        tone: tone, summary: nil, recentMessages: recentMessages)
                    solicitations.insert(solicitation, at: 0)
                    let id = solicitation.id
                    onWake?(solicitation)

                    // B: opportunistic generated brief, computed after the wake.
                    if awareness.summaryMode == .generative {
                        let windowStart = now.addingTimeInterval(-Double(awareness.summaryMinutes) * 60)
                        let inWindow = recentSentences.filter { $0.date >= windowStart }
                        let cut = now.addingTimeInterval(-self.recentVerbatimWindow)
                        let farContext = inWindow.filter { $0.date < cut }.map(\.text)
                        let recentContext = inWindow.filter { $0.date >= cut }.map(\.text)
                        Task { @MainActor in
                            let brief = await self.summarizer.summarize(
                                sentence: entry.text, speaker: entry.speaker.displayName,
                                farContext: farContext, recentContext: recentContext,
                                monitoredName: self.primaryName)
                            guard let brief else { return }
                            // Fold the brief into the recorded solicitation so the
                            // history window shows it once ready.
                            if let idx = self.solicitations.firstIndex(where: { $0.id == id }) {
                                self.solicitations[idx].summary = brief
                            }
                            // Local copy rather than mutating the captured `var`,
                            // so there is no cross-task mutation to reason about.
                            var s = solicitation
                            s.summary = brief
                            self.onSummaryReady?(s)
                        }
                    }
                }
            }
        } else {
            let configured = awareness?.isConfigured ?? false
            Log.stateManager.debug(
                "MeetingClassifier — awareness not evaluated (configured=\(configured))")
        }

        if let bingo, bingo.isConfigured {
            applyBingo(bingo.marked(in: response))
        }
    }

    /// Summarises the last ~30 seconds into up to three tags, via one JuL Choice
    /// over a fixed taxonomy (no text generation). Returns [] if there is nothing
    /// buffered or JuL is unavailable — the wake still fires, just without tags.
    private func summariseRecentContext() async -> [String] {
        let cutoff = Date().addingTimeInterval(-tagWindow)
        let recent = recentSentences.filter { $0.date >= cutoff }.map(\.text)
        guard !recent.isEmpty else { return [] }
        let passage = recent.joined(separator: " ")
        do {
            let response = try await client.classify(state: passage, questions: ContextSummary.question())
            return ContextSummary.topTags(response)
        } catch {
            Log.stateManager.debug("MeetingClassifier — summary failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Bingo grid

    private func rebuildBingoSquares() {
        let allTerms = bingo?.terms ?? []
        let n = BingoConfig.gridSide          // 4
        let capacity = BingoConfig.cellCount  // 16
        // The first 16 terms fill the grid; any extra are ignored.
        let used = Array(allTerms.prefix(capacity))
        var cells = used.enumerated().map { BingoSquare(term: $0.element, index: $0.offset) }
        // Pad up to 16 with free "★" squares so the 4×4 lines are complete.
        while cells.count < capacity && !used.isEmpty {
            cells.append(BingoSquare(term: "★", index: cells.count, isFree: true))
        }
        bingoSquares = cells
        gridSide = used.isEmpty ? 0 : n
        winningLine = []
        // A grid with free squares may already contain completed lines; re-detect
        // so the state is consistent, but do not fire the celebration on setup.
        hasBingo = false
    }

    /// Starts a fresh bingo game: records the current one for the session log,
    /// then clears every square. Called from the "New game" button.
    func resetBingo() {
        let marked = bingoSquares.filter(\.isMarked).count
        if marked > 0 {
            bingoGames.insert(
                BingoGame(endedAt: Date(), marked: marked, total: bingoSquares.count,
                          completed: hasBingo),
                at: 0)
        }
        rebuildBingoSquares()
    }

    /// Mark the given slugs on the grid, reporting only the ones that flipped so
    /// the UI can highlight the fresh hits, then check for a completed line.
    private func applyBingo(_ markedSlugs: [String]) {
        guard !markedSlugs.isEmpty else { return }
        let marked = Set(markedSlugs)
        var newlyMarked: [String] = []
        for i in bingoSquares.indices where marked.contains(bingoSquares[i].id) && !bingoSquares[i].isMarked {
            bingoSquares[i].isMarked = true
            newlyMarked.append(bingoSquares[i].id)
        }
        guard !newlyMarked.isEmpty else { return }
        onBingoUpdate?(newlyMarked)
        detectBingo()
    }

    /// Checks every row, column and diagonal; on the first fully-marked line,
    /// latches `hasBingo`, records the line for highlighting, and fires `onBingo`.
    private func detectBingo() {
        guard !hasBingo, gridSide > 1 else { return }
        let n = gridSide
        func allMarked(_ idx: [Int]) -> Bool { idx.allSatisfy { bingoSquares[$0].isMarked } }

        var lines: [[Int]] = []
        for r in 0..<n { lines.append((0..<n).map { r * n + $0 }) }          // rows
        for c in 0..<n { lines.append((0..<n).map { $0 * n + c }) }          // columns
        lines.append((0..<n).map { $0 * n + $0 })                            // main diagonal
        lines.append((0..<n).map { $0 * n + (n - 1 - $0) })                  // anti-diagonal

        for line in lines where allMarked(line) {
            winningLine = line
            hasBingo = true
            onBingo?()
            return
        }
    }
}
