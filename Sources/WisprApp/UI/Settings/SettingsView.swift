//
//  SettingsView.swift
//  wispr
//
//  SwiftUI settings view with sections for Shortcut, Audio Device,
//  Recognition, After Transcription, Feedback, and General.
//

import SwiftUI
import WisprCore
import os

// MARK: - Reusable Components

private struct SectionHeader: View {
    let title: String
    let systemImage: String
    let tint: Color

    @ScaledMetric(relativeTo: .headline) private var iconSize = 18.0

    var body: some View {
        Label {
            Text(title)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(tint.gradient)
        }
    }
}

// MARK: - SettingsView

struct SettingsView: View {

    // MARK: Accessibility Hints

    /// Shared hint strings so tests can assert against the same values the view uses.
    enum AccessibilityHints {
        // Shortcut section
        static let hotkeyShortcut = "Activate to record a new hotkey combination"
        static let handsFreeMode =
            "When enabled, press the hotkey once to start recording and again to stop. When disabled, hold the hotkey to record."

        // Audio Device section
        static let inputDevice = "Select the microphone to use for recording"

        // Recognition section
        static let activeModel = "Select the speech recognition model to use"
        static let autoDetectLanguage =
            "When enabled, Wispr automatically detects the spoken language"
        static let languagePicker = "Select the language for speech transcription"
        static let alwaysUseLanguage =
            "When enabled, always transcribes in the selected language instead of detecting per-recording"

        // After Transcription section
        static let removeFillerWords =
            "When enabled, removes filler words like um, uh, and ah from transcriptions"
        static let aiTextCorrection =
            "When enabled, uses on-device AI to correct grammar and improve transcription fluency. All processing stays on your Mac."
        static let autoInsertSuffix = "When enabled, appends a suffix to transcribed text"
        static let autoSendEnter = "When enabled, simulates pressing Enter after text insertion"
        static let customVocabulary =
            "When enabled, corrects mis-transcribed proper nouns like client names to the spelling you provide"

        // Feedback section
        static let soundFeedback = "When enabled, plays audio cues when recording starts and stops"
        static let showRecordingOverlay = "When enabled, a floating overlay appears while recording"
        static let meetingDetection = "When enabled, Wispr notifies you when another app starts using your microphone so you can start meeting transcription in one click"

        // Meeting section
        static let meetingDiarization =
            "When enabled, the meeting transcript labels remote participants as Speaker 1, Speaker 2, and so on using on-device diarization"
        static let meetingEchoSuppression =
            "When enabled, speech from remote participants that leaks into your microphone is not transcribed a second time as your own speech"
        static let openTranscriptsFolder =
            "Opens the folder where saved meeting transcripts are stored in Finder"
        static let changeTranscriptsFolder =
            "Choose a different folder for Wispr to save new meeting transcripts in"
        static let resetTranscriptsFolder =
            "Saves new meeting transcripts inside Wispr's own folder again"

        // General section
        static let launchAtLogin = "When enabled, Wispr starts automatically when you log in"
        static let restoreDefaults = "Resets all settings to their original values"
    }
    @Environment(SettingsStore.self) private var settingsStore: SettingsStore
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine
    @Environment(UpdateChecker.self) private var updateChecker: UpdateChecker
    @Environment(StateManager.self) private var stateManager: StateManager
    @Environment(HotkeyMonitor.self) private var hotkeyMonitor: HotkeyMonitor
    @Environment(TextCorrectionService.self) private var textCorrectionService:
        TextCorrectionService
    @Environment(\.openURL) private var openURL

    @State private var audioDevices: [AudioInputDevice] = []
    @State private var whisperModels: [ModelInfo] = []
    @State private var isRecordingHotkey = false
    @State private var hotkeyError: String?
    @State private var showRestoreDefaultsAlert = false

    /// Live JuL server reachability for the Live Meeting Features badge.
    @State private var julReachable = false
    @State private var julModel: String?
    @State private var julVerifying = false
    @State private var julVerifyMessage: String?
    /// Expansion state of the collapsible Advanced and install-guide groups.
    @State private var showJulAdvanced = false
    @State private var showJulInstall = false
    /// Bumping this restarts the `.task` probe; kept constant so the probe loop
    /// runs for the lifetime of the view.
    @State private var julProbeTick = 0

