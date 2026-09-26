//
//  FeaturePanel.swift
//  wispr
//
//  A floating, resizable NSPanel that hosts an arbitrary SwiftUI view. Used for
//  the live bingo grid and the awareness history, so both share one window
//  behaviour, including an attention "flash" when something happens.
//

import AppKit
import SwiftUI

@MainActor
final class FeaturePanel: NSObject, NSWindowDelegate {

    private var panel: NSPanel?
    private let title: String
    private let autosaveName: String
    private let size: NSSize
    private let minSize: NSSize
    private let content: () -> AnyView

    private(set) var isVisible = false

    init<Content: View>(title: String, autosaveName: String, size: NSSize,
                        minSize: NSSize? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.autosaveName = autosaveName
        self.size = size
        self.minSize = minSize ?? NSSize(width: 320, height: 280)
        self.content = { AnyView(content()) }
    }

    func show() {
        if panel == nil { build() }
        guard let panel else { return }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        isVisible = true
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    /// Draws attention to the window when an event fires: brings it to front and
    /// plays a brief highlight animation. Also bounces the Dock icon once. Used in
    /// addition to the notification.
    func flashAttention() {
        show()
        guard let panel else { return }
        // A short, non-blocking bounce of the window: nudge the title bar's alpha
        // and request user attention (bounces the Dock icon / pulses the app).
        NSApp.requestUserAttention(.informationalRequest)
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.6
        pulse.duration = 0.18
        pulse.autoreverses = true
        pulse.repeatCount = 2
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.add(pulse, forKey: "attentionPulse")
    }

    private func build() {
        let hosting = NSHostingView(rootView: content())
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            // Resizable, standard titled panel (dropped the compact HUD style so
            // the window can grow and shows a normal title bar).
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.title = title
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = minSize
        panel.contentView = hosting
        panel.delegate = self
        panel.setFrameAutosaveName(autosaveName)
        if UserDefaults.standard.object(forKey: "NSWindow Frame \(autosaveName)") == nil,
           let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.maxX - size.width - 20, y: v.maxY - size.height - 20))
        }
        self.panel = panel
    }

    func windowWillClose(_ notification: Notification) {
        isVisible = false
    }
}
