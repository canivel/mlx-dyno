import Foundation

/// Composes the individual collectors into one `Snapshot` per interval.
///
/// Marked `@unchecked Sendable` deliberately, and only two entry points may be
/// used concurrently: `sample()` must stay on one queue, while
/// `refreshModels(processes:)` touches nothing but the lock-protected
/// `ModelMonitor` and is safe to call from anywhere.
public final class Sampler: @unchecked Sendable {
    public let system: SystemInfo

    private let gpuStatsGroups: [IOReportSubscription.Group] = [
        .init("GPU Stats", "GPU Performance States"),
        .init("GPU Stats", "GPU Throttler Counters"),
        .init("GPU Stats", "PPM Target as % of Max GPU Power"),
    ]
    /// The memory-controller bandwidth histograms live under a per-die power
    /// management group. PMP0 is the usual name; alternates are tried only when
    /// it yields nothing, so the common case pays for one lookup.
    private let bandwidthGroup = IOReportSubscription.Group("PMP0", "DCS BW")
    private let bandwidthFallbacks = [
        IOReportSubscription.Group("PMP", "DCS BW"),
        IOReportSubscription.Group("PMP1", "DCS BW"),
    ]

    private static let energyChannels: Set<String> = [
        "GPU Energy", "GPU", "CPU Energy", "DRAM", "ANE",
    ]
    private static let bandwidthChannels: Set<String> = ["AMCC RD", "AMCC WR"]

    /// Above this share of the Metal working-set budget, further allocations
    /// start competing with the rest of the system.
    private static let gpuMemoryWarnPercent = 90.0
    private static let compressorWarnBytes = Int64(8 * GB)
    /// Scanning processes costs more than every other collector combined, and
    /// process memory does not move on a sub-second timescale.
    private static let processRefreshInterval: TimeInterval = 2.0

    private var subscription: IOReportSubscription?
    private let cpuLoad = CPULoadTracker()
    private let processScanner = ProcessScanner()
    private var previousSwapouts: UInt64?
    private var cachedProcesses: [ProcessSample] = []
    private var processesRefreshedAt: CFAbsoluteTime = 0
    private let modelMonitor = ModelMonitor()

    /// Below this the GPU is not really generating, so a bandwidth-derived
    /// rate would be noise rather than throughput. Idle sits well above zero on
    /// a Mac that is merely drawing its own desktop.
    private static let generatingGPUPercent = 25.0
    private static let idleGPUPercent = 15.0

    public var processLimit = 8
    public var processMinimumMemory = Int64(GB)

    public init(peakBandwidthOverride: Double? = nil) {
        var info = MachineInfo.gather()
        if let peakBandwidthOverride { info.peakBandwidthGBps = peakBandwidthOverride }
        system = info

        // Prime the process scanner so the first panel shows real names and
        // memory immediately; CPU shares fill in on the next scan.
        cachedProcesses = processScanner.scan(
            gpuPIDs: GPURegistry.clientPIDs(), minimumMemory: processMinimumMemory, limit: 8
        )
        processesRefreshedAt = CFAbsoluteTimeGetCurrent()

        subscription = Self.subscribe(gpuStatsGroups + [.init("Energy Model"), bandwidthGroup])
        if let current = subscription, !current.hasSubgroup("DCS BW") {
            // Some SoCs name the power-management group differently; pay for
            // the extra lookups only on those.
            current.close()
            subscription = Self.subscribe(
                gpuStatsGroups + [.init("Energy Model"), bandwidthGroup] + bandwidthFallbacks
            )
        }
    }

    private static func subscribe(
        _ groups: [IOReportSubscription.Group]
    ) -> IOReportSubscription? {
        if let subscription = try? IOReportSubscription(groups: groups) { return subscription }
        // Fall back to the whole GPU Stats group on SoCs that name their
        // performance-state subgroup differently.
        return try? IOReportSubscription(groups: [.init("GPU Stats"), .init("Energy Model")])
    }

    public var isAvailable: Bool { subscription != nil }

    public func close() {
        subscription?.close()
        subscription = nil
    }

    private static func keepChannel(_ group: String, _ subgroup: String?, _ name: String) -> Bool {
        if group == "Energy Model" { return energyChannels.contains(name) }
        if subgroup == "DCS BW" { return bandwidthChannels.contains(name) }
        if group == "GPU Stats" {
            if subgroup == "GPU Throttler Counters" { return name == "Throttle Counter Total" }
            return true
        }
        return false
    }

