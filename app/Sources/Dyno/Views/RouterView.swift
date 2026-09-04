import DynoKit
import SwiftUI

/// What the router decided, and why.
///
/// A router you cannot interrogate is one you end up switching off, so every
/// decision shows the models it considered, what each would have cost, and the
/// reason the rest were rejected.
struct RouterView: View {
    var model: MonitorModel

    private var snapshot: RouterClient.Snapshot { model.router }

    @State private var showingSettings = false

    var body: some View {
        if snapshot.isReachable {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if showingSettings { settings }
                    backends
                    harnesses
                    decisions
                }
                .padding(20)
            }
        } else {
            notRunning
        }
    }

    // MARK: - Policy

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading("Policy", trailing: "applies immediately, no restart")

            HStack(spacing: 22) {
                Toggle(isOn: binding(\.selfRouting) { ["self_routing": $0] }) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Self-routing").font(.system(size: 11))
                        Text("strongest model tags the conversation")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
                Toggle(isOn: binding(\.useCostModel) { ["use_cost_model": $0] }) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Cost model").font(.system(size: 11))
                        Text("fastest model clearing the tier")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            .toggleStyle(.switch).controlSize(.mini)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text("Escalate below").font(.system(size: 11))
                        Text(config.escalateBelow <= 0
                             ? "off"
                             : String(format: "%.2f", config.escalateBelow))
                            .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    }
                    Text("retry on a stronger model when its own token probability drops")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Slider(
                    value: Binding(
                        get: { config.escalateBelow },
                        set: { model.updateRouter(["escalate_below": $0]) }
                    ),
                    in: 0...0.98
                )
                .controlSize(.mini).frame(width: 190)
            }

            HStack(spacing: 8) {
                Text("Assume replies of").font(.system(size: 11))
                Text("\(config.expectedTokens)").font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                Text("tokens when comparing models").font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Stepper("", value: Binding(
                    get: { config.expectedTokens },
                    set: { model.updateRouter(["expected_tokens": $0]) }
                ), in: 32...4096, step: 100)
                .labelsHidden().controlSize(.mini)
                Spacer()
            }

            rules
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    private var config: RouterConfig { snapshot.config }

    private func binding(
        _ path: KeyPath<RouterConfig, Bool>, _ change: @escaping (Bool) -> [String: Any]
    ) -> Binding<Bool> {
        Binding(
            get: { config[keyPath: path] },
            set: { model.updateRouter(change($0)) }
        )
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("RULES").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary).tracking(0.7)
                Text("checked first, in order")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                Spacer()
                Button("Add") { addRule() }.controlSize(.mini)
            }
            if config.rules.isEmpty {
                Text("No rules. Routing falls to self-routing and the cost model.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            ForEach(config.rules) { rule in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { rule.enabled },
                        set: { enabled in
                            var updated = config.rules
                            if let index = updated.firstIndex(where: { $0.name == rule.name }) {
                                updated[index].enabled = enabled
                                model.setRouterRules(updated)
                            }
                        }
                    ))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    Text(rule.name).font(.system(size: 11, weight: .medium))
                    Text(rule.summary).font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.setRouterRules(config.rules.filter { $0.name != rule.name })
                    } label: {
                        Image(systemName: "trash").font(.system(size: 9))
                    }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// A starting point rather than a blank form: the common rule is "send
    /// anything that looks like code to the biggest model".
    private func addRule() {
        var updated = config.rules
        updated.append(RouterConfig.Rule(
            name: "rule \(updated.count + 1)",
            tier: "hard",
            matches: "(refactor|debug|stack trace|traceback)"
        ))
        model.setRouterRules(updated)
    }

    private var notRunning: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 26)).foregroundStyle(.tertiary)
            Text("The router is not running").font(.system(size: 13, weight: .medium))
            Text("One endpoint in front of every model you have running, choosing\n"
                 + "between them on difficulty, speed and the model's own confidence.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("dyno route")
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06)))
                .textSelection(.enabled)
                .padding(.top, 4)
            Text("Then point any OpenAI client at 127.0.0.1:8970 with model \"auto\".")
                .font(.system(size: 10)).foregroundStyle(.tertiary)

            switch model.routerState {
            case .launching:
                ProgressView().controlSize(.small).padding(.top, 6)
            case let .failed(message):
                Text(message).font(.system(size: 10)).foregroundStyle(.orange)
                    .padding(.top, 4)
                startButton
            default:
                startButton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var startButton: some View {
        Button("Start the router") { model.startRouter() }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(Runtime.current == nil)
            .padding(.top, 6)
    }

    private var header: some View {
        HStack(spacing: 26) {
            stat("\(snapshot.requestsTotal)", "routed")
            stat("\(snapshot.escalationsTotal)", "escalated")
            stat(String(format: "%.0fs", snapshot.secondsSaved), "saved",
                 detail: "versus the slowest candidate")
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { showingSettings.toggle() }
            } label: {
                Label("Policy", systemImage: "slider.horizontal.3").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(showingSettings ? Color.accentColor : .secondary)
            if case .running = model.routerState {
                Button("Stop") { model.stopRouter() }.controlSize(.small)
            }
        }
    }

    private func stat(_ value: String, _ caption: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 22, weight: .medium)).monospacedDigit()
            Text(caption).font(.system(size: 10)).foregroundStyle(.secondary)
            if let detail {
                Text(detail).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }

    private var backends: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeading("Models it can reach", trailing: "strongest first")
            ForEach(snapshot.backends) { backend in
                HStack(spacing: 10) {
                    Text(backend.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    if let parameters = backend.parametersB {
                        tag(String(format: "%.4gB", parameters))
                    }
                    if let bits = backend.bits { tag("\(bits)-bit") }
                    Spacer(minLength: 8)
                    if backend.activeRequests > 0 {
                        Text("\(backend.activeRequests) in flight")
                            .font(.system(size: 10)).foregroundStyle(Color.accentColor)
                    }
                    if let rate = backend.tokensPerSecond {
                        Text(String(format: "%.0f tok/s", rate))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Text(String(format: "cap %.1f", backend.capability))
                        .font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                    Text(":\(String(backend.port))")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }

    // MARK: - Harnesses

    @State private var harnessEntries: [HarnessEntry] = []
    @State private var harnessNote: String?

    private var harnesses: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeading("Point a tool at this endpoint",
                           trailing: "http://127.0.0.1:\(String(model.routerPort))/v1")
            if harnessEntries.isEmpty {
                Text("Loading…").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            ForEach(harnessEntries) { entry in
                HStack(spacing: 10) {
                    Image(systemName: entry.isConfigured
                          ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.system(size: 11))
                        .foregroundStyle(entry.isConfigured ? Color.green : Color.secondary.opacity(0.6))
                    Text(entry.name).font(.system(size: 12, weight: .medium))
                    Text(entry.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(entry.configPath)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                        .frame(maxWidth: 220, alignment: .trailing)
                    Button(entry.isConfigured ? "Rewrite" : "Configure") {
                        configure(entry)
                    }
                    .controlSize(.small)
                }
            }
            if let harnessNote {
                Text(harnessNote).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text("Configs name model “auto”, which asks the router to choose.")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .task {
            if harnessEntries.isEmpty { harnessEntries = await Harnesses.list() }
        }
    }

    private func configure(_ entry: HarnessEntry) {
        Task { @MainActor in
            let endpoint = "http://127.0.0.1:\(model.routerPort)"
            let result = await Harnesses.install(entry.key, endpoint: endpoint, model: "auto")
            harnessNote = result?
                .split(separator: "\n").first.map(String.init) ?? "could not write the config"
            harnessEntries = await Harnesses.list()
        }
    }

    private var decisions: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading("Decisions", trailing: "newest first")
            if snapshot.traces.isEmpty {
                Text("Nothing routed yet. Send a request to 127.0.0.1:8970.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            ForEach(snapshot.traces) { trace in
                TraceRow(trace: trace)
            }
        }
    }
}

private struct TraceRow: View {
    var trace: RouteTrace
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(trace.date.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 9)).foregroundStyle(.tertiary).monospacedDigit()
                Text(trace.prompt.isEmpty ? "(no prompt)" : trace.prompt)
                    .font(.system(size: 12))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                if let seconds = trace.seconds {
                    Text(String(format: "%.1fs", seconds))
                        .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                }
            }

            HStack(spacing: 7) {
                Image(systemName: trace.didEscalate ? "arrow.up.right" : "arrow.right")
                    .font(.system(size: 9))
                    .foregroundStyle(trace.didEscalate ? .orange : .secondary)
                Text(trace.didEscalate ? (trace.escalatedTo ?? trace.chosen) : trace.chosen)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(trace.didEscalate ? Color.orange : .primary)
                mechanismTag
                if let tier = trace.tier { tagView(tier) }
                if let confidence = trace.confidence {
                    tagView(String(format: "confidence %.2f", confidence))
                }
                Spacer(minLength: 6)
                Button {
                    withAnimation(.easeInOut(duration: 0.1)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text(trace.reason)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let escalation = trace.escalationReason, let from = trace.escalatedFrom {
                        Text("escalated from \(from) — \(escalation)")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                    }
                    ForEach(Array(trace.candidates.enumerated()), id: \.offset) { _, candidate in
                        HStack(spacing: 8) {
                            Text(candidate.wasChosen ? "✓" : "·")
                                .font(.system(size: 9))
                                .foregroundStyle(candidate.wasChosen
                                                 ? Color.green : Color.secondary.opacity(0.6))
                                .frame(width: 10)
                            Text(candidate.model)
                                .font(.system(size: 10))
                                .foregroundStyle(candidate.wasChosen
                                                 ? Color.primary : Color.secondary)
                            Text(String(format: "~%.1fs", candidate.estimatedSeconds))
                                .font(.system(size: 9)).foregroundStyle(.tertiary).monospacedDigit()
                            if let reason = candidate.rejectedBecause {
                                Text(reason).font(.system(size: 9)).foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                    }
                    if let saved = trace.secondsSaved, saved > 0.1 {
                        Text(String(format: "about %.1fs faster than the slowest candidate", saved))
                            .font(.system(size: 9)).foregroundStyle(.green)
                    }
                }
                .padding(.leading, 16)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 11)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
    }

    private var mechanismTag: some View {
        tagView(trace.mechanism)
            .foregroundStyle(Color.accentColor)
    }

    private func tagView(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.secondary.opacity(0.14), in: Capsule())
    }
}
