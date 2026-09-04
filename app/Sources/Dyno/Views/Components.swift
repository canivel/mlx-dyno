import DynoKit
import SwiftUI

/// Thresholds shared by every gauge, so a colour means the same thing wherever
/// it appears.
enum Level {
    static let warning = 70.0
    static let critical = 90.0

    static func color(_ percent: Double) -> Color {
        if percent >= critical { return .red }
        if percent >= warning { return .orange }
        return .green
    }
}

/// A thin horizontal fill bar.
struct GaugeBar: View {
    var fraction: Double
    var color: Color?
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(color ?? Level.color(clamped * 100))
                    .frame(width: max(clamped * geometry.size.width, clamped > 0 ? 3 : 0))
            }
        }
        .frame(height: height)
    }
}

/// A filled trend line. `ceiling` pins the top of the scale so the shape does
/// not silently rescale itself between frames.
struct Sparkline: View {
    var values: [Double]
    var ceiling: Double?
    var color: Color

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let points = Array(values.suffix(120))
            // With no fixed ceiling, scaling to the maximum makes a flat series
            // fill the whole box and read as solid colour. Leave headroom.
            let top = max(ceiling ?? ((points.max() ?? 1) * 1.3), 0.0001)

            if points.count > 1 {
                let step = size.width / CGFloat(points.count - 1)
                let coordinates = points.enumerated().map { index, value in
                    CGPoint(
                        x: CGFloat(index) * step,
                        y: size.height - CGFloat(min(max(value / top, 0), 1)) * size.height
                    )
                }

                // Fill under the line first, then the line itself on top.
                Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height))
                    coordinates.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.20), color.opacity(0.01)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                Path { path in
                    path.move(to: coordinates[0])
                    coordinates.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
        .drawingGroup()
    }
}

/// A label / value row with optional trailing detail.
struct StatRow: View {
    var label: String
    var value: String
    var detail: String?
    var valueColor: Color = .primary

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(valueColor)
                .monospacedDigit()
            if let detail {
                Text(detail)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .font(.system(size: 11))
    }
}

/// Section heading inside the panel.
struct SectionLabel: View {
    var title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.6)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }
}