    public func sample() -> Snapshot {
        var snapshot = Snapshot()
        guard let subscription else { return snapshot }

        let (channels, interval) = subscription.sample(keep: Self.keepChannel)
        snapshot.interval = interval

        var bandwidthClipped = false
        for channel in channels {
            if isGPUResidency(channel) {
                let decoded = decodeResidency(channel)
                snapshot.gpu.busyPercent = decoded.busy
                snapshot.gpu.frequencyMHz = decoded.megahertz
                snapshot.gpu.stateResidency = decoded.residency
            } else if channel.group == "GPU Stats", channel.name == "Throttle Counter Total" {
                snapshot.gpu.throttleEvents = channel.value
            } else if channel.group == "GPU Stats", channel.format == .state,
                      channel.subgroup?.hasPrefix("PPM Target") == true {
                snapshot.gpu.powerTargetPercent = Self.percentMean(channel.states)
            } else if channel.group == "Energy Model", let joules = channel.joules {
                let watts = joules / interval
                switch channel.name {
                case "GPU Energy": snapshot.power.gpuWatts = watts
                case "GPU": if snapshot.power.gpuWatts == nil { snapshot.power.gpuWatts = watts }
                case "CPU Energy": snapshot.power.cpuWatts = watts
                case "DRAM": snapshot.power.dramWatts = watts
                case "ANE": snapshot.power.aneWatts = watts
                default: break
                }
            } else if channel.subgroup == "DCS BW",
                      let result = Self.histogramMean(channel.states) {
                bandwidthClipped = bandwidthClipped || result.clipped
                if channel.name == "AMCC RD" {
                    snapshot.bandwidth.readGBps = result.mean
                } else {
                    snapshot.bandwidth.writeGBps = result.mean
                }
            }
        }

        let accelerator = GPURegistry.accelerator()
        snapshot.gpu.allocatedBytes = accelerator.allocatedBytes
        snapshot.gpu.inUseBytes = accelerator.inUseBytes

        let vm = VirtualMemory.statistics()
        let swap = Sysctl.swapUsage()
        snapshot.memory.total = system.totalMemory
        snapshot.memory.app = vm.app
        snapshot.memory.wired = vm.wired
        snapshot.memory.compressed = vm.compressed
        snapshot.memory.free = vm.free
        snapshot.memory.used = vm.app + vm.wired + vm.compressed
        snapshot.memory.swapUsed = swap.used
        snapshot.memory.swapTotal = swap.total
        snapshot.memory.gpuBudget = system.gpuMemoryBudget
        snapshot.memory.gpuUsed = accelerator.inUseBytes

        var power = PowerSourceReader.read()
        power.gpuWatts = snapshot.power.gpuWatts
        power.cpuWatts = snapshot.power.cpuWatts
        power.dramWatts = snapshot.power.dramWatts
        power.aneWatts = snapshot.power.aneWatts
        snapshot.power = power

        snapshot.cpuPercent = cpuLoad.sample()
        snapshot.processes = refreshedProcesses()
        snapshot.models = tokenRates(
            for: modelMonitor.current,
            readGBps: snapshot.bandwidth.readGBps,
            gpuBusy: snapshot.gpu.busyPercent
        )
        snapshot.warnings = warnings(for: snapshot, swapouts: vm.swapouts, clipped: bandwidthClipped)
        return snapshot
    }

    /// Re-probe local model servers. Runs on its own cadence because it does
    /// loopback HTTP, unlike the counter reads in `sample()`.
    ///
    /// The process list is passed in rather than read from the cache: this runs
    /// on a different task from `sample()`, and the cache is not synchronised.
    public func refreshModels(processes: [ProcessSample]) async {
        await modelMonitor.refresh(processes: processes)
    }

    /// Fill in a token rate for every model that did not report one itself.
    ///
    /// During decode a dense model re-reads its entire weight set once per
    /// step, so `read bandwidth / weight bytes` is the step rate — which for a
    /// single stream is tokens per second. Measured against a 27B 8-bit model
    /// on an M5 Max this lands within a few percent. It only holds when one
    /// model owns the GPU, so anything else reports no rate rather than a
    /// number that looks authoritative and is not.
    private func tokenRates(
        for models: [LLMModel], readGBps: Double?, gpuBusy: Double
    ) -> [LLMModel] {
        let needingEstimate = models.filter { $0.rateSource != .measured }
        let attributable = needingEstimate.count == 1 && models.count == 1

        return models.map { model in
            guard model.rateSource != .measured else { return model }
            var model = model

            // A server that reports its own request count tells us directly
            // whether it is generating; no need to infer it from GPU load.
            if let stats = model.stats {
                model.tokensPerSecond = stats.activeRequests == 0 ? 0 : nil
                model.rateSource = stats.activeRequests == 0 ? .idle : .unavailable
                return model
            }

            if gpuBusy < Self.idleGPUPercent {
                model.tokensPerSecond = 0
                model.rateSource = .idle
            } else if attributable,
                      gpuBusy >= Self.generatingGPUPercent,
                      let readGBps, readGBps > 0,
                      let sizeGB = model.sizeGB, sizeGB > 0.5 {
                model.tokensPerSecond = readGBps / sizeGB
                model.rateSource = .estimated
            } else {
                model.tokensPerSecond = nil
                model.rateSource = .unavailable
            }
            return model
        }
    }

    private func refreshedProcesses() -> [ProcessSample] {
        let now = CFAbsoluteTimeGetCurrent()
        if !cachedProcesses.isEmpty,
           now - processesRefreshedAt < Self.processRefreshInterval {
            return cachedProcesses
        }
        cachedProcesses = processScanner.scan(
            gpuPIDs: GPURegistry.clientPIDs(),
            minimumMemory: processMinimumMemory,
            limit: processLimit
        )
        processesRefreshedAt = now
        return cachedProcesses
    }

