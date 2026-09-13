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
    var diameter: CGFloat = 26
    var spacing: CGFloat = 8

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                let isSelected = color == selection
                Circle()
                    .fill(Color(color.uiColor))
                    .frame(width: diameter, height: diameter)
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
                .lineLimit(1)
        }
        // A chip that wraps its title onto two lines pushes every neighbour out
        // of alignment; it must grow sideways instead.
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
        .foregroundStyle(isSelected ? Color.white : Color.primary)
    }
}

/// One item in the bottom tool strip: an icon over a one-line caption, in a
/// fixed width cell so a longer word in one language never shifts the row.
struct StripButton: View {
    enum Style {
        case plain
        case prominent
    }

    let title: LocalizedStringKey
    let systemImage: String
    var isSelected: Bool = false
    var style: Style = .plain
    var badge: Int? = nil
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            StripItemLabel(title: title,
                           systemImage: systemImage,
                           isSelected: isSelected,
                           style: style,
                           badge: badge)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The look of a strip item, shared by buttons and menus.
struct StripItemLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isSelected: Bool = false
    var style: StripButton.Style = .plain
    var badge: Int? = nil
    /// Draws the icon cell in this colour instead of the icon glyph — used for
    /// the colour picker so the current colour is visible at a glance.
    var swatch: Color? = nil

    static let width: CGFloat = 62

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(cellFill)
                    .frame(width: 44, height: 36)
                if let swatch {
                    Circle()
                        .fill(swatch)
                        .frame(width: 18, height: 18)
                        .overlay { Circle().strokeBorder(Color(.separator), lineWidth: 0.5) }
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(iconColor)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let badge, badge > 0 {
                    Text(badge > 99 ? "99+" : "\(badge)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.red, in: Capsule())
                        .offset(x: 6, y: -5)
                }
            }
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        }
        .frame(width: Self.width)
        .contentShape(Rectangle())
    }

    private var cellFill: Color {
        switch style {
        case .prominent: return .accentColor
        case .plain: return isSelected ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemFill)
        }
    }

    private var iconColor: Color {
        switch style {
        case .prominent: return .white
        case .plain: return isSelected ? .accentColor : .primary
        }
    }
}

/// A detail sheet opened from the tool strip. Medium height by default with the
/// canvas still live behind it, so a slider or a checkbox can be judged against
/// the image without closing anything.
struct DetailSheet<Content: View>: View {
    let title: LocalizedStringKey
    var detents: Set<PresentationDetent> = [.medium, .large]
    var onDone: @MainActor () -> Void = {}
    @ViewBuilder let content: Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") {
                        onDone()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents(detents)
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationContentInteraction(.scrolls)
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

/// Like `DetailSheet`, for content that is a `Form`: grouped rows, the same
/// half-height presentation with the canvas live behind it.
struct FormSheet<Content: View>: View {
    let title: LocalizedStringKey
    var detents: Set<PresentationDetent> = [.medium, .large]
    var onDone: @MainActor () -> Void = {}
    @ViewBuilder let content: Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                content
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") {
                        onDone()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents(detents)
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationContentInteraction(.scrolls)
    }
}
