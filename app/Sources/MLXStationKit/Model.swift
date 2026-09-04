import Foundation

public let GB: Double = 1024 * 1024 * 1024

public struct GPUSample: Sendable {
    public var busyPercent: Double = 0
    public var frequencyMHz: Double?
    public var stateResidency: [String: Double] = [:]
    public var allocatedBytes: Int64?
    public var inUseBytes: Int64?
    public var throttleEvents: Int64 = 0
    public var powerTargetPercent: Double?
}

public struct MemorySample: Sendable {
    public var total: Int64 = 0
    public var used: Int64 = 0
    public var app: Int64 = 0
    public var wired: Int64 = 0
    public var compressed: Int64 = 0
    public var free: Int64 = 0
    public var swapUsed: Int64 = 0
    public var swapTotal: Int64 = 0
    public var gpuBudget: Int64?
    public var gpuUsed: Int64?

    public var gpuHeadroom: Int64? {
        guard let gpuBudget, let gpuUsed else { return nil }
        return max(0, gpuBudget - gpuUsed)
    }

    public var gpuUsedPercent: Double? {
        guard let gpuBudget, gpuBudget > 0, let gpuUsed else { return nil }
        return 100 * Double(gpuUsed) / Double(gpuBudget)
    }

    public var usedPercent: Double {
        total > 0 ? 100 * Double(used) / Double(total) : 0
    }
}

public struct PowerSample: Sendable {
    public var gpuWatts: Double?
    public var cpuWatts: Double?
    public var dramWatts: Double?
    public var aneWatts: Double?
    public var systemWatts: Double?
    public var adapterMaxWatts: Double?
    public var onBattery: Bool = false
    public var batteryPercent: Int?

    public var socWatts: Double? {
        let parts = [gpuWatts, cpuWatts, dramWatts, aneWatts].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }
}

public struct BandwidthSample: Sendable {
    public var readGBps: Double?
    public var writeGBps: Double?

    public var totalGBps: Double? {
        let parts = [readGBps, writeGBps].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }
}

public struct ProcessSample: Sendable, Identifiable {
    public var pid: Int32
    public var name: String
    public var runtime: String?
    public var memory: Int64
    public var cpuPercent: Double
    public var usesGPU: Bool
    public var command: String

    public var id: Int32 { pid }
    public var isKnownRuntime: Bool { runtime != nil }
}

public struct Snapshot: Sendable {
    public var date: Date = .init()
    public var interval: TimeInterval = 0
    public var gpu = GPUSample()
    public var memory = MemorySample()
    public var power = PowerSample()
    public var bandwidth = BandwidthSample()
    public var cpuPercent: Double = 0
    public var processes: [ProcessSample] = []
    public var models: [LLMModel] = []
    public var warnings: [String] = []

    public init() {}
}

/// Static facts about the machine, gathered once at launch.
public struct SystemInfo: Sendable {
    public var chip: String = "Apple Silicon"
    public var gpuCores: Int?
    public var cpuCores: Int = 0
    public var performanceCores: Int?
    public var efficiencyCores: Int?
    public var totalMemory: Int64 = 0
    public var gpuMemoryBudget: Int64?
    public var gpuFrequenciesMHz: [Double] = []
    public var peakBandwidthGBps: Double?
    public var macOSVersion: String = ""

    public var gpuMaxMHz: Double? { gpuFrequenciesMHz.max() }

    public init() {}
}

public enum Format {
    public static func bytes(_ value: Int64?, precision: Int = 1) -> String {
        guard let value else { return "--" }
        return bytes(Double(value), precision: precision)
    }

    public static func bytes(_ value: Double?, precision: Int = 1) -> String {
        guard let value else { return "--" }
        let units: [(String, Double)] = [
            ("TB", 1024 * GB), ("GB", GB), ("MB", 1024 * 1024), ("KB", 1024),
        ]
        for (unit, scale) in units where abs(value) >= scale {
            return String(format: "%.\(precision)f %@", value / scale, unit)
        }
        return String(format: "%.0f B", value)
    }

    public static func watts(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.1f W", value)
    }

    public static func percent(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.0f%%", value)
    }
}