    /// Surfaced when a chosen transcripts folder could not be used, so the app
    /// silently falling back to the default location is visible rather than
    /// looking like the setting was ignored.
    @State private var transcriptsFolderError: String?

    /// The model ID currently being activated from the Settings picker.
    @State private var activatingModelId: String?

    /// Local selection state for the model picker, synced via .onChange/.task.
    @State private var selectedModelId: String = ""

    private let audioEngine: AudioEngine
    private let whisperService: any TranscriptionEngine

    init(audioEngine: AudioEngine, whisperService: any TranscriptionEngine) {
        self.audioEngine = audioEngine
        self.whisperService = whisperService
    }

    var body: some View {
        Form {
            shortcutSection
            audioDeviceSection
            recognitionSection
            afterTranscriptionSection
            feedbackSection
            meetingSection
            liveFeaturesSection
            generalSection
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(maxHeight: 600)
        .liquidGlassPanel()
        .alert("Restore Defaults?", isPresented: $showRestoreDefaultsAlert) {
            Button("Restore", role: .destructive, action: restoreDefaults)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All settings will be reset to their original values. This cannot be undone.")
        }
        .task {
            selectedModelId = settingsStore.activeModelName
            await loadAudioDevices()
            await loadWhisperModels()
        }
        .onChange(of: isRecordingHotkey) { _, recording in
            if recording {
                hotkeyMonitor.unregister()
            } else {
                do {
                    try hotkeyMonitor.register(
                        keyCode: settingsStore.hotkeyKeyCode,
                        modifiers: settingsStore.hotkeyModifiers
                    )
                    hotkeyError = nil
                } catch {
                    hotkeyError = error.localizedDescription
                    Log.hotkey.error(
                        "Settings — failed to re-register hotkey: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Shortcut Section

    private var shortcutSection: some View {
        Section {
            LabeledContent("Shortcut") {
                HotkeyRecorderView(
                    keyCode: Bindable(settingsStore).hotkeyKeyCode,
                    modifiers: Bindable(settingsStore).hotkeyModifiers,
                    isRecording: $isRecordingHotkey,
                    errorMessage: $hotkeyError
                )
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Hotkey shortcut")
            .accessibilityHint(AccessibilityHints.hotkeyShortcut)

            if let error = hotkeyError {
                Label(error, systemImage: theme.actionSymbol(.warning))
                    .foregroundStyle(theme.errorColor)
                    .font(.callout)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if settingsStore.hotkeyKeyCode == HotkeyMonitor.fnKeyCode
                && settingsStore.hotkeyModifiers == 0
            {
                Label {
                    Text(
                        "The Globe key may conflict with macOS features like the emoji picker or input source switching. If dictation doesn't start, go to System Settings → Keyboard → \"Press 🌐 key to\" and select \"Do Nothing\"."
                    )
                } icon: {
                    Image(systemName: SFSymbols.info)
                        .foregroundStyle(.blue)
                }
                .font(.caption)
            }

            @Bindable var store = settingsStore
            Toggle("Hands-Free Mode", isOn: $store.handsFreeMode)
                .accessibilityHint(AccessibilityHints.handsFreeMode)

        } header: {
            SectionHeader(
                title: "Shortcut",
                systemImage: SFSymbols.keyboard,
                tint: .orange
            )
        }
        .motionRespectingAnimation(value: hotkeyError)
    }

    // MARK: - Audio Device Section

    private var audioDeviceSection: some View {
        Section {
            if audioDevices.isEmpty {
                Text("No audio input devices found")
                    .foregroundStyle(.secondary)
            } else {
                @Bindable var store = settingsStore
                Picker("Input Device", selection: $store.selectedAudioDeviceUID) {
                    Text("System Default")
                        .tag(nil as String?)
                    ForEach(audioDevices) { device in
                        Text(device.name)
                            .tag(device.uid as String?)
                    }
                }
                .accessibilityHint(AccessibilityHints.inputDevice)
            }
        } header: {
            SectionHeader(
                title: "Audio Device",
                systemImage: theme.actionSymbol(.microphone),
                tint: .blue
            )
        }
    }

    // MARK: - Recognition Section

    private var availableModels: [ModelInfo] {
        whisperModels.filter { $0.status == .downloaded || $0.status == .active }
    }

    private var recognitionSection: some View {
        Section {
            if availableModels.isEmpty {
                Text("No models downloaded")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Active Model", selection: $selectedModelId) {
                    ForEach(availableModels) { model in
                        HStack {
                            Text(model.displayName)
                            Text("(\(model.sizeDescription))")
                                .foregroundStyle(.secondary)
                        }
                        .tag(model.id)
                    }
                }
                .disabled(activatingModelId != nil)
                .overlay(alignment: .trailing) {
                    if activatingModelId != nil {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 4)
                    }
                }
                .accessibilityHint(AccessibilityHints.activeModel)
                .onChange(of: selectedModelId) { _, newModelId in
                    guard newModelId != settingsStore.activeModelName,
                        !newModelId.isEmpty
                    else { return }
                    activatingModelId = newModelId
                }
                .task(id: activatingModelId) {
                    guard let modelId = activatingModelId else { return }
                    do {
                        try await stateManager.switchActiveModel(to: modelId)
                    } catch {
                        selectedModelId = settingsStore.activeModelName
                    }
                    await loadWhisperModels()
                    activatingModelId = nil
                }
                .onChange(of: settingsStore.activeModelName) { _, newName in
                    guard activatingModelId == nil else { return }
                    selectedModelId = newName
                }
            }

            Toggle("Auto-Detect Language", isOn: autoDetectBinding)
                .accessibilityHint(AccessibilityHints.autoDetectLanguage)

            if !settingsStore.languageMode.isAutoDetect {
                Picker("Language", selection: selectedLanguageCodeBinding) {
                    ForEach(SupportedLanguage.all) { lang in
                        Text(lang.name).tag(lang.id)
                    }
                }
                .accessibilityHint(AccessibilityHints.languagePicker)

                Toggle("Always use this language", isOn: pinLanguageBinding)
                    .accessibilityHint(AccessibilityHints.alwaysUseLanguage)
            }
        } header: {
            SectionHeader(
                title: "Recognition",
                systemImage: theme.actionSymbol(.model),
                tint: .purple
            )
        }
        .motionRespectingAnimation(value: settingsStore.languageMode.isAutoDetect)
    }

    // MARK: - After Transcription Section

    private var afterTranscriptionSection: some View {
        Section {
            @Bindable var store = settingsStore
            Toggle("Remove Filler Words", isOn: $store.removeFillerWords)
                .accessibilityHint(AccessibilityHints.removeFillerWords)

            Toggle("Local AI Text Correction", isOn: $store.aiTextCorrectionEnabled)
                .disabled(textCorrectionService.availability != .available)
                .accessibilityHint(AccessibilityHints.aiTextCorrection)
                .onAppear { textCorrectionService.checkAvailability() }

            if case .notAvailable(let reason) = textCorrectionService.availability {
                Label(reason, systemImage: SFSymbols.info)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Correction style picker hidden — fullRephrase mode not reliable with
            // Apple's on-device model (interprets input as instructions instead of
            // correcting it). Keeping the code for when the model improves.
            // if settingsStore.aiTextCorrectionEnabled, textCorrectionService.availability == .available {
            //     Picker("Correction Style", selection: $store.aiTextCorrectionStyle) {
            //         ForEach(CorrectionStyle.allCases, id: \.self) { style in
            //             Text(style.displayName).tag(style)
            //         }
            //     }
            // }

            Toggle("Custom Vocabulary", isOn: $store.customVocabularyEnabled)
                .accessibilityHint(AccessibilityHints.customVocabulary)

            if settingsStore.customVocabularyEnabled {
                VocabularyEditorView(vocabulary: $store.customVocabulary)
            }

            Toggle("Auto-Insert Suffix", isOn: $store.autoSuffixEnabled)
                .accessibilityHint(AccessibilityHints.autoInsertSuffix)

            if settingsStore.autoSuffixEnabled {
                LabeledContent("Suffix") {
                    SuffixEditorView(suffixText: $store.autoSuffixText)
                }
            }

            Toggle("Auto-Send Enter", isOn: $store.autoSendEnterEnabled)
                .accessibilityHint(AccessibilityHints.autoSendEnter)
        } header: {
            SectionHeader(
                title: "After Transcription",
                systemImage: SFSymbols.textOutput,
                tint: .teal
            )
        }
        .motionRespectingAnimation(value: settingsStore.autoSuffixEnabled)
        .motionRespectingAnimation(value: settingsStore.aiTextCorrectionEnabled)
        .motionRespectingAnimation(value: settingsStore.customVocabularyEnabled)
    }

    // MARK: - Feedback Section

    private var feedbackSection: some View {
        Section {
            @Bindable var store = settingsStore
            Toggle("Sound Feedback", isOn: $store.soundFeedbackEnabled)
                .accessibilityHint(AccessibilityHints.soundFeedback)

            Toggle("Show Recording Overlay", isOn: $store.showRecordingOverlay)
                .accessibilityHint(AccessibilityHints.showRecordingOverlay)

            Toggle("Detect Meetings", isOn: $store.meetingDetectionEnabled)
                .accessibilityHint(AccessibilityHints.meetingDetection)
        } header: {
            SectionHeader(
                title: "Feedback",
                systemImage: SFSymbols.feedback,
                tint: .mint
            )
        }
    }

    // MARK: - Meeting Section

    private var meetingSection: some View {
        Section {
            @Bindable var store = settingsStore
            Toggle("Identify Individual Speakers", isOn: $store.meetingDiarizationEnabled)
                .accessibilityHint(AccessibilityHints.meetingDiarization)

            Text(
                "Splits the \"Others\" track into Speaker 1, Speaker 2, … using on-device diarization. Downloads a small model on first use. Experimental."
            )
            .font(.caption)
            .foregroundStyle(theme.secondaryTextColor)

            Toggle("Suppress Microphone Echo", isOn: $store.meetingEchoSuppressionEnabled)
                .accessibilityHint(AccessibilityHints.meetingEchoSuppression)

            Text(
                "Avoids transcribing remote participants twice when their voice leaks from your speakers into the microphone. Turn off if you use headphones and want every microphone word kept."
            )
            .font(.caption)
            .foregroundStyle(theme.secondaryTextColor)

            HStack {
                Text("Saved Transcripts")
                    .foregroundStyle(theme.primaryTextColor)
                Spacer()
                Button("Change…") {
                    chooseTranscriptsFolder()
                }
                .accessibilityHint(AccessibilityHints.changeTranscriptsFolder)
                if hasCustomTranscriptsFolder {
                    Button("Use Default") {
                        resetTranscriptsFolder()
                    }
                    .accessibilityHint(AccessibilityHints.resetTranscriptsFolder)
                }
                Button("Open Folder") {
                    openTranscriptsFolder()
                }
                .accessibilityHint(AccessibilityHints.openTranscriptsFolder)
            }

            Text(transcriptsFolderPath)
                .font(.caption)
                .foregroundStyle(theme.secondaryTextColor)
                .textSelection(.enabled)
                .accessibilityLabel("Transcripts are saved to \(transcriptsFolderPath)")

            Text(
                "New transcripts are saved here. Changing the folder leaves transcripts already saved elsewhere where they are, so they no longer appear in the meeting history."
            )
            .font(.caption)
            .foregroundStyle(theme.secondaryTextColor)

            if let transcriptsFolderError {
                Label(transcriptsFolderError, systemImage: SFSymbols.warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Transcripts folder problem: \(transcriptsFolderError)")
            }
        } header: {
            SectionHeader(
                title: "Meeting",
                systemImage: SFSymbols.meeting,
                tint: .indigo
            )
        }
    }

    // MARK: - Live Meeting Features Section (JuL)

    /// Awareness ("someone is talking about you") and bullshit bingo. Both send
    /// each transcript sentence to a local JuL server (`jul serve`) during a
    /// meeting; when JuL is not running they simply stay inert.
    private var liveFeaturesSection: some View {
        Section {
            @Bindable var store = settingsStore

            // 0. Master switch — opt-in. The whole feature set is off by default.
            Toggle(isOn: $store.liveMeetingFeaturesEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable Live Meeting Features")
                        .foregroundStyle(theme.primaryTextColor)
                    Text("On-device meeting awareness and bingo, powered by JuL. Off by default.")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryTextColor)
                }
            }
            .accessibilityHint("Master switch for the awareness and bingo features.")

            if store.liveMeetingFeaturesEnabled {
                liveFeaturesBody(store: store)
            }
        } header: {
            SectionHeader(
                title: "Live Meeting Features",
                systemImage: "brain.head.profile",
                tint: .purple
            )
        }
        .task(id: julProbeTick) { await probeJul() }
    }

    /// The section body, shown only when the master switch is on.
    @ViewBuilder private func liveFeaturesBody(store storeParam: SettingsStore) -> some View {
        @Bindable var store = storeParam
        Group {
            // 1. Status + install guidance (for everyone).
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Powered by JuL (on-device)", systemImage: "cpu")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(theme.primaryTextColor)
                    Spacer()
                    JulStatusBadge(isReachable: julReachable, modelName: julModel)
                }
                if !julReachable {
                    DisclosureGroup(isExpanded: $showJulInstall) {
                        julInstallGuide
                    } label: {
                        Label("How to install & run JuL", systemImage: "questionmark.circle")
                            .font(.caption)
                    }
                } else {
                    Text("Audio and text stay on this Mac. These features are inert while JuL is not running.")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryTextColor)
                }
            }
            .padding(.vertical, 2)

            Divider()

            // 2. Awareness — toggle + names.
            Toggle(isOn: $store.awarenessEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wake me when I'm addressed")
                        .foregroundStyle(theme.primaryTextColor)
                    Text("Notification + haptic when someone addresses you a question or a task by name. Works in French and English.")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryTextColor)
                }
            }
            .accessibilityHint("Wakes you when you are addressed during a meeting.")

            if store.awarenessEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    NameChipsEditor(names: $store.awarenessMonitoredNames)
                    if store.awarenessMonitoredNames.isEmpty {
                        Text("Add at least one name for this to do anything.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.leading, 4)

                // 3. Context mode — how much to show on a wake.
                if !store.awarenessMonitoredNames.isEmpty {
                    contextModePicker(store: store)

                    // Anti-spam cooldown between wakes.
                    VStack(alignment: .leading, spacing: 2) {
                        Stepper(value: $store.awarenessCooldownSeconds, in: 0...300, step: 15) {
                            Text(store.awarenessCooldownSeconds == 0
                                 ? "Wake me every time"
                                 : "Wait \(cooldownLabel(store.awarenessCooldownSeconds)) between wakes")
                                .font(.caption)
                        }
                        Text("Avoids repeated buzzes when you're addressed several times in a row.")
                            .font(.caption2)
                            .foregroundStyle(theme.secondaryTextColor)
                    }
                    .padding(.leading, 4)
                }
            }

            Divider()

            // 4. Bingo.
            Toggle(isOn: $store.bingoEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live Bullshit Bingo")
                        .foregroundStyle(theme.primaryTextColor)
                    Text("A jargon grid in the menu bar that lights up as buzzwords are heard.")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryTextColor)
                }
            }
            .accessibilityHint("Fills a jargon bingo grid in the menu bar during a meeting.")

            if store.bingoEnabled {
                BingoTermsEditor(terms: $store.bingoTerms)
                    .padding(.leading, 4)
            }

            // 5. Advanced — server config, collapsed by default.
            DisclosureGroup(isExpanded: $showJulAdvanced) {
                advancedServerConfig(store: store)
            } label: {
                Label("Advanced", systemImage: "gearshape.2")
                    .font(.caption)
            }
        }
    }

