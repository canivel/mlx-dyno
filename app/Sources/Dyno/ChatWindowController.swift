import AppKit
import SwiftUI

/// Chat lives in its own window.
///
/// Not a tab: the reason to run a router is to watch what it decides while you
/// talk to it, which is impossible if the conversation and the decision log
/// cannot be on screen at the same time.
@MainActor
final class ChatWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: MonitorModel

    init(model: MonitorModel) {
        self.model = model
        super.init()
    }

    var isOpen: Bool { window?.isVisible ?? false }

    func toggle() {
        if isOpen {
            window?.performClose(nil)
        } else {
            show()
        }
    }

    func show() {
        if window == nil { build() }
        guard let window else { return }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let hosting = NSHostingView(rootView: ChatView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Chat"
        window.contentView = hosting
        // Its own autosave name, so it remembers a position beside the main
        // window rather than on top of it.
        window.setFrameAutosaveName("DynoChatWindow")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 620, height: 460)
        if window.frame.origin == .zero { window.center() }
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        // Only drop back to a menu bar app when no window is left.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let visible = NSApp.windows.contains { $0.isVisible && $0.canBecomeKey }
                if !visible { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }
}
