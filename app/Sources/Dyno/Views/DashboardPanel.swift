import AppKit
import DynoKit
import ServiceManagement
import SwiftUI

/// The menu bar popover.
///
/// Deliberately small: a glance, and a door into the app. Everything with any
/// depth — the model library, throughput history, processes — lives in the
/// window. A popover is the wrong place for it, and a tall one risks not being
/// presentable at all.
///
/// Note there is no `ScrollView` here. Inside a `MenuBarExtra` it expands to
/// the available height and the popover collapses to an empty strip.
struct DashboardPanel: View {
    var model: MonitorModel
    @State private var showingSettings = false

    private var snapshot: Snapshot { model.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            if let error = model.startupError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            } else {
                Divider()
                running
                Divider()
                machine
            }
            if showingSettings {
                Divider()
                settings
            }
            Divider()
            footer
        }
        .padding(13)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.system.chip).font(.system(size: 13, weight: .semibold))
            Spacer()
            Text("\(model.system.gpuCores ?? 0)-core GPU")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    // What is loaded, and how fast it is going.
    @ViewBuilder
    private var running: some View {
        if let served = snapshot.models.first {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(served.rateSource == .idle ? Color.secondary : Color.green)
                        .frame(width: 6, height: 6)
                    Text(served.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    if let rate = served.tokensPerSecond, served.rateSource != .idle {
                        Text(String(format: "%@%.1f tok/s",
                                    served.rateSource == .estimated ? "≈" : "", rate))
                            .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    } else {
                        Text("idle").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                Text([served.runtime, Format.bytes(served.sizeBytes),
                      served.port.map { ":\(String($0))" }]
                        .compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        } else {
            HStack(spacing: 6) {
                Text("No model running").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Open Dyno") { AppDelegate.shared?.showMainWindow() }
                    .controlSize(.small)
            }
        }
    }

    private var machine: some View {
        VStack(spacing: 6) {
            line("GPU", String(format: "%.0f%%", snapshot.gpu.busyPercent),
                 snapshot.gpu.busyPercent / 100, .green)
            line("Memory", Format.bytes(snapshot.memory.gpuUsed),
                 (snapshot.memory.gpuUsedPercent ?? 0) / 100, .green,
                 detail: "of \(Format.bytes(snapshot.memory.gpuBudget))")
            line("Bandwidth",
                 snapshot.bandwidth.totalGBps.map { String(format: "%.0f GB/s", $0) } ?? "—",
                 (snapshot.bandwidth.totalGBps ?? 0)
                    / (model.system.peakBandwidthGBps
                       ?? max(model.history.bandwidth.peak * 1.25, 64)), .blue)
            line("Power", Format.watts(snapshot.power.socWatts),
                 (snapshot.power.socWatts ?? 0) / max(model.history.gpuPower.peak + 20, 30),
                 .purple,
                 detail: snapshot.power.systemWatts.map { String(format: "%.0f W wall", $0) })
        }
    }

    private func line(
        _ label: String, _ value: String, _ fraction: Double, _ tint: Color,
        detail: String? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
            Text(value).font(.system(size: 11, weight: .medium)).monospacedDigit()
                .frame(width: 62, alignment: .trailing)
            GaugeBar(fraction: fraction, color: tint, height: 5)
            if let detail {
                Text(detail).font(.system(size: 9)).foregroundStyle(.tertiary)
                    .frame(width: 62, alignment: .leading)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                AppDelegate.shared?.showMainWindow()
            } label: {
                Label("Open Dyno", systemImage: "macwindow").font(.system(size: 11))
            }
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { showingSettings.toggle() }
            } label: {
                Image(systemName: "gearshape").font(.system(size: 11))
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .font(.system(size: 11))
                .keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker("Menu bar", selection: Binding(
                get: { model.menuBarContent }, set: { model.menuBarContent = $0 }
            )) {
                ForEach(MenuBarContent.allCases) { Text($0.title).tag($0) }
            }
            HStack {
                Text("Update every")
                Slider(value: Binding(
                    get: { model.interval }, set: { model.interval = $0 }
                ), in: 0.25...5.0, step: 0.25)
                Text(String(format: "%.2gs", model.interval)).monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
            }
            LaunchAtLoginToggle()
        }
        .font(.system(size: 11))
        .controlSize(.small)
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
                Text(failure).font(.system(size: 9)).foregroundStyle(.orange)
            }
        }
    }
}