    // MARK: - Live features sub-views

    /// Human label for a cooldown in seconds: "45 s" or "2 min".
    private func cooldownLabel(_ seconds: Int) -> String {
        seconds % 60 == 0 && seconds >= 60 ? "\(seconds / 60) min" : "\(seconds) s"
    }

    /// The context mode picker: last N messages (default) vs on-device generative
    /// summary (opt-in), with the relevant sizing control shown inline.
    @ViewBuilder private func contextModePicker(store: SettingsStore) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("When woken, show me")
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.secondaryTextColor)

            Picker("Context", selection: Bindable(store).awarenessSummaryMode) {
                Text("The last messages").tag(AwarenessSummaryMode.lastMessages)
                Text("A short AI summary").tag(AwarenessSummaryMode.generative)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch store.awarenessSummaryMode {
            case .lastMessages:
                Stepper(value: Bindable(store).awarenessLastMessages, in: 1...10) {
                    Text("Show the last \(store.awarenessLastMessages) message\(store.awarenessLastMessages == 1 ? "" : "s")")
                        .font(.caption)
                }
                Text("No AI, no extra processing — just the recent transcript lines.")
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryTextColor)

            case .generative:
                if AwarenessSummarizer.isAvailable {
                    Stepper(value: Bindable(store).awarenessSummaryMinutes, in: 1...10) {
                        Text("Summarize the last \(store.awarenessSummaryMinutes) minute\(store.awarenessSummaryMinutes == 1 ? "" : "s")")
                            .font(.caption)
                    }
                    Text("A short brief (2–3 sentences) generated on-device by Apple Intelligence, covering what you're asked and the context. Nothing leaves your Mac.")
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryTextColor)
                } else {
                    Label(AwarenessSummarizer.unavailabilityReason ?? "Apple Intelligence is unavailable.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("Falls back to showing the last \(store.awarenessLastMessages) messages until it's available.")
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryTextColor)
                }
            }
        }
        .padding(.leading, 4)
        .padding(.top, 2)
    }

    /// Advanced server configuration: endpoint URL, API key, verify. Collapsed.
    @ViewBuilder private func advancedServerConfig(store: SettingsStore) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("JuL endpoint")
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.secondaryTextColor)
            HStack(spacing: 6) {
                TextField("http://127.0.0.1:8577", text: Bindable(store).julEndpoint)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .accessibilityLabel("JuL endpoint URL")
                Button {
                    Task { await verifyJul() }
                } label: {
                    if julVerifying { ProgressView().controlSize(.small) } else { Text("Verify") }
                }
                .disabled(julVerifying)
                Button("Default") {
                    store.julEndpoint = JulClient.defaultBaseURL
                    Task { await verifyJul() }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "key.fill").foregroundStyle(.secondary).font(.caption)
                SecureField("API key (optional — leave empty for local)", text: Bindable(store).julApiKey)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("JuL API key")
            }
            if let julVerifyMessage {
                Text(julVerifyMessage)
                    .font(.caption)
                    .foregroundStyle(julReachable ? theme.successColor : theme.secondaryTextColor)
            }
            Text("Change the endpoint only if JuL runs on another port or machine. A key is required when it is not on 127.0.0.1.")
                .font(.caption2)
                .foregroundStyle(theme.secondaryTextColor)
        }
        .padding(.leading, 4)
    }

    /// Step-by-step guidance to install and run JuL, for non-technical users.
    @ViewBuilder private var julInstallGuide: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("JuL is a tiny local program that powers these features. It runs entirely on your Mac. To set it up once:")
                .font(.caption)
                .foregroundStyle(theme.secondaryTextColor)

            installStep(1, "Open the Terminal app (in Applications ▸ Utilities).")
            installStep(2, "Install JuL — paste this and press Return:",
                        command: "pip3 install jul")
            installStep(3, "Download the model and check it works (a few GB, once):",
                        command: "jul setup")
            installStep(4, "Start the server — leave this window open during meetings:",
                        command: "jul serve")

            Text("Once it says “listening on http://127.0.0.1:8577”, come back here — the badge above turns green.")
                .font(.caption2)
                .foregroundStyle(theme.secondaryTextColor)
        }
        .padding(.top, 4)
    }

    @ViewBuilder private func installStep(_ n: Int, _ text: String, command: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                Text("\(n).").font(.caption.monospacedDigit().weight(.semibold))
                Text(text).font(.caption)
            }
            if let command {
                HStack(spacing: 6) {
                    Text(command)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Copy “\(command)”")
                }
                .padding(.leading, 16)
            }
        }
    }

    /// Polls the configured JuL server so the badge reflects reality. Uses the
    /// endpoint from Settings, not a hard-coded address.
    private func probeJul() async {
        while !Task.isCancelled {
            let client = JulClient(baseURL: settingsStore.julEndpoint, apiKey: settingsStore.julApiKey)
            let model = await client.health()
            julReachable = (model != nil)
            julModel = model
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// One-shot verification triggered by the Verify button, with user feedback.
    /// Checks reachability via /health, then validates the API key (if any) with a
    /// tiny classify — since /health is intentionally unauthenticated.
    private func verifyJul() async {
        julVerifying = true
        julVerifyMessage = nil
        defer { julVerifying = false }
        let client = JulClient(baseURL: settingsStore.julEndpoint, apiKey: settingsStore.julApiKey)
        let model = await client.health()
        julReachable = (model != nil)
        julModel = model
        guard model != nil else {
            julVerifyMessage = "Could not reach the server. Is `jul serve` running at this address?"
            return
        }
        // Validate the key with a minimal authenticated call.
        do {
            _ = try await client.classify(state: "connectivity check ok",
                questions: ["c": JulQuestion(.noul, instructions: "Is this a test?")])
            let m = model ?? ""
            julVerifyMessage = m.isEmpty ? "Connected." : "Connected — model: \(m)"
        } catch JulClientError.badStatus(401) {
            julVerifyMessage = "Reached the server, but the API key was rejected (401)."
        } catch JulClientError.badStatus(403) {
            julVerifyMessage = "The server requires an API key — add it above (403)."
        } catch {
            julVerifyMessage = "Reached the server, but a test request failed."
        }
    }

    // MARK: - Transcripts Folder

    /// Whether a user-chosen folder is in force.
    ///
    /// Derived from the stored bookmark rather than `TranscriptLocation.isCustom`
    /// so that reading it in the body registers an Observation dependency on
    /// `settingsStore`. The resolved location itself is a plain static, so without
    /// this the section would keep showing the previous folder after a change.
    private var hasCustomTranscriptsFolder: Bool {
        settingsStore.transcriptsFolderBookmark != nil
    }

    /// Home-abbreviated path to the folder where meeting transcripts are saved.
    private var transcriptsFolderPath: String {
        let path = TranscriptStore.directory.path(percentEncoded: false)
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// Reveals the transcripts folder in Finder, creating it first if no meeting
    /// has been saved yet so the button never opens a missing directory.
    private func openTranscriptsFolder() {
        let dir = TranscriptStore.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        openURL(dir)
    }

    /// Asks the user for a folder and saves new transcripts there.
    ///
    /// The panel is what grants sandbox access to the chosen folder, so the
    /// bookmark has to be minted from the URL it returns — a path typed or
    /// constructed by hand would not be readable.
    private func chooseTranscriptsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where Wispr saves meeting transcripts."
        panel.directoryURL = TranscriptStore.directory

        guard panel.runModal() == .OK, let chosen = panel.url else { return }

        do {
            settingsStore.transcriptsFolderBookmark = try TranscriptLocation.makeBookmark(
                for: chosen)
        } catch {
            transcriptsFolderError =
                "Could not save that folder choice: \(error.localizedDescription)"
            return
        }

        // Activating through the same path used at launch keeps stale-bookmark and
        // permission handling in one place.
        transcriptsFolderError = TranscriptLocation.applyStoredFolder(from: settingsStore)
    }

    /// Returns to storing transcripts inside the app's own container.
    private func resetTranscriptsFolder() {
        settingsStore.transcriptsFolderBookmark = nil
        TranscriptLocation.useDefault()
        transcriptsFolderError = nil
    }

    // MARK: - General Section

    private var generalSection: some View {
        Section {
            @Bindable var store = settingsStore
            Toggle("Launch at Login", isOn: $store.launchAtLogin)
                .accessibilityHint(AccessibilityHints.launchAtLogin)

            HStack {
                Text("Version")
                    .foregroundStyle(theme.primaryTextColor)
                Spacer()
                Text(appVersion)
                    .foregroundStyle(theme.secondaryTextColor)
                    .font(.callout)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Version \(appVersion)")

            if let update = updateChecker.availableUpdate {
                HStack {
                    Label("Version \(update.version) available", systemImage: SFSymbols.download)
                        .foregroundStyle(.tint)
                        .font(.callout)
                    Spacer()
                    Link("Download", destination: update.downloadURL)
                        .font(.callout)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Version \(update.version) available. Activate to download.")
            }

            Button("Restore Defaults") {
                showRestoreDefaultsAlert = true
            }
            .accessibilityHint(AccessibilityHints.restoreDefaults)
        } header: {
            SectionHeader(
                title: "General",
                systemImage: SFSymbols.settings,
                tint: .secondary
            )
        }
    }

    // MARK: - Version Info

    /// Returns the app version string in the format "1.0.0 (123)" where 123 is the build number.
    private var appVersion: String {
        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Unknown"
        let build =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "\(version) (\(build))"
    }

    // MARK: - Data Loading

    private func loadAudioDevices() async {
        audioDevices = await audioEngine.availableInputDevices()
    }

    private func loadWhisperModels() async {
        var models = await whisperService.availableModels()
        for index in models.indices {
            models[index].status = await whisperService.modelStatus(models[index].id)
        }
        whisperModels = models
    }

    // MARK: - Restore Defaults

    private func restoreDefaults() {
        settingsStore.restoreDefaults()
        hotkeyError = nil
        isRecordingHotkey = false
    }

    // MARK: - Bindings

    /// Manual binding because toggling auto-detect has side effects:
    /// enabling it clears the language selection, disabling it defaults to English.
    private var autoDetectBinding: Binding<Bool> {
        Binding<Bool>(
            get: { settingsStore.languageMode.isAutoDetect },
            set: { newValue in
                withAnimation(theme.standardSpringAnimation) {
                    if newValue {
                        settingsStore.languageMode = .autoDetect
                    } else {
                        settingsStore.languageMode = .specific(code: "en")
                    }
                }
            }
        )
    }

    /// Manual binding because changing the language code must preserve the
    /// current pinned/specific mode.
    private var selectedLanguageCodeBinding: Binding<String> {
        Binding<String>(
            get: {
                settingsStore.languageMode.languageCode ?? "en"
            },
            set: { newCode in
                if settingsStore.languageMode.isPinned {
                    settingsStore.languageMode = .pinned(code: newCode)
                } else {
                    settingsStore.languageMode = .specific(code: newCode)
                }
            }
        )
    }

    /// Manual binding because toggling pin must preserve the currently
    /// selected language code.
    private var pinLanguageBinding: Binding<Bool> {
        Binding<Bool>(
            get: { settingsStore.languageMode.isPinned },
            set: { newValue in
                let code = settingsStore.languageMode.languageCode ?? "en"
                if newValue {
                    settingsStore.languageMode = .pinned(code: code)
                } else {
                    settingsStore.languageMode = .specific(code: code)
                }
            }
        )
    }
}

// MARK: - Preview

#if DEBUG
    private struct SettingsPreview: View {
        @State private var settingsStore: SettingsStore
        @State private var theme = PreviewMocks.makeTheme()
        @State private var updateChecker = PreviewMocks.makeUpdateChecker()
        @State private var stateManager: StateManager
        @State private var textCorrectionService = TextCorrectionService()

        private let whisperService: any TranscriptionEngine

        init(
            autoSuffixEnabled: Bool = false,
            autoSendEnterEnabled: Bool = false,
            languageSpecific: Bool = false,
            languagePinned: Bool = false
        ) {
            let store = PreviewMocks.makeSettingsStore()
            store.autoSuffixEnabled = autoSuffixEnabled
            store.autoSendEnterEnabled = autoSendEnterEnabled
            if languagePinned {
                store.languageMode = .pinned(code: "en")
            } else if languageSpecific {
                store.languageMode = .specific(code: "en")
            }
            self._settingsStore = State(initialValue: store)

            let service = PreviewMocks.makeWhisperService()
            self.whisperService = service
            self._stateManager = State(
                initialValue: PreviewMocks.makeStateManager(
                    settingsStore: store,
                    whisperService: service
                ))
        }

        var body: some View {
            SettingsView(
                audioEngine: PreviewMocks.makeAudioEngine(),
                whisperService: whisperService
            )
            .environment(settingsStore)
            .environment(theme)
            .environment(updateChecker)
            .environment(stateManager)
            .environment(HotkeyMonitor())
            .environment(textCorrectionService)
        }
    }

    #Preview("Settings") {
        SettingsPreview()
    }

    #Preview("Settings - Dark") {
        SettingsPreview()
            .preferredColorScheme(.dark)
    }

    #Preview("Settings - Suffix & Language Expanded") {
        SettingsPreview(autoSuffixEnabled: true, languageSpecific: true)
    }

    #Preview("Settings - All Toggles On") {
        SettingsPreview(
            autoSuffixEnabled: true,
            autoSendEnterEnabled: true,
            languageSpecific: true,
            languagePinned: true
        )
    }
#endif
