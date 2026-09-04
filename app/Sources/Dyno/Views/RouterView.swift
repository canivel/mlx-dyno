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

    var body: some View {
        if snapshot.isReachable {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    backends
                    decisions
                }
                .padding(20)
            }
        } else {
            notRunning
        }
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 26) {
            stat("\(snapshot.requestsTotal)", "routed")
            stat("\(snapshot.escalationsTotal)", "escalated")
            stat(String(format: "%.0fs", snapshot.secondsSaved), "saved",
                 detail: "versus the slowest candidate")
            Spacer()
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
