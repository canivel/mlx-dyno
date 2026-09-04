import AppKit
import DynoKit
import SwiftUI

/// The menu bar item.
///
/// Built on `NSStatusItem` rather than SwiftUI's `MenuBarExtra`. Two reasons:
/// `MenuBarExtra` cannot tell a left click from a right click, so the icon
/// could not both open the app and offer a glance; and its popover sizes
/// itself from the content, which made a tall panel collapse to an empty strip.
///
/// Left click opens the window — clicking an app's icon should open the app.
/// Right click shows the summary panel.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item: NSStatusItem
    private let model: MonitorModel
    private var popover: NSPopover?

    init(model: MonitorModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "cpu", accessibilityDescription: "Dyno"
            )
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Dyno — click to open, right-click for a summary"
        }

        model.onUpdate = { [weak self] in self?.refreshTitle() }
        refreshTitle()
    }

    // MARK: - Title

    private func refreshTitle() {
        guard let button = item.button else { return }
        let text = readout
        button.title = text.isEmpty ? "" : " \(text)"
        // Fixed-width digits so the menu bar does not jitter as numbers change.
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    }

    private var readout: String {
        let snapshot = model.snapshot
        let gpu = String(format: "%.0f%%", snapshot.gpu.busyPercent)
        let watts = snapshot.power.gpuWatts.map { String(format: "%.0fW", $0) } ?? "--"
        let memory = snapshot.memory.gpuUsed.map {
            String(format: "%.0fG", Double($0) / GB)
        } ?? "--"

        switch model.menuBarContent {
        case .gpuOnly: return gpu
        case .gpuAndPower: return "\(gpu) \(watts)"
        case .gpuPowerMemory: return "\(gpu) \(watts) \(memory)"
        case .memoryOnly: return memory
        case .tokensPerSecond:
            guard let served = model.snapshot.models.first,
                  let rate = served.tokensPerSecond,
                  served.rateSource == .measured || served.rateSource == .estimated
            else { return gpu }
            return String(format: "%@%.1f tok/s",
                          served.rateSource == .estimated ? "~" : "", rate)
        case .iconOnly: return ""
        }
    }

    // MARK: - Clicks

    @objc private func clicked() {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isSecondary {
            togglePopover()
        } else {
            closePopover()
            AppDelegate.shared?.showMainWindow()
        }
    }

    private func togglePopover() {
        if popover?.isShown == true {
            closePopover()
            return
        }
        guard let button = item.button else { return }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        let panel = DashboardPanel(model: model)
        let hosting = NSHostingController(rootView: panel)
        // Size to the content, so the popover is never taller than its panel.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        self.popover = popover
    }

    private func closePopover() {
        popover?.performClose(nil)
        popover = nil
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
    }
}
