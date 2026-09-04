import Foundation
import SwiftUI

/// What the status item shows in the menu bar. Space up there is scarce, so
/// this is deliberately a small set of fixed layouts rather than free choice.
enum MenuBarContent: String, CaseIterable, Identifiable {
    case gpuOnly
    case gpuAndPower
    case gpuPowerMemory
    case memoryOnly
    case tokensPerSecond
    case iconOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gpuOnly: return "GPU load"
        case .gpuAndPower: return "GPU load and power"
        case .gpuPowerMemory: return "GPU load, power and memory"
        case .memoryOnly: return "GPU memory"
        case .tokensPerSecond: return "Tokens per second"
        case .iconOnly: return "Icon only"
        }
    }
}

enum Defaults {
    static let interval = "updateInterval"
    static let menuBarContent = "menuBarContent"
    static let peakBandwidth = "peakBandwidthGBps"
    static let dynoPath = "dynoPath"
    static let modelFolders = "modelFolders"
    static let serverPort = "serverPort"

    static func register() {
        UserDefaults.standard.register(defaults: [
            interval: 1.0,
            menuBarContent: MenuBarContent.gpuAndPower.rawValue,
            peakBandwidth: 0.0,
            dynoPath: "",
            modelFolders: [String](),
            // Away from 8080 and 1234, which other local servers commonly take.
            serverPort: 8971,
        ])
    }
}
