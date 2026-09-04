import AppKit
import SwiftUI

@main
struct DynoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var model: MonitorModel { MonitorModel.shared }

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

    var body: some Scene {
        // The label is kept a plain, non-interactive view: anything that makes
        // it an interactive hierarchy can swallow the click that opens the menu.
        MenuBarExtra {
            DashboardPanel(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the window and stops any model server on quit, so exiting never leaves
/// a process holding tens of gigabytes of unified memory.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate?
    private lazy var windowController = MainWindowController(model: MonitorModel.shared)

    func showMainWindow() {
        windowController.show()
    }

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppDelegate.shared = self

            // A menu bar app with no window is easy to install and then fail to
            // find, so show it once on the very first launch. Deferred a beat so
            // the status item is in place first.
            let defaults = UserDefaults.standard
            guard !defaults.bool(forKey: Defaults.hasLaunchedBefore) else { return }
            defaults.set(true, forKey: Defaults.hasLaunchedBefore)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated { AppDelegate.shared?.showMainWindow() }
            }
        }
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { MonitorModel.shared.shutdown() }
    }
}
