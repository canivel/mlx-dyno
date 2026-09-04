import DynoKit
import SwiftUI

/// Talk to the running model, and watch how fast it answers.
///
/// The per-reply figures under each answer are the point: a chat window that
/// does not tell you the throughput is the same as any other client.
struct ChatView: View {
    var model: MonitorModel
    @State private var session = ChatSession()
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    /// The server to talk to, and the exact name it expects for its model.
    ///
    /// Never guessed from `/v1/models`: that lists what a server could load,
    /// and naming the wrong one would make it swap the loaded model out.
    private var target: (port: UInt16, modelID: String)? {
        if case let .running(name, port) = model.serverState {
            let identifier = model.snapshot.models.first { $0.port == port }?.identifier
            return (port, identifier?.isEmpty == false ? identifier! : name)
        }
        // A server started outside the app: Dyno reads what it was launched
        // with, which is the authoritative answer.
        guard let served = model.snapshot.models.first, let port = served.port,
              !served.identifier.isEmpty
        else { return nil }
        return (port, served.identifier)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let target {
                transcript
                Divider()
                composer(target: target)
            } else {
                notRunning
            }
        }
    }

    private var notRunning: some View {
        VStack(spacing: 9) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 26)).foregroundStyle(.tertiary)
            Text("No model is running").font(.system(size: 13, weight: .medium))
            Text("Start one on the Run tab, then come back to talk to it.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Go to Run") { model.requestedTab = .run }
                .controlSize(.small)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if session.isEmpty {
                        Text("Ask it something.")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(session.messages) { message in
                        MessageRow(message: message).id(message.id)
                    }
                    if let error = session.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    // Anchor so the newest text stays in view while streaming.
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(18)
            }
            .onChange(of: session.messages.last?.text) { _, _ in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private func composer(target: (port: UInt16, modelID: String)) -> some View {
        HStack(alignment: .bottom, spacing: 9) {
            TextField("Message the model…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .focused($isFocused)
                .onSubmit { send(target) }
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06))
                )
            if session.isGenerating {
                Button { session.stop() } label: {
                    Image(systemName: "stop.fill")
                }
                .controlSize(.large)
                .help("Stop generating")
            } else {
                Button { send(target) } label: {
                    Image(systemName: "arrow.up")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: [])
            }
            if !session.isEmpty {
                Button { session.clear() } label: { Image(systemName: "trash") }
                    .controlSize(.large)
                    .help("Clear the conversation")
            }
        }
        .padding(14)
    }

    private func send(_ target: (port: UInt16, modelID: String)) {
        let text = draft
        draft = ""
        session.send(text, modelID: target.modelID, port: target.port)
        isFocused = true
    }
}

private struct MessageRow: View {
    var message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(message.role == .user ? "You" : "Model")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(message.role == .user ? Color.accentColor : .secondary)
                .tracking(0.6)

            Text(message.text.isEmpty && message.isStreaming ? "…" : message.text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(message.role == .user
                              ? Color.accentColor.opacity(0.10)
                              : Color.primary.opacity(0.05))
                )

            if message.role == .assistant, !message.isStreaming {
                HStack(spacing: 10) {
                    if let rate = message.tokensPerSecond {
                        stat(String(format: "%.1f tok/s", rate))
                    }
                    if let ttft = message.timeToFirstToken {
                        stat(String(format: "%.2fs to first token", ttft))
                    }
                }
            }
        }
    }

    private func stat(_ text: String) -> some View {
        Text(text).font(.system(size: 9)).foregroundStyle(.tertiary).monospacedDigit()
    }
}
