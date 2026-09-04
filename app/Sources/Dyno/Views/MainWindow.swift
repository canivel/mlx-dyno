import DynoKit
import SwiftUI

/// The app's window: pick a model on the left, watch it run on the right.
///
/// The menu bar popover stays the glanceable summary; this is where you
/// actually work — start a model, then see its throughput next to the machine
/// metrics that explain the number.
struct MainWindow: View {
    var model: MonitorModel

    @State private var tab: Tab

    init(model: MonitorModel, initialTab: Tab = .chat) {
        self.model = model
        _tab = State(initialValue: initialTab)
    }

    enum Tab: String, CaseIterable, Identifiable {
        case chat = "Chat"
        case run = "Models"
        case observe = "Performance"
        case discover = "Discover"
        var id: String { rawValue }
    }



    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 340)
                Spacer()
                if case let .running(name, port) = model.serverState {
                    HStack(spacing: 5) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("\(name) · :\(String(port))")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()

            switch tab {
            case .chat:
                ChatView(model: model)
            case .observe:
                ObservabilityView(model: model)
            case .run:
                HStack(spacing: 0) {
                    ModelSidebar(model: model)
                        .frame(width: 240)
                    Divider()
                    RunPanel(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .discover:
                DiscoverView(model: model)
            }
        }
        .frame(minWidth: 800, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        // One view asking to show another — Chat sending you to Run when
        // nothing is loaded — goes through the model rather than reaching into
        // this view's state directly.
        .onChange(of: model.requestedTab) { _, requested in
            if let requested { tab = requested; model.requestedTab = nil }
        }
    }
}

// MARK: - Sidebar

private struct ModelSidebar: View {
    var model: MonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("MODELS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.7)
                Spacer()
                Button {
                    model.rescanModels()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Rescan for models")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if model.localModels.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No MLX models found.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("Dyno looks in the Hugging Face cache, the LM Studio cache and ~/models.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Use Discover to download one.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.localModels) { candidate in
                            ModelRow(
                                candidate: candidate,
                                isSelected: model.selectedModel?.id == candidate.id,
                                isRunning: model.serverState.runningModel == candidate.name
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { model.selectedModel = candidate }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }

            Spacer()
            Divider()
            Button {
                chooseFolder()
            } label: {
                Label("Add folder…", systemImage: "plus")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(14)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        panel.message = "Choose a folder containing MLX models"
        if panel.runModal() == .OK, let url = panel.url {
            model.addModelFolder(url.path)
        }
    }
}

private struct ModelRow: View {
    var candidate: LocalModel
    var isSelected: Bool
    var isRunning: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isRunning ? Color.green : Color.clear)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.shortName)
                    .font(.system(size: 12, weight: isRunning ? .semibold : .regular))
                    .lineLimit(1).truncationMode(.tail)
                Text([candidate.owner, Format.bytes(candidate.sizeBytes)]
                        .compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        )
    }
}

// MARK: - Run panel

private struct RunPanel: View {
    var model: MonitorModel
    @State private var showingOptions = false

