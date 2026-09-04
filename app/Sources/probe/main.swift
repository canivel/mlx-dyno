// Command-line harness for the metrics layer: prints what the app reads.
//
//   swift build -c release --product probe
//   ./.build/release/probe [extra-model-folder ...]
import Foundation
import MLXStationKit

let extraFolders = Array(CommandLine.arguments.dropFirst())

let sampler = Sampler()
var snapshot = sampler.sample()
await sampler.refreshModels(processes: snapshot.processes)

let info = sampler.system
print("\(info.chip) · \(info.gpuCores ?? 0)-core GPU · "
      + "\(Format.bytes(info.totalMemory, precision: 0)) unified · macOS \(info.macOSVersion)")
print("mlxserve: \(ServerController.findExecutable() ?? "not found")")

let models = ModelLibrary.scan(extraPaths: extraFolders)
print("\nModels on disk (\(models.count)):")
for model in models {
    print("  \(model.name)  \(Format.bytes(model.sizeBytes))  [\(model.source)]")
}

print("\nLive:")
for round in 0..<5 {
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    snapshot = sampler.sample()
    if round % 3 == 0 { await sampler.refreshModels(processes: snapshot.processes) }

    print(String(format: "  GPU %3.0f%% @ %4.0f MHz  %@  mem %@ of %@  DRAM %.0f GB/s",
                 snapshot.gpu.busyPercent, snapshot.gpu.frequencyMHz ?? 0,
                 Format.watts(snapshot.power.gpuWatts),
                 Format.bytes(snapshot.memory.gpuUsed), Format.bytes(snapshot.memory.gpuBudget),
                 snapshot.bandwidth.totalGBps ?? 0))
    for served in snapshot.models {
        let rate = served.tokensPerSecond.map { String(format: "%.1f", $0) } ?? "—"
        var line = "    \(served.name) [\(served.runtime)] "
            + ":\(served.port.map(String.init) ?? "-")  \(rate) tok/s (\(served.rateSource.rawValue))"
        if let stats = served.stats {
            line += String(format: "  active=%d ttft=%@", stats.activeRequests,
                           stats.timeToFirstToken.map { String(format: "%.2fs", $0) } ?? "-")
        }
        print(line)
    }
    for warning in snapshot.warnings { print("    ! \(warning)") }
}
