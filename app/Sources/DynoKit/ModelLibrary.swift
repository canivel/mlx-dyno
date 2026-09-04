import Foundation

/// A model on disk that MLX can load.
public struct LocalModel: Sendable, Identifiable, Equatable, Hashable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var sizeBytes: Int64
    /// Where it came from, for grouping in the picker.
    public var source: String

    public var sizeGB: Double { Double(sizeBytes) / GB }
}

/// Finds MLX-loadable models on disk.
///
/// A directory qualifies if it has a `config.json` and at least one weights
/// file; that is the same test `mlx_lm.load` effectively applies, and it avoids
/// listing half-downloaded or non-MLX repos.
public enum ModelLibrary {
    private static let weightSuffixes = [".safetensors", ".npz"]

    public static func defaultSearchPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.cache/huggingface/hub",
            "\(home)/.cache/lm-studio/models",
            "\(home)/models",
            "\(home)/Documents/models",
        ]
    }

    /// Scan the given roots plus the Hugging Face cache.
    public static func scan(extraPaths: [String] = [], limit: Int = 60) -> [LocalModel] {
        var found: [String: LocalModel] = [:]
        let roots = extraPaths + defaultSearchPaths()

        for root in roots {
            guard FileManager.default.fileExists(atPath: root) else { continue }
            let label = (root as NSString).lastPathComponent
            for directory in candidateDirectories(under: root) {
                guard found[directory] == nil, isModelDirectory(directory) else { continue }
                let size = directorySize(directory)
                // Anything this small is a stub or a config-only repo.
                guard size > 50 * 1024 * 1024 else { continue }
                found[directory] = LocalModel(
                    path: directory,
                    name: displayName(for: directory),
                    sizeBytes: size,
                    source: label
                )
                if found.count >= limit { break }
            }
        }
        return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Model directories sit either directly under a root, or two levels down
    /// inside a Hugging Face cache entry (`models--org--name/snapshots/<sha>`).
    private static func candidateDirectories(under root: String) -> [String] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: root) else { return [] }

        var directories: [String] = []
        for entry in entries where !entry.hasPrefix(".") {
            let path = (root as NSString).appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            if entry.hasPrefix("models--") {
                let snapshots = (path as NSString).appendingPathComponent("snapshots")
                if let revisions = try? manager.contentsOfDirectory(atPath: snapshots) {
                    for revision in revisions where !revision.hasPrefix(".") {
                        directories.append((snapshots as NSString).appendingPathComponent(revision))
                    }
                }
            } else {
                directories.append(path)
            }
        }
        return directories
    }

    private static func isModelDirectory(_ path: String) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: (path as NSString).appendingPathComponent("config.json")),
              let entries = try? manager.contentsOfDirectory(atPath: path)
        else { return false }
        return entries.contains { entry in
            weightSuffixes.contains { entry.hasSuffix($0) }
        }
    }

    /// A Hugging Face snapshot directory is named after a commit hash, so walk
    /// back up to the `models--org--name` entry for something readable.
    private static func displayName(for path: String) -> String {
        var components = (path as NSString).pathComponents
        if let index = components.lastIndex(where: { $0.hasPrefix("models--") }) {
            let raw = components[index].dropFirst("models--".count)
            return raw.replacingOccurrences(of: "--", with: "/")
        }
        return components.last ?? path
    }

    /// Sum of the weight files only. Walking every file would be slow on a
    /// cache with many snapshots, and the weights are what occupy memory.
    private static func directorySize(_ path: String) -> Int64 {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: path) else { return 0 }
        var total: Int64 = 0
        for entry in entries where weightSuffixes.contains(where: { entry.hasSuffix($0) }) {
            let file = (path as NSString).appendingPathComponent(entry)
            // Resolve the symlinks the Hugging Face cache uses for blobs.
            if let attributes = try? manager.attributesOfItem(atPath: file),
               let size = attributes[.size] as? NSNumber {
                if let type = attributes[.type] as? FileAttributeType, type == .typeSymbolicLink,
                   let resolved = try? manager.destinationOfSymbolicLink(atPath: file) {
                    let absolute = resolved.hasPrefix("/")
                        ? resolved
                        : (path as NSString).appendingPathComponent(resolved)
                    if let real = try? manager.attributesOfItem(atPath: absolute),
                       let realSize = real[.size] as? NSNumber {
                        total += realSize.int64Value
                        continue
                    }
                }
                total += size.int64Value
            }
        }
        return total
    }
}
