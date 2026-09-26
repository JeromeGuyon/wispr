//
//  SettingsStore.swift
//  wispr
//
//  Settings persistence using UserDefaults
//

import Foundation
import Observation
import ServiceManagement
import WisprCore
import os

@MainActor
@Observable
final class SettingsStore {
    // MARK: - Hotkey Settings
    var hotkeyKeyCode: UInt32 {
        didSet {
            guard !isLoading else { return }
            defaults.set(Int(hotkeyKeyCode), forKey: Keys.hotkeyKeyCode)
        }
    }

    var hotkeyModifiers: UInt32 {
        didSet {
            guard !isLoading else { return }
            defaults.set(Int(hotkeyModifiers), forKey: Keys.hotkeyModifiers)
        }
    }

    // MARK: - Audio Settings
    var selectedAudioDeviceUID: String? {
        didSet {
            guard !isLoading else { return }
            defaults.set(selectedAudioDeviceUID, forKey: Keys.selectedAudioDeviceUID)
        }
    }

    // MARK: - Model Settings
    var activeModelName: String {
        didSet {
            guard !isLoading else { return }
            defaults.set(activeModelName, forKey: Keys.activeModelName)
        }
    }

    // MARK: - Language Settings
    var languageMode: TranscriptionLanguage {
        didSet {
            guard !isLoading else { return }
            if let encoded = try? JSONEncoder().encode(languageMode) {
                defaults.set(encoded, forKey: Keys.languageMode)
            }
        }
    }

    // MARK: - General Settings
    var showRecordingOverlay: Bool {
        didSet {
            guard !isLoading else { return }
            defaults.set(showRecordingOverlay, forKey: Keys.showRecordingOverlay)
        }
    }

    var launchAtLogin: Bool {
        didSet {
            guard !isLoading else { return }
            updateLaunchAtLogin(launchAtLogin)
        }
    }

    var onboardingCompleted: Bool {
        didSet {
            guard !isLoading else { return }
            defaults.set(onboardingCompleted, forKey: Keys.onboardingCompleted)
        }
    }

    var onboardingLastStep: Int {
        didSet {
            guard !isLoading else { return }
            defaults.set(onboardingLastStep, forKey: Keys.onboardingLastStep)
        }
    }

    // MARK: - Dictation Mode

    /// When true, hotkey toggles recording on/off (press once to start, press again to stop).
    /// When false, uses push-to-talk (hold to record, release to stop).
    var handsFreeMode: Bool {
        didSet {
            guard !isLoading else { return }
            defaults.set(handsFreeMode, forKey: Keys.handsFreeMode)
        }
    }

    /// When true, the "Others" track is split into per-speaker labels
    /// (Speaker 1, Speaker 2, …) using on-device Sortformer diarization.
    /// Requires a one-time model download (~30 MB). Defaults to false.
    var meetingDiarizationEnabled: Bool {
        didSet {
            guard !isLoading else { return }
            defaults.set(meetingDiarizationEnabled, forKey: Keys.meetingDiarizationEnabled)
        }
    }

    /// When true, microphone transcriptions that duplicate a recent system-audio
    /// ("Others") transcription are suppressed. Without headphones, remote
    /// participants' speech leaks from the speakers into the mic and would
    /// otherwise be transcribed twice (see issue #65). Defaults to true.
    var meetingEchoSuppressionEnabled: Bool {
        didSet {
            guard !isLoading else { return }
            defaults.set(meetingEchoSuppressionEnabled, forKey: Keys.meetingEchoSuppressionEnabled)
        }
    }

    // MARK: - Live-meeting classifier (JuL) Settings

    /// Master switch for the whole Live Meeting Features section (awareness +
    /// bingo, powered by JuL). Opt-in: off by default, so nothing runs and no
    /// server is contacted until the user turns it on.
    var liveMeetingFeaturesEnabled: Bool {
        didSet {
            guard !isLoading else { return }
            defaults.set(liveMeetingFeaturesEnabled, forKey: Keys.liveMeetingFeaturesEnabled)
        }
    }

