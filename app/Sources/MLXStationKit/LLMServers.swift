import Foundation

/// How a model's token rate was obtained. The distinction matters: only some
/// runtimes report throughput, and the fallback is a physical estimate whose
/// assumptions the UI should not hide.
public enum TokenRateSource: String, Sendable {
    /// Read from the runtime's own counters.
    case measured
    /// Derived from memory bandwidth divided by weight-set size.
    case estimated
    /// The GPU is idle: nothing is generating.
    case idle
    /// Bandwidth cannot be attributed to one model, or the size is unknown.
    case unavailable

    public var label: String {
        switch self {
        case .measured: return "measured"
        case .estimated: return "est."
        case .idle: return "idle"
        case .unavailable: return ""
        }
    }
}

/// Live figures reported by a server that instruments its own generation loop.
public struct ServerStats: Sendable, Equatable {
    public var decodeTokensPerSecond: Double?
    public var promptTokensPerSecond: Double?
    public var timeToFirstToken: Double?
    public var activeRequests: Int = 0
    public var requestsTotal: Int = 0
    public var generatedTokens: Int = 0
    public var promptTokens: Int = 0
    public var cachedPromptTokens: Int = 0
    public var loadSeconds: Double?

    /// Share of prompt tokens served from the prompt cache. High values are the
    /// difference between a snappy multi-turn chat and re-reading the context
    /// every turn.
    public var cacheHitRate: Double? {
        guard promptTokens > 0 else { return nil }
        return 100 * Double(cachedPromptTokens) / Double(promptTokens)
    }
}

/// A model loaded by a local inference server.
public struct LLMModel: Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var runtime: String
    public var pid: Int32
    public var port: UInt16?
    public var sizeBytes: Int64?
    public var contextLength: Int?
    public var tokensPerSecond: Double?
    public var rateSource: TokenRateSource = .unavailable
    /// Present only for servers that report their own generation metrics.
    public var stats: ServerStats?

    public var sizeGB: Double? {
        guard let sizeBytes, sizeBytes > 0 else { return nil }
        return Double(sizeBytes) / GB
    }
}

/// Cumulative token counters scraped from a Prometheus-style `/metrics`
/// endpoint, used to derive a measured rate from successive deltas.
private struct TokenCounters {
    var generated: Double
    var timestamp: CFAbsoluteTime
}

/// What a given server turned out to support.
///
/// Servers log every request they receive, so once a probe has established
/// which endpoints exist, the ones that 404 are never asked again and the
/// static ones are asked only once.
private struct ServerCapabilities {
    var ollamaPS = false
    var metrics = false
    /// mlxserve's JSON endpoint: everything /metrics has, plus per-request
    /// detail, in one request.
    var stats = false
    /// Model identity, resolved once: it does not change while the process
    /// lives, except on Ollama, which is covered by `ollamaPS`.
    var staticName: String?
    var staticContext: Int?
    var probed = false
}

