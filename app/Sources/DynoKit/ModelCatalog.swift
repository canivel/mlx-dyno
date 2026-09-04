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
    /// `filter=mlx` alone also returns speech and vision models; the pipeline
    /// tag narrows it to things this app can actually serve.
    private static let common = "filter=mlx&pipeline_tag=text-generation"

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

    /// Most-downloaded MLX text models.
    public static func featured(limit: Int = 40) async throws -> [CatalogModel] {
        try await fetch("\(base)?\(common)&sort=downloads&direction=-1&limit=\(limit)")
    }

    public static func search(_ query: String, limit: Int = 40) async throws -> [CatalogModel] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try await featured(limit: limit) }
        let escaped = trimmed.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? trimmed
        return try await fetch(
            "\(base)?\(common)&search=\(escaped)&sort=downloads&direction=-1&limit=\(limit)"
        )
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

    private static func fetch(_ urlString: String) async throws -> [CatalogModel] {
        guard let url = URL(string: urlString) else { throw CatalogError.unreachable }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { throw CatalogError.unreachable }

        return payload.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
            let name = parts.count > 1 ? parts[1] : id
            return CatalogModel(
                id: id,
                name: name,
                author: parts.first ?? "",
                downloads: (entry["downloads"] as? NSNumber)?.intValue ?? 0,
                likes: (entry["likes"] as? NSNumber)?.intValue ?? 0,
                sizeBytes: nil,
                quantization: quantization(in: name)
            )
        }
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
