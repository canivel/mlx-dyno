// Command-line harness for the metrics and catalog layers.
//
//   swift build -c release --product probe
//   ./.build/release/probe [extra-model-folder ...]
import Foundation
import DynoKit

let extraFolders = Array(CommandLine.arguments.dropFirst())
let sampler = Sampler()
var snapshot = sampler.sample()
await sampler.refreshModels(processes: snapshot.processes)

let info = sampler.system
print("\(info.chip) · \(info.gpuCores ?? 0)-core GPU · "
      + "\(Format.bytes(info.totalMemory, precision: 0)) unified · macOS \(info.macOSVersion)")
print("runtime: \(Runtime.current.map { "\($0)" } ?? "none found")")

let models = ModelLibrary.scan(extraPaths: extraFolders)
print("\nModels on disk (\(models.count)):")
for model in models {
    print("  \(model.shortName)  \(Format.bytes(model.sizeBytes))  [\(model.source)]")
}

print("\nLive:")
for round in 0..<5 {
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    snapshot = sampler.sample()
    if round % 3 == 0 { await sampler.refreshModels(processes: snapshot.processes) }
    print(String(format: "  GPU %3.0f%% @ %4.0f MHz  %@  mem %@  DRAM %.0f GB/s",
                 snapshot.gpu.busyPercent, snapshot.gpu.frequencyMHz ?? 0,
                 Format.watts(snapshot.power.gpuWatts),
                 Format.bytes(snapshot.memory.gpuUsed),
                 snapshot.bandwidth.totalGBps ?? 0))
    for served in snapshot.models {
        let rate = served.tokensPerSecond.map { String(format: "%.1f", $0) } ?? "—"
        print("    \(served.name) [\(served.runtime)] :\(served.port.map(String.init) ?? "-")"
              + "  \(rate) tok/s (\(served.rateSource.rawValue))")
    }
}
