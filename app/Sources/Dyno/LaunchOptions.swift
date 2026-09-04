import Foundation

/// Flags passed to `dyno serve` when a model is started.
///
/// These are launch-time settings — changing one means restarting the server,
/// unlike the per-request `GenerationOptions`. Only values that differ from the
/// server's own defaults are passed, so an untouched setting stays whatever
/// mlx_lm considers correct.
struct LaunchOptions: Codable, Equatable {
    var maxTokens: Int = 4096
    var temperature: Double = 0.0
    var topP: Double = 1.0
    var topK: Int = 0

    /// How many prompts the server keeps cached. The difference between a
    /// snappy multi-turn chat and re-reading the context every turn.
    var promptCacheSize: Int = 10
    /// Sequences decoded together. Raising it trades latency for total
    /// throughput when more than one request is in flight.
    var decodeConcurrency: Int = 1
    var promptConcurrency: Int = 1

    /// Speculative decoding: a small model drafts, the big one verifies.
    var draftModelPath: String = ""
    var draftTokens: Int = 3

    var trustRemoteCode = false

    static let `default` = LaunchOptions()

    var arguments: [String] {
        var flags: [String] = []
        let defaults = LaunchOptions.default

        if maxTokens != defaults.maxTokens { flags += ["--max-tokens", String(maxTokens)] }
        if temperature != defaults.temperature { flags += ["--temp", String(temperature)] }
        if topP != defaults.topP { flags += ["--top-p", String(topP)] }
        if topK != defaults.topK { flags += ["--top-k", String(topK)] }
        if promptCacheSize != defaults.promptCacheSize {
            flags += ["--prompt-cache-size", String(promptCacheSize)]
        }
        if decodeConcurrency != defaults.decodeConcurrency {
            flags += ["--decode-concurrency", String(decodeConcurrency)]
        }
        if promptConcurrency != defaults.promptConcurrency {
            flags += ["--prompt-concurrency", String(promptConcurrency)]
        }
        if !draftModelPath.isEmpty {
            flags += ["--draft-model", draftModelPath,
                      "--num-draft-tokens", String(draftTokens)]
        }
        if trustRemoteCode { flags.append("--trust-remote-code") }
        return flags
    }

    /// What the Run tab shows so it is obvious the model is not being started
    /// with stock settings.
    var summary: String {
        let flags = arguments
        return flags.isEmpty ? "default settings" : flags.joined(separator: " ")
    }
}
