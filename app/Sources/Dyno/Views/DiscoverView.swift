import DynoKit
import SwiftUI

/// Browse MLX models on the Hugging Face hub and download one.
///
/// The two things that decide whether a model is worth downloading are its size
/// against this machine's GPU budget, and its precision — both are shown on the
/// row, so nobody has to open a model card to find out a 103 GB repo will not
/// fit.
struct DiscoverView: View {
    var model: MonitorModel

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            content
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary).font(.system(size: 12))
            TextField(
                "Search MLX models on Hugging Face",
                text: Binding(
                    get: { model.searchText },
                    set: { model.searchCatalog($0) }
                )
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            if model.isSearching {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.catalogError {
            centred {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 22)).foregroundStyle(.tertiary)
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Try again") { model.loadCatalog() }.controlSize(.small)
            }
        } else if model.catalog.isEmpty && !model.isSearching {
            centred {
                Text("No MLX models matched.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.catalog) { candidate in
                        CatalogRow(
                            model: model,
                            candidate: candidate,
                            isDownloaded: model.downloadedRepositories.contains(candidate.id),
                            progress: model.downloads[candidate.id],
                            budget: model.system.gpuMemoryBudget
                        )
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
    }

    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 10) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CatalogRow: View {
    var model: MonitorModel
    var candidate: CatalogModel
    var isDownloaded: Bool
    var progress: DownloadManager.Progress?
    var budget: Int64?

    /// A model whose weights alone exceed the GPU budget cannot run here, and
    /// one that is close will have no room left for the KV cache.
    private var fitsComfortably: Bool {
        guard let budget, let size = candidate.sizeBytes else { return true }
        return Double(size) < Double(budget) * 0.85
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(candidate.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    if let quantization = candidate.quantization {
                        Text(quantization)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                    if !fitsComfortably {
                        Label("too large", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .help("Larger than this Mac's GPU memory budget.")
                    }
                }
                HStack(spacing: 8) {
                    Text(candidate.author)
                    if let size = candidate.sizeBytes {
                        Text("· \(Format.bytes(size))")
                    }
                    Text("· \(formatted(candidate.downloads)) downloads")
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            }
            Spacer(minLength: 8)
            action
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var action: some View {
        if let progress, let error = progress.error {
            VStack(alignment: .trailing, spacing: 2) {
                Text("Failed").font(.system(size: 10)).foregroundStyle(.red)
                Button("Dismiss") { model.dismissDownload(candidate.id) }
                    .controlSize(.mini)
            }
            .help(error)
        } else if let progress, !progress.isFinished {
            VStack(alignment: .trailing, spacing: 3) {
                if let fraction = progress.fraction {
                    ProgressView(value: fraction).frame(width: 96)
                    Text("\(Format.bytes(progress.downloadedBytes)) of "
                         + "\(Format.bytes(progress.totalBytes))")
                        .font(.system(size: 9)).foregroundStyle(.tertiary).monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                }
                Button("Cancel") { model.cancelDownload(candidate) }
                    .controlSize(.mini)
            }
        } else if isDownloaded || progress?.isFinished == true {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.system(size: 11))
                Text("Downloaded").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } else {
            Button("Download") { model.download(candidate) }
                .controlSize(.small)
                .disabled(model.runtime == nil)
        }
    }

    private func formatted(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.0fk", Double(count) / 1_000) }
        return "\(count)"
    }
}
