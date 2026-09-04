import DynoKit
import SwiftUI

/// What the model was doing, token by token — and what a quantisation changed.
///
/// Two questions this answers that a chat window cannot: where did it hesitate,
/// and where did the cheaper build start giving a different answer. The second
/// needs the same prompt at the same seed on two models, which is exactly what
/// nobody has to hand.
struct InspectView: View {
    var model: MonitorModel

    @State private var prompt = "Explain in two sentences why B-tree indexes suit range queries."
    @State private var referencePort: UInt16?
    @State private var comparePort: UInt16?
    @State private var maxTokens = 120
    @State private var seed = 0
    @State private var running = false
    @State private var reference: TokenTrace?
    @State private var other: TokenTrace?
    @State private var selected: TokenReading?

    private var servers: [(name: String, id: String, port: UInt16)] {
        model.snapshot.models.compactMap { served in
            guard let port = served.port, !served.identifier.isEmpty else { return nil }
            return (served.name, served.identifier, port)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                controls
                if servers.isEmpty {
                    Text("Start a model on the Models tab first.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else if let reference {
                    traceView(reference, title: reference.model, isReference: true)
                    if let other {
                        traceView(other, title: other.model, isReference: false)
                        divergences(reference, other)
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading("Prompt", trailing: "greedy, fixed seed — so runs are comparable")
            TextField("Prompt", text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(2...5)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.05)))

            HStack(spacing: 12) {
                labelled("Model") {
                    Picker("", selection: $referencePort) {
                        ForEach(servers, id: \.port) { Text($0.name).tag(Optional($0.port)) }
                    }
                    .labelsHidden().frame(width: 190).controlSize(.small)
                }
                labelled("Compare with") {
                    Picker("", selection: $comparePort) {
                        Text("none").tag(Optional<UInt16>.none)
                        ForEach(servers, id: \.port) { Text($0.name).tag(Optional($0.port)) }
                    }
                    .labelsHidden().frame(width: 190).controlSize(.small)
                }
                labelled("Tokens") {
                    Stepper("\(maxTokens)", value: $maxTokens, in: 16...1024, step: 32)
                        .controlSize(.small).frame(width: 96)
                }
                labelled("Seed") {
                    Stepper("\(seed)", value: $seed, in: 0...9999)
                        .controlSize(.small).frame(width: 84)
                }
                Spacer()
                Button(running ? "Running…" : "Inspect") { run() }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(running || servers.isEmpty
                              || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            if referencePort == nil { referencePort = servers.first?.port }
        }
    }

    private func labelled<Content: View>(
        _ title: String, @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 9)).foregroundStyle(.tertiary)
            content()
        }
    }

    private func run() {
        guard let referencePort,
              let referenceModel = servers.first(where: { $0.port == referencePort })?.id
        else { return }
        running = true
        reference = nil
        other = nil
        selected = nil

        Task { @MainActor in
            reference = await Inspection.capture(
                port: referencePort, model: referenceModel, prompt: prompt,
                maxTokens: maxTokens, seed: seed
            )
            if let comparePort,
               let compareModel = servers.first(where: { $0.port == comparePort })?.id {
                other = await Inspection.capture(
                    port: comparePort, model: compareModel, prompt: prompt,
                    maxTokens: maxTokens, seed: seed
                )
            }
            running = false
        }
    }

    // MARK: - Trace

