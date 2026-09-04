import DynoKit
import Foundation

/// `Dyno.app/Contents/MacOS/Dyno --diagnose [model-folder ...]`
///
/// Prints what the app resolved at launch and, optionally, actually starts a
/// model server so a failure shows up here rather than as a silent red line in
/// the menu. This is the first thing to run when a model will not start.
/// A value shared with a callback that runs on another queue.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: Value) { lock.lock(); value = new; lock.unlock() }
}

enum Diagnose {
    static func run(arguments: [String]) -> Int32 {
        let folders = arguments.filter { !$0.hasPrefix("--") }
        let shouldStart = arguments.contains("--start")

        print("Dyno diagnostics\n")

        switch Runtime.current {
        case let .bundled(python, libraries):
            print("  runtime    bundled in the app")
            print("  python     \(python)")
            print("  libraries  \(libraries)")
        case let .external(executable):
            print("  runtime    external CLI")
            print("  dyno       \(executable)")
        case nil:
            print("  runtime    NONE FOUND — the app cannot serve models")
        }

        let system = Sampler().system
        print("  machine    \(system.chip), \(system.gpuCores ?? 0)-core GPU, "
              + "\(Format.bytes(system.totalMemory, precision: 0)) unified")
        print("  gpu budget \(Format.bytes(system.gpuMemoryBudget))")

        let models = ModelLibrary.scan(extraPaths: folders)
        print("\n  models found: \(models.count)")
        for model in models {
            print("    \(model.name)  \(Format.bytes(model.sizeBytes))  [\(model.source)]")
        }

        guard shouldStart, let model = models.first else { return models.isEmpty ? 1 : 0 }

        print("\n  starting \(model.name) …")
        let controller = ServerController()
        let semaphore = DispatchSemaphore(value: 0)
        // The callback fires on the controller's own queue, so the result
        // crosses threads through a lock rather than a bare captured var.
        let outcome = Locked("timed out")
        controller.onStateChange = { state in
            switch state {
            case let .running(name, port):
                outcome.set("running: \(name) on :\(port)")
                semaphore.signal()
            case let .failed(message):
                outcome.set("failed: \(message)")
                semaphore.signal()
            default:
                break
            }
        }
        controller.start(model: model, port: 8971)
        _ = semaphore.wait(timeout: .now() + 600)
        let result = outcome.get()
        print("  \(result)")
        controller.stop()
        Thread.sleep(forTimeInterval: 1.5)
        return result.hasPrefix("running") ? 0 : 1
    }
}
