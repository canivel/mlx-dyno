import AppKit
import SwiftUI

@main
struct DynoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Support hatches: inspect what the app resolved, or render its UI,
        // without launching the interface.
        let arguments = CommandLine.arguments
        if arguments.contains("--diagnose") {
            exit(Diagnose.run(arguments: Array(arguments.dropFirst())))
        }
        if arguments.contains("--snapshot") {
            let rest = Array(arguments.dropFirst())
            exit(MainActor.assumeIsolated { ViewSnapshot.run(arguments: rest) })
        }
    }

    /// The interface is the status item and the window, both AppKit-managed.
    /// This scene exists because an App needs one; it is never shown.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Owns the menu bar item and the window, and stops any model server on quit so
/// exiting never leaves a process holding tens of gigabytes of unified memory.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate?

    private var statusItem: StatusItemController?
    private lazy var windowController = MainWindowController(model: MonitorModel.shared)

    func showMainWindow() {
        windowController.show()
    }

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppDelegate.shared = self
            // Menu bar only until a window is opened.
            NSApp.setActivationPolicy(.accessory)
            statusItem = StatusItemController(model: MonitorModel.shared)

            // A menu bar app with no window is easy to install and then fail to
            // find, so show it once on the very first launch.
            let defaults = UserDefaults.standard
            guard !defaults.bool(forKey: Defaults.hasLaunchedBefore) else { return }
            defaults.set(true, forKey: Defaults.hasLaunchedBefore)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                MainActor.assumeIsolated { AppDelegate.shared?.showMainWindow() }
            }
        }
    }

    /// Clicking the app in the Dock or Finder while it is already running.
    nonisolated func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        MainActor.assumeIsolated { showMainWindow() }
        return true
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { MonitorModel.shared.shutdown() }
    }
}
