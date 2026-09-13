import SwiftUI
import UIKit
import PicSigCore

/// Titled block used by every inspector panel.
struct PanelSection<Content: View>: View {
    let title: LocalizedStringKey
    var footnote: LocalizedStringKey?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            content
            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10)
    }
}

/// Slider with a title and a live read-out.
///
/// `onEditingChanged` is what makes it usable for the stitch settings too: those
/// rebuild the whole canvas, so they may only react when the finger lifts.
struct SliderRow: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    var display: (Double) -> String = { String(format: "%.2f", $0) }
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                Text(display(value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step, onEditingChanged: onEditingChanged)
        }
    }
}

/// Horizontal row of colour swatches.
struct ColorSwatchRow: View {
    @Binding var selection: RGBAColor
    var colors: [RGBAColor] = RGBAColor.palette

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                let isSelected = color == selection
                Circle()
                    .fill(Color(color.uiColor))
                    .frame(width: 26, height: 26)
                    .overlay {
                        Circle().strokeBorder(Color(.separator), lineWidth: 0.5)
                    }
                    .overlay {
                        if isSelected {
                            Circle()
                                .strokeBorder(Color.accentColor, lineWidth: 2.5)
                                .padding(-3)
                        }
                    }
                    .onTapGesture { selection = color }
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

/// Pill shaped label. Split out from `ChipButton` so a menu can use the same
/// look without nesting a button inside its own label.
struct ChipLabel: View {
    let title: LocalizedStringKey
    var systemImage: String?
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption)
            }
            Text(title)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
        .foregroundStyle(isSelected ? Color.white : Color.primary)
    }
}

/// Compact pill button used for tools and layout presets.
struct ChipButton: View {
    let title: LocalizedStringKey
    var systemImage: String?
    var isSelected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ChipLabel(title: title, systemImage: systemImage, isSelected: isSelected)
        }
        .buttonStyle(.plain)
    }
}

/// Coloured badge for a severity level or a warning.
struct SeverityDot: View {
    let severity: SensitiveCategory.Severity

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch severity {
        case .high: return .red
        case .medium: return .orange
        case .low: return .blue
        }
    }
}

/// One line of advice or trouble, used for stitch warnings and audit findings.
struct NoticeRow: View {
    enum Level {
        case info
        case warning
        case problem

        var symbol: String {
            switch self {
            case .info: return "info.circle"
            case .warning: return "exclamationmark.triangle"
            case .problem: return "xmark.octagon"
            }
        }

        var tint: Color {
            switch self {
            case .info: return .secondary
            case .warning: return .orange
            case .problem: return .red
            }
        }
    }

    let level: Level
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: level.symbol)
                .font(.caption)
                .foregroundStyle(level.tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
