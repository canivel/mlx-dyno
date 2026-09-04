import Foundation

/// Runs `dyno pull` and follows its progress.
///
/// Downloading goes through Python because `huggingface_hub` owns the cache
/// layout, resumes part-finished transfers and handles Xet — all of which a
/// hand-rolled downloader would have to reimplement to put files where MLX
/// will later find them.
public final class DownloadManager: @unchecked Sendable {
    public struct Progress: Sendable, Equatable {
        public var repository: String
        public var downloadedBytes: Int64 = 0
        public var totalBytes: Int64?
        public var isFinished = false
        public var error: String?

        public var fraction: Double? {
            guard let totalBytes, totalBytes > 0 else { return nil }
            return min(1.0, Double(downloadedBytes) / Double(totalBytes))
        }
    }

    private let lock = NSLock()
    private var active: [String: Progress] = [:]
    private var tasks: [String: Process] = [:]

    /// Fires on every progress update, on an arbitrary queue.
    public var onChange: (@Sendable ([String: Progress]) -> Void)?

    public init() {}

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body()
    }

    public var current: [String: Progress] { withLock { active } }

    public func isDownloading(_ repository: String) -> Bool {
        withLock { active[repository]?.isFinished == false && active[repository]?.error == nil }
    }

    private func publish(_ progress: Progress) {
        let snapshot = withLock { () -> [String: Progress] in
            active[progress.repository] = progress
            return active
        }
        onChange?(snapshot)
    }

    public func clear(_ repository: String) {
        let snapshot = withLock { () -> [String: Progress] in
            active.removeValue(forKey: repository)
            return active
        }
        onChange?(snapshot)
    }

    public func cancel(_ repository: String) {
        let task = withLock { tasks.removeValue(forKey: repository) }
        task?.terminate()
        clear(repository)
    }

    public func download(_ repository: String) {
        guard !isDownloading(repository) else { return }
        guard let invocation = Runtime.invocation(for: ["pull", repository, "--json"]) else {
            publish(Progress(repository: repository, isFinished: true,
                             error: "No Python runtime found. Reinstall Dyno."))
            return
        }

        publish(Progress(repository: repository))

        let task = Process()
        task.executableURL = URL(fileURLWithPath: invocation.executable)
        task.arguments = invocation.arguments
        task.environment = invocation.environment

        let output = Pipe()
        task.standardOutput = output
        // The hub's own chatter goes to stderr; it is noise here.
        task.standardError = FileHandle.nullDevice

        var buffer = Data()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            buffer.append(handle.availableData)
            // Progress arrives as newline-delimited JSON; a read can split a line.
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.isEmpty,
                      let event = (try? JSONSerialization.jsonObject(with: Data(line)))
                        as? [String: Any]
                else { continue }
                self.handle(event: event, repository: repository)
            }
        }

        task.terminationHandler = { [weak self] finished in
            output.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            _ = self.withLock { self.tasks.removeValue(forKey: repository) }
            let existing = self.withLock { self.active[repository] }
            // A non-zero exit with no error event means it died without saying why.
            if finished.terminationStatus != 0, existing?.isFinished != true {
                var progress = existing ?? Progress(repository: repository)
                progress.isFinished = true
                progress.error = progress.error ?? "Download failed."
                self.publish(progress)
            }
        }

        do {
            try task.run()
            _ = withLock { tasks[repository] = task }
        } catch {
            publish(Progress(repository: repository, isFinished: true,
                             error: "Could not start the download: \(error.localizedDescription)"))
        }
    }

    private func handle(event: [String: Any], repository: String) {
        var progress = withLock { active[repository] } ?? Progress(repository: repository)
        switch event["type"] as? String {
        case "start":
            progress.totalBytes = (event["total_bytes"] as? NSNumber)?.int64Value
            progress.downloadedBytes = (event["existing_bytes"] as? NSNumber)?.int64Value ?? 0
        case "progress":
            progress.downloadedBytes = (event["downloaded_bytes"] as? NSNumber)?.int64Value ?? 0
            if let total = (event["total_bytes"] as? NSNumber)?.int64Value {
                progress.totalBytes = total
            }
        case "done":
            progress.downloadedBytes = (event["downloaded_bytes"] as? NSNumber)?.int64Value
                ?? progress.downloadedBytes
            progress.isFinished = true
        case "error":
            progress.isFinished = true
            progress.error = event["message"] as? String ?? "Download failed."
        default:
            return
        }
        publish(progress)
    }
}
