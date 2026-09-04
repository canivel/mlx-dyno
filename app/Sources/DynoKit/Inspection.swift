import Foundation

/// One generated token and the alternatives the model weighed against it.
public struct TokenReading: Sendable, Identifiable {
    public var id: Int
    public var text: String
    public var probability: Double
    public var alternatives: [(token: String, probability: Double)]

    /// Spread across the alternatives, in bits. Probability says how sure the
    /// model was of its pick; entropy says whether anything else was close.
    public var entropy: Double {
        let weights = alternatives.map(\.probability).filter { $0 > 0 }
        guard !weights.isEmpty else { return 0 }
        let total = weights.reduce(0, +)
        return -weights.reduce(0.0) { partial, weight in
            let p = weight / total
            return partial + p * log2(p)
        }
    }

    public var runnerUp: (token: String, probability: Double)? {
        alternatives.first { $0.token != text }
    }
}

public struct TokenTrace: Sendable {
    public var model: String
    public var text: String = ""
    public var tokens: [TokenReading] = []
    public var error: String?

    public var meanProbability: Double? {
        guard !tokens.isEmpty else { return nil }
        return tokens.map(\.probability).reduce(0, +) / Double(tokens.count)
    }
}

/// Where two runs of the same prompt stopped agreeing.
public struct Divergence: Sendable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var referenceToken: String
    public var otherToken: String
    public var referenceProbability: Double
    public var otherProbability: Double
    /// Whether the reference even ranked the other model's choice.
    public var wasConsidered: Bool
}

/// Asks a running model to generate with its probabilities attached.
public enum Inspection {
    public static func capture(
        port: UInt16, model: String, prompt: String,
        maxTokens: Int = 120, topK: Int = 5, seed: Int = 0, temperature: Double = 0
    ) async -> TokenTrace {
        var trace = TokenTrace(model: model)
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else {
            trace.error = "bad port"
            return trace
        }
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": maxTokens,
            "temperature": temperature,
            "seed": seed,
            "logprobs": true,
            "top_logprobs": max(1, min(topK, 10)),
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 1800
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                trace.error = "the server replied with "
                    + "\((response as? HTTPURLResponse)?.statusCode ?? 0)"
                return trace
            }
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choice = (payload["choices"] as? [[String: Any]])?.first
            else {
                trace.error = "unexpected reply"
                return trace
            }
            trace.text = ((choice["message"] as? [String: Any])?["content"] as? String) ?? ""
            let entries = ((choice["logprobs"] as? [String: Any])?["content"]
                           as? [[String: Any]]) ?? []
            trace.tokens = entries.enumerated().map { index, entry in
                let alternatives = (entry["top_logprobs"] as? [[String: Any]] ?? []).map {
                    (token: $0["token"] as? String ?? "",
                     probability: exp(($0["logprob"] as? NSNumber)?.doubleValue ?? -99))
                }
                return TokenReading(
                    id: index,
                    text: entry["token"] as? String ?? "",
                    probability: exp((entry["logprob"] as? NSNumber)?.doubleValue ?? -99),
                    alternatives: alternatives
                )
            }
        } catch {
            trace.error = error.localizedDescription
        }
        return trace
    }

    /// Two builds of one model, run at the same seed, produce identical text
    /// until precision starts to matter. That token is the whole comparison.
    public static func compare(
        _ reference: TokenTrace, _ other: TokenTrace
    ) -> (first: Int?, all: [Divergence]) {
        var all: [Divergence] = []
        var first: Int?
        for (index, pair) in zip(reference.tokens, other.tokens).enumerated()
        where pair.0.text != pair.1.text {
            if first == nil { first = index }
            all.append(Divergence(
                index: index,
                referenceToken: pair.0.text,
                otherToken: pair.1.text,
                referenceProbability: pair.0.probability,
                otherProbability: pair.1.probability,
                wasConsidered: pair.0.alternatives.contains { $0.token == pair.1.text }
            ))
        }
        return (first, all)
    }
}