    /// Whether the awareness feature ("wake me when I'm addressed") is on. On by
    /// default once Live Meeting Features are enabled, but the user can opt out.
    var awarenessEnabled: Bool {
        didSet {
            guard !isLoading else { return }
            defaults.set(awarenessEnabled, forKey: Keys.awarenessEnabled)
        }
    }

    /// Names the awareness feature listens for ("someone is talking about you").
    /// When non-empty and a meeting is running, each sentence is checked against
    /// these names and the user is woken when one is addressed a question or task.
    /// Empty (the default) disables the feature.
    var awarenessMonitoredNames: [String] {
        didSet {
            guard !isLoading else { return }
            defaults.set(awarenessMonitoredNames, forKey: Keys.awarenessMonitoredNames)
        }
    }

    /// When true, the live bullshit-bingo grid is filled during meetings. Off by
    /// default: it is a novelty, not a default behaviour.
    var bingoEnabled: Bool {
        didSet {
            guard !isLoading else { return }
            defaults.set(bingoEnabled, forKey: Keys.bingoEnabled)
        }
    }

    /// The jargon terms shown on the bingo grid, editable by the user. A perfect
    /// square count (e.g. 16) makes the nicest grid, but any count renders.
    var bingoTerms: [String] {
        didSet {
            guard !isLoading else { return }
            defaults.set(bingoTerms, forKey: Keys.bingoTerms)
        }
    }

    /// Base URL of the local JuL server that powers the live features. Editable so
    /// a user can point Wispr at a JuL running on another port or host.
    var julEndpoint: String {
        didSet {
            guard !isLoading else { return }
            defaults.set(julEndpoint, forKey: Keys.julEndpoint)
        }
    }

    /// Optional API key sent as `x-api-key` to the JuL server. Empty means no
    /// authentication (fine for the default localhost server).
    var julApiKey: String {
        didSet {
            guard !isLoading else { return }
            defaults.set(julApiKey, forKey: Keys.julApiKey)
        }
    }

    /// How the awareness feature shows context on a wake. Defaults to showing the
    /// last few transcript lines (no model). Generative summary is opt-in.
    var awarenessSummaryMode: AwarenessSummaryMode {
        didSet {
            guard !isLoading else { return }
            defaults.set(awarenessSummaryMode.rawValue, forKey: Keys.awarenessSummaryMode)
        }
    }

    /// Number of recent transcript lines shown when the mode is `.lastMessages`.
    var awarenessLastMessages: Int {
        didSet {
            guard !isLoading else { return }
            defaults.set(awarenessLastMessages, forKey: Keys.awarenessLastMessages)
        }
    }

    /// Context window in minutes fed to the generative summary (mode `.generative`).
    var awarenessSummaryMinutes: Int {
        didSet {
            guard !isLoading else { return }
            defaults.set(awarenessSummaryMinutes, forKey: Keys.awarenessSummaryMinutes)
        }
    }

    /// Minimum seconds between two awareness wakes (anti-spam).
    var awarenessCooldownSeconds: Int {
        didSet {
            guard !isLoading else { return }
            defaults.set(awarenessCooldownSeconds, forKey: Keys.awarenessCooldownSeconds)
        }
    }

    /// Remembers the last meeting capture mode chosen in the meeting window's
    /// header toggle. `true` means the next meeting defaults to in-person
    /// (mic-only, diarized, no privileged "You"). Defaults to false (online).
    var meetingInPersonMode: Bool {
        didSet {
            guard !isLoading else { return }
            defaults.set(meetingInPersonMode, forKey: Keys.meetingInPersonMode)
        }
    }

    /// When true, plays short audio cues on recording start/stop.
    var soundFeedbackEnabled: Bool {
        didSet {
            guard !isLoading else { return }
            defaults.set(soundFeedbackEnabled, forKey: Keys.soundFeedbackEnabled)
        }
    }

    // MARK: - Meeting Detection

    /// Security-scoped bookmark for the folder meeting transcripts are saved to,
    /// or `nil` to use the app's own container.
    ///
    /// A bookmark rather than a path: the app is sandboxed, so a stored path would
    /// resolve after relaunch to a folder it is no longer allowed to open.
    /// `TranscriptLocation` owns resolving this and holding the sandbox scope.
    var transcriptsFolderBookmark: Data? {
        didSet {
            guard !isLoading else { return }
            if let transcriptsFolderBookmark {
                defaults.set(transcriptsFolderBookmark, forKey: Keys.transcriptsFolderBookmark)
            } else {
                defaults.removeObject(forKey: Keys.transcriptsFolderBookmark)
            }
        }
    }

