import AppKit
import SwiftUI

@main
struct DynoApp: App {
    @State private var model = MonitorModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // A support hatch: run the app binary from a terminal to see what it
        // resolved, without having to read the UI.
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
        MenuBarExtra {
            DashboardPanel(model: model)
                .onAppear { AppDelegate.shared = model }
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Dyno", id: WindowID.main) {
            MainWindow(model: model)
                // The app lives in the menu bar, so it has no Dock icon until
                // a window is open; without this the window cannot take focus.
                .onAppear { NSApp.setActivationPolicy(.regular) }
                .onDisappear { NSApp.setActivationPolicy(.accessory) }
        }
        .defaultSize(width: 900, height: 580)
        .windowResizability(.contentMinSize)
    }
}

enum WindowID {
    static let main = "dyno-main"
}

/// Stops any model server the app started, so quitting never leaves a process
/// holding tens of gigabytes of unified memory.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var shared: MonitorModel?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppDelegate.shared?.shutdown() }
    }
}
