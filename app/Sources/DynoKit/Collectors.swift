import Darwin
import Foundation
import IOKit
import Metal

// MARK: - sysctl

enum Sysctl {
    static func integer(_ name: String) -> Int64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        if size >= 8 { return buffer.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) } }
        if size >= 4 { return Int64(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }) }
        return nil
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// `vm.swapusage` returns a struct, not a scalar: (total, available, used).
    static func swapUsage() -> (used: Int64, total: Int64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (Int64(usage.xsu_used), Int64(usage.xsu_total))
    }
}

// MARK: - Virtual memory

public struct VMStatistics {
    public var free: Int64 = 0
    public var wired: Int64 = 0
    public var compressed: Int64 = 0
    public var app: Int64 = 0
    public var swapouts: UInt64 = 0
}

enum VirtualMemory {
    static let pageSize = Int64(Sysctl.integer("hw.pagesize") ?? 16384)

    static func statistics() -> VMStatistics {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return VMStatistics() }

        var output = VMStatistics()
        output.free = Int64(stats.free_count - stats.speculative_count) * pageSize
        output.wired = Int64(stats.wire_count) * pageSize
        output.compressed = Int64(stats.compressor_page_count) * pageSize
        // "App memory" as Activity Monitor counts it: internal pages that are
        // not purgeable.
        output.app = Int64(max(0, Int(stats.internal_page_count) - Int(stats.purgeable_count)))
            * pageSize
        output.swapouts = stats.swapouts
        return output
    }
}

/// Whole-machine CPU utilisation, from tick deltas.
public final class CPULoadTracker {
    private var previous: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?

    public init() { previous = Self.ticks() }

    private static func ticks() -> (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (
            info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3
        )
    }

    public func sample() -> Double {
        guard let current = Self.ticks() else { return 0 }
        defer { previous = current }
        guard let previous else { return 0 }
        let busy = Double(current.user &- previous.user)
            + Double(current.system &- previous.system)
            + Double(current.nice &- previous.nice)
        let total = busy + Double(current.idle &- previous.idle)
        return total > 0 ? 100 * busy / total : 0
    }
}

// MARK: - IOKit helpers

enum Registry {
    static func services(matching className: String, _ body: (io_object_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching(className) else { return }
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            body(entry)
            IOObjectRelease(entry)
        }
    }

    static func property(_ entry: io_object_t, _ key: String) -> Any? {
        guard let value = IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        return value.takeRetainedValue()
    }
}

public enum GPURegistry {
    private static let acceleratorClasses = ["AGXAccelerator", "IOAccelerator"]

    public struct Accelerator {
        public var inUseBytes: Int64?
        public var allocatedBytes: Int64?
        public var cores: Int?
        public var model: String?
    }

    public static func accelerator() -> Accelerator {
        var result = Accelerator()
        for className in acceleratorClasses {
            var found = false
            Registry.services(matching: className) { entry in
                guard !found,
                      let stats = Registry.property(entry, "PerformanceStatistics")
                        as? [String: Any]
                else { return }
                found = true
                result.inUseBytes = (stats["In use system memory"] as? NSNumber)?.int64Value
                result.allocatedBytes = (stats["Alloc system memory"] as? NSNumber)?.int64Value
                result.cores = (Registry.property(entry, "gpu-core-count") as? NSNumber)?.intValue
                result.model = Registry.property(entry, "model") as? String
            }
            if found { break }
        }
        return result
    }

    /// GPU DVFS frequencies in MHz, index-aligned with the P-state channel.
    /// The kernel publishes (frequency Hz, voltage mV) pairs; index 0 is idle.
    public static func frequencyTable() -> [Double] {
        var table: [Double] = []
        Registry.services(matching: "AppleARMIODevice") { entry in
            guard table.isEmpty,
                  let data = Registry.property(entry, "voltage-states9") as? Data,
                  data.count >= 8
            else { return }
            let words = data.withUnsafeBytes { raw -> [UInt32] in
                let count = raw.count / 4
                return (0..<count).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self) }
            }
            table = stride(from: 0, to: words.count - 1, by: 2).map { Double(words[$0]) / 1e6 }
        }
        return table
    }

    /// PIDs holding an open GPU user client, i.e. processes that can submit
    /// Metal work right now.
    public static func clientPIDs() -> Set<Int32> {
        var pids = Set<Int32>()

        func walk(_ entry: io_object_t, depth: Int) {
            if depth > 4 { return }
            if let creator = Registry.property(entry, "IOUserClientCreator") as? String,
               let range = creator.range(of: #"pid (\d+)"#, options: .regularExpression) {
                let digits = creator[range].dropFirst(4)
                if let pid = Int32(digits) { pids.insert(pid) }
            }
            var iterator: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS
            else { return }
            defer { IOObjectRelease(iterator) }
            while case let child = IOIteratorNext(iterator), child != 0 {
                walk(child, depth: depth + 1)
                IOObjectRelease(child)
            }
        }

        for className in acceleratorClasses {
            var found = false
            Registry.services(matching: className) { entry in
                found = true
                walk(entry, depth: 0)
            }
            if found { break }
        }
        return pids
    }
}

