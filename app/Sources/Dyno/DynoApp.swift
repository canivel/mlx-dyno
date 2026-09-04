import AppKit
import SwiftUI

@main
struct DynoApp: App {
    @State private var model = MonitorModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            DashboardPanel(model: model)
                .onAppear { AppDelegate.shared = model }
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Stops any model server the app started, so quitting never leaves a process
/// holding tens of gigabytes of unified memory.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var shared: MonitorModel?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppDelegate.shared?.shutdown() }
    }
}