    /// When true, Wispr watches for another app using the microphone and posts a
    /// notification inviting the user to start meeting transcription.
    var meetingDetectionEnabled: Bool {
        didSet { guard !isLoading else { return }; defaults.set(meetingDetectionEnabled, forKey: Keys.meetingDetectionEnabled) }
    }

    // MARK: - Auto-Suffix Settings

    /// When true, appends `autoSuffixText` to transcribed text before insertion.
    var autoSuffixEnabled: Bool {
        didSet {
            guard !isLoading else { return }
            defaults.set(autoSuffixEnabled, forKey: Keys.autoSuffixEnabled)
        }
    }

    /// The suffix string appended to transcribed text when `autoSuffixEnabled` is true.
    var autoSuffixText: String {
        didSet {
            guard !isLoading else { return }
            defaults.set(autoSuffixText, forKey: Keys.autoSuffixText)
        }
    }

    // MARK: - Filler Word Removal Settings

    /// When true, removes common filler words (um, uh, ah, etc.) from transcriptions before insertion.
    var removeFillerWords: Bool {
        didSet {
            guard !isLoading else { return }
            defaults.set(removeFillerWords, forKey: Keys.removeFillerWords)
        }
    }

    // MARK: - Auto-Send Enter Settings

    /// When true, simulates an Enter/Return keystroke after text insertion.
    var autoSendEnterEnabled: Bool {
        didSet {
            guard !isLoading else { return }
            defaults.set(autoSendEnterEnabled, forKey: Keys.autoSendEnterEnabled)
        }
    }

    // MARK: - AI Text Correction Settings

    /// When true, applies on-device AI text correction after filler word removal.
    var aiTextCorrectionEnabled: Bool {
        didSet {
            guard !isLoading else { return }
            defaults.set(aiTextCorrectionEnabled, forKey: Keys.aiTextCorrectionEnabled)
        }
    }

    /// The correction style used by AI text correction.
    var aiTextCorrectionStyle: CorrectionStyle {
        didSet {
            guard !isLoading else { return }
            if let encoded = try? JSONEncoder().encode(aiTextCorrectionStyle) {
                defaults.set(encoded, forKey: Keys.aiTextCorrectionStyle)
            }
        }
    }

    // MARK: - Custom Vocabulary Settings

    /// When true, transcriptions are corrected against `customVocabulary` so
    /// mis-transcribed proper nouns (client names, etc.) are fixed to their
    /// canonical spelling.
    var customVocabularyEnabled: Bool {
        didSet {
            guard !isLoading else { return }
            defaults.set(customVocabularyEnabled, forKey: Keys.customVocabularyEnabled)
        }
    }

    /// Correctly spelled words the transcription is biased toward (e.g. "kubectl").
    var customVocabulary: [String] {
        didSet {
            guard !isLoading else { return }
            if let encoded = try? JSONEncoder().encode(customVocabulary) {
                defaults.set(encoded, forKey: Keys.customVocabulary)
            }
        }
    }

