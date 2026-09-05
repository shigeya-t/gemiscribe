import SwiftUI

/// Per-source input level, updated ten times a second.
///
/// It reads the level out of an observable of its own rather than taking it as a value:
/// a `Float` parameter would invalidate the whole control bar — pickers, toggles and all
/// — ten times a second, which is enough to make the window stutter.
struct LevelMeterView: View {
    let label: String
    let source: AudioMixer.Source
    let levels: AudioLevels
    let isActive: Bool

    var body: some View {
        let level = isActive ? levels[source] : 0

        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(color(for: level))
                    // One animated bar rather than twelve independently animated
                    // segments: the same reading, a fraction of the layout cost.
                    .frame(width: 44 * CGFloat(barFraction(level)))
                    .animation(.linear(duration: 0.1), value: level)
            }
            .frame(width: 44, height: 8)

            Text(label)
                .font(.caption)
                .foregroundStyle(isActive ? .secondary : .tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(level * 100))%")
    }

    /// Square root keeps quiet speech visible without the bar pinning on loud passages.
    private func barFraction(_ level: Float) -> Double {
        min(1, max(0, Double(level).squareRoot()))
    }

    private func color(for level: Float) -> Color {
        guard isActive else { return .clear }
        let fraction = barFraction(level)
        if fraction > 0.92 { return .red }
        if fraction > 0.78 { return .yellow }
        return .green
    }
}
