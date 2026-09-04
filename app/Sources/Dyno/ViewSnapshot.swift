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

        let targets: [(String, AnyView, CGSize)] = [
            ("window-run", AnyView(MainWindow(model: model, initialTab: .run)),
             CGSize(width: 900, height: 580)),
            ("window-discover", AnyView(MainWindow(model: model, initialTab: .discover)),
             CGSize(width: 900, height: 580)),
            ("menu-panel", AnyView(DashboardPanel(model: model)),
             CGSize(width: 340, height: 700)),
        ]

        // Both appearances: a colour that reads in one and vanishes in the
        // other is the most common way this UI can be wrong.
        let appearances: [(String, NSAppearance.Name)] = [
            ("dark", .darkAqua), ("light", .aqua),
        ]

        var wrote = 0
        for (name, view, size) in targets {
            for (suffix, appearance) in appearances {
                let path = (directory as NSString)
                    .appendingPathComponent("\(name)-\(suffix).png")
                if capture(view: view, size: size, appearance: appearance, to: path) {
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
               model.snapshot.interval > 0 { break }
        }
        // A little longer so async sizes and a second sample arrive.
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
    }

    private static func capture(
        view: AnyView, size: CGSize, appearance: NSAppearance.Name, to path: String
    ) -> Bool {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        hosting.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        // Positioned offscreen: ordered in so AppKit lays out and draws it, but
        // never visible to the user.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderBack(nil)

        hosting.layoutSubtreeIfNeeded()
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
