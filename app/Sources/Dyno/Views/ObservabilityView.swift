import Charts
import DynoKit
import SwiftUI

/// Performance over time.
///
/// The Run tab answers "what is it doing now"; this answers "what has it been
/// doing", which is the question that matters when comparing quantisations or
/// working out why a run slowed down.
struct ObservabilityView: View {
    var model: MonitorModel

    private var snapshot: Snapshot { model.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                summary
                charts
                if let served = snapshot.models.first, let stats = served.stats {
                    serverDetail(served, stats)
                }
                requestLog
            }
            .padding(20)
        }
    }

    // MARK: - Headline numbers

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading("Now", trailing: model.system.chip)
            HStack(spacing: 26) {
                Tile(value: String(format: "%.0f%%", snapshot.gpu.busyPercent),
                     caption: "GPU busy",
                     detail: snapshot.gpu.frequencyMHz.map { String(format: "%.0f MHz", $0) })
                Tile(value: snapshot.models.first?.tokensPerSecond
                        .map { String(format: "%.1f", $0) } ?? "—",
                     caption: "tokens/sec",
                     detail: snapshot.models.first?.rateSource.label)
                Tile(value: snapshot.bandwidth.totalGBps.map { String(format: "%.0f", $0) } ?? "—",
                     caption: "GB/s DRAM",
                     detail: String(format: "read %.0f", snapshot.bandwidth.readGBps ?? 0))
                Tile(value: Format.bytes(snapshot.memory.gpuUsed, precision: 0),
                     caption: "GPU memory",
                     detail: "of \(Format.bytes(snapshot.memory.gpuBudget, precision: 0))")
                Tile(value: Format.watts(snapshot.power.socWatts),
                     caption: "SoC power",
                     detail: snapshot.power.systemWatts.map { String(format: "%.0f W wall", $0) })
            }
        }
    }

    // MARK: - Charts

    private var charts: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading("History", trailing: "\(model.history.gpu.all.count) samples")
            HStack(spacing: 14) {
                TrendChart(title: "GPU busy", unit: "%",
                           values: model.history.gpu.all, ceiling: 100, tint: .green)
                TrendChart(title: "Tokens/sec", unit: "tok/s",
                           values: model.history.tokenRate.all, ceiling: nil,
                           tint: .accentColor, floor: 20)
            }
            HStack(spacing: 14) {
                TrendChart(title: "Memory bandwidth", unit: "GB/s",
                           values: model.history.bandwidth.all,
                           ceiling: model.system.peakBandwidthGBps, tint: .blue)
                TrendChart(title: "GPU power", unit: "W",
                           values: model.history.gpuPower.all, ceiling: nil,
                           tint: .purple, floor: 10)
            }
            HStack(spacing: 14) {
                TrendChart(title: "GPU memory", unit: "GB",
                           values: model.history.gpuMemory.all.map { $0 / GB },
                           ceiling: model.system.gpuMemoryBudget.map { Double($0) / GB },
                           tint: .teal)
                TrendChart(title: "Wall power", unit: "W",
                           values: model.history.systemPower.all,
                           ceiling: snapshot.power.adapterMaxWatts, tint: .orange)
            }
        }
    }

    // MARK: - Server counters

    private func serverDetail(_ served: LLMModel, _ stats: ServerStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading("Server", trailing: served.name)
            HStack(spacing: 26) {
                Tile(value: "\(stats.requestsTotal)", caption: "requests")
                Tile(value: "\(stats.generatedTokens)", caption: "tokens generated")
                Tile(value: stats.timeToFirstToken.map { String(format: "%.2fs", $0) } ?? "—",
                     caption: "last TTFT")
                Tile(value: stats.promptTokensPerSecond
                        .map { String(format: "%.0f", $0) } ?? "—",
                     caption: "prefill tok/s")
                Tile(value: stats.cacheHitRate.map { String(format: "%.0f%%", $0) } ?? "—",
                     caption: "prompt cache",
                     detail: "\(stats.cachedPromptTokens) of \(stats.promptTokens)")
                Tile(value: "\(stats.activeRequests)", caption: "in flight")
            }
        }
    }

    // MARK: - Warnings and processes

    private var requestLog: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !snapshot.warnings.isEmpty {
                SectionHeading("Attention")
                ForEach(snapshot.warnings, id: \.self) { warning in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                        Text(warning).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            SectionHeading("Processes using the GPU")
            ForEach(snapshot.processes) { process in
                HStack(spacing: 8) {
                    Circle().fill(process.usesGPU ? Color.purple : .clear)
                        .frame(width: 5, height: 5)
                    Text(process.name)
                        .font(.system(size: 11,
                                      weight: process.isKnownRuntime ? .medium : .regular))
                        .lineLimit(1).truncationMode(.middle)
                    if let runtime = process.runtime {
                        Text(runtime).font(.system(size: 9))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                    Spacer(minLength: 8)
                    Text(Format.bytes(process.memory)).font(.system(size: 10))
                        .foregroundStyle(.secondary).monospacedDigit()
                    Text(String(format: "%.0f%%", process.cpuPercent))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - Pieces

struct SectionHeading: View {
    var title: String
    var trailing: String?
    init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }
    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary).tracking(0.7)
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 10)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

private struct Tile: View {
    var value: String
    var caption: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 22, weight: .medium)).monospacedDigit()
            Text(caption).font(.system(size: 10)).foregroundStyle(.secondary)
            if let detail, !detail.isEmpty {
                Text(detail).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// A single metric over time.
///
/// `ceiling` pins the y-axis where a real maximum exists — GPU percentage, the
/// memory budget, the adapter's rating — so the shape means something between
/// frames instead of rescaling to whatever just happened.
private struct TrendChart: View {
    var title: String
    var unit: String
    var values: [Double]
    var ceiling: Double?
    var tint: Color

    private var points: [(index: Int, value: Double)] {
        Array(values.suffix(180)).enumerated().map { ($0.offset, $0.element) }
    }

    /// A floor as well as a ceiling: an all-zero series scaled to its own
    /// maximum produces an axis labelled in ten-thousandths.
    var floor: Double = 1

    private var upperBound: Double {
        if let ceiling, ceiling > 0 { return ceiling }
        return max((values.max() ?? 0) * 1.25, floor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(String(format: "%.0f %@", values.last ?? 0, unit))
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }
            Chart(points, id: \.index) { point in
                AreaMark(x: .value("t", point.index), y: .value(unit, point.value))
                    .foregroundStyle(.linearGradient(
                        colors: [tint.opacity(0.28), tint.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    ))
                LineMark(x: .value("t", point.index), y: .value(unit, point.value))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.4))
            }
            .chartYScale(domain: 0...upperBound)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                    AxisValueLabel().font(.system(size: 8)).foregroundStyle(.tertiary)
                }
            }
            .frame(height: 92)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color.primary.opacity(0.035)))
    }
}
