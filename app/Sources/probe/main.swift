// Command-line harness for the metrics and catalog layers.
import Foundation
import DynoKit

print("runtime: \(Runtime.current.map { "\($0)" } ?? "none found")")

for sort in [ModelCatalog.Sort.recent, .popular] {
    print("\n=== \(sort.title) ===")
    if let models = try? await ModelCatalog.featured(sort: sort, limit: 6) {
        for m in models {
            let created = m.createdAt.map { ISO8601DateFormatter().string(from: $0).prefix(10) } ?? "?"
            print("  \(created)  \(m.id.prefix(52))  [\(m.quantization ?? "-")]\(m.isMultimodal ? " mm" : "")")
        }
    }
}

print("\n=== search 'qwen3.8' (the case that was broken) ===")
if let models = try? await ModelCatalog.search("qwen3.8", sort: .popular, limit: 8) {
    for m in models { print("  \(m.id.prefix(56))  [\(m.quantization ?? "-")] \(m.pipeline ?? "-")") }
}

print("\n=== search 'gemma' ===")
if let models = try? await ModelCatalog.search("gemma", sort: .popular, limit: 5) {
    for m in models { print("  \(m.id.prefix(56))") }
}

print("\n=== speech models excluded? ===")
if let models = try? await ModelCatalog.featured(sort: .popular, limit: 20) {
    let bad = models.filter { ($0.pipeline ?? "").contains("speech") || ($0.pipeline ?? "").contains("audio") }
    print("  \(models.count) results, \(bad.count) speech/audio (should be 0)")
}