    private var snapshot: Snapshot { model.snapshot }
    /// The served model matching what we started, if the server is up.
    private var served: LLMModel? {
        guard let running = model.serverState.runningModel else {
            return snapshot.models.first
        }
        return snapshot.models.first { $0.name == running } ?? snapshot.models.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                controls
                launchOptions
                if let served, served.stats != nil || served.tokensPerSecond != nil {
                    throughput(served)
                } else {
                    idleHint
                }
                hardware
            }
            .padding(20)
        }
    }

    // -- top row: what is running, and start/stop --------------------------

    private var controls: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Text(subline)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch model.serverState {
            case .running:
                Button("Stop") { model.stopServer() }
                    .controlSize(.large)
            case .launching:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.stopServer() }
                }
            case .stopped, .failed:
                Button("Start") { model.startSelectedModel() }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedModel == nil || model.runtime == nil)
            }
        }
    }

    private var headline: String {
        switch model.serverState {
        case let .running(name, _), let .launching(name):
            return name.split(separator: "/").last.map(String.init) ?? name
        default: return model.selectedModel?.shortName ?? "No model selected"
        }
    }

    private var subline: String {
        switch model.serverState {
        case let .running(_, port):
            return "Running · OpenAI API on 127.0.0.1:\(port)"
        case .launching:
            return "Loading into unified memory…"
        case let .failed(message):
            return message
        case .stopped:
            guard model.runtime != nil else { return "No Python runtime found — reinstall Dyno" }
            guard let selected = model.selectedModel else { return "Pick a model on the left" }
            return "\(Format.bytes(selected.sizeBytes)) · ready to start"
        }
    }

    /// Server flags. Collapsed by default — most runs want the defaults, and
    /// changing one of these means restarting the model.
    @ViewBuilder
    private var launchOptions: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { showingOptions.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showingOptions ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8))
                    Text("LAUNCH OPTIONS")
                        .font(.system(size: 10, weight: .semibold)).tracking(0.7)
                    Text(model.launchOptions.summary)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer()
                }
                .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)

            if showingOptions {
                let options = Binding(
                    get: { model.launchOptions }, set: { model.launchOptions = $0 }
                )
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 20) {
                        number("Max tokens", options.maxTokens, 128...131_072, 512)
                        number("Prompt cache", options.promptCacheSize, 0...200, 5)
                        number("Decode concurrency", options.decodeConcurrency, 1...16, 1)
                        number("Prompt concurrency", options.promptConcurrency, 1...16, 1)
                    }
                    HStack(spacing: 20) {
                        decimal("Temperature", options.temperature, 0...2)
                        decimal("Top-p", options.topP, 0.05...1)
                        number("Top-k", options.topK, 0...200, 5)
                        Toggle("Trust remote code", isOn: options.trustRemoteCode)
                            .toggleStyle(.switch).controlSize(.mini)
                    }
                    if case .running = model.serverState {
                        Text("Restart the model for changes to take effect.")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 11))
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 9)
                    .fill(Color.primary.opacity(0.035)))
            }
        }
    }

    private func number(
        _ label: String, _ value: Binding<Int>, _ range: ClosedRange<Int>, _ step: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text("\(value.wrappedValue)").monospacedDigit()
                Stepper("", value: value, in: range, step: step)
                    .labelsHidden().controlSize(.mini)
            }
        }
    }

    private func decimal(
        _ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit()
                    .frame(width: 34, alignment: .leading)
                Slider(value: value, in: range).controlSize(.mini).frame(width: 78)
            }
        }
    }

    /// What the empty half of the panel is for, rather than blank space.
    private var idleHint: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeading("Throughput")
            Text("Start the model to measure it.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Text("Dyno reads tokens per second, time to first token, prefill rate and "
                 + "prompt-cache hits from inside the generation loop — not estimated "
                 + "from the outside.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    // -- measured throughput ------------------------------------------------

    private func throughput(_ served: LLMModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading("Throughput", trailing: served.rateSource == .measured
                           ? "measured by the server" : served.rateSource.label)
            HStack(alignment: .top, spacing: 26) {
                BigStat(
                    value: served.tokensPerSecond.map { String(format: "%.1f", $0) } ?? "—",
                    unit: "tok/s",
                    caption: served.rateSource == .estimated ? "estimated" : "decode"
                )
                if let stats = served.stats {
                    BigStat(
                        value: stats.timeToFirstToken.map { String(format: "%.2f", $0) } ?? "—",
                        unit: "s", caption: "to first token"
                    )
                    BigStat(
                        value: stats.promptTokensPerSecond.map { String(format: "%.0f", $0) } ?? "—",
                        unit: "tok/s", caption: "prefill"
                    )
                    BigStat(
                        value: stats.cacheHitRate.map { String(format: "%.0f", $0) } ?? "—",
                        unit: "%", caption: "prompt cache"
                    )
                    BigStat(value: "\(stats.activeRequests)", unit: "", caption: "active")
                }
            }
            Sparkline(values: model.history.tokenRate.all, ceiling: nil, color: .accentColor)
                .frame(height: 54)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
        }
    }

    // -- the machine underneath ---------------------------------------------

    private var hardware: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading("Machine", trailing: model.system.chip)
            MeterRow(
                label: "GPU",
                value: String(format: "%.0f%%", snapshot.gpu.busyPercent),
                detail: snapshot.gpu.frequencyMHz.map { String(format: "%.0f MHz", $0) },
                fraction: snapshot.gpu.busyPercent / 100
            )
            MeterRow(
                label: "GPU memory",
                value: Format.bytes(snapshot.memory.gpuUsed),
                detail: "of \(Format.bytes(snapshot.memory.gpuBudget))",
                fraction: (snapshot.memory.gpuUsedPercent ?? 0) / 100
            )
            MeterRow(
                label: "Bandwidth",
                value: snapshot.bandwidth.totalGBps.map { String(format: "%.0f GB/s", $0) } ?? "—",
                detail: model.system.peakBandwidthGBps.map { String(format: "of %.0f", $0) }
                    ?? "peak unknown",
                // Without a published peak for this chip, scale against what
                // this machine has actually reached rather than showing a bar
                // pinned at 100% of itself.
                fraction: (snapshot.bandwidth.totalGBps ?? 0)
                    / (model.system.peakBandwidthGBps
                       ?? max(model.history.bandwidth.peak * 1.25, 64)),
                tint: .blue
            )
            MeterRow(
                label: "Power",
                value: Format.watts(snapshot.power.socWatts),
                detail: snapshot.power.systemWatts.map { String(format: "%.0f W wall", $0) },
                fraction: (snapshot.power.socWatts ?? 0)
                    / max(model.history.gpuPower.peak + 20, 30),
                tint: .purple
            )

            if !snapshot.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(snapshot.warnings, id: \.self) { warning in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10)).foregroundStyle(.orange)
                            Text(warning).font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - Small pieces

private struct BigStat: View {
    var value: String
    var unit: String
    var caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 26, weight: .medium))
                    .monospacedDigit()
                Text(unit).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(caption).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}

private struct MeterRow: View {
    var label: String
    var value: String
    var detail: String?
    var fraction: Double
    var tint: Color?

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                .frame(width: 82, alignment: .trailing)
            GaugeBar(fraction: fraction, color: tint, height: 7)
            if let detail {
                Text(detail)
                    .font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                    .frame(width: 84, alignment: .leading)
            }
        }
    }
}
