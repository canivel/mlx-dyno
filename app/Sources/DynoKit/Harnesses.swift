import Foundation

/// A coding tool that can be pointed at a local endpoint.
public struct HarnessEntry: Sendable, Identifiable {
    public var id: String { key }
    public var key: String
    public var name: String
    public var detail: String
    public var configPath: String
    public var state: String   // configured / ready / not found

    public var isConfigured: Bool { state == "configured" }
}

/// Reads and writes harness configuration through the CLI.
///
/// Deliberately not reimplemented in Swift: which file each tool reads and what
/// shape it wants is the entire feature, and having that knowledge in one place
/// means the CLI and the app can never disagree about it.
public enum Harnesses {
    public static func list() async -> [HarnessEntry] {
        guard let output = await run(["harness", "list"]) else { return [] }
        var entries: [HarnessEntry] = []
        var pending: (key: String, name: String, detail: String, state: String)?

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
                if let pending {
                    entries.append(HarnessEntry(
                        key: pending.key, name: pending.name, detail: pending.detail,
                        configPath: trimmed, state: pending.state
                    ))
                }
                pending = nil
                continue
            }
            // "  key        state        Name — description"
            guard text.hasPrefix("  "), trimmed.contains("—") else { continue }
            let fields = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3 else { continue }
            let key = String(fields[0])
            let state = fields[1] == "not" ? "not found" : String(fields[1])
            guard let dash = trimmed.range(of: "—") else { continue }
            let after = trimmed[trimmed.index(after: dash.lowerBound)...]
            let before = trimmed[..<dash.lowerBound]
            let name = before.split(separator: " ").dropFirst(state == "not found" ? 3 : 2)
                .joined(separator: " ")
            pending = (key, name.trimmingCharacters(in: .whitespaces),
                       String(after).trimmingCharacters(in: .whitespaces), state)
        }
        return entries
    }

    public static func configuration(
        for key: String, endpoint: String, model: String
    ) async -> String? {
        await run(["harness", "show", key, "--endpoint", endpoint, "--model", model])
    }

    @discardableResult
    public static func install(
        _ key: String, endpoint: String, model: String
    ) async -> String? {
        await run(["harness", "install", key, "--endpoint", endpoint, "--model", model])
    }

    private static func run(_ arguments: [String]) async -> String? {
        guard let invocation = Runtime.invocation(for: arguments) else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: invocation.executable)
        task.arguments = invocation.arguments
        task.environment = invocation.environment
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