    private func isGPUResidency(_ channel: IOReportChannel) -> Bool {
        guard channel.format == .state, channel.group == "GPU Stats" else { return false }
        let names = Set(channel.states.map(\.name))
        return names.contains("OFF") && names.contains("P1")
    }

    /// GPU busy share and average clock, from time spent per P-state.
    private func decodeResidency(
        _ channel: IOReportChannel
    ) -> (busy: Double, megahertz: Double?, residency: [String: Double]) {
        let total = channel.states.reduce(Int64(0)) { $0 + $1.residency }
        guard total > 0 else { return (0, nil, [:]) }

        var residency: [String: Double] = [:]
        for state in channel.states {
            residency[state.name] = 100 * Double(state.residency) / Double(total)
        }
        let busy = max(0, 100 - (residency["OFF"] ?? 0))

        var megahertz: Double?
        let frequencies = system.gpuFrequenciesMHz
        if !frequencies.isEmpty {
            var weighted = 0.0
            var activeShare = 0.0
            for (index, state) in channel.states.enumerated() {
                guard state.name != "OFF", index < frequencies.count else { continue }
                let share = Double(state.residency) / Double(total)
                weighted += frequencies[index] * share
                activeShare += share
            }
            // The clock the GPU runs at while busy, not averaged with idle.
            megahertz = activeShare > 0 ? weighted / activeShare : nil
        }
        return (busy, megahertz, residency)
    }

    /// Mean of a bandwidth histogram whose state names are bucket upper edges.
    /// `clipped` marks residency in the top bucket: the real value may be higher.
    static func histogramMean(
        _ states: [(name: String, residency: Int64)]
    ) -> (mean: Double, clipped: Bool)? {
        var edges: [(edge: Double, residency: Int64)] = []
        edges.reserveCapacity(states.count)
        for state in states {
            guard let edge = parseBandwidth(state.name) else { return nil }
            edges.append((edge, state.residency))
        }
        guard edges.count >= 2 else { return nil }
        let total = edges.reduce(Int64(0)) { $0 + $1.residency }
        guard total > 0 else { return nil }
        let width = edges[1].edge - edges[0].edge
        let mean = edges.reduce(0.0) {
            $0 + ($1.edge - width / 2) * Double($1.residency)
        } / Double(total)
        return (mean, edges.last!.residency > 0)
    }

    private static func parseBandwidth(_ label: String) -> Double? {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        let scales: [(String, Double)] = [("GB/s", 1), ("MB/s", 1.0 / 1024), ("KB/s", 1.0 / (1024 * 1024))]
        for (suffix, scale) in scales where trimmed.hasSuffix(suffix) {
            let number = trimmed.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            guard let value = Double(number) else { return nil }
            return value * scale
        }
        return nil
    }

    private static func percentMean(_ states: [(name: String, residency: Int64)]) -> Double? {
        var values: [(value: Double, residency: Int64)] = []
        for state in states {
            let trimmed = state.name.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix("%"),
                  let value = Double(trimmed.dropLast()) else { return nil }
            values.append((value, state.residency))
        }
        let total = values.reduce(Int64(0)) { $0 + $1.residency }
        guard total > 0 else { return nil }
        return values.reduce(0.0) { $0 + $1.value * Double($1.residency) } / Double(total)
    }

    private func warnings(
        for snapshot: Snapshot, swapouts: UInt64, clipped: Bool
    ) -> [String] {
        var messages: [String] = []

        if let usedPercent = snapshot.memory.gpuUsedPercent,
           usedPercent >= Self.gpuMemoryWarnPercent {
            messages.append(String(
                format: "GPU memory at %.0f%% of the Metal working-set budget — further allocations may spill to CPU memory",
                usedPercent
            ))
        }

        if let previous = previousSwapouts, swapouts > previous {
            let written = Double(swapouts - previous) * Double(VirtualMemory.pageSize)
            messages.append(
                "Actively swapping (\(Format.bytes(written)) since last sample) — token throughput will drop sharply"
            )
        }
        previousSwapouts = swapouts

        if snapshot.memory.compressed >= Self.compressorWarnBytes {
            messages.append(
                "Memory compressor holding \(Format.bytes(snapshot.memory.compressed)) — the model no longer fits comfortably"
            )
        }

        if snapshot.gpu.throttleEvents > 0 {
            messages.append("GPU throttled \(snapshot.gpu.throttleEvents) time(s) this interval")
        }

        if let system = snapshot.power.systemWatts,
           let adapter = snapshot.power.adapterMaxWatts, system > adapter {
            messages.append(String(
                format: "Drawing %.0f W from a %.0f W adapter — the battery is making up the difference",
                system, adapter
            ))
        } else if snapshot.power.onBattery {
            messages.append("On battery — the GPU may be held below its plugged-in clocks")
        }

        if clipped {
            messages.append(
                "Memory bandwidth is saturating the controller's top histogram bucket — the real figure may be higher than shown"
            )
        }
        return messages
    }
}