    // MARK: - UserDefaults Keys
    private enum Keys {
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let selectedAudioDeviceUID = "selectedAudioDeviceUID"
        static let activeModelName = "activeModelName"
        static let languageMode = "languageMode"
        static let showRecordingOverlay = "showRecordingOverlay"
        static let launchAtLogin = "launchAtLogin"
        static let onboardingCompleted = "onboardingCompleted"
        static let onboardingLastStep = "onboardingLastStep"
        static let handsFreeMode = "handsFreeMode"
        static let meetingDiarizationEnabled = "meetingDiarizationEnabled"
        static let meetingEchoSuppressionEnabled = "meetingEchoSuppressionEnabled"
        static let liveMeetingFeaturesEnabled = "liveMeetingFeaturesEnabled"
        static let awarenessEnabled = "awarenessEnabled"
        static let awarenessMonitoredNames = "awarenessMonitoredNames"
        static let bingoEnabled = "bingoEnabled"
        static let bingoTerms = "bingoTerms"
        static let julEndpoint = "julEndpoint"
        static let julApiKey = "julApiKey"
        static let awarenessSummaryMode = "awarenessSummaryMode"
        static let awarenessLastMessages = "awarenessLastMessages"
        static let awarenessSummaryMinutes = "awarenessSummaryMinutes"
        static let awarenessCooldownSeconds = "awarenessCooldownSeconds"
        static let meetingInPersonMode = "meetingInPersonMode"
        static let soundFeedbackEnabled = "soundFeedbackEnabled"
        static let meetingDetectionEnabled = "meetingDetectionEnabled"
        static let transcriptsFolderBookmark = "transcriptsFolderBookmark"
        static let autoSuffixEnabled = "autoSuffixEnabled"
        static let autoSuffixText = "autoSuffixText"
        static let removeFillerWords = "removeFillerWords"
        static let autoSendEnterEnabled = "autoSendEnterEnabled"
        static let aiTextCorrectionEnabled = "aiTextCorrectionEnabled"
        static let aiTextCorrectionStyle = "aiTextCorrectionStyle"
        static let customVocabularyEnabled = "customVocabularyEnabled"
        static let customVocabulary = "customVocabulary"
    }

    // MARK: - Default Values

    /// Single source of truth for all setting defaults.
    /// Referenced by `init`, `restoreDefaults()`, and tests.
    enum Defaults {
        static let hotkeyKeyCode: UInt32 = 49  // Space
        static let hotkeyModifiers: UInt32 = 2048  // Option
        static let selectedAudioDeviceUID: String? = nil
        static let activeModelName: String = ModelInfo.KnownID.tiny
        static let languageMode: TranscriptionLanguage = .autoDetect
        static let showRecordingOverlay: Bool = true
        static let launchAtLogin: Bool = false
        static let onboardingCompleted: Bool = false
        static let onboardingLastStep: Int = 0
        static let handsFreeMode: Bool = false
        static let meetingDiarizationEnabled: Bool = false
        static let meetingEchoSuppressionEnabled: Bool = true
        static let liveMeetingFeaturesEnabled: Bool = false
        static let awarenessEnabled: Bool = true
        static let awarenessMonitoredNames: [String] = []
        static let bingoEnabled: Bool = false
        static let bingoTerms: [String] = BingoConfig.defaultTerms
        static let julEndpoint: String = JulClient.defaultBaseURL
        static let julApiKey: String = ""
        static let awarenessSummaryMode: AwarenessSummaryMode = .lastMessages
        static let awarenessLastMessages: Int = 3
        static let awarenessSummaryMinutes: Int = 5
        static let awarenessCooldownSeconds: Int = 45
        static let meetingInPersonMode: Bool = false
        static let soundFeedbackEnabled: Bool = false
        static let meetingDetectionEnabled: Bool = false
        static let transcriptsFolderBookmark: Data? = nil
        static let autoSuffixEnabled: Bool = false
        static let autoSuffixText: String = " "
        static let removeFillerWords: Bool = false
        static let autoSendEnterEnabled: Bool = false
        static let aiTextCorrectionEnabled: Bool = false
        static let aiTextCorrectionStyle: CorrectionStyle = .minimal
        static let customVocabularyEnabled: Bool = false
        static let customVocabulary: [String] = []
    }

    // MARK: - Dependencies
    private let defaults: UserDefaults
    private var isLoading = false

