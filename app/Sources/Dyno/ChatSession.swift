import DynoKit
import Foundation
import Observation

/// Per-request generation settings.
///
/// These go in the request body rather than the server's launch flags, so they
/// can change between messages without reloading the model.
struct GenerationOptions: Codable, Equatable {
    var temperature: Double = 0.7
    var topP: Double = 1.0
    var topK: Int = 0
    var maxTokens: Int = 2048
    var repetitionPenalty: Double = 1.0
    var seed: Int?
    /// Reasoning models can be asked to skip thinking. Sent as
    /// `chat_template_kwargs.enable_thinking`, which is what the Qwen and
    /// DeepSeek templates read.
    var enableThinking = true

    static let `default` = GenerationOptions()

    /// Only non-default values are sent, so the server's own defaults win where
    /// nothing was chosen here.
    func body(model: String, messages: [[String: String]], stream: Bool) -> [String: Any] {
        var payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": stream,
            "max_tokens": maxTokens,
            "temperature": temperature,
        ]
        if topP < 1.0 { payload["top_p"] = topP }
        if topK > 0 { payload["top_k"] = topK }
        if repetitionPenalty != 1.0 { payload["repetition_penalty"] = repetitionPenalty }
        if let seed { payload["seed"] = seed }
        if !enableThinking {
            payload["chat_template_kwargs"] = ["enable_thinking": false]
        }
        return payload
    }
}

/// Streams a reply from a running model into a conversation.
@Observable
@MainActor
final class ChatSession {
    private(set) var isGenerating = false
    private(set) var error: String?

    @ObservationIgnored private var task: Task<Void, Never>?

    func stop() {
        task?.cancel()
        task = nil
        isGenerating = false
    }

    /// Append the prompt and stream the answer, mutating `conversation`
    /// in place through `onChange` so the store can persist as it goes.
    func send(
        prompt: String,
        conversation: Conversation,
        modelID: String,
        modelName: String,
        port: UInt16,
        options: GenerationOptions,
        onChange: @escaping (Conversation) -> Void
    ) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isGenerating else { return }

        error = nil
        var working = conversation
        working.messages.append(ChatMessage(role: .user, text: trimmed))
        working.messages.append(ChatMessage(
            role: .assistant, text: "", isStreaming: true, modelName: modelName
        ))
        working.lastModelID = modelID
        onChange(working)
        isGenerating = true

        // History excludes the placeholder we just added for the answer.
        let history = working.messages.dropLast().map {
            ["role": $0.role.rawValue, "content": $0.text]
        }

        task = Task { [weak self] in
            await self?.stream(
                history: Array(history), conversation: working, modelID: modelID,
                port: port, options: options, onChange: onChange
            )
        }
    }

    private func stream(
        history: [[String: String]],
        conversation: Conversation,
        modelID: String,
        port: UInt16,
        options: GenerationOptions,
        onChange: @escaping (Conversation) -> Void
    ) async {
        var working = conversation
        let started = Date()
        var firstTokenAt: Date?

        func lastIndex() -> Int? {
            working.messages.indices.last
        }

        do {
            var request = URLRequest(
                url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
            )
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 900
            request.httpBody = try JSONSerialization.data(
                withJSONObject: options.body(model: modelID, messages: history, stream: true)
            )

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw ChatError.server((response as? HTTPURLResponse)?.statusCode ?? 0)
            }

            for try await line in bytes.lines {
                if Task.isCancelled { break }
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any]
                else { continue }

                guard let index = lastIndex() else { break }
                // mlx_lm reports thinking in its own field, so it never has to
                // be cut out of the answer afterwards.
                if let reasoning = delta["reasoning"] as? String, !reasoning.isEmpty {
                    if firstTokenAt == nil { firstTokenAt = Date() }
                    working.messages[index].reasoning += reasoning
                    onChange(working)
                }
                if let chunk = delta["content"] as? String, !chunk.isEmpty {
                    if firstTokenAt == nil { firstTokenAt = Date() }
                    working.messages[index].text += chunk
                    onChange(working)
                }
            }
        } catch is CancellationError {
            // Stopping is not an error.
        } catch {
            self.error = (error as? ChatError)?.message ?? error.localizedDescription
        }

        if let index = lastIndex() {
            working.messages[index].isStreaming = false
            working.messages[index].timeToFirstToken =
                firstTokenAt.map { $0.timeIntervalSince(started) }
            working.messages[index].tokensPerSecond = await measuredRate(port: port)
            if working.messages[index].text.isEmpty,
               !working.messages[index].hasReasoning,
               self.error == nil {
                working.messages[index].text = "(no output)"
            }
        }
        onChange(working)
        isGenerating = false
        task = nil
    }

    /// The server's own figure, which excludes queue time and prefill.
    private func measuredRate(port: UInt16) async -> Double? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/stats"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let live = json["live"] as? [String: Any]
        else { return nil }
        return (live["last_decode_tokens_per_second"] as? NSNumber)?.doubleValue
    }

    enum ChatError: Error {
        case server(Int)
        var message: String {
            switch self {
            case let .server(code):
                return code == 404
                    ? "The server does not have that model loaded."
                    : "The model server replied with HTTP \(code)."
            }
        }
    }
}
