import Foundation

/// A model on the Hugging Face hub that MLX can run.
public struct CatalogModel: Sendable, Identifiable, Hashable {
    public var id: String            // "mlx-community/Qwen3-8B-4bit"
    public var name: String          // "Qwen3-8B-4bit"
    public var author: String
    public var downloads: Int
    public var likes: Int
    public var sizeBytes: Int64?
    public var quantization: String?
    public var pipeline: String?
    public var createdAt: Date?
    public var updatedAt: Date?

    /// Multimodal models are still servable, but worth flagging: they are
    /// bigger than a text-only build of the same weights.
    public var isMultimodal: Bool {
        pipeline == "image-text-to-text" || pipeline == "any-to-any"
    }

    public var sizeGB: Double? {
        guard let sizeBytes else { return nil }
        return Double(sizeBytes) / GB
    }
}

/// Browses MLX models on the Hugging Face hub.
///
/// The hub's read API needs no token for public models, so this works out of
/// the box. Listing is done here rather than in Python: it is one request, and
/// the browser should stay responsive whether or not a model is loaded.
public enum ModelCatalog {
    private static let base = "https://huggingface.co/api/models"

    /// How the hub should order results.
    public enum Sort: String, Sendable, CaseIterable, Identifiable {
        /// Most downloaded. The default: a freshly created repository has no
        /// downloads and no likes yet, so ordering by date shows a column of
        /// zeroes and gives nothing to choose on.
        case popular
        case liked
        /// Newest repositories first — what "just released" means on the hub.
        case recent
        /// Recently re-uploaded or fixed.
        case updated

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .recent: return "Newest"
            case .updated: return "Updated"
            case .popular: return "Popular"
            case .liked: return "Liked"
            }
        }

        var apiValue: String {
            switch self {
            case .recent: return "createdAt"
            case .updated: return "lastModified"
            case .popular: return "downloads"
            case .liked: return "likes"
            }
        }
    }

    /// Pipeline tags this app can actually serve.
    ///
    /// Filtering on `pipeline_tag=text-generation` in the query is wrong and
    /// hides the best models: current multimodal LLMs — Qwen3.8, Gemma 3 — are
    /// tagged `image-text-to-text`, and many MLX conversions carry no tag at
    /// all. So the query stays broad and speech and audio models are dropped
    /// here instead.
    private static let excludedPipelines: Set<String> = [
        "automatic-speech-recognition", "text-to-speech", "text-to-audio",
        "audio-to-audio", "audio-classification", "voice-activity-detection",
        "text-to-image", "image-to-image", "image-classification",
        "image-segmentation", "object-detection", "depth-estimation",
        "text-to-video", "video-classification", "zero-shot-image-classification",
        "feature-extraction", "sentence-similarity", "fill-mask",
        "token-classification", "image-feature-extraction",
    ]

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    public enum CatalogError: Error, LocalizedError {
        case unreachable
        public var errorDescription: String? {
            "Could not reach the Hugging Face hub. Check your connection."
        }
    }

    public static func featured(
        sort: Sort = .popular, limit: Int = 50
    ) async throws -> [CatalogModel] {
        try await fetch(query: nil, sort: sort, limit: limit)
    }

    public static func search(
        _ query: String, sort: Sort = .popular, limit: Int = 50
    ) async throws -> [CatalogModel] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await fetch(query: trimmed.isEmpty ? nil : trimmed, sort: sort, limit: limit)
    }

    /// Total download size, summed from the repository's file listing.
    /// Requested separately because the listing endpoint omits blob sizes.
    public static func size(of repository: String) async -> Int64? {
        let escaped = repository.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? repository
        guard let url = URL(string: "\(base)/\(escaped)?blobs=true"),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let siblings = payload["siblings"] as? [[String: Any]]
        else { return nil }

        var total: Int64 = 0
        for sibling in siblings {
            let name = sibling["rfilename"] as? String ?? ""
            // Skip formats MLX will not load; they would inflate the estimate.
            if [".bin", ".pth", ".gguf", ".onnx"].contains(where: { name.hasSuffix($0) }) {
                continue
            }
            total += (sibling["size"] as? NSNumber)?.int64Value ?? 0
        }
        return total > 0 ? total : nil
    }

    private static func fetch(
        query: String?, sort: Sort, limit: Int
    ) async throws -> [CatalogModel] {
        // Ask for extra: some of what comes back is filtered out below.
        var components = "filter=mlx&sort=\(sort.apiValue)&direction=-1&limit=\(limit * 2)"
        if let query, !query.isEmpty {
            let escaped = query.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed
            ) ?? query
            components += "&search=\(escaped)"
        }
        guard let url = URL(string: "\(base)?\(components)") else {
            throw CatalogError.unreachable
        }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { throw CatalogError.unreachable }

        let models: [CatalogModel] = payload.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            if let pipeline = entry["pipeline_tag"] as? String,
               excludedPipelines.contains(pipeline) { return nil }

            let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
            let name = parts.count > 1 ? parts[1] : id
            return CatalogModel(
                id: id,
                name: name,
                author: parts.first ?? "",
                downloads: (entry["downloads"] as? NSNumber)?.intValue ?? 0,
                likes: (entry["likes"] as? NSNumber)?.intValue ?? 0,
                sizeBytes: nil,
                quantization: quantization(in: name),
                pipeline: entry["pipeline_tag"] as? String,
                createdAt: date(from: entry["createdAt"] as? String),
                updatedAt: date(from: entry["lastModified"] as? String)
            )
        }
        return Array(models.prefix(limit))
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func date(from raw: String?) -> Date? {
        guard let raw else { return nil }
        return isoFormatter.date(from: raw)
            ?? ISO8601DateFormatter().date(from: raw)
    }

    /// MLX conversions carry their precision in the repository name; showing it
    /// saves opening the model card to find out how big it will be.
    static func quantization(in name: String) -> String? {
        let lowered = name.lowercased()
        for bits in ["2bit", "3bit", "4bit", "5bit", "6bit", "8bit"]
        where lowered.contains(bits) {
            return bits.replacingOccurrences(of: "bit", with: "-bit")
        }
        for wide in ["bf16", "fp16", "float16", "mxfp4", "fp8"] where lowered.contains(wide) {
            return wide.uppercased()
        }
        return nil
    }
}
