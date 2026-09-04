import DynoKit
import ServiceManagement
import SwiftUI

/// The dropdown panel shown when the status item is clicked.
struct DashboardPanel: View {
    var model: MonitorModel
    @State private var showingSettings = false

    private var snapshot: Snapshot { model.snapshot }
    private var system: SystemInfo { model.system }

    var body: some View {
        ScrollView {
            content
        }
        .frame(width: 340)
        .frame(maxHeight: maximumHeight)
        .scrollBounceBehavior(.basedOnSize)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let error = model.startupError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            } else {
                if !snapshot.models.isEmpty {
                    modelSection
                    Divider()
                }
                serveSection
                Divider()
                gpuSection
                Divider()
                memorySection
                Divider()
                powerSection
                Divider()
                bandwidthSection
                if !snapshot.processes.isEmpty {
                    Divider()
                    processSection
                }
                if !snapshot.warnings.isEmpty {
                    Divider()
                    warningSection
                }
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    /// A popover taller than the screen cannot be presented, and this panel
    /// grows with the number of models, processes and warnings.
    private var maximumHeight: CGFloat {
        max((NSScreen.main?.visibleFrame.height ?? 800) - 40, 400)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(system.chip)
                .font(.system(size: 13, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let cores = system.gpuCores { parts.append("\(cores)-core GPU") }
        parts.append("\(Format.bytes(system.totalMemory, precision: 0)) unified")
        if system.cpuCores > 0 { parts.append("\(system.cpuCores)-core CPU") }
        return parts.joined(separator: " · ")
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(
                title: snapshot.models.count == 1 ? "Model loaded" : "Models loaded",
                trailing: snapshot.models.count > 1 ? "\(snapshot.models.count)" : nil
            )
            ForEach(snapshot.models) { model in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(model.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(model.runtime)
                            .font(.system(size: 9))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                        Spacer(minLength: 4)
                        rateView(model)
                    }
                    HStack(spacing: 4) {
                        Text(Format.bytes(model.sizeBytes))
                        if let port = model.port {
                            Text("· :\(String(port))")
                        }
                        if let context = model.contextLength {
                            Text("· \(context / 1024)K ctx")
                        }
                        if let stats = model.stats, stats.activeRequests > 0 {
                            Text("· \(stats.activeRequests) active")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()

                    if let stats = model.stats {
                        serverDetail(stats)
                    }
                }
            }
        }
    }

    /// The extra figures only an instrumented server can report.
    private func serverDetail(_ stats: ServerStats) -> some View {
        HStack(spacing: 10) {
            if let ttft = stats.timeToFirstToken {
                metric("TTFT", String(format: "%.2fs", ttft))
            }
            if let prompt = stats.promptTokensPerSecond {
                metric("prompt", String(format: "%.0f/s", prompt))
            }
            if let cache = stats.cacheHitRate, stats.promptTokens > 0 {
                metric("cache", String(format: "%.0f%%", cache))
            }
            if stats.generatedTokens > 0 {
                metric("total", "\(stats.generatedTokens) tok")
            }
            Spacer()
        }
        .padding(.top, 1)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.system(size: 9))
    }

    /// Token throughput, with the provenance of the number attached. An
    /// estimate and a runtime-reported figure should never look alike.
    @ViewBuilder
    private func rateView(_ model: LLMModel) -> some View {
        switch model.rateSource {
        case .idle:
            Text("idle")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        case .unavailable:
            Text("—")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .help(unavailableExplanation)
        case .measured, .estimated:
            HStack(spacing: 3) {
                Text(model.rateSource == .estimated ? "≈" : "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1f", model.tokensPerSecond ?? 0))
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: -1) {
                    Text("tok/s").font(.system(size: 8))
                    Text(model.rateSource.label).font(.system(size: 7))
                }
                .foregroundStyle(.secondary)
            }
            .help(model.rateSource == .estimated ? estimateExplanation : measuredExplanation)
        }
    }

    private var measuredExplanation: String {
        "Reported by the runtime's own token counters."
    }

    private var estimateExplanation: String {
        """
        Estimated from memory bandwidth: generating a token re-reads the whole \
        weight set, so read bandwidth divided by model size gives the decode \
        rate. Accurate to a few percent when this model has the GPU to itself; \
        reads high when other requests or other GPU work share the bandwidth.
        """
    }

    private var unavailableExplanation: String {
        "More than one model is loaded, so bandwidth cannot be attributed to "
            + "any single one. Runtimes that expose /metrics (llama.cpp, vLLM) "
            + "report a measured rate instead."
    }

    // MARK: - Serving

