import Foundation
import Observation

/// One turn in a conversation.
struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant }

    var id = UUID()
    var role: Role
    var text: String
    /// Reasoning models emit their thinking separately; mlx_lm returns it in
    /// its own field rather than inline, so it can be shown or hidden without
    /// parsing the answer apart.
    var reasoning: String = ""
    var isStreaming = false

    // Measured, not timed from outside: the server reports these.
    var tokensPerSecond: Double?
    var timeToFirstToken: Double?
    /// Which model produced it — a conversation can span several.
    var modelName: String?

    var hasReasoning: Bool { !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// A saved conversation.
struct Conversation: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String = "New chat"
    var createdAt = Date()
    var updatedAt = Date()
    var messages: [ChatMessage] = []
    /// The model last used here, so resuming picks up where it left off.
    var lastModelID: String?

    var isEmpty: Bool { messages.isEmpty }

    var preview: String {
        messages.first { $0.role == .user }?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ") ?? ""
    }

    /// Name a conversation after its opening line, the way a chat app does.
    mutating func retitleFromFirstMessage() {
        guard title == "New chat",
              let first = messages.first(where: { $0.role == .user })?.text
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !first.isEmpty
        else { return }
        let flattened = first.replacingOccurrences(of: "\n", with: " ")
        title = flattened.count > 48 ? String(flattened.prefix(48)) + "…" : flattened
    }
}

/// Conversations on disk.
///
/// One file per conversation under Application Support, so a corrupt or
/// half-written file costs one chat rather than the whole history, and a
/// conversation can be deleted or backed up on its own.
@Observable
@MainActor
final class ConversationStore {
    private(set) var conversations: [Conversation] = []
    var selectedID: Conversation.ID?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var saveTasks: [UUID: Task<Void, Never>] = [:]

    var selected: Conversation? {
        guard let selectedID else { return nil }
        return conversations.first { $0.id == selectedID }
    }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("Dyno/conversations", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        load()
    }

    private func load() {
        let decoder = JSONDecoder()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        conversations = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Conversation.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
        selectedID = conversations.first?.id
    }

    @discardableResult
    func newConversation() -> Conversation {
        // Reuse an untouched blank rather than piling up empties.
        if let existing = conversations.first(where: { $0.isEmpty }) {
            selectedID = existing.id
            return existing
        }
        let conversation = Conversation()
        conversations.insert(conversation, at: 0)
        selectedID = conversation.id
        return conversation
    }

    func update(_ conversation: Conversation, persist: Bool = true) {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else {
            return
        }
        var updated = conversation
        updated.updatedAt = Date()
        updated.retitleFromFirstMessage()
        conversations[index] = updated
        if persist { scheduleSave(updated) }
    }

    func delete(_ id: Conversation.ID) {
        conversations.removeAll { $0.id == id }
        saveTasks[id]?.cancel()
        try? FileManager.default.removeItem(at: fileURL(for: id))
        if selectedID == id { selectedID = conversations.first?.id }
    }

    func deleteAll() {
        for conversation in conversations { delete(conversation.id) }
    }

    /// Debounced: a streaming reply mutates the conversation on every token,
    /// and writing the file that often would be absurd.
    private func scheduleSave(_ conversation: Conversation) {
        saveTasks[conversation.id]?.cancel()
        saveTasks[conversation.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await self?.write(conversation)
        }
    }

    private func write(_ conversation: Conversation) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(conversation) else { return }
        try? data.write(to: fileURL(for: conversation.id), options: .atomic)
    }

    /// Flush anything still pending, on quit.
    func saveNow() {
        for conversation in conversations where !conversation.isEmpty {
            write(conversation)
        }
    }

    private func fileURL(for id: Conversation.ID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Where a "save the full trace" export lands.
    var exportDirectory: URL { directory.deletingLastPathComponent() }
}