    // MARK: - Initialization
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Initialize with defaults
        self.hotkeyKeyCode = Defaults.hotkeyKeyCode
        self.hotkeyModifiers = Defaults.hotkeyModifiers
        self.selectedAudioDeviceUID = Defaults.selectedAudioDeviceUID
        self.activeModelName = Defaults.activeModelName
        self.languageMode = Defaults.languageMode
        self.showRecordingOverlay = Defaults.showRecordingOverlay
        self.launchAtLogin = Defaults.launchAtLogin
        self.onboardingCompleted = Defaults.onboardingCompleted
        self.onboardingLastStep = Defaults.onboardingLastStep
        self.handsFreeMode = Defaults.handsFreeMode
        self.meetingDiarizationEnabled = Defaults.meetingDiarizationEnabled
        self.meetingEchoSuppressionEnabled = Defaults.meetingEchoSuppressionEnabled
        self.liveMeetingFeaturesEnabled = Defaults.liveMeetingFeaturesEnabled
        self.awarenessEnabled = Defaults.awarenessEnabled
        self.awarenessMonitoredNames = Defaults.awarenessMonitoredNames
        self.bingoEnabled = Defaults.bingoEnabled
        self.bingoTerms = Defaults.bingoTerms
        self.julEndpoint = Defaults.julEndpoint
        self.julApiKey = Defaults.julApiKey
        self.awarenessSummaryMode = Defaults.awarenessSummaryMode
        self.awarenessLastMessages = Defaults.awarenessLastMessages
        self.awarenessSummaryMinutes = Defaults.awarenessSummaryMinutes
        self.awarenessCooldownSeconds = Defaults.awarenessCooldownSeconds
        self.meetingInPersonMode = Defaults.meetingInPersonMode
        self.soundFeedbackEnabled = Defaults.soundFeedbackEnabled
        self.meetingDetectionEnabled = Defaults.meetingDetectionEnabled
        self.transcriptsFolderBookmark = Defaults.transcriptsFolderBookmark
        self.autoSuffixEnabled = Defaults.autoSuffixEnabled
        self.autoSuffixText = Defaults.autoSuffixText
        self.removeFillerWords = Defaults.removeFillerWords
        self.autoSendEnterEnabled = Defaults.autoSendEnterEnabled
        self.aiTextCorrectionEnabled = Defaults.aiTextCorrectionEnabled
        self.aiTextCorrectionStyle = Defaults.aiTextCorrectionStyle
        self.customVocabularyEnabled = Defaults.customVocabularyEnabled
        self.customVocabulary = Defaults.customVocabulary

