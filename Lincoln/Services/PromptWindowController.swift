//
//  PromptWindowController.swift
//  Lincoln
//
//  Shows the ssh prompt panel whenever the manager has an active prompt.
//  An AppKit panel so it works in menu-bar-only mode and floats above
//  whatever the user is doing.
//

import AppKit
import SwiftUI
import Combine

@MainActor
final class PromptWindowController {
    private let manager: TunnelManager
    private var panel: NSPanel?
    private var cancellable: AnyCancellable?

    init(manager: TunnelManager) {
        self.manager = manager
        cancellable = manager.$activePrompt
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prompt in
                if let prompt = prompt {
                    self?.show(prompt)
                } else {
                    self?.hide()
                }
            }
    }

    private func show(_ prompt: PendingPrompt) {
        let content = PromptView(manager: manager, prompt: prompt)
        let hosting = NSHostingController(rootView: content)
        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
            panel.contentViewController = hosting
        } else {
            panel = NSPanel(contentViewController: hosting)
            panel.styleMask = [.titled, .closable, .nonactivatingPanel]
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.title = "Lincoln"
            panel.delegate = delegate
            self.panel = panel
        }
        panel.title = manager.supervisor(for: prompt.tunnelID).map { "\($0.tunnel.displayName) — Lincoln" } ?? "Lincoln"
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private lazy var delegate = PanelDelegate { [weak self] in
        // Closing the panel is a cancel.
        self?.manager.cancelActivePrompt()
    }

    private final class PanelDelegate: NSObject, NSWindowDelegate {
        let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            onClose()
            return false
        }
    }
}
