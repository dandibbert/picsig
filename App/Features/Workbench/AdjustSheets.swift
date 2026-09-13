import SwiftUI
import PicSigCore

// MARK: - Tone

/// Brightness, contrast and friends. Each slider previews continuously and
/// becomes one undo step when the finger lifts.
struct ToneSheet: View {
    let model: WorkbenchViewModel

    var body: some View {
        FormSheet(title: "adjust.section.tone", onDone: model.commitAdjustments) {
            Section {
                row("adjust.brightness", \.brightness, -0.5...0.5, 0.02, percent)
                row("adjust.contrast", \.contrast, 0.5...1.6, 0.02, multiplier)
                row("adjust.saturation", \.saturation, 0...2, 0.05, multiplier)
            }
            Section {
                row("adjust.temperature", \.temperature, -1...1, 0.05, percent)
                row("adjust.sharpness", \.sharpness, 0...1, 0.05, percent)
                row("adjust.vignette", \.vignette, 0...1, 0.05, percent)
            }
            Section {
                Button("adjust.resetTone") { model.resetAdjustments() }
                    .disabled(model.document.state.adjustments.isNeutral)
            }
        }
    }

    private func row(_ title: LocalizedStringKey,
                     _ keyPath: WritableKeyPath<ImageAdjustments, Double>,
                     _ range: ClosedRange<Double>,
                     _ step: Double,
                     _ display: @escaping (Double) -> String) -> some View {
        SliderRow(title: title,
                  value: Binding(get: { model.document.state.adjustments[keyPath: keyPath] },
                                 set: { value in model.setAdjustments { $0[keyPath: keyPath] = value } }),
                  range: range,
                  step: step,
                  display: display) { isEditing in
            if !isEditing { model.commitAdjustments() }
        }
        .padding(.vertical, 2)
    }

    private func percent(_ value: Double) -> String { String(format: "%+.0f%%", value * 100) }
    private func multiplier(_ value: Double) -> String { String(format: "%.2f×", value) }
}

// MARK: - Watermark

/// Text, where it goes, how it looks. Position is picked on a small page
/// diagram rather than from a menu, so the choice is visible before it is made.
struct WatermarkSheet: View {
    let model: WorkbenchViewModel

    @State private var draft: Watermark = Watermark(text: "")
    @State private var didLoad = false

    var body: some View {
        FormSheet(title: "adjust.section.watermark", onDone: model.commitWatermark) {
            Section {
                TextField("adjust.watermark.placeholder", text: text)
                    .textInputAutocapitalization(.never)
            } footer: {
                Text("adjust.watermark.hint")
            }

            Section("adjust.watermark.position") {
                WatermarkPositionPicker(selection: binding(\.position))
                    .padding(.vertical, 6)
            }
            .disabled(draft.isEmpty)

            Section("adjust.watermark.style") {
                SliderRow(title: "adjust.watermark.opacity",
                          value: binding(\.opacity),
                          range: 0.1...1,
                          step: 0.05,
                          display: { String(format: "%.0f%%", $0 * 100) })
                    .padding(.vertical, 2)
                SliderRow(title: "adjust.watermark.size",
                          value: binding(\.fontSize),
                          range: 0.015...0.08,
                          step: 0.005,
                          display: { String(format: "%.0f", $0 * 1000) })
                    .padding(.vertical, 2)
                HStack {
                    Text("annotate.color")
                    Spacer()
                    ColorSwatchRow(selection: binding(\.color), diameter: 22, spacing: 6)
                }
            }
            .disabled(draft.isEmpty)

            if !draft.isEmpty {
                Section {
                    Button(role: .destructive) {
                        draft.text = ""
                        model.previewWatermark(nil)
                    } label: {
                        Label("adjust.watermark.remove", systemImage: "trash")
                    }
                }
            }
        }
        .onAppear(perform: load)
        // Swiping the sheet away keeps what is on screen, as one undo step.
        .onDisappear { model.commitWatermark() }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        draft = model.document.state.watermark ?? Watermark(text: "")
    }

    private var text: Binding<String> {
        Binding(get: { draft.text },
                set: { value in
                    draft.text = value
                    model.previewWatermark(draft.isEmpty ? nil : draft)
                })
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Watermark, Value>) -> Binding<Value> {
        Binding(get: { draft[keyPath: keyPath] },
                set: { value in
                    draft[keyPath: keyPath] = value
                    if !draft.isEmpty { model.previewWatermark(draft) }
                })
    }
}

/// A page diagram with a tap target at each corner and the centre, plus a
/// "tiled" choice that repeats the mark across the whole page.
struct WatermarkPositionPicker: View {
    @Binding var selection: WatermarkPosition

    private let pageSize = CGSize(width: 108, height: 150)

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            page
            VStack(alignment: .leading, spacing: 10) {
                tiledToggle
                Text(LocalizedStringKey(selection.localizationKey))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var page: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.tertiarySystemFill))
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(.separator), lineWidth: 0.5)

            // Faint lines standing in for page content.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<7, id: \.self) { index in
                    Capsule()
                        .fill(Color(.systemFill))
                        .frame(width: index % 3 == 2 ? 44 : 70, height: 4)
                }
            }
            .padding(.leading, 18)
            .padding(.top, 8)
            .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)

            if selection == .tiled {
                tiledGlyphs
            } else {
                ForEach([WatermarkPosition.topLeading, .topTrailing, .center, .bottomLeading, .bottomTrailing],
                        id: \.self) { position in
                    dot(for: position)
                }
            }
        }
        .frame(width: pageSize.width, height: pageSize.height)
    }

    private func dot(for position: WatermarkPosition) -> some View {
        let isSelected = selection == position
        return Button {
            withAnimation(.snappy(duration: 0.2)) { selection = position }
        } label: {
            ZStack {
                Circle()
                    .fill(isSelected ? Color.accentColor : Color(.systemBackground))
                    .frame(width: 22, height: 22)
                    .overlay {
                        Circle().strokeBorder(isSelected ? Color.accentColor : Color(.separator), lineWidth: 1)
                    }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .position(point(for: position))
        .accessibilityLabel(LocalizedStringKey(position.localizationKey))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func point(for position: WatermarkPosition) -> CGPoint {
        let inset: CGFloat = 20
        switch position {
        case .topLeading: return CGPoint(x: inset, y: inset)
        case .topTrailing: return CGPoint(x: pageSize.width - inset, y: inset)
        case .center: return CGPoint(x: pageSize.width / 2, y: pageSize.height / 2)
        case .bottomLeading: return CGPoint(x: inset, y: pageSize.height - inset)
        case .bottomTrailing, .tiled: return CGPoint(x: pageSize.width - inset, y: pageSize.height - inset)
        }
    }

    private var tiledGlyphs: some View {
        VStack(spacing: 22) {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: 20) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule()
                            .fill(Color.accentColor.opacity(0.7))
                            .frame(width: 22, height: 5)
                            .rotationEffect(.degrees(-30))
                    }
                }
                .offset(x: row % 2 == 0 ? 0 : 12)
            }
        }
        .frame(width: pageSize.width, height: pageSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var tiledToggle: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                selection = selection == .tiled ? .bottomTrailing : .tiled
            }
        } label: {
            Label("watermark.position.tiled", systemImage: "square.grid.3x3")
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(selection == .tiled ? .accentColor : .secondary)
    }
}