    private func traceView(_ trace: TokenTrace, title: String, isReference: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(
                title.split(separator: "/").last.map(String.init) ?? title,
                trailing: trace.meanProbability.map {
                    String(format: "mean confidence %.2f · %d tokens", $0, trace.tokens.count)
                }
            )
            if let error = trace.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange)
            } else {
                TokenFlow(tokens: trace.tokens, selected: $selected)
                if let selected, trace.tokens.contains(where: { $0.id == selected.id }) {
                    alternativesView(selected)
                }
                leastConfident(trace)
            }
        }
    }

    private func alternativesView(_ token: TokenReading) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(display(token.text))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Text(String(format: "%.0f%%", token.probability * 100))
                    .font(.system(size: 11)).monospacedDigit()
                Text(String(format: "entropy %.2f bits", token.entropy))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            ForEach(Array(token.alternatives.prefix(6).enumerated()), id: \.offset) { _, item in
                HStack(spacing: 8) {
                    Text(display(item.token))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 150, alignment: .leading)
                        .foregroundStyle(item.token == token.text ? .primary : .secondary)
                    GaugeBar(fraction: item.probability, color: .accentColor, height: 5)
                        .frame(width: 160)
                    Text(String(format: "%.1f%%", item.probability * 100))
                        .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                }
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func leastConfident(_ trace: TokenTrace) -> some View {
        let ranked = trace.tokens.sorted { $0.probability < $1.probability }.prefix(5)
        return VStack(alignment: .leading, spacing: 3) {
            Text("WHERE IT HESITATED")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary).tracking(0.7)
            ForEach(Array(ranked)) { token in
                HStack(spacing: 8) {
                    Text("\(token.id)").font(.system(size: 9))
                        .foregroundStyle(.tertiary).frame(width: 26, alignment: .trailing)
                    Text(display(token.text))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 140, alignment: .leading)
                    Text(String(format: "%.0f%%", token.probability * 100))
                        .font(.system(size: 10)).monospacedDigit()
                    if let runner = token.runnerUp {
                        Text("wanted \(display(runner.token)) at "
                             + String(format: "%.0f%%", runner.probability * 100))
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Divergence

    private func divergences(_ reference: TokenTrace, _ other: TokenTrace) -> some View {
        let result = Inspection.compare(reference, other)
        return VStack(alignment: .leading, spacing: 6) {
            SectionHeading(
                "What changed",
                trailing: result.first == nil
                    ? "identical output"
                    : "\(result.all.count) of \(reference.tokens.count) tokens differ"
            )
            if result.first == nil {
                Text("Same prompt, same seed, same answer — this build changed nothing here.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text("Diverged at token \(result.first!).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(result.all.prefix(8)) { divergence in
                    HStack(spacing: 8) {
                        Text("\(divergence.index)").font(.system(size: 9))
                            .foregroundStyle(.tertiary).frame(width: 26, alignment: .trailing)
                        Text(display(divergence.referenceToken))
                            .font(.system(size: 11, design: .monospaced))
                        Text(String(format: "%.0f%%", divergence.referenceProbability * 100))
                            .font(.system(size: 9)).foregroundStyle(.tertiary).monospacedDigit()
                        Image(systemName: "arrow.right").font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        Text(display(divergence.otherToken))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.orange)
                        Text(String(format: "%.0f%%", divergence.otherProbability * 100))
                            .font(.system(size: 9)).foregroundStyle(.tertiary).monospacedDigit()
                        // Whether the reference even ranked that token is the
                        // difference between a near-tie and a real disagreement.
                        Text(divergence.wasConsidered
                             ? "reference ranked it" : "reference never ranked it")
                            .font(.system(size: 9))
                            .foregroundStyle(divergence.wasConsidered
                                             ? Color.secondary.opacity(0.7) : Color.orange)
                        Spacer()
                    }
                }
            }
        }
    }

    private func display(_ token: String) -> String {
        token.replacingOccurrences(of: "Ġ", with: "␣")
            .replacingOccurrences(of: "Ċ", with: "⏎")
            .replacingOccurrences(of: "\n", with: "⏎")
    }
}

/// The generated text, each token shaded by how sure the model was.
private struct TokenFlow: View {
    var tokens: [TokenReading]
    @Binding var selected: TokenReading?

    var body: some View {
        FlowLayout(spacing: 1, lineSpacing: 3) {
            ForEach(tokens) { token in
                Text(token.text.replacingOccurrences(of: "Ġ", with: " ")
                        .replacingOccurrences(of: "Ċ", with: "⏎"))
                    .font(.system(size: 12.5, design: .monospaced))
                    .padding(.horizontal, 1).padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(shade(token.probability))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(selected?.id == token.id
                                            ? Color.accentColor : .clear, lineWidth: 1.5)
                            )
                    )
                    .onTapGesture { selected = token }
                    .help(String(format: "%.0f%% · entropy %.2f", token.probability * 100,
                                 token.entropy))
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
    }

    /// Bands rather than a gradient: the question is "was it sure", and a
    /// continuous ramp reads as noise across a paragraph.
    private func shade(_ probability: Double) -> Color {
        switch probability {
        case 0.9...: return .clear
        case 0.6..<0.9: return Color.yellow.opacity(0.16)
        case 0.3..<0.6: return Color.orange.opacity(0.22)
        default: return Color.red.opacity(0.24)
        }
    }
}

/// Wraps subviews onto lines, which SwiftUI has no stock layout for.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