    @ViewBuilder
    private var serveSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: "Serve a model", trailing: serverStatusText)

            if model.runtime == nil {
                setupHint
            } else {
                switch model.serverState {
                case .running(let name, let port):
                    HStack(spacing: 6) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text(name)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                        Text(":\(String(port))")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                        Spacer()
                        Button("Stop") { model.stopServer() }
                            .font(.system(size: 10))
                    }
                case .launching(let name):
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                            .frame(width: 10, height: 10)
                        Text("Loading \(name)…")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Cancel") { model.stopServer() }
                            .font(.system(size: 10))
                    }
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message)
                            .font(.system(size: 10)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        modelPicker
                    }
                case .stopped:
                    modelPicker
                }
            }
        }
    }

    private var serverStatusText: String? {
        switch model.serverState {
        case .running: return "running"
        case .launching: return "loading"
        case .failed: return "failed"
        case .stopped: return model.localModels.isEmpty ? nil : "\(model.localModels.count) found"
        }
    }

    private var modelPicker: some View {
        HStack(spacing: 6) {
            if model.localModels.isEmpty {
                Text("No MLX models found. Add a folder in Settings.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
            } else {
                Picker("", selection: Binding(
                    get: { model.selectedModel },
                    set: { model.selectedModel = $0 }
                )) {
                    ForEach(model.localModels) { candidate in
                        Text("\(candidate.name)  ·  \(Format.bytes(candidate.sizeBytes, precision: 0))")
                            .tag(Optional(candidate))
                    }
                }
                .labelsHidden()
                .font(.system(size: 10))
                Button("Start") { model.startSelectedModel() }
                    .font(.system(size: 10))
                    .disabled(model.selectedModel == nil)
            }
        }
        .controlSize(.small)
    }

    private var setupHint: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("dyno not found — install it to run models from here:")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Text("uv venv ~/.mlx-dyno/venv && uv pip install --python ~/.mlx-dyno/venv/bin/python 'mlx-dyno[serve]'")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var gpuSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel(title: "GPU", trailing: clockLabel)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%.0f%%", snapshot.gpu.busyPercent))
                    .font(.system(size: 22, weight: .medium))
                    .monospacedDigit()
                Text(Format.watts(snapshot.power.gpuWatts))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if snapshot.gpu.throttleEvents > 0 {
                    Label("throttled", systemImage: "thermometer.high")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
            }
            GaugeBar(fraction: snapshot.gpu.busyPercent / 100)
            Sparkline(values: model.history.gpu.all, ceiling: 100, color: .accentColor)
                .frame(height: 26)
        }
    }

    /// "520 / 1620 MHz" when the DVFS table is known, otherwise just the clock.
    private var clockLabel: String? {
        guard let current = snapshot.gpu.frequencyMHz else { return nil }
        if let maximum = system.gpuMaxMHz {
            return String(format: "%.0f / %.0f MHz", current, maximum)
        }
        return String(format: "%.0f MHz", current)
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel(
                title: "GPU memory (Metal working set)",
                trailing: snapshot.memory.gpuUsedPercent.map { String(format: "%.0f%%", $0) }
            )
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.bytes(snapshot.memory.gpuUsed))
                    .font(.system(size: 15, weight: .medium))
                    .monospacedDigit()
                Text("of \(Format.bytes(snapshot.memory.gpuBudget))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if let headroom = snapshot.memory.gpuHeadroom {
                    Text("\(Format.bytes(headroom)) free")
                        .font(.system(size: 11))
                        .foregroundStyle(headroom > Int64(4 * GB) ? .secondary : Color.red)
                        .monospacedDigit()
                }
            }
            GaugeBar(fraction: (snapshot.memory.gpuUsedPercent ?? 0) / 100)

            StatRow(
                label: "System memory",
                value: "\(Format.bytes(snapshot.memory.used)) of \(Format.bytes(snapshot.memory.total))",
                detail: String(format: "%.0f%%", snapshot.memory.usedPercent)
            )
            StatRow(
                label: "Wired · compressed · swap",
                value: [
                    Format.bytes(snapshot.memory.wired),
                    Format.bytes(snapshot.memory.compressed),
                    Format.bytes(snapshot.memory.swapUsed),
                ].joined(separator: "  ·  "),
                valueColor: snapshot.memory.swapUsed > 0 ? .red : .primary
            )
        }
    }

    private var powerSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel(title: "Power", trailing: Format.watts(snapshot.power.socWatts) + " SoC")
            let scale = max(10, model.history.gpuPower.peak, snapshot.power.socWatts ?? 0)
            rail("GPU", snapshot.power.gpuWatts, scale, .purple)
            rail("CPU", snapshot.power.cpuWatts, scale, .teal)
            rail("DRAM", snapshot.power.dramWatts, scale, .blue)
            if let ane = snapshot.power.aneWatts, ane > 0.05 {
                rail("ANE", ane, scale, .gray)
            }
            StatRow(
                label: snapshot.power.onBattery ? "Battery draw" : "Wall power",
                value: Format.watts(snapshot.power.systemWatts),
                detail: snapshot.power.adapterMaxWatts.map { String(format: "of %.0f W", $0) }
            )
        }
    }

    private func rail(_ name: String, _ watts: Double?, _ scale: Double, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            Text(Format.watts(watts))
                .font(.system(size: 10))
                .monospacedDigit()
                .frame(width: 46, alignment: .trailing)
            GaugeBar(fraction: (watts ?? 0) / scale, color: color, height: 4)
        }
    }

    private var bandwidthSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel(
                title: "Memory bandwidth",
                trailing: system.peakBandwidthGBps.map { String(format: "peak %.0f GB/s", $0) }
                    ?? "estimated"
            )
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(snapshot.bandwidth.totalGBps.map { String(format: "%.0f", $0) } ?? "--")
                    .font(.system(size: 15, weight: .medium))
                    .monospacedDigit()
                Text("GB/s")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(
                    format: "read %.0f · write %.0f",
                    snapshot.bandwidth.readGBps ?? 0, snapshot.bandwidth.writeGBps ?? 0
                ))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            if let peak = system.peakBandwidthGBps {
                GaugeBar(fraction: (snapshot.bandwidth.totalGBps ?? 0) / peak, color: .blue)
            }
            Sparkline(
                values: model.history.bandwidth.all,
                ceiling: system.peakBandwidthGBps,
                color: .blue
            )
            .frame(height: 22)
        }
    }

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(title: "Processes")
            ForEach(snapshot.processes) { process in
                HStack(spacing: 6) {
                    Circle()
                        .fill(process.usesGPU ? Color.purple : Color.clear)
                        .frame(width: 5, height: 5)
                    Text(process.name)
                        .font(.system(size: 11, weight: process.isKnownRuntime ? .medium : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(process.isKnownRuntime ? .primary : .secondary)
                    if let runtime = process.runtime {
                        Text(runtime)
                            .font(.system(size: 9))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                    Spacer(minLength: 4)
                    Text(Format.bytes(process.memory))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text(String(format: "%.0f%%", process.cpuPercent))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
    }

    private var warningSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(snapshot.warnings, id: \.self) { warning in
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .padding(.top, 1)
                    Text(warning)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showingSettings { settings }
            HStack(spacing: 10) {
                Button {
                    AppDelegate.shared?.showMainWindow()
                } label: {
                    Label("Open Dyno", systemImage: "macwindow")
                        .font(.system(size: 11))
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) { showingSettings.toggle() }
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .font(.system(size: 11))
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .font(.system(size: 11))
                    .keyboardShortcut("q")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Menu bar", selection: Binding(
                get: { model.menuBarContent },
                set: { model.menuBarContent = $0 }
            )) {
                ForEach(MenuBarContent.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            HStack {
                Text("Update every")
                Slider(
                    value: Binding(get: { model.interval }, set: { model.interval = $0 }),
                    in: 0.25...5.0,
                    step: 0.25
                )
                Text(String(format: "%.2gs", model.interval))
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
            }
            LaunchAtLoginToggle()
            HStack {
                Button("Add model folder…") { chooseModelFolder() }
                Button("Rescan") { model.rescanModels() }
                Spacer()
            }
            if !model.modelFolders.isEmpty {
                Text(model.modelFolders.joined(separator: "\n"))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
            }
            Button("Reset trends") { model.resetHistory() }
        }
        .font(.system(size: 11))
        .controlSize(.small)
    }
}

extension DashboardPanel {
    /// Ask for a folder to scan for MLX models. Sandboxing is off, so a plain
    /// open panel is enough.
    func chooseModelFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a folder containing MLX models"
        if panel.runModal() == .OK, let url = panel.url {
            model.addModelFolder(url.path)
        }
    }
}

/// Registers the app as a login item. Requires the app to be in a bundle, so
/// the toggle reports rather than hides a failure.
struct LaunchAtLoginToggle: View {
    @State private var isEnabled = SMAppService.mainApp.status == .enabled
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Open at login", isOn: Binding(
                get: { isEnabled },
                set: { newValue in
                    do {
                        try newValue
                            ? SMAppService.mainApp.register()
                            : SMAppService.mainApp.unregister()
                        isEnabled = newValue
                        failure = nil
                    } catch {
                        failure = error.localizedDescription
                    }
                }
            ))
            if let failure {
                Text(failure)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
        }
    }
}
