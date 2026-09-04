import Foundation

/// Launches and supervises a `dyno serve` process.
///
/// The app deliberately runs the server as a child process rather than
/// embedding a Python runtime: MLX lives in Python, and a crash in a model load
/// should not take the monitor down with it.
public final class ServerController: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case launching(model: String)
        case running(model: String, port: UInt16)
        case failed(String)

        public var isBusy: Bool {
            if case .launching = self { return true }
            return false
        }

        public var runningModel: String? {
            if case let .running(model, _) = self { return model }
            return nil
        }
    }

    /// Where the `dyno` CLI might be, most specific first.
    public static func executableCandidates(configured: String?) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            configured,
            "\(home)/.mlx-dyno/venv/bin/dyno",
            "/opt/homebrew/bin/dyno",
            "/usr/local/bin/dyno",
        ].compactMap { $0 }
    }

    public static func findExecutable(configured: String? = nil) -> String? {
        let manager = FileManager.default
        for candidate in executableCandidates(configured: configured)
        where manager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // Fall back to PATH.
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for directory in path.split(separator: ":") {
            let candidate = (String(directory) as NSString).appendingPathComponent("dyno")
            if manager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private let lock = NSLock()
    private var process: Process?
    private var _state: State = .stopped
    private var recentOutput: [String] = []

    public var onStateChange: (@Sendable (State) -> Void)?

    public init() {}

    public var state: State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    /// The last few lines the server printed, for showing why a start failed.
    public var log: String {
        lock.lock(); defer { lock.unlock() }
        return recentOutput.joined(separator: "\n")
    }

    private func setState(_ new: State) {
        lock.lock()
        _state = new
        let callback = onStateChange
        lock.unlock()
        callback?(new)
    }

    public func start(
        executable: String, model: LocalModel, port: UInt16, extraArguments: [String] = []
    ) {
        stop()
        setState(.launching(model: model.name))
        lock.lock(); recentOutput = []; lock.unlock()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = [
            "serve",
            "--model", model.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--log-level", "WARNING",
        ] + extraArguments

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.appendOutput(text)
        }

        task.terminationHandler = { [weak self] finished in
            guard let self else { return }
            pipe.fileHandleForReading.readabilityHandler = nil
            // A clean stop already moved us to .stopped; anything else is a crash.
            if case .stopped = self.state { return }
            let reason = finished.terminationStatus == 0
                ? "dyno serve exited."
                : "dyno serve exited with status \(finished.terminationStatus)."
            self.setState(.failed(reason + " " + self.lastErrorLine()))
        }

        do {
            try task.run()
        } catch {
            setState(.failed("Could not launch dyno: \(error.localizedDescription)"))
            return
        }

        lock.lock(); process = task; lock.unlock()

        // The model has to load before the port answers, which for a large
        // model is tens of seconds; poll rather than guess a timeout.
        Task.detached { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(600)
            while Date() < deadline {
                if case .failed = self.state { return }
                if !task.isRunning { return }
                if await Self.isHealthy(port: port) {
                    self.setState(.running(model: model.name, port: port))
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            self.setState(.failed("dyno serve did not become ready in time."))
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
        // Give it a moment to shut down cleanly before insisting.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
        }
    }

    private func appendOutput(_ text: String) {
        lock.lock()
        for line in text.split(separator: "\n") {
            recentOutput.append(String(line))
        }
        if recentOutput.count > 40 { recentOutput.removeFirst(recentOutput.count - 40) }
        lock.unlock()
    }

    private func lastErrorLine() -> String {
        lock.lock(); defer { lock.unlock() }
        return recentOutput.last(where: { !$0.isEmpty }) ?? ""
    }

    private static func isHealthy(port: UInt16) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.0
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        return http.statusCode == 200
    }
}
