import DynoKit
import Foundation
import Observation

/// One turn in the conversation.
struct ChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant }

    let id = UUID()
    var role: Role
    var text: String
    var isStreaming = false
    /// Filled in when the turn finishes, from the server's own metrics.
    var tokensPerSecond: Double?
    var timeToFirstToken: Double?
}

/// Talks to the running model over its OpenAI-compatible endpoint.
///
/// Streaming rather than waiting for the whole reply: the point of running a
/// model locally is watching it produce tokens, and time-to-first-token is only
/// visible if the first token is shown when it arrives.
@Observable
@MainActor
final class ChatSession {
    private(set) var messages: [ChatMessage] = []
    private(set) var isGenerating = false
    private(set) var error: String?

    @ObservationIgnored private var task: Task<Void, Never>?

    var isEmpty: Bool { messages.isEmpty }

    func clear() {
        stop()
        messages = []
        error = nil
    }

    func stop() {
        task?.cancel()
        task = nil
        isGenerating = false
        if let index = messages.indices.last, messages[index].isStreaming {
            messages[index].isStreaming = false
        }
    }

    func send(_ text: String, modelID: String, port: UInt16) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isGenerating else { return }

        error = nil
        messages.append(ChatMessage(role: .user, text: prompt))
        messages.append(ChatMessage(role: .assistant, text: "", isStreaming: true))
        isGenerating = true

        let history = messages.dropLast().map {
            ["role": $0.role.rawValue, "content": $0.text]
        }
        task = Task { await stream(history: Array(history), modelID: modelID, port: port) }
    }

    private func stream(history: [[String: String]], modelID: String, port: UInt16) async {
        let started = Date()
        var firstTokenAt: Date?

        do {
            var request = URLRequest(
                url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
            )
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 600
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": modelID,
                "messages": history,
                "stream": true,
                "max_tokens": 2048,
            ])

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw ChatError.server((response as? HTTPURLResponse)?.statusCode ?? 0)
            }

            for try await line in bytes.lines {
                if Task.isCancelled { break }
                // Server-sent events: payload lines are prefixed, others are
                // keepalives or blanks.
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any],
                      let chunk = delta["content"] as? String, !chunk.isEmpty
                else { continue }

                if firstTokenAt == nil { firstTokenAt = Date() }
                if let index = messages.indices.last {
                    messages[index].text += chunk
                }
            }
        } catch is CancellationError {
            // Stopping is not an error.
        } catch {
            self.error = describe(error)
        }

        if let index = messages.indices.last {
            messages[index].isStreaming = false
            messages[index].timeToFirstToken = firstTokenAt.map { $0.timeIntervalSince(started) }
            // Prefer the server's own figure; it excludes queue and prefill.
            messages[index].tokensPerSecond = await measuredRate(port: port)
            if messages[index].text.isEmpty && self.error == nil {
                messages[index].text = "(no output)"
            }
        }
        isGenerating = false
        task = nil
    }

    private func measuredRate(port: UInt16) async -> Double? {
        let url = URL(string: "http://127.0.0.1:\(port)/stats")!
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let live = json["live"] as? [String: Any]
        else { return nil }
        return (live["last_decode_tokens_per_second"] as? NSNumber)?.doubleValue
    }

    private func describe(_ error: Error) -> String {
        if let chat = error as? ChatError { return chat.message }
        return error.localizedDescription
    }

    enum ChatError: Error {
        case server(Int)

        var message: String {
            switch self {
            case let .server(code): return "The model server replied with HTTP \(code)."
            }
        }
    }
}
