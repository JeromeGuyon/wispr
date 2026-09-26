//
//  MeetingNotificationService.swift
//  wispr
//
//  Posts an actionable local notification when a meeting is detected and
//  routes the user's action back to the meeting transcription flow.
//

import Foundation
import UserNotifications
import WisprCore
import AppKit
import os

/// Abstraction over posting the "meeting detected" notification, so the
/// coordinating service can be unit-tested without the notification center.
@MainActor
protocol MeetingNotifying: AnyObject {
    /// Requests notification authorization (awaiting the user's response) and
    /// performs any one-time setup. Safe to call repeatedly.
    func requestAuthorization() async

    /// Posts the actionable "meeting detected" notification.
    func postMeetingDetectedNotification() async
}

/// Concrete `MeetingNotifying` backed by `UNUserNotificationCenter`.
///
/// Registers a single foreground action ("Start transcription"). When the user
/// activates the action — or taps the notification body — `onStartMeetingRequested`
/// is invoked on the main actor.
///
/// Setup (delegate + notification categories) is deferred until the first
/// `requestAuthorization()` call, so a disabled feature does no launch-time work
/// and does not claim the notification center's single delegate slot.
@MainActor
final class MeetingNotificationService: NSObject, MeetingNotifying,
    UNUserNotificationCenterDelegate
{

    nonisolated static let categoryIdentifier = "com.stormacq.mac.wispr.meeting-detected"
    nonisolated static let startActionIdentifier = "START_MEETING_TRANSCRIPTION"
    nonisolated static let notificationIdentifier =
        "com.stormacq.mac.wispr.meeting-detected.notification"
    nonisolated static let awarenessNotificationIdentifier =
        "com.stormacq.mac.wispr.awareness.notification"

    /// Invoked on the main actor when the user asks to start transcription.
    var onStartMeetingRequested: (@MainActor () -> Void)?

    private let center = UNUserNotificationCenter.current()

    /// Whether the delegate and notification categories have been registered.
    private var isConfigured = false

    // MARK: - MeetingNotifying

    func requestAuthorization() async {
        configureIfNeeded()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            Log.app.debug("MeetingNotificationService — authorization granted: \(granted)")
        } catch {
            Log.app.error(
                "MeetingNotificationService — authorization error: \(error.localizedDescription)")
        }
    }

    func postMeetingDetectedNotification() async {
        let content = UNMutableNotificationContent()
        content.title = "Meeting detected"
        content.body = "Start transcribing this meeting with Wispr?"
        content.categoryIdentifier = Self.categoryIdentifier
        content.sound = .default

        // Fixed identifier so a pending/duplicate notification coalesces rather
        // than stacking up.
        let request = UNNotificationRequest(
            identifier: Self.notificationIdentifier,
            content: content,
            trigger: nil)

        do {
            try await center.add(request)
        } catch {
            Log.app.error(
                "MeetingNotificationService — failed to post notification: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Awareness ("someone is talking about you")

    /// Emoji for a 0…4 tone level. nil for the neutral middle (no clutter).
    nonisolated static func toneEmoji(_ tone: Int) -> String? {
        switch tone {
        case 0: return "🙂"   // calm and positive
        case 1: return nil     // neutral — don't clutter
        case 2: return "😐"   // slightly pressing
        case 3: return "😟"   // tense/frustrated
        case 4: return "😠"   // angry/confrontational
        default: return nil
        }
    }

    /// Posts the "someone is talking about you" alert with a haptic cue. Reuses
    /// the notification center already set up for meeting detection, so no extra
    /// authorization step is needed once meetings are in use.
    ///
    /// `sentence` is the transcript line that triggered the wake and `speaker` its
    /// author, both surfaced in the notification body so the user sees at a glance
    /// what they are being pulled in for.
    func postAwarenessNotification(id: UUID, sentence: String? = nil, speaker: String? = nil,
                                   tags: [String] = [], urgent: Bool = false,
                                   needsAction: Bool = false, hasDeadline: Bool = false,
                                   tone: Int? = nil, summary: String? = nil,
                                   recentMessages: [String] = []) async {
        configureIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = urgent ? "⚡ You're needed now" : "👋 You were just addressed"
        // Headline priority: generated summary (B) → last N messages → raw sentence.
        if let summary, !summary.isEmpty {
            content.body = summary
            if let sentence, !sentence.isEmpty {
                let who = speaker.map { "\($0): " } ?? ""
                content.subtitle = "\(who)“\(sentence)”"
            }
        } else if !recentMessages.isEmpty {
            // Show the last few lines verbatim, most recent last.
            content.body = recentMessages.suffix(3).joined(separator: "\n")
        } else if let sentence, !sentence.isEmpty {
            let who = speaker.map { "\($0): " } ?? ""
            content.body = "\(who)“\(sentence)”"
        } else {
            content.body = "Someone asked you a question or gave you a task."
        }
        // Highlights line: action / deadline / tone, then context tags.
        var chips: [String] = []
        if needsAction { chips.append("🙋 action") }
        if hasDeadline { chips.append("📅 deadline") }
        if let tone, let emoji = Self.toneEmoji(tone) { chips.append(emoji) }
        chips += tags.prefix(3).map { "#\($0)" }
        if !chips.isEmpty {
            let line = chips.joined(separator: "  ")
            content.subtitle = content.subtitle.isEmpty ? line : content.subtitle + "  ·  " + line
        }
        content.sound = .default
        content.interruptionLevel = urgent ? .timeSensitive : .active

        // Stable identifier per wake (derived from the solicitation id): the
        // follow-up carrying the generated brief reuses it, so macOS replaces the
        // first banner instead of stacking a second one. Distinct wakes still get
        // distinct ids, so consecutive alerts don't coalesce into one.
        let request = UNNotificationRequest(
            identifier: Self.awarenessNotificationIdentifier + "." + id.uuidString,
            content: content,
            trigger: nil)

        do {
            try await center.add(request)
            // A double haptic cue on top of the banner — the "your Mac vibrates" part.
            let performer = NSHapticFeedbackManager.defaultPerformer
            performer.perform(.levelChange, performanceTime: .now)
        } catch {
            Log.app.error(
                "MeetingNotificationService — failed to post awareness notification: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - One-time Setup

    /// Registers the delegate and notification category the first time the
    /// feature is enabled. Idempotent.
    private func configureIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true
        center.delegate = self
        registerCategory()
    }

    private func registerCategory() {
        let startAction = UNNotificationAction(
            identifier: Self.startActionIdentifier,
            title: "Start transcription",
            options: [.foreground])

        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [startAction],
            intentIdentifiers: [],
            options: [])

        center.setNotificationCategories([category])
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Present the banner even though a menu-bar (accessory) app is effectively
    /// always frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Route the "Start transcription" action (or a tap on the notification) to
    /// the meeting flow.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        guard action == Self.startActionIdentifier
            || action == UNNotificationDefaultActionIdentifier
        else { return }

        await MainActor.run { [weak self] in
            self?.onStartMeetingRequested?()
        }
    }
}
