import AppKit
import SwiftUI

/// Owns the app's window.
///
/// Built with AppKit rather than a SwiftUI `Window` scene. In a `LSUIElement`
/// app the SwiftUI route needs `openWindow` from the environment, which pulls
/// window management into views that have no business knowing about it — and
/// putting that on the `MenuBarExtra` label turns the status item into an
/// interactive view hierarchy that can swallow the click that opens the menu.
/// A window controller keeps the status item a plain button.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: MonitorModel

    init(model: MonitorModel) {
        self.model = model
        super.init()
    }

    func show() {
        if window == nil { build() }
        guard let window else { return }
        // A menu bar app has no Dock icon until it shows a window; without a
        // regular policy the window cannot take keyboard focus.
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let hosting = NSHostingView(rootView: MainWindow(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Dyno"
        window.contentView = hosting
        window.setFrameAutosaveName("DynoMainWindow")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 820, height: 540)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu bar app: no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)
    }
}