// MARK: - Power source

public enum PowerSourceReader {
    /// Whole-system draw and battery state. `SystemPowerIn` in the SMC power
    /// telemetry block is the wall/battery draw for the entire machine, in mW.
    public static func read() -> PowerSample {
        var sample = PowerSample()
        var done = false
        Registry.services(matching: "IOPMPowerSource") { entry in
            guard !done else { return }
            done = true
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                entry, &properties, kCFAllocatorDefault, 0
            ) == KERN_SUCCESS,
                let dictionary = properties?.takeRetainedValue() as? [String: Any]
            else { return }

            if let telemetry = dictionary["PowerTelemetryData"] as? [String: Any],
               let milliwatts = (telemetry["SystemPowerIn"] as? NSNumber)?.doubleValue,
               milliwatts > 0 {
                sample.systemWatts = milliwatts / 1000
            }
            if let adapter = dictionary["AdapterDetails"] as? [String: Any] {
                sample.adapterMaxWatts = (adapter["Watts"] as? NSNumber)?.doubleValue
            }
            sample.onBattery = !((dictionary["ExternalConnected"] as? Bool) ?? true)
            sample.batteryPercent = (dictionary["CurrentCapacity"] as? NSNumber)?.intValue
        }
        return sample
    }
}

// MARK: - Machine identity

public enum MachineInfo {
    /// Nominal peak unified-memory bandwidth, GB/s. Only chips with a well
    /// established figure are listed; anything else reports absolute GB/s.
    private static let peakBandwidth: [(String, Double)] = [
        ("M1 Ultra", 800), ("M1 Max", 400), ("M1 Pro", 200), ("M1", 68.25),
        ("M2 Ultra", 800), ("M2 Max", 400), ("M2 Pro", 200), ("M2", 100),
        ("M3 Ultra", 800), ("M3 Max", 400), ("M3 Pro", 150), ("M3", 100),
        ("M4 Max", 546), ("M4 Pro", 273), ("M4", 120),
    ]

    public static func peakBandwidthGBps(chip: String, gpuCores: Int?) -> Double? {
        for (name, value) in peakBandwidth where chip.contains(name) {
            // The binned M3 Max ships a narrower memory bus than the full part.
            if name == "M3 Max", let gpuCores, gpuCores <= 30 { return 300 }
            return value
        }
        return nil
    }

    public static func gather() -> SystemInfo {
        var info = SystemInfo()
        let accelerator = GPURegistry.accelerator()
        let device = MTLCreateSystemDefaultDevice()

        info.chip = device?.name
            ?? accelerator.model
            ?? Sysctl.string("machdep.cpu.brand_string")
            ?? "Apple Silicon"
        info.gpuCores = accelerator.cores
        info.cpuCores = Int(Sysctl.integer("hw.ncpu") ?? 0)
        info.performanceCores = Sysctl.integer("hw.perflevel0.logicalcpu").map(Int.init)
        info.efficiencyCores = Sysctl.integer("hw.perflevel1.logicalcpu").map(Int.init)
        info.totalMemory = Sysctl.integer("hw.memsize") ?? 0
        // The number that decides whether a model fits: how much unified memory
        // Metal will let the GPU hold.
        info.gpuMemoryBudget = device.map { Int64($0.recommendedMaxWorkingSetSize) }
        info.gpuFrequenciesMHz = GPURegistry.frequencyTable()
        info.peakBandwidthGBps = peakBandwidthGBps(chip: info.chip, gpuCores: info.gpuCores)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        info.macOSVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        return info
    }
}
