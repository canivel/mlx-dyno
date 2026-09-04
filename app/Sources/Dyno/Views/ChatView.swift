import DynoKit
import SwiftUI

/// Chat, in the shape people expect one: conversations on the left, the thread
/// in the middle, and the model it is talking to named at the top so a
/// conversation can be picked up on a different model later.
struct ChatView: View {
    var model: MonitorModel
    @State private var session = ChatSession()
    @State private var draft = ""
    @State private var showingOptions = false
    @FocusState private var isFocused: Bool

    private var store: ConversationStore { model.conversations }

    /// Servers that are up, with the exact name each expects for its model.
    private var available: [(id: String, name: String, port: UInt16)] {
        model.snapshot.models.compactMap { served in
            guard let port = served.port, !served.identifier.isEmpty else { return nil }
            return (served.identifier, served.name, port)
        }
    }

    private var target: (id: String, name: String, port: UInt16)? {
        // Prefer the model this conversation was last using, if it is still up.
        if let wanted = store.selected?.lastModelID,
           let match = available.first(where: { $0.id == wanted }) {
            return match
        }
        return available.first
    }

    var body: some View {
        HStack(spacing: 0) {
            ConversationSidebar(store: store, session: session)
                .frame(width: 220)
            Divider()
            thread
        }
    }

    @ViewBuilder
    private var thread: some View {
        VStack(spacing: 0) {
            modelBar
            Divider()
            if available.isEmpty {
                noModel
            } else {
                transcript
                Divider()
                composer
            }
        }
    }

    // MARK: - Model bar

    private var modelBar: some View {
        HStack(spacing: 8) {
            if available.isEmpty {
                Text("No model running").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Picker("", selection: Binding(
                    get: { target?.id ?? "" },
                    set: { newID in
                        guard var conversation = store.selected else { return }
                        conversation.lastModelID = newID
                        store.update(conversation)
                    }
                )) {
                    ForEach(available, id: \.id) { entry in
                        Text(entry.name).tag(entry.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
                .controlSize(.small)
                .help("Replies from here on use this model")
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { showingOptions.toggle() }
            } label: {
                Label("Options", systemImage: "slider.horizontal.3")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(showingOptions ? Color.accentColor : .secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            if showingOptions {
                GenerationOptionsBar(options: Binding(
                    get: { model.generationOptions },
                    set: { model.generationOptions = $0 }
                ))
                .offset(y: 96)
                .zIndex(1)
            }
        }
    }

    private var noModel: some View {
        VStack(spacing: 9) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 26)).foregroundStyle(.tertiary)
            Text("No model is running").font(.system(size: 13, weight: .medium))
            Text("Start one on the Models tab, then come back to talk to it.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Go to Models") { model.requestedTab = .run }
                .controlSize(.small).padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Thread

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if store.selected?.isEmpty ?? true {
                        Text("Ask it something.")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity).padding(.top, 60)
                    }
                    ForEach(store.selected?.messages ?? []) { message in
                        MessageRow(message: message,
                                   showThinking: model.showThinking).id(message.id)
                    }
                    if let error = session.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: store.selected?.messages.last?.text) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 9) {
            TextField("Message the model…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...8)
                .focused($isFocused)
                .onSubmit(send)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9)
                    .fill(Color.primary.opacity(0.06)))
            if session.isGenerating {
                Button { session.stop() } label: { Image(systemName: "stop.fill") }
                    .controlSize(.large).help("Stop generating")
            } else {
                Button(action: send) { Image(systemName: "arrow.up") }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || target == nil)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(14)
        .frame(maxWidth: 792)
        .frame(maxWidth: .infinity)
    }

    private func send() {
        guard let target else { return }
        let conversation = store.selected ?? store.newConversation()
        let text = draft
        draft = ""
        session.send(
            prompt: text,
            conversation: conversation,
            modelID: target.id,
            modelName: target.name,
            port: target.port,
            options: model.generationOptions
        ) { updated in
            store.update(updated)
        }
        isFocused = true
    }
}

// MARK: - Sidebar

