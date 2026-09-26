//
//  wisprApp.swift
//  wispr
//
//  Main entry point for the Wispr voice dictation application.
//  Initializes all services, sets menu bar-only mode, and shows
//  onboarding on first launch.
//  Requirements: 5.6, 13.1, 13.12, 13.16
//

import SwiftUI
import WisprCore
import os

/// Main application entry point for Wispr.
///
/// Sets `NSApplication.ActivationPolicy.accessory` so the app lives
/// entirely in the menu bar with no Dock icon (Req 5.6).
/// On first launch, presents the `OnboardingFlow` wizard (Req 13.1).
/// On subsequent launches, the menu bar is the only visible UI.
@main
struct WisprApp: App {

    // MARK: - App Delegate

    /// Adaptor that bootstraps services and manages the menu bar lifecycle.
    @NSApplicationDelegateAdaptor(WisprAppDelegate.self) private var appDelegate

    // MARK: - Body

    var body: some Scene {
        // All windows (onboarding, settings, model management) are opened
        // imperatively via NSWindow + NSHostingController from the app delegate
        // and MenuBarController, because SwiftUI Window scenes don't reliably
        // open in accessory (menu-bar-only) apps.
        // LSUIElement=YES in Info.plist hides the Dock icon and app menu,
        // so this Settings scene is never visible to the user.
        Settings {
            EmptyView()
        }
    }

    // MARK: - Initialization

    init() {
        guard ProcessInfo.processInfo.environment["CI_TEST_MODE"] == nil else { return }
        // Requirement 5.6: Menu bar-only app — no Dock icon
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

// MARK: - App Delegate

/// Application delegate that bootstraps all services on launch.
///
/// Using `NSApplicationDelegate` ensures services are initialized
/// before any SwiftUI scene body is evaluated, and provides a
/// clean hook for the `applicationDidFinishLaunching` lifecycle event.
@MainActor
final class WisprAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    // MARK: - Services

    /// Persistent settings store — created first since other services read from it.
    let settingsStore = SettingsStore()

    /// Permission manager for microphone and accessibility checks.
    let permissionManager = PermissionManager()

    /// Audio capture engine (actor).
    let audioEngine = AudioEngine()

    /// On-device transcription service (actor).
    /// Composite engine aggregating WhisperKit and Parakeet V3 behind a single interface.
    let whisperService: any TranscriptionEngine = CompositeTranscriptionEngine(engines: [
        WhisperService(),
        ParakeetService(),
    ])

    /// Text insertion via Accessibility API / clipboard fallback.
    let textInsertionService = TextInsertionService()

    /// Global hotkey registration (Carbon Events).
    let hotkeyMonitor = HotkeyMonitor()

    /// On-device AI text correction using FoundationModels.
    let textCorrectionService = TextCorrectionService()

    /// Shared UI theme engine for appearance and accessibility adaptations.
    let themeEngine = UIThemeEngine.shared

    /// Checks GitHub Releases for a newer app version.
    let updateChecker = UpdateChecker()

    /// Meeting audio engine for dual capture (mic + system audio).
    let meetingAudioEngine = MeetingAudioEngine()

    /// Posts actionable notifications when a meeting is detected.
    let meetingNotificationService = MeetingNotificationService()

    /// Speaker diarization engine for the meeting "Others" track.
    let meetingDiarizer = MeetingDiarizer()

    /// Live-meeting classifier (JuL): drives the awareness and bingo features.
    /// Talks to a local `jul serve` over HTTP; inert if that server is not running.
    let meetingClassifier = MeetingClassifier()

    /// Browsing state for past meeting transcripts (the window's history sidebar).
    let meetingHistoryStore = MeetingHistoryStore()

    /// Central state coordinator — depends on all services above.
    private(set) var stateManager: StateManager?

    /// Meeting state manager for meeting transcription mode.
    private(set) var meetingStateManager: MeetingStateManager?

    /// Detects meeting start via CoreAudio and drives the notification.
    private(set) var meetingDetectionService: MeetingDetectionService?

    /// Menu bar status item controller.
    private var menuBarController: MenuBarController?

    /// Recording overlay floating panel.
    private var overlayPanel: RecordingOverlayPanel?

    /// Meeting transcription floating window.
    private var meetingPanel: MeetingWindowPanel?

    /// Dedicated floating window for the live bingo grid.
    private var bingoWindowPanel: FeaturePanel?

    /// Dedicated floating window for the awareness solicitation history.
    private var awarenessHistoryPanel: FeaturePanel?

    /// Task observing StateManager.appState to drive overlay visibility.
    private var overlayObservationTask: Task<Void, Never>?

    /// Task observing MeetingStateManager to drive meeting window visibility.
    private var meetingObservationTask: Task<Void, Never>?

    /// Task observing hotkey settings changes to re-register the global hotkey.
    private var hotkeyObservationTask: Task<Void, Never>?

    /// Task keeping the live classifier in sync with bingo terms and JuL endpoint.
    private var settingsObservationTask: Task<Void, Never>?
    /// The JuL API key currently applied to the classifier, to avoid rebuilding
    /// the client when nothing changed.
    private var currentJulKey: String = ""

    /// Task monitoring permission changes (microphone, accessibility).
    private var permissionMonitoringTask: Task<Void, Never>?

    /// Task that checks for app updates on launch.
    private var updateCheckTask: Task<Void, Never>?

    /// Retained reference to the onboarding window.
    private var onboardingWindow: NSWindow?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["CI_TEST_MODE"] == nil else { return }
        bootstrap()
    }

