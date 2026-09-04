import AppKit
import DynoKit
import SwiftUI

/// `Dyno.app/Contents/MacOS/Dyno --snapshot <directory>`
///
/// Renders the app's own views to PNG. This hosts them in a real, offscreen
/// `NSWindow` and asks the view hierarchy to draw itself, rather than using
/// `ImageRenderer`: SwiftUI's renderer cannot draw AppKit-backed controls —
/// segmented pickers and buttons come out blank or as placeholder blocks — and
/// the whole point here is to see what the controls actually look like.
///
/// Nothing is captured from the screen, so no Screen Recording permission is
/// involved.
@MainActor
enum ViewSnapshot {
    static func run(arguments: [String]) -> Int32 {
        let paths = arguments.filter { !$0.hasPrefix("--") }
        let directory = paths.first ?? FileManager.default.currentDirectoryPath
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )

        // Drawing needs a real app context even though nothing is shown.
        NSApplication.shared.setActivationPolicy(.accessory)

        let model = MonitorModel()
        waitForData(model)

        // Built lazily: constructing every view up front would run each one's
        // initialiser before the first capture.
        let targets: [(String, () -> AnyView, CGSize)] = [
            ("chat", { AnyView(ChatView(model: model)) },
             CGSize(width: 860, height: 620)),
            ("window-run", { AnyView(MainWindow(model: model, initialTab: .run)) },
             CGSize(width: 980, height: 620)),
            ("window-router", { AnyView(MainWindow(model: model, initialTab: .router)) },
             CGSize(width: 980, height: 620)),
            ("window-observe", { AnyView(MainWindow(model: model, initialTab: .observe)) },
             CGSize(width: 980, height: 700)),
            ("window-discover", { AnyView(MainWindow(model: model, initialTab: .discover)) },
             CGSize(width: 980, height: 620)),
            ("menu-panel", { AnyView(DashboardPanel(model: model)) },
             CGSize(width: 320, height: 330)),
        ]

        // Both appearances: a colour that reads in one and vanishes in the
        // other is the most common way this UI can be wrong.
        let appearances: [(String, NSAppearance.Name)] = [
            ("dark", .darkAqua), ("light", .aqua),
        ]

        // The popover is presented at whatever height the content asks for;
        // measure it unconstrained to be sure it fits on a screen.
        let probe = NSHostingView(rootView: AnyView(DashboardPanel(model: model)))
        probe.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let natural = probe.fittingSize
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 0
        print(String(format: "  panel natural height: %.0f pt (screen allows %.0f pt)%@",
                     natural.height, visibleHeight,
                     natural.height > visibleHeight ? "  ** TOO TALL **" : ""))

        var wrote = 0
        for (name, makeView, size) in targets {
            for (suffix, appearance) in appearances {
                let path = (directory as NSString)
                    .appendingPathComponent("\(name)-\(suffix).png")
                if capture(view: makeView(), size: size, appearance: appearance, to: path) {
                    wrote += 1
                } else {
                    print("  FAILED \(name)-\(suffix)")
                }
            }
            print("  wrote \(name) (dark + light)")
        }
        print("  models: \(model.localModels.count)  catalog: \(model.catalog.count)  "
              + "gpu: \(String(format: "%.0f%%", model.snapshot.gpu.busyPercent))")
        return wrote == targets.count * appearances.count ? 0 : 1
    }

    /// Let samples land and the catalog load, so the images show real numbers.
    private static func waitForData(_ model: MonitorModel) {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            if !model.catalog.isEmpty,
               !model.localModels.isEmpty,
               model.router.isReachable,
               model.snapshot.interval > 0 { break }
        }
        // A little longer so async sizes and a second sample arrive.
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
    }

    private static func capture(
        view: AnyView, size: CGSize, appearance: NSAppearance.Name, to path: String
    ) -> Bool {
        // The AppKit appearance and the SwiftUI colour scheme have to be set
        // together. Setting only the former leaves SwiftUI drawing light text
        // onto a window AppKit painted light, which comes out blank.
        let isDark = appearance == .darkAqua
        let rooted = view
            .environment(\.colorScheme, isDark ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: AnyView(rooted))
        hosting.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // Set it application-wide: a per-window appearance does not reach
        // views AppKit hosts separately, such as a ScrollView's clip view,
        // which then renders light text on a light background.
        NSApp.appearance = NSAppearance(named: appearance)
        window.appearance = NSAppearance(named: appearance)
        hosting.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        // Positioned offscreen: ordered in so AppKit lays out and draws it, but
        // never visible to the user.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderBack(nil)

        hosting.layoutSubtreeIfNeeded()
        print("    [\((path as NSString).lastPathComponent)] natural size: "
              + "\(Int(hosting.fittingSize.width))x\(Int(hosting.fittingSize.height))")
        // Give SwiftUI a couple of runloop turns to settle its layout.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        hosting.layoutSubtreeIfNeeded()

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            window.close()
            return false
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        window.close()

        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
