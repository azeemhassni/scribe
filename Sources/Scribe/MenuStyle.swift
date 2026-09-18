import SwiftUI

/// A row that highlights on hover, the way rows in Control Center and the
/// system menus do.
///
/// Deliberately a neutral grey rather than the accent colour: the menu shows a
/// list of meetings, and filling a whole row with a user's accent colour (red,
/// for instance) reads as an alert rather than as a pointer.
struct MenuRowStyle: ButtonStyle {
    var stretch = true
    var verticalPadding: CGFloat = 5

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, stretch: stretch, verticalPadding: verticalPadding)
    }

    private struct Row: View {
        let configuration: Configuration
        let stretch: Bool
        let verticalPadding: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(.horizontal, 8)
                .padding(.vertical, verticalPadding)
                .frame(maxWidth: stretch ? .infinity : nil, alignment: .leading)
                .background(fill, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 && isEnabled }
        }

        private var fill: Color {
            if configuration.isPressed { return Color.primary.opacity(0.12) }
            return hovering ? Color.primary.opacity(0.07) : .clear
        }
    }
}

/// Small caps label above a group, matching the weight of native section
/// headers without shouting.
struct MenuSectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 8)
    }
}

extension MenuSectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title: title, trailing: { EmptyView() })
    }
}

/// Neutral count pill. Glass rather than a flat fill so it reads as part of the
/// floating control layer, and stays legible whatever accent colour is set.
struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .glassEffect(.regular, in: .capsule)
    }
}

/// The status glyph at the top of the menu: a tinted disc so the current state
/// is readable at a glance before any text is read.
struct StatusChip: View {
    let symbol: String
    let tint: Color
    var pulsing = false

    @State private var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .glassEffect(.regular.tint(tint.opacity(0.25)), in: .circle)
            .opacity(pulsing && dimmed ? 0.55 : 1)
        .animation(pulseAnimation, value: dimmed)
        .onAppear { if pulsing { dimmed = true } }
    }

    private var pulseAnimation: Animation? {
        guard pulsing, !reduceMotion else { return nil }
        return .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
    }
}
