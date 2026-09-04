import Foundation

/// Starts and stops `dyno route`.
///
/// Separate from `ServerController` because a router is not a model: it holds
/// no weights, starts instantly, and there is only ever one.
public final class RouterController: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case launching
        case running(port: UInt16)
        case failed(String)
    }

    private let lock = NSLock()
    private var process: Process?
    private var _state: State = .stopped
    private var output: [String] = []

    public var onStateChange: (@Sendable (State) -> Void)?

    public init() {}

    public var state: State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    public var log: String {
        lock.lock(); defer { lock.unlock() }
        return output.joined(separator: "\n")
    }

    private func setState(_ new: State) {
        lock.lock(); _state = new; let callback = onStateChange; lock.unlock()
        callback?(new)
    }

    public func start(port: UInt16 = 8970) {
        stop()
        guard let invocation = Runtime.invocation(
            for: ["route", "--port", String(port), "--log-level", "WARNING"]
        ) else {
            setState(.failed("No Python runtime found. Reinstall Dyno."))
            return
        }

        setState(.launching)
        lock.lock(); output = []; lock.unlock()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: invocation.executable)
        task.arguments = invocation.arguments
        task.environment = invocation.environment

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.lock.lock()
            self?.output.append(contentsOf: text.split(separator: "\n").map(String.init))
            if let count = self?.output.count, count > 40 {
                self?.output.removeFirst(count - 40)
            }
            self?.lock.unlock()
        }

        task.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            if case .stopped = self.state { return }
            self.setState(.failed(
                "The router exited with status \(finished.terminationStatus)."
            ))
        }

        do {
            try task.run()
        } catch {
            setState(.failed("Could not start the router: \(error.localizedDescription)"))
            return
        }
        lock.lock(); process = task; lock.unlock()

        // It binds a port immediately; poll rather than assume.
        Task.detached { [weak self] in
            guard let self else { return }
            for _ in 0..<40 {
                if !task.isRunning { return }
                if await Self.isHealthy(port: port) {
                    self.setState(.running(port: port))
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            self.setState(.failed("The router did not become ready."))
        }
    }

    public func stop() {
        lock.lock()
        let task = process
        process = nil
        _state = .stopped
        lock.unlock()
        onStateChange?(.stopped)
        guard let task, task.isRunning else { return }
        task.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
        }
    }

    private static func isHealthy(port: UInt16) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request) else {
            return false
        }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