/// Discovers local model servers and what they have loaded.
///
/// Everything is probed over loopback HTTP against the ports the processes are
/// actually listening on, so a server on a non-default port is still found.
public final class ModelMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var models: [LLMModel] = []
    private var counters: [String: TokenCounters] = [:]
    private var capabilities: [String: ServerCapabilities] = [:]
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.5
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    /// All lock use goes through this synchronous helper: taking a lock
    /// directly inside an async function is rejected under Swift 6 concurrency.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public var current: [LLMModel] { withLock { models } }

    /// Re-probe every LLM process. Cheap enough to run every few seconds:
    /// loopback requests to a handful of ports.
    public func refresh(processes: [ProcessSample]) async {
        var discovered: [LLMModel] = []

        for process in processes where process.runtime != nil {
            let ports = ListeningPorts.forProcess(process.pid)
            var handled = false

            for port in ports {
                let found = await probe(port: port, process: process)
                if !found.isEmpty {
                    discovered.append(contentsOf: found)
                    handled = true
                    break
                }
            }

            // A runtime with no reachable HTTP API still tells us what it
            // loaded, via its own command line.
            if !handled, let name = Self.modelArgument(in: process.command) {
                discovered.append(LLMModel(
                    id: "\(process.pid)-\(name)",
                    name: Self.shortName(name),
                    runtime: process.runtime ?? "LLM",
                    pid: process.pid,
                    port: ports.first,
                    sizeBytes: process.memory
                ))
            }
        }

        withLock { models = discovered }
        pruneCapabilities(livePIDs: Set(processes.map(\.pid)))
    }

    // MARK: - Probing

    private func probe(port: UInt16, process: ProcessSample) async -> [LLMModel] {
        let key = "\(process.pid)-\(port)"
        var caps = withLock { capabilities[key] } ?? ServerCapabilities()

        if !caps.probed {
            caps = await discoverCapabilities(port: port, process: process)
            withLock { capabilities[key] = caps }
        }

        // Ollama loads and unloads models on its own, so its list is re-read
        // every cycle rather than cached.
        if caps.ollamaPS {
            if let payload = await getJSON(port: port, path: "/api/ps"),
               let entries = payload["models"] as? [[String: Any]] {
                return entries.enumerated().map { index, entry in
                    let name = entry["name"] as? String ?? entry["model"] as? String ?? "model"
                    let vram = (entry["size_vram"] as? NSNumber)?.int64Value
                    return LLMModel(
                        id: "\(key)-\(index)-\(name)",
                        name: Self.shortName(name),
                        runtime: "Ollama",
                        pid: process.pid,
                        port: port,
                        sizeBytes: vram ?? (entry["size"] as? NSNumber)?.int64Value,
                        contextLength: (entry["context_length"] as? NSNumber)?.intValue
                    )
                }
            }
            return []
        }

        guard let name = caps.staticName else { return [] }
        var model = LLMModel(
            id: key,
            name: Self.shortName(name),
            runtime: process.runtime ?? "LLM",
            pid: process.pid,
            port: port,
            sizeBytes: process.memory,
            contextLength: caps.staticContext
        )

        if caps.stats, let stats = await serverStats(port: port) {
            model.stats = stats
            if let rate = stats.decodeTokensPerSecond {
                model.tokensPerSecond = rate
                model.rateSource = .measured
            }
        } else if caps.metrics, let rate = await measuredRate(port: port, key: key) {
            model.tokensPerSecond = rate
            model.rateSource = .measured
        }
        return [model]
    }

    /// One-time probe of a newly seen server.
    private func discoverCapabilities(
        port: UInt16, process: ProcessSample
    ) async -> ServerCapabilities {
        var caps = ServerCapabilities()
        caps.probed = true

        if let payload = await getJSON(port: port, path: "/api/ps"),
           payload["models"] != nil {
            caps.ollamaPS = true
            return caps
        }

        // llama.cpp reports the loaded file and context window here.
        if let props = await getJSON(port: port, path: "/props") {
            caps.staticName = props["model_path"] as? String
                ?? (props["default_generation_settings"] as? [String: Any])?["model"] as? String
            caps.staticContext = (props["n_ctx"] as? NSNumber)?.intValue
                ?? ((props["default_generation_settings"] as? [String: Any])?["n_ctx"]
                    as? NSNumber)?.intValue
        }

        // The command line is more trustworthy than /v1/models, which lists
        // everything a server *could* serve rather than what is loaded.
        if caps.staticName == nil {
            caps.staticName = Self.modelArgument(in: process.command)
        }

        if caps.staticName == nil, let payload = await getJSON(port: port, path: "/v1/models"),
           let entries = payload["data"] as? [[String: Any]] {
            caps.staticName = entries.first?["id"] as? String
        }

        // Prefer the richer JSON endpoint when the server offers it.
        if let payload = await getJSON(port: port, path: "/stats"), payload["live"] != nil {
            caps.stats = true
            if let model = payload["model"] as? [String: Any],
               let name = model["name"] as? String, !name.isEmpty {
                caps.staticName = name
            }
        } else {
            caps.metrics = await getText(port: port, path: "/metrics") != nil
        }
        return caps
    }

    /// Forget servers that have gone away, so a restarted one is re-probed.
    private func pruneCapabilities(livePIDs: Set<Int32>) {
        withLock {
            capabilities = capabilities.filter { key, _ in
                guard let pid = Int32(key.split(separator: "-").first ?? "") else { return false }
                return livePIDs.contains(pid)
            }
            counters = counters.filter { key, _ in
                guard let pid = Int32(key.split(separator: "-").first ?? "") else { return false }
                return livePIDs.contains(pid)
            }
        }
    }

    /// mlxserve reports its own generation metrics, measured inside the decode
    /// loop, so nothing here has to be inferred.
    private func serverStats(port: UInt16) async -> ServerStats? {
        guard let payload = await getJSON(port: port, path: "/stats") else { return nil }
        var stats = ServerStats()

        if let live = payload["live"] as? [String: Any] {
            stats.decodeTokensPerSecond = (live["decode_tokens_per_second"] as? NSNumber)?.doubleValue
            stats.promptTokensPerSecond = (live["last_prompt_tokens_per_second"] as? NSNumber)?.doubleValue
            stats.timeToFirstToken = (live["last_time_to_first_token"] as? NSNumber)?.doubleValue
            stats.activeRequests = (live["requests_active"] as? NSNumber)?.intValue ?? 0
        }
        if let totals = payload["totals"] as? [String: Any] {
            stats.requestsTotal = (totals["requests"] as? NSNumber)?.intValue ?? 0
            stats.generatedTokens = (totals["generated_tokens"] as? NSNumber)?.intValue ?? 0
            stats.promptTokens = (totals["prompt_tokens"] as? NSNumber)?.intValue ?? 0
            stats.cachedPromptTokens = (totals["cached_prompt_tokens"] as? NSNumber)?.intValue ?? 0
        }
        if let model = payload["model"] as? [String: Any] {
            stats.loadSeconds = (model["load_seconds"] as? NSNumber)?.doubleValue
        }
        return stats
    }

    /// llama.cpp (with `--metrics`) and vLLM expose cumulative token counters;
    /// two samples give a real rate rather than an estimate.
    private func measuredRate(port: UInt16, key: String) async -> Double? {
        guard let body = await getText(port: port, path: "/metrics") else { return nil }

        let wanted = [
            "llamacpp:tokens_predicted_total",
            "vllm:generation_tokens_total",
            "mlx:tokens_generated_total",
        ]
        var generated: Double?
        for line in body.split(separator: "\n") {
            guard !line.hasPrefix("#") else { continue }
            for metric in wanted where line.hasPrefix(metric) {
                if let value = Double(line.split(separator: " ").last ?? "") {
                    generated = value
                }
            }
        }
        guard let generated else { return nil }

        let now = CFAbsoluteTimeGetCurrent()
        let previous = withLock { () -> TokenCounters? in
            let existing = counters[key]
            counters[key] = TokenCounters(generated: generated, timestamp: now)
            return existing
        }

        guard let previous, now > previous.timestamp else { return nil }
        let elapsed = now - previous.timestamp
        let delta = generated - previous.generated
        guard delta >= 0, elapsed > 0.1 else { return nil }
        return delta / elapsed
    }

    private func getJSON(port: UInt16, path: String) async -> [String: Any]? {
        guard let data = await get(port: port, path: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func getText(port: UInt16, path: String) async -> String? {
        guard let data = await get(port: port, path: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Loopback only: 127.0.0.1 is exempt from the local-network permission
    /// prompt, and a model server on another host is not this app's business.
    private func get(port: UInt16, path: String) async -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    // MARK: - Naming

    /// Pull the model out of a command line: `--model X`, `-m X`, `--hf-repo X`.
    static func modelArgument(in command: String) -> String? {
        let tokens = command.split(separator: " ").map(String.init)
        let flags: Set<String> = ["--model", "-m", "--model-path", "--hf-repo", "--hf-model"]
        for (index, token) in tokens.enumerated() {
            if flags.contains(token), index + 1 < tokens.count {
                return tokens[index + 1]
            }
            // Also accept the `--model=X` spelling.
            for flag in flags where token.hasPrefix(flag + "=") {
                return String(token.dropFirst(flag.count + 1))
            }
        }
        return nil
    }

    /// Trim a path or repo id down to something that fits a menu panel.
    static func shortName(_ raw: String) -> String {
        var name = raw
        if name.contains("/") {
            // Keep the last path component, which is the model directory or file.
            name = (name as NSString).lastPathComponent
        }
        for suffix in [".gguf", ".safetensors", ".bin"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return name.isEmpty ? raw : name
    }
}