        // Load persisted values
        load()
    }

    // MARK: - Restore Defaults

    /// Resets all user-facing settings to their default values.
    /// This is the single source of truth — call this from SettingsView
    /// instead of duplicating default values.
    func restoreDefaults() {
        hotkeyKeyCode = Defaults.hotkeyKeyCode
        hotkeyModifiers = Defaults.hotkeyModifiers
        selectedAudioDeviceUID = Defaults.selectedAudioDeviceUID
        activeModelName = Defaults.activeModelName
        languageMode = Defaults.languageMode
        showRecordingOverlay = Defaults.showRecordingOverlay
        launchAtLogin = Defaults.launchAtLogin
        handsFreeMode = Defaults.handsFreeMode
        meetingDiarizationEnabled = Defaults.meetingDiarizationEnabled
        meetingEchoSuppressionEnabled = Defaults.meetingEchoSuppressionEnabled
        liveMeetingFeaturesEnabled = Defaults.liveMeetingFeaturesEnabled
        awarenessEnabled = Defaults.awarenessEnabled
        awarenessMonitoredNames = Defaults.awarenessMonitoredNames
        bingoEnabled = Defaults.bingoEnabled
        bingoTerms = Defaults.bingoTerms
        julEndpoint = Defaults.julEndpoint
        julApiKey = Defaults.julApiKey
        awarenessSummaryMode = Defaults.awarenessSummaryMode
        awarenessLastMessages = Defaults.awarenessLastMessages
        awarenessSummaryMinutes = Defaults.awarenessSummaryMinutes
        awarenessCooldownSeconds = Defaults.awarenessCooldownSeconds
        meetingInPersonMode = Defaults.meetingInPersonMode
        soundFeedbackEnabled = Defaults.soundFeedbackEnabled
        meetingDetectionEnabled = Defaults.meetingDetectionEnabled
        // Files already written to a custom folder are left where they are; only
        // the destination for new transcripts returns to the app container.
        transcriptsFolderBookmark = Defaults.transcriptsFolderBookmark
        TranscriptLocation.useDefault()
        autoSuffixEnabled = Defaults.autoSuffixEnabled
        autoSuffixText = Defaults.autoSuffixText
        removeFillerWords = Defaults.removeFillerWords
        autoSendEnterEnabled = Defaults.autoSendEnterEnabled
        aiTextCorrectionEnabled = Defaults.aiTextCorrectionEnabled
        aiTextCorrectionStyle = Defaults.aiTextCorrectionStyle
        customVocabularyEnabled = Defaults.customVocabularyEnabled
        customVocabulary = Defaults.customVocabulary
    }

    // MARK: - Persistence

    /// Persists all current values to UserDefaults without forcing a disk flush.
    /// Safe to call frequently — each `defaults.set` is cheap (in-memory update
    /// that the system coalesces and writes to disk on its own schedule).
    func save() {
        guard !isLoading else { return }

        defaults.set(Int(hotkeyKeyCode), forKey: Keys.hotkeyKeyCode)
        defaults.set(Int(hotkeyModifiers), forKey: Keys.hotkeyModifiers)
        defaults.set(selectedAudioDeviceUID, forKey: Keys.selectedAudioDeviceUID)
        defaults.set(activeModelName, forKey: Keys.activeModelName)
        defaults.set(showRecordingOverlay, forKey: Keys.showRecordingOverlay)
        defaults.set(onboardingCompleted, forKey: Keys.onboardingCompleted)
        defaults.set(onboardingLastStep, forKey: Keys.onboardingLastStep)
        defaults.set(handsFreeMode, forKey: Keys.handsFreeMode)
        defaults.set(meetingDiarizationEnabled, forKey: Keys.meetingDiarizationEnabled)
        defaults.set(meetingEchoSuppressionEnabled, forKey: Keys.meetingEchoSuppressionEnabled)
        defaults.set(liveMeetingFeaturesEnabled, forKey: Keys.liveMeetingFeaturesEnabled)
        defaults.set(awarenessEnabled, forKey: Keys.awarenessEnabled)
        defaults.set(awarenessMonitoredNames, forKey: Keys.awarenessMonitoredNames)
        defaults.set(bingoEnabled, forKey: Keys.bingoEnabled)
        defaults.set(bingoTerms, forKey: Keys.bingoTerms)
        defaults.set(julEndpoint, forKey: Keys.julEndpoint)
        defaults.set(julApiKey, forKey: Keys.julApiKey)
        defaults.set(awarenessSummaryMode.rawValue, forKey: Keys.awarenessSummaryMode)
        defaults.set(awarenessLastMessages, forKey: Keys.awarenessLastMessages)
        defaults.set(awarenessSummaryMinutes, forKey: Keys.awarenessSummaryMinutes)
        defaults.set(awarenessCooldownSeconds, forKey: Keys.awarenessCooldownSeconds)
        defaults.set(meetingInPersonMode, forKey: Keys.meetingInPersonMode)
        defaults.set(soundFeedbackEnabled, forKey: Keys.soundFeedbackEnabled)
        defaults.set(meetingDetectionEnabled, forKey: Keys.meetingDetectionEnabled)
        defaults.set(autoSuffixEnabled, forKey: Keys.autoSuffixEnabled)
        defaults.set(autoSuffixText, forKey: Keys.autoSuffixText)
        defaults.set(removeFillerWords, forKey: Keys.removeFillerWords)
        defaults.set(autoSendEnterEnabled, forKey: Keys.autoSendEnterEnabled)
        defaults.set(aiTextCorrectionEnabled, forKey: Keys.aiTextCorrectionEnabled)
        defaults.set(customVocabularyEnabled, forKey: Keys.customVocabularyEnabled)

        if let encoded = try? JSONEncoder().encode(languageMode) {
            defaults.set(encoded, forKey: Keys.languageMode)
        }

        if let encoded = try? JSONEncoder().encode(aiTextCorrectionStyle) {
            defaults.set(encoded, forKey: Keys.aiTextCorrectionStyle)
        }

        if let encoded = try? JSONEncoder().encode(customVocabulary) {
            defaults.set(encoded, forKey: Keys.customVocabulary)
        }
    }

    /// Persists all values and forces cfprefsd to flush to disk immediately.
    /// Only call this at critical moments (app termination, onboarding completion)
    /// where an abrupt process exit could lose in-memory changes.
    func flush() {
        save()
        defaults.synchronize()
    }

    func load() {
        isLoading = true
        defer { isLoading = false }

        // Load hotkey settings
        let storedKeyCode = defaults.integer(forKey: Keys.hotkeyKeyCode)
        if storedKeyCode != 0 || defaults.object(forKey: Keys.hotkeyKeyCode) != nil {
            self.hotkeyKeyCode = UInt32(storedKeyCode)
        }

        let storedModifiers = defaults.integer(forKey: Keys.hotkeyModifiers)
        if storedModifiers != 0 || defaults.object(forKey: Keys.hotkeyModifiers) != nil {
            self.hotkeyModifiers = UInt32(storedModifiers)
        }

        // Load audio settings
        self.selectedAudioDeviceUID = defaults.string(forKey: Keys.selectedAudioDeviceUID)

        // Load model settings
        if let modelName = defaults.string(forKey: Keys.activeModelName) {
            self.activeModelName = modelName
        }

        // Load language mode
        if let data = defaults.data(forKey: Keys.languageMode),
            let decoded = try? JSONDecoder().decode(TranscriptionLanguage.self, from: data)
        {
            self.languageMode = decoded
        }

        // Load general settings
        if defaults.object(forKey: Keys.showRecordingOverlay) != nil {
            self.showRecordingOverlay = defaults.bool(forKey: Keys.showRecordingOverlay)
        }
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.onboardingCompleted = defaults.bool(forKey: Keys.onboardingCompleted)

        self.onboardingLastStep = defaults.integer(forKey: Keys.onboardingLastStep)

        if defaults.object(forKey: Keys.handsFreeMode) != nil {
            self.handsFreeMode = defaults.bool(forKey: Keys.handsFreeMode)
        }

        if defaults.object(forKey: Keys.meetingDiarizationEnabled) != nil {
            self.meetingDiarizationEnabled = defaults.bool(forKey: Keys.meetingDiarizationEnabled)
        }

        if defaults.object(forKey: Keys.meetingEchoSuppressionEnabled) != nil {
            self.meetingEchoSuppressionEnabled = defaults.bool(
                forKey: Keys.meetingEchoSuppressionEnabled)
        }

        if defaults.object(forKey: Keys.liveMeetingFeaturesEnabled) != nil {
            self.liveMeetingFeaturesEnabled = defaults.bool(forKey: Keys.liveMeetingFeaturesEnabled)
        }

        if defaults.object(forKey: Keys.awarenessEnabled) != nil {
            self.awarenessEnabled = defaults.bool(forKey: Keys.awarenessEnabled)
        }

        if let names = defaults.stringArray(forKey: Keys.awarenessMonitoredNames) {
            self.awarenessMonitoredNames = names
        }

        if defaults.object(forKey: Keys.bingoEnabled) != nil {
            self.bingoEnabled = defaults.bool(forKey: Keys.bingoEnabled)
        }

        if let terms = defaults.stringArray(forKey: Keys.bingoTerms) {
            self.bingoTerms = terms
        }

        if let endpoint = defaults.string(forKey: Keys.julEndpoint), !endpoint.isEmpty {
            self.julEndpoint = endpoint
        }

        if let key = defaults.string(forKey: Keys.julApiKey) {
            self.julApiKey = key
        }

        if let raw = defaults.string(forKey: Keys.awarenessSummaryMode),
           let mode = AwarenessSummaryMode(rawValue: raw) {
            self.awarenessSummaryMode = mode
        }
        if defaults.object(forKey: Keys.awarenessLastMessages) != nil {
            self.awarenessLastMessages = defaults.integer(forKey: Keys.awarenessLastMessages)
        }
        if defaults.object(forKey: Keys.awarenessSummaryMinutes) != nil {
            self.awarenessSummaryMinutes = defaults.integer(forKey: Keys.awarenessSummaryMinutes)
        }
        if defaults.object(forKey: Keys.awarenessCooldownSeconds) != nil {
            self.awarenessCooldownSeconds = defaults.integer(forKey: Keys.awarenessCooldownSeconds)
        }

        if defaults.object(forKey: Keys.meetingInPersonMode) != nil {
            self.meetingInPersonMode = defaults.bool(forKey: Keys.meetingInPersonMode)
        }

        if defaults.object(forKey: Keys.soundFeedbackEnabled) != nil {
            self.soundFeedbackEnabled = defaults.bool(forKey: Keys.soundFeedbackEnabled)
        }

        if defaults.object(forKey: Keys.meetingDetectionEnabled) != nil {
            self.meetingDetectionEnabled = defaults.bool(forKey: Keys.meetingDetectionEnabled)
        }

        self.transcriptsFolderBookmark = defaults.data(forKey: Keys.transcriptsFolderBookmark)

        // Load auto-suffix settings
        if defaults.object(forKey: Keys.autoSuffixEnabled) != nil {
            self.autoSuffixEnabled = defaults.bool(forKey: Keys.autoSuffixEnabled)
        }

        if let suffixText = defaults.string(forKey: Keys.autoSuffixText) {
            self.autoSuffixText = suffixText
        }

        // Load filler word removal setting
        if defaults.object(forKey: Keys.removeFillerWords) != nil {
            self.removeFillerWords = defaults.bool(forKey: Keys.removeFillerWords)
        }

        // Load auto-send Enter settings
        if defaults.object(forKey: Keys.autoSendEnterEnabled) != nil {
            self.autoSendEnterEnabled = defaults.bool(forKey: Keys.autoSendEnterEnabled)
        }

        // Load AI text correction settings
        if defaults.object(forKey: Keys.aiTextCorrectionEnabled) != nil {
            self.aiTextCorrectionEnabled = defaults.bool(forKey: Keys.aiTextCorrectionEnabled)
        }

        if let data = defaults.data(forKey: Keys.aiTextCorrectionStyle),
            let decoded = try? JSONDecoder().decode(CorrectionStyle.self, from: data)
        {
            self.aiTextCorrectionStyle = decoded
        }

        // Load custom vocabulary settings
        if defaults.object(forKey: Keys.customVocabularyEnabled) != nil {
            self.customVocabularyEnabled = defaults.bool(forKey: Keys.customVocabularyEnabled)
        }

        if let data = defaults.data(forKey: Keys.customVocabulary),
            let decoded = try? JSONDecoder().decode([String].self, from: data)
        {
            self.customVocabulary = decoded
        }
    }

    // MARK: - Launch at Login

    /// Registers or unregisters the app as a login item using ServiceManagement.
    /// After the operation, reads back the actual system state so the toggle
    /// always reflects reality.
    /// Requirements: 10.3, 10.4
    func updateLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                // unregister() throws if the app was never registered — that's
                // not a real failure, the desired state (not registered) is already true.
                if service.status != .notRegistered {
                    try service.unregister()
                }
            }
        } catch {
            Log.app.error("Failed to \(enabled ? "register" : "unregister") login item: \(error)")
        }

        // Always sync back to the actual system state.
        // The source of truth for launch-at-login is ServiceManagement, not UserDefaults,
        // so no explicit defaults.set is needed — load() reads from SMAppService.mainApp.status.
        let actualState = service.status == .enabled
        if launchAtLogin != actualState {
            isLoading = true
            launchAtLogin = actualState
            isLoading = false
        }
    }
}

// MARK: - Observation Helpers

extension SettingsStore {

    /// An `AsyncStream` that yields once each time any value read inside
    /// `track` changes.
    ///
    /// Observation is re-armed from *within* the change handler rather than
    /// after the consumer's async work, so a change that lands while the
    /// consumer is awaiting is not missed — unlike a bare
    /// `withObservationTracking` loop that only re-registers once its async body
    /// returns. Centralizes the observation idiom that would otherwise be
    /// duplicated across observers.
    nonisolated func changes(
        tracking track: @escaping @MainActor @Sendable () -> Void
    ) -> AsyncStream<Void> {
        AsyncStream { continuation in
            @Sendable func arm() {
                Task { @MainActor in
                    withObservationTracking {
                        track()
                    } onChange: {
                        continuation.yield(())
                        arm()
                    }
                }
            }
            arm()
        }
    }
}
