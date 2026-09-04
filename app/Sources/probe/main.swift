// Command-line harness for the metrics and catalog layers.
import Foundation
import DynoKit

print("runtime: \(Runtime.current.map { "\($0)" } ?? "none found")\n")

print("Featured MLX models on the hub:")
do {
    let featured = try await ModelCatalog.featured(limit: 6)
    for model in featured {
        let size = await ModelCatalog.size(of: model.id)
        print(String(format: "  %-52s %8s  %-6s  %d downloads",
                     (model.id as NSString).utf8String!,
                     ((size.map { Format.bytes($0) } ?? "?") as NSString).utf8String!,
                     ((model.quantization ?? "-") as NSString).utf8String!,
                     model.downloads))
    }
} catch { print("  catalog failed: \(error.localizedDescription)") }

print("\nSearch 'qwen3':")
if let results = try? await ModelCatalog.search("qwen3", limit: 4) {
    for model in results { print("  \(model.id)  [\(model.quantization ?? "-")]") }
}

print("\nDownload a small model through the manager:")
let manager = DownloadManager()
let done = DispatchSemaphore(value: 0)
manager.onChange = { progress in
    guard let p = progress["mlx-community/Qwen1.5-0.5B-Chat-4bit"] else { return }
    if let error = p.error { print("  error: \(error)"); done.signal(); return }
    if p.isFinished { print("  finished: \(Format.bytes(p.downloadedBytes))"); done.signal(); return }
    if let fraction = p.fraction {
        print(String(format: "  %.0f%%  %@ of %@", fraction * 100,
                     Format.bytes(p.downloadedBytes), Format.bytes(p.totalBytes)))
    }
}
manager.download("mlx-community/Qwen1.5-0.5B-Chat-4bit")
_ = done.wait(timeout: .now() + 180)
