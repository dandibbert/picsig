import SwiftUI
import PicSigCore

/// Crop, rotate, tone and watermark.
///
/// Tone sliders update the preview continuously but only add one entry to the
/// undo stack per gesture, which is why every one of them commits on release.
struct AdjustPanel: View {
    let model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            geometrySection
            toneSection
            watermarkSection
        }
    }

    // MARK: - Crop and rotation

    private var geometrySection: some View {
        PanelSection(title: "adjust.section.geometry",
                     footnote: model.activeTool == .cropBox ? "adjust.crop.hint" : nil) {
            HStack(spacing: 8) {
                ChipButton(title: "adjust.crop",
                           systemImage: "crop",
                           isSelected: model.activeTool == .cropBox) {
                    model.activeTool = model.activeTool == .cropBox ? .none : .cropBox
                }
                ChipButton(title: "adjust.rotate", systemImage: "rotate.right") {
                    model.rotate()
                }
                ChipButton(title: "adjust.mirror", systemImage: "flip.horizontal") {
                    model.mirror()
                }
                if model.isCropped {
                    ChipButton(title: "adjust.resetCrop", systemImage: "arrow.counterclockwise") {
                        model.resetCrop()
                    }
                }
            }
        }
    }

    // MARK: - Tone

    private var toneSection: some View {
        PanelSection(title: "adjust.section.tone") {
            SliderRow(title: "adjust.brightness",
                      value: adjustment(\.brightness),
                      range: -0.5...0.5,
                      step: 0.02,
                      display: percent,
                      onEditingChanged: commit)
            SliderRow(title: "adjust.contrast",
                      value: adjustment(\.contrast),
                      range: 0.5...1.6,
                      step: 0.02,
                      display: multiplier,
                      onEditingChanged: commit)
            SliderRow(title: "adjust.saturation",
                      value: adjustment(\.saturation),
                      range: 0...2,
                      step: 0.05,
                      display: multiplier,
                      onEditingChanged: commit)
            SliderRow(title: "adjust.temperature",
                      value: adjustment(\.temperature),
                      range: -1...1,
                      step: 0.05,
                      display: percent,
                      onEditingChanged: commit)
            SliderRow(title: "adjust.sharpness",
                      value: adjustment(\.sharpness),
                      range: 0...1,
                      step: 0.05,
                      display: percent,
                      onEditingChanged: commit)
            SliderRow(title: "adjust.vignette",
                      value: adjustment(\.vignette),
                      range: 0...1,
                      step: 0.05,
                      display: percent,
                      onEditingChanged: commit)

            if !model.document.state.adjustments.isNeutral {
                Button("adjust.resetTone") { model.resetAdjustments() }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
        }
    }

    private func adjustment(_ keyPath: WritableKeyPath<ImageAdjustments, Double>) -> Binding<Double> {
        Binding(get: { model.document.state.adjustments[keyPath: keyPath] },
                set: { value in model.setAdjustments { $0[keyPath: keyPath] = value } })
    }

    private func commit(_ isEditing: Bool) {
        guard !isEditing else { return }
        model.commitAdjustments()
    }

    private func percent(_ value: Double) -> String {
        String(format: "%+.0f%%", value * 100)
    }

    private func multiplier(_ value: Double) -> String {
        String(format: "%.2f×", value)
    }

    // MARK: - Watermark

    private var watermarkSection: some View {
        PanelSection(title: "adjust.section.watermark",
                     footnote: "adjust.watermark.hint") {
            TextField("adjust.watermark.placeholder", text: watermarkText)
                .textFieldStyle(.roundedBorder)
                .font(.subheadline)

            if let watermark = model.document.state.watermark, !watermark.isEmpty {
                Picker("adjust.watermark.position", selection: positionBinding(watermark)) {
                    ForEach(WatermarkPosition.allCases, id: \.self) { position in
                        Text(LocalizedStringKey(position.localizationKey)).tag(position)
                    }
                }
                .font(.caption)

                SliderRow(title: "adjust.watermark.opacity",
                          value: Binding(get: { watermark.opacity },
                                         set: { value in
                                             var copy = watermark
                                             copy.opacity = value
                                             model.setWatermark(copy)
                                         }),
                          range: 0.1...1,
                          step: 0.05,
                          display: percent)

                SliderRow(title: "adjust.watermark.size",
                          value: Binding(get: { watermark.fontSize },
                                         set: { value in
                                             var copy = watermark
                                             copy.fontSize = value
                                             model.setWatermark(copy)
                                         }),
                          range: 0.015...0.08,
                          step: 0.005,
                          display: { String(format: "%.1f", $0 * 1000) })

                ColorSwatchRow(selection: Binding(get: { watermark.color },
                                                 set: { color in
                                                     var copy = watermark
                                                     copy.color = color
                                                     model.setWatermark(copy)
                                                 }))
            }
        }
    }

    private var watermarkText: Binding<String> {
        Binding(get: { model.document.state.watermark?.text ?? "" },
                set: { text in
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else {
                        model.setWatermark(nil)
                        return
                    }
                    var watermark = model.document.state.watermark ?? Watermark(text: text)
                    watermark.text = text
                    model.setWatermark(watermark)
                })
    }

    private func positionBinding(_ watermark: Watermark) -> Binding<WatermarkPosition> {
        Binding(get: { watermark.position },
                set: { position in
                    var copy = watermark
                    copy.position = position
                    model.setWatermark(copy)
                })
    }
}