private struct ConversationSidebar: View {
    var store: ConversationStore
    var session: ChatSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("CHATS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary).tracking(0.7)
                Spacer()
                Button {
                    session.stop()
                    store.newConversation()
                } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("New chat")
            }
            .padding(.horizontal, 13).padding(.top, 13).padding(.bottom, 8)

            if store.conversations.isEmpty {
                Text("No conversations yet.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 13)
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.conversations) { conversation in
                        ConversationRow(
                            conversation: conversation,
                            isSelected: store.selectedID == conversation.id
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            session.stop()
                            store.selectedID = conversation.id
                        }
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                store.delete(conversation.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 7)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct ConversationRow: View {
    var conversation: Conversation
    var isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(conversation.title)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .lineLimit(1).truncationMode(.tail)
            Text(conversation.updatedAt.formatted(.relative(presentation: .numeric)))
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(isSelected ? Color.accentColor.opacity(0.14) : .clear))
    }
}

// MARK: - Messages

private struct MessageRow: View {
    var message: ChatMessage
    var showThinking: Bool
    @State private var thinkingExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(message.role == .user ? "You" : "Model")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(message.role == .user ? Color.accentColor : .secondary)
                    .tracking(0.6)
                if let name = message.modelName, message.role == .assistant {
                    Text(name).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }

            if message.hasReasoning && showThinking {
                thinking
            }

            if !message.text.isEmpty || !message.isStreaming {
                Text(message.text.isEmpty && message.isStreaming ? "…" : message.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(message.role == .user
                              ? Color.accentColor.opacity(0.10)
                              : Color.primary.opacity(0.05)))
            } else if message.isStreaming && !message.hasReasoning {
                Text("…").font(.system(size: 13)).foregroundStyle(.tertiary)
            }

            if message.role == .assistant, !message.isStreaming {
                HStack(spacing: 10) {
                    if let rate = message.tokensPerSecond {
                        stat(String(format: "%.1f tok/s", rate))
                    }
                    if let ttft = message.timeToFirstToken {
                        stat(String(format: "%.2fs to first token", ttft))
                    }
                    if message.hasReasoning {
                        stat("\(message.reasoning.count) chars thinking")
                    }
                }
            }
        }
    }

    /// Thinking is collapsed by default: it is usually far longer than the
    /// answer, and it is there to be inspected, not read every time.
    private var thinking: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { thinkingExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: thinkingExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8))
                    Text("Thinking").font(.system(size: 10, weight: .medium))
                    if message.isStreaming {
                        Text("…").font(.system(size: 10))
                    }
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if thinkingExpanded {
                Text(message.reasoning)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(11)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.04)))
            }
        }
    }

    private func stat(_ text: String) -> some View {
        Text(text).font(.system(size: 9)).foregroundStyle(.tertiary).monospacedDigit()
    }
}

// MARK: - Options

private struct GenerationOptionsBar: View {
    @Binding var options: GenerationOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 18) {
                slider("Temperature", value: $options.temperature, range: 0...2, format: "%.2f")
                slider("Top-p", value: $options.topP, range: 0.05...1, format: "%.2f")
            }
            HStack(spacing: 18) {
                stepperField("Max tokens", value: $options.maxTokens, step: 256)
                Toggle("Thinking", isOn: $options.enableThinking)
                    .toggleStyle(.switch).controlSize(.mini)
                    .help("Ask reasoning models to think before answering")
                Spacer()
            }
        }
        .font(.system(size: 11))
        .padding(13)
        .frame(width: 430)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .controlBackgroundColor))
            .shadow(radius: 12, y: 4))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color.primary.opacity(0.10)))
    }

    private func slider(
        _ label: String, value: Binding<Double>, range: ClosedRange<Double>, format: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: format, value.wrappedValue)).monospacedDigit()
            }
            Slider(value: value, in: range).controlSize(.mini)
        }
    }

    private func stepperField(_ label: String, value: Binding<Int>, step: Int) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Text("\(value.wrappedValue)").monospacedDigit()
            Stepper("", value: value, in: 128...32768, step: step)
                .labelsHidden().controlSize(.mini)
        }
    }
}