    // MARK: - Bootstrap

    /// Initializes all services and wires them together.
    ///
    /// Creates the `StateManager` with all dependencies, sets up the menu bar,
    /// registers the hotkey, and starts monitoring tasks.
    private func bootstrap() {
        Log.app.debug("bootstrap — creating services")
        Log.app.debug("bootstrap — SettingsStore created")
        Log.app.debug("bootstrap — PermissionManager created")
        Log.app.debug("bootstrap — AudioEngine created")
        Log.app.debug("bootstrap — WhisperService created")
        Log.app.debug("bootstrap — TextInsertionService created")
        Log.app.debug("bootstrap — HotkeyMonitor created")

        // Inject URL-opening handler so PermissionManager stays AppKit-free
        permissionManager.openURLHandler = { url in
            NSWorkspace.shared.open(url)
        }

        // Open the sandbox scope for a user-chosen transcripts folder before
        // anything can read or write transcripts. Must happen before the meeting
        // services below, which resolve `TranscriptStore.directory`.
        TranscriptLocation.applyStoredFolder(from: settingsStore)

        // Build the StateManager with all injected dependencies
        let sm = StateManager(
            audioEngine: audioEngine,
            whisperService: whisperService,
            textInsertionService: textInsertionService,
            textCorrectionService: textCorrectionService,
            hotkeyMonitor: hotkeyMonitor,
            permissionManager: permissionManager,
            settingsStore: settingsStore
        )
        stateManager = sm

        // Check AI text correction availability on launch
        textCorrectionService.checkAvailability()

        Log.app.debug("bootstrap — StateManager initialized")

        // Configure the live-meeting classifier before handing it to the meeting
        // manager. Awareness wakes the user via the same notification service used
        // for meeting detection; the bingo grid is read by the menu-bar UI.
        // The whole section is opt-in: nothing runs unless the master switch is on.
        if settingsStore.liveMeetingFeaturesEnabled {
            if settingsStore.awarenessEnabled {
                meetingClassifier.awareness = AwarenessConfig.from(
                    names: settingsStore.awarenessMonitoredNames,
                    mode: settingsStore.awarenessSummaryMode,
                    lastMessages: settingsStore.awarenessLastMessages,
                    summaryMinutes: settingsStore.awarenessSummaryMinutes,
                    cooldownSeconds: settingsStore.awarenessCooldownSeconds)
            }
            if settingsStore.bingoEnabled {
                meetingClassifier.bingo = BingoConfig(terms: settingsStore.bingoTerms)
            }
        }
        // Keep the classifier in sync with Settings, and only ever contact the
        // server when the feature is enabled. Driven by Observation: the loop
        // re-arms after each change rather than polling every second, and while
        // the master switch is off nothing is contacted at all.
        settingsObservationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let store = self.settingsStore
                let master = store.liveMeetingFeaturesEnabled

                if master {
                    // Point at the configured endpoint and keep the badge live.
                    let endpoint = store.julEndpoint
                    let key = store.julApiKey
                    if self.meetingClassifier.endpoint != (JulClient.normalizedBase(endpoint) ?? "")
                        || self.currentJulKey != key {
                        self.meetingClassifier.setEndpoint(endpoint, apiKey: key)
                        self.currentJulKey = key
                    }
                    self.meetingClassifier.startHealthMonitoring()
                    // Reflect the bingo grid edits live. Only reassign when the
                    // config actually changed: `bingo`'s didSet rebuilds (and thus
                    // clears) the grid, so an unconditional assignment would wipe a
                    // mid-meeting grid on any unrelated settings change (e.g. the
                    // API key or endpoint). BingoConfig is Equatable.
                    let newBingo = store.bingoEnabled
                        ? BingoConfig(terms: store.bingoTerms) : nil
                    if newBingo != self.meetingClassifier.bingo {
                        self.meetingClassifier.bingo = newBingo
                    }
                } else {
                    // Off: stop the poll, contact nothing, clear the grid, and tear
                    // down awareness too — otherwise it stays configured and keeps
                    // shipping sentences to JuL until the next meeting.
                    self.meetingClassifier.stopHealthMonitoring()
                    self.meetingClassifier.bingo = nil
                    self.meetingClassifier.awareness = nil
                }

                // Wait until any of the relevant settings change, then re-run.
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = store.liveMeetingFeaturesEnabled
                        _ = store.bingoEnabled
                        _ = store.bingoTerms
                        _ = store.julEndpoint
                        _ = store.julApiKey
                    } onChange: { continuation.resume() }
                }
            }
        }
        // Re-read the two settings at the start of each meeting, so toggling them
        // in Settings applies to the next meeting without an app relaunch.
        meetingClassifier.configProvider = { [weak settingsStore] in
            guard let settingsStore, settingsStore.liveMeetingFeaturesEnabled else { return (nil, nil) }
            let awareness = settingsStore.awarenessEnabled
                ? AwarenessConfig.from(
                    names: settingsStore.awarenessMonitoredNames,
                    mode: settingsStore.awarenessSummaryMode,
                    lastMessages: settingsStore.awarenessLastMessages,
                    summaryMinutes: settingsStore.awarenessSummaryMinutes,
                    cooldownSeconds: settingsStore.awarenessCooldownSeconds)
                : nil
            let bingo = settingsStore.bingoEnabled
                ? BingoConfig(terms: settingsStore.bingoTerms) : nil
            return (awareness, bingo)
        }
        meetingClassifier.onWake = { [weak self] solicitation in
            guard let self else { return }
            Task {
                await self.meetingNotificationService.postAwarenessNotification(
                    id: solicitation.id,
                    sentence: solicitation.sentence, speaker: solicitation.speaker,
                    tags: solicitation.tags, urgent: solicitation.urgent,
                    needsAction: solicitation.needsAction, hasDeadline: solicitation.hasDeadline,
                    tone: solicitation.tone, summary: solicitation.summary,
                    recentMessages: solicitation.recentMessages)
            }
        }
        // The generated brief lands after the immediate wake; post a short
        // follow-up carrying it, so the first notification is never delayed.
        meetingClassifier.onSummaryReady = { [weak self] solicitation in
            guard let self, let brief = solicitation.summary, !brief.isEmpty else { return }
            Task {
                await self.meetingNotificationService.postAwarenessNotification(
                    id: solicitation.id,
                    sentence: solicitation.sentence, speaker: solicitation.speaker,
                    tags: solicitation.tags, urgent: solicitation.urgent,
                    needsAction: solicitation.needsAction, hasDeadline: solicitation.hasDeadline,
                    tone: solicitation.tone, summary: brief)
            }
        }
        // Celebrate a completed bingo line with a haptic burst.
        meetingClassifier.onBingo = {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        // Request notification permission at meeting start when awareness is on,
        // so the first wake actually shows a banner (the app otherwise never asks).
        meetingClassifier.onAwarenessArmed = { [weak self] in
            await self?.meetingNotificationService.requestAuthorization()
        }

        // Create meeting state manager
        let msm = MeetingStateManager(
            meetingAudioEngine: meetingAudioEngine,
            transcriptionEngine: whisperService,
            settingsStore: settingsStore,
            meetingDiarizer: meetingDiarizer,
            meetingClassifier: meetingClassifier
        )
        meetingStateManager = msm

        // Wire meeting detection: post a notification when another app starts
        // using the microphone, and start transcription when the user acts on it.
        meetingNotificationService.onStartMeetingRequested = { [weak self] in
            guard let self, let meetingManager = self.meetingStateManager else { return }
            // Don't start a meeting while dictation is active: MeetingAudioEngine
            // would contend with the dictation engine for the microphone. Guard
            // here because the notification may have been posted while idle and
            // acted on later, after dictation started.
            let dictating =
                self.stateManager?.appState == .recording
                || self.stateManager?.appState == .processing
            guard !dictating else {
                Log.app.debug(
                    "Start-meeting action ignored — dictation active, avoiding dual mic capture")
                return
            }
            Task { await meetingManager.startMeeting() }
        }

        let detection = MeetingDetectionService(
            settingsStore: settingsStore,
            notifier: meetingNotificationService
        )
        // Ignore microphone activity caused by Wispr itself (dictation or an
        // active meeting recording) to avoid self-triggered notifications.
        detection.isSelfUsingMicrophone = { [weak self] in
            guard let self else { return false }
            let dictating =
                self.stateManager?.appState == .recording
                || self.stateManager?.appState == .processing
            let inMeeting = self.meetingStateManager?.meetingState == .recording
            return dictating || inMeeting
        }
        meetingDetectionService = detection
        Task { await detection.start() }

        // Create menu bar controller (Req 5.1)
        menuBarController = MenuBarController(
            stateManager: sm,
            settingsStore: settingsStore,
            themeEngine: themeEngine,
            hotkeyMonitor: hotkeyMonitor,
            audioEngine: audioEngine,
            whisperService: whisperService,
            permissionManager: permissionManager,
            textCorrectionService: textCorrectionService,
            updateChecker: updateChecker,
            meetingStateManager: msm,
            meetingClassifier: meetingClassifier
        )

        // Dedicated floating windows for the live bingo grid and the awareness
        // history, opened from the menu (bingo also auto-shows on a completed line).
        let bingoPanel = FeaturePanel(
            title: "Bullshit Bingo", autosaveName: "BingoWindow",
            size: NSSize(width: 360, height: 460)) { [meetingClassifier] in
                BingoGridView(classifier: meetingClassifier)
            }
        let historyPanel = FeaturePanel(
            title: "You were mentioned", autosaveName: "AwarenessHistoryWindow",
            size: NSSize(width: 460, height: 620),
            minSize: NSSize(width: 380, height: 360)) { [meetingClassifier] in
                AwarenessHistoryView(classifier: meetingClassifier)
            }
        self.bingoWindowPanel = bingoPanel
        self.awarenessHistoryPanel = historyPanel
        menuBarController?.onOpenBingoWindow = { [weak bingoPanel] in
            bingoPanel?.show()
        }
        menuBarController?.onOpenAwarenessHistory = { [weak historyPanel] in
            historyPanel?.show()
        }
        // Auto-show the grid when a bingo line completes, so the celebration is
        // seen even if the window was closed.
        let existingOnBingo = meetingClassifier.onBingo
        meetingClassifier.onBingo = { [weak bingoPanel] in
            existingOnBingo?()
            bingoPanel?.show()
        }
        // Flash the awareness window when the user is addressed, on top of the
        // notification, so the eye is drawn to it.
        let existingOnWake = meetingClassifier.onWake
        meetingClassifier.onWake = { [weak historyPanel] solicitation in
            existingOnWake?(solicitation)
            historyPanel?.flashAttention()
        }

        // Create recording overlay panel
        overlayPanel = RecordingOverlayPanel(
            stateManager: sm,
            settingsStore: settingsStore,
            themeEngine: themeEngine
        )

        // Create meeting transcription panel
        meetingPanel = MeetingWindowPanel(
            meetingStateManager: msm,
            settingsStore: settingsStore,
            themeEngine: themeEngine,
            historyStore: meetingHistoryStore
        )

        // Register the persisted hotkey (Req 1.3)
        do {
            try hotkeyMonitor.register(
                keyCode: settingsStore.hotkeyKeyCode,
                modifiers: settingsStore.hotkeyModifiers
            )
        } catch {
            Log.hotkey.error(
                "bootstrap — hotkey registration failed: \(error.localizedDescription)")
        }

        // Start theme engine monitoring for appearance / accessibility changes
        let themeMonitor = UIThemeEngineMonitor(engine: themeEngine)
        themeMonitor.start()
        themeEngine.monitor = themeMonitor

        // Start observing state to drive overlay visibility (Req 9.1, 9.3, 9.4, 9.5)
        startOverlayObservation(stateManager: sm)

        // Start observing meeting state to drive meeting window visibility
        startMeetingObservation(meetingStateManager: msm)

        // Re-register hotkey whenever the user changes it in settings
        startHotkeyObservation()

        // Start permission monitoring
        let permissionManager = self.permissionManager
        permissionMonitoringTask = Task { [permissionManager] in
            await permissionManager.startMonitoringPermissionChanges()
        }

        // Check for app updates (non-blocking, runs in parallel)
        Log.updateChecker.info("Scheduling update check from applicationDidFinishLaunching")
        let updater = updateChecker
        updateCheckTask = Task {
            await updater.checkForUpdate()
            Log.updateChecker.info(
                "Update check task completed — availableUpdate: \(updater.availableUpdate?.version ?? "none")"
            )
        }

        // Requirement 13.1, 13.12: Show onboarding on first launch
        if !settingsStore.onboardingCompleted {
            // During onboarding, model loading happens in the model selection step.
            // Start idle so the hotkey works for the test dictation step.
            sm.markAsReady()
            showOnboardingWindow(stateManager: sm)
        } else {
            // Load the active model on subsequent launches so whisperKit is ready
            Task { await sm.loadActiveModel() }
        }
    }

    /// Called when the user completes onboarding.
    ///
    /// Persists the onboarding-completed flag (Req 13.12) and
    /// dismisses the onboarding window.
    func completeOnboarding() {
        Log.app.debug("completeOnboarding — onboarding finished")

        settingsStore.onboardingCompleted = true
        settingsStore.flush()

        onboardingWindow?.close()
        onboardingWindow = nil

        // Model was already loaded during the onboarding download step
        // (WhisperService.downloadModel loads the model and sets activeModelName).
        // Just ensure we're in idle state.
        stateManager?.markAsReady()
    }

    // MARK: - NSWindowDelegate

    /// Handles the onboarding window being closed (e.g. via the red close button).
    ///
    /// If onboarding was not completed, the app terminates without persisting
    /// the onboarding-completed flag so the wizard reappears on next launch (Req 13.16).
    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
            closingWindow === onboardingWindow
        else { return }
        if !settingsStore.onboardingCompleted {
            NSApplication.shared.terminate(nil)
        }
        onboardingWindow = nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlayObservationTask?.cancel()
        meetingObservationTask?.cancel()
        hotkeyObservationTask?.cancel()
        permissionMonitoringTask?.cancel()
        updateCheckTask?.cancel()

        // Persist any in-progress meeting BEFORE cancelling its task group, so a
        // session left running with the window closed is not lost on quit.
        meetingStateManager?.finalizeForTermination()
        meetingStateManager?.cancelRecording()

        // Stop meeting detection monitoring.
        Task { await meetingDetectionService?.stop() }

        // Force UserDefaults to flush to disk before the process exits.
        settingsStore.flush()
    }

    // MARK: - Onboarding Window

    /// Creates and shows the onboarding window using NSWindow + NSHostingController.
    ///
    /// Requirement 13.1: Present a multi-step setup wizard on first launch.
    private func showOnboardingWindow(stateManager sm: StateManager) {
        Log.app.debug("showOnboardingWindow — presenting onboarding wizard")

        let onboardingView = OnboardingFlow(
            whisperService: whisperService,
            onDismiss: { [weak self] in
                self?.completeOnboarding()
            }
        )
        .environment(permissionManager)
        .environment(settingsStore)
        .environment(themeEngine)
        .environment(sm)
        .environment(updateChecker)
        .frame(minWidth: 600, minHeight: 500)

        let hostingController = NSHostingController(rootView: onboardingView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Wispr Setup"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 600, height: 500))
        window.center()
        // Keep the onboarding window above normal windows. Accessory apps
        // (no Dock icon) lose window layering when focus moves to another
        // app (e.g. System Settings for permissions). Floating level
        // ensures the wizard stays visible throughout the setup flow.
        window.level = .floating

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.delegate = self
        onboardingWindow = window
    }

    // MARK: - Hotkey Settings Observation

    /// Observes `settingsStore.hotkeyKeyCode` and `hotkeyModifiers` and
    /// re-registers the global hotkey whenever the user changes either value.
    private func startHotkeyObservation() {
        hotkeyObservationTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let currentKeyCode = self.settingsStore.hotkeyKeyCode
                let currentModifiers = self.settingsStore.hotkeyModifiers

                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.settingsStore.hotkeyKeyCode
                        _ = self.settingsStore.hotkeyModifiers
                    } onChange: {
                        continuation.resume()
                    }
                }

                // Values changed — re-register with the new combination
                let newKeyCode = self.settingsStore.hotkeyKeyCode
                let newModifiers = self.settingsStore.hotkeyModifiers
                guard newKeyCode != currentKeyCode || newModifiers != currentModifiers else {
                    continue
                }

                do {
                    try self.hotkeyMonitor.updateHotkey(
                        keyCode: newKeyCode,
                        modifiers: newModifiers
                    )
                    Log.app.debug("hotkeyObservation — re-registered hotkey")
                } catch {
                    Log.app.error(
                        "hotkeyObservation — failed to re-register hotkey: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    // MARK: - Overlay State Observation

    /// Observes `StateManager.appState` and shows/dismisses the overlay panel accordingly.
    ///
    /// - Shows the overlay when state transitions to `.recording`
    /// - Keeps it visible during `.processing`
    /// - Dismisses when transitioning to `.idle`
    /// - Shows error state (overlay stays visible until StateManager auto-resets to `.idle`)
    ///
    /// **Validates**: Requirement 9.1 (overlay appears on recording),
    /// 9.3 (processing indicator), 9.4 (auto-dismiss on idle),
    /// 9.5 (error display before dismiss)
    private func startOverlayObservation(stateManager sm: StateManager) {
        overlayObservationTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                // Process current state
                self.updateOverlayVisibility(for: sm.appState)

                // Wait for the next state change, then act immediately
                // in the onChange callback to avoid missing fast transitions
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = sm.appState
                        _ = self.settingsStore.showRecordingOverlay
                    } onChange: {
                        // Resume immediately; the next loop iteration
                        // calls updateOverlayVisibility on @MainActor.
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Shows or dismisses the overlay based on the current app state.
    private func updateOverlayVisibility(for state: AppStateType) {
        switch state {
        case .loading, .recording, .processing, .error:
            if settingsStore.showRecordingOverlay, let overlay = overlayPanel, !overlay.isVisible {
                Log.app.debug("overlayObservation — showing overlay for state: \(state)")
                overlay.show()
            } else if !settingsStore.showRecordingOverlay, let overlay = overlayPanel,
                overlay.isVisible
            {
                overlay.dismiss()
            }
        case .idle:
            if let overlay = overlayPanel, overlay.isVisible {
                Log.app.debug("overlayObservation — dismissing overlay")
                overlay.dismiss()
            }
        }
    }

    // MARK: - Meeting Window Observation

    /// Observes `MeetingStateManager.isWindowVisible` and shows/dismisses the meeting panel.
    private func startMeetingObservation(meetingStateManager msm: MeetingStateManager) {
        meetingObservationTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let shouldShow = msm.isWindowVisible

                if shouldShow {
                    if let panel = self.meetingPanel, !panel.isVisible {
                        Log.app.debug("meetingObservation — showing meeting window")
                        panel.show()
                    }
                } else {
                    if let panel = self.meetingPanel, panel.isVisible {
                        Log.app.debug("meetingObservation — dismissing meeting window")
                        panel.dismiss()
                    }
                }

                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = msm.isWindowVisible
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }
}
