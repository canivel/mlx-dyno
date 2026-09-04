import Foundation

/// One routing decision, as the router recorded it.
public struct RouteTrace: Sendable, Identifiable, Equatable {
    public struct Candidate: Sendable, Equatable {
        public var model: String
        public var estimatedSeconds: Double
        public var tokensPerSecond: Double?
        public var rejectedBecause: String?
        public var wasChosen: Bool { rejectedBecause == nil }
    }

    public var id: String
    public var date: Date
    public var prompt: String
    public var chosen: String
    public var mechanism: String
    public var reason: String
    public var tier: String?
    public var candidates: [Candidate] = []
    public var confidence: Double?
    public var escalatedFrom: String?
    public var escalatedTo: String?
    public var escalationReason: String?
    public var seconds: Double?
    public var secondsSaved: Double?

    public var didEscalate: Bool { escalatedFrom != nil }
}

/// A model server the router can send work to.
public struct RouterBackend: Sendable, Identifiable, Equatable {
    public var id: String { url }
    public var url: String
    public var name: String
    public var port: Int
    public var capability: Double
    public var parametersB: Double?
    public var bits: Int?
    public var tokensPerSecond: Double?
    public var activeRequests: Int
}

/// Reads the router's decision log.
///
/// The router is a separate process on its own port, so this is a plain client
/// rather than anything shared: the app shows what the router did, and works
/// perfectly well when no router is running.
public final class RouterClient: @unchecked Sendable {
    public struct Snapshot: Sendable, Equatable {
        public init() {}

        public var isReachable = false
        public var backends: [RouterBackend] = []
        public var traces: [RouteTrace] = []
        public var requestsTotal = 0
        public var escalationsTotal = 0
        public var secondsSaved = 0.0
    }

    public var port: UInt16

    private let session: URLSession

    public init(port: UInt16 = 8970) {
        self.port = port
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2.5
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    public func fetch() async -> Snapshot {
        var snapshot = Snapshot()
        guard let health = await get("/health"), health["status"] != nil else {
            return snapshot
        }
        snapshot.isReachable = true

        if let payload = await get("/backends"),
           let entries = payload["backends"] as? [[String: Any]] {
            snapshot.backends = entries.compactMap(Self.backend)
        }
        if let payload = await get("/routes"),
           let entries = payload["routes"] as? [[String: Any]] {
            snapshot.traces = entries.compactMap(Self.trace)
        }
        if let text = await getText("/metrics") {
            snapshot.requestsTotal = Self.metric(text, "dyno_router_requests_total")
            snapshot.escalationsTotal = Self.metric(text, "dyno_router_escalations_total")
            snapshot.secondsSaved = Double(
                Self.metric(text, "dyno_router_seconds_saved_total")
            )
        }
        return snapshot
    }

    // MARK: - Parsing

    private static func backend(_ raw: [String: Any]) -> RouterBackend? {
        guard let url = raw["url"] as? String, let name = raw["name"] as? String else {
            return nil
        }
        return RouterBackend(
            url: url,
            name: name,
            port: (raw["port"] as? NSNumber)?.intValue ?? 0,
            capability: (raw["capability"] as? NSNumber)?.doubleValue ?? 0,
            parametersB: (raw["parameters_b"] as? NSNumber)?.doubleValue,
            bits: (raw["bits"] as? NSNumber)?.intValue,
            tokensPerSecond: (raw["tokens_per_second"] as? NSNumber)?.doubleValue,
            activeRequests: (raw["active_requests"] as? NSNumber)?.intValue ?? 0
        )
    }

    private static func trace(_ raw: [String: Any]) -> RouteTrace? {
        guard let id = raw["id"] as? String,
              let decision = raw["decision"] as? [String: Any],
              let chosen = decision["chosen"] as? String
        else { return nil }

        let candidates = (decision["candidates"] as? [[String: Any]] ?? []).map { entry in
            RouteTrace.Candidate(
                model: entry["model"] as? String ?? "",
                estimatedSeconds: (entry["estimated_seconds"] as? NSNumber)?.doubleValue ?? 0,
                tokensPerSecond: (entry["tokens_per_second"] as? NSNumber)?.doubleValue,
                rejectedBecause: entry["rejected_because"] as? String
            )
        }

        return RouteTrace(
            id: id,
            date: Date(timeIntervalSince1970: (raw["time"] as? NSNumber)?.doubleValue ?? 0),
            prompt: raw["prompt"] as? String ?? "",
            chosen: chosen,
            mechanism: decision["mechanism"] as? String ?? "",
            reason: decision["reason"] as? String ?? "",
            tier: decision["tier"] as? String,
            candidates: candidates,
            confidence: (raw["confidence"] as? NSNumber)?.doubleValue,
            escalatedFrom: raw["escalated_from"] as? String,
            escalatedTo: raw["escalated_to"] as? String,
            escalationReason: raw["escalation_reason"] as? String,
            seconds: (raw["seconds"] as? NSNumber)?.doubleValue,
            secondsSaved: (raw["seconds_saved"] as? NSNumber)?.doubleValue
        )
    }

    private static func metric(_ body: String, _ name: String) -> Int {
        for line in body.split(separator: "\n") where line.hasPrefix(name) {
            if let value = Double(line.split(separator: " ").last ?? "") {
                return Int(value)
            }
        }
        return 0
    }

    // MARK: - Transport

    private func get(_ path: String) async -> [String: Any]? {
        guard let data = await raw(path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func getText(_ path: String) async -> String? {
        guard let data = await raw(path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func raw(_ path: String) async -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)"),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }
}
