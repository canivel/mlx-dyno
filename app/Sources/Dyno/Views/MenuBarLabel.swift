import AppKit
import DynoKit
import SwiftUI

/// The status item itself. Kept to fixed-width digits so the menu bar does not
/// jitter as numbers change.
struct MenuBarLabel: View {
    var model: MonitorModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "cpu")
                .imageScale(.small)
            if let text = readout {
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }
        }
        .task {
            // A menu bar app with no window is easy to install and then fail to
            // find. Show the window once, the first time it is ever launched.
            let defaults = UserDefaults.standard
            guard !defaults.bool(forKey: Defaults.hasLaunchedBefore) else { return }
            defaults.set(true, forKey: Defaults.hasLaunchedBefore)
            openWindow(id: WindowID.main)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var readout: String? {
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
            guard let model = snapshot.models.first,
                  let rate = model.tokensPerSecond,
                  model.rateSource == .measured || model.rateSource == .estimated
            else { return gpu }
            let prefix = model.rateSource == .estimated ? "~" : ""
            return String(format: "%@%.1f tok/s", prefix, rate)
        case .iconOnly: return nil
        }
    }
}
