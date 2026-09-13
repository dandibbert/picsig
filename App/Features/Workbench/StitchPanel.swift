import SwiftUI
import UIKit
import PicSigCore

/// Everything about how the inputs become one image: mode, direction, seams and
/// the collage settings for the manual layouts.
struct StitchPanel: View {
    let model: WorkbenchViewModel
    /// The strip has its own sources sheet; the settings sheet leaves them out.
    var showsSources = true

    /// Sliders here rebuild the entire canvas, so they edit a draft and only
    /// commit when the finger lifts.
    @State private var toleranceDraft: Double?
    @State private var framesPerSecondDraft: Double?
    @State private var spacingDraft: Double?
    @State private var paddingDraft: Double?
    @State private var marginDraft: Double?
    @State private var cornerDraft: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            modeSection
            if !model.plan.warnings.isEmpty || model.plan.joinsNeedingReview.count > 0 {
                warningSection
            }
            switch model.mode {
            case .auto: autoSection
            case .video: videoSection
            case .manual: manualSection
            }
            canvasSection
            if showsSources { sourceSection }
        }
    }

    // MARK: - Mode and direction

    private var modeSection: some View {
        PanelSection(title: "stitch.section.mode") {
            HStack(spacing: 8) {
                ForEach(availableModes) { mode in
                    ChipButton(title: LocalizedStringKey(mode.localizationKey),
                               systemImage: symbol(for: mode),
                               isSelected: model.mode == mode) {
                        model.setMode(mode)
                    }
                }
            }

            Picker("stitch.axis", selection: axisBinding) {
                Label("stitch.axis.vertical", systemImage: "arrow.down")
                    .tag(StitchAxis.vertical)
                Label("stitch.axis.horizontal", systemImage: "arrow.right")
                    .tag(StitchAxis.horizontal)
            }
            .pickerStyle(.segmented)
            .disabled(model.mode == .manual)
        }
    }

    /// Video mode only makes sense for a recording, and a recording cannot be
    /// re-stitched as a set of arbitrary screenshots without losing the frame
    /// ordering, so the two sets never mix.
    private var availableModes: [StitchMode] {
        model.videoURL == nil ? [.auto, .manual] : [.video, .manual]
    }

    private func symbol(for mode: StitchMode) -> String {
        switch mode {
        case .auto: return "wand.and.stars"
        case .manual: return "square.grid.2x2"
        case .video: return "film"
        }
    }

    private var axisBinding: Binding<StitchAxis> {
        Binding(get: { model.preferences.axis },
                set: { axis in
                    model.updatePreferences { preferences in
                        preferences.axis = axis
                        // The manual layout has its own flow direction; keep the two
                        // in step so switching modes does not flip the result.
                        preferences.layout.flow = axis
                    }
                })
    }

    // MARK: - Automatic stitching

    private var autoSection: some View {
        PanelSection(title: "stitch.section.alignment",
                     footnote: "stitch.alignment.hint") {
            Toggle("stitch.trimFixed", isOn: boolBinding(\.trimsFixedRegions))
                .font(.subheadline)
            if model.preferences.trimsFixedRegions {
                Toggle("stitch.keepHeader", isOn: boolBinding(\.keepsHeader))
                    .font(.subheadline)
                Toggle("stitch.keepFooter", isOn: boolBinding(\.keepsFooter))
                    .font(.subheadline)
            }

            SliderRow(title: "stitch.tolerance",
                      value: Binding(get: { toleranceDraft ?? model.preferences.matchTolerance },
                                     set: { toleranceDraft = $0 }),
                      range: 4...40,
                      step: 1,
                      display: { String(format: "%.0f", $0) }) { isEditing in
                guard !isEditing, let value = toleranceDraft else { return }
                toleranceDraft = nil
                model.updatePreferences { $0.matchTolerance = value }
            }

            seamControls
        }
    }

    @ViewBuilder
    private var seamControls: some View {
        Toggle("stitch.showSeams", isOn: Binding(get: { model.showsSeams },
                                                set: { model.showsSeams = $0 }))
            .font(.subheadline)

        // Markers live in the stitched image's coordinates, so a crop or rotation
        // takes them away; saying so beats leaving the toggle looking broken.
        if model.seamMarkersHiddenByGeometry {
            NoticeRow(level: .info, text: NSLocalizedString("stitch.seams.hiddenByGeometry", comment: ""))
        }

        if !model.plan.joins.isEmpty {
            ForEach(Array(model.plan.joins.enumerated()), id: \.offset) { index, join in
                HStack(spacing: 8) {
                    Image(systemName: join.needsReview ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(join.needsReview ? .orange : .green)
                    Text(seamTitle(index: index, join: join))
                        .font(.caption.monospacedDigit())
                    Spacer()
                    if model.canAdjustSeams {
                        Button {
                            model.adjustOverlap(forJoinAt: index, by: -4)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        Button {
                            model.adjustOverlap(forJoinAt: index, by: 4)
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                    }
                }
                .buttonStyle(.borderless)
            }

            if model.canAdjustSeams, model.hasManualOverlaps {
                Button("stitch.resetOverlaps") { model.resetOverlaps() }
                    .font(.caption)
            }
        }
    }

    private func seamTitle(index: Int, join: StitchJoin) -> String {
        let format = NSLocalizedString("stitch.seam.format", comment: "seam index, overlap, confidence")
        return String(format: format, index + 1, join.overlap, Int((join.confidence * 100).rounded()))
    }

    // MARK: - Video

    private var videoSection: some View {
        PanelSection(title: "stitch.section.video",
                     footnote: "stitch.video.hint") {
            SliderRow(title: "stitch.framesPerSecond",
                      value: Binding(get: { framesPerSecondDraft ?? model.preferences.videoFramesPerSecond },
                                     set: { framesPerSecondDraft = $0 }),
                      range: 1...15,
                      step: 1,
                      display: { String(format: "%.0f fps", $0) }) { isEditing in
                guard !isEditing, let value = framesPerSecondDraft else { return }
                framesPerSecondDraft = nil
                model.updatePreferences { $0.videoFramesPerSecond = value }
            }
            Text(frameSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            SliderRow(title: "stitch.tolerance",
                      value: Binding(get: { toleranceDraft ?? model.preferences.matchTolerance },
                                     set: { toleranceDraft = $0 }),
                      range: 4...40,
                      step: 1,
                      display: { String(format: "%.0f", $0) }) { isEditing in
                guard !isEditing, let value = toleranceDraft else { return }
                toleranceDraft = nil
                model.updatePreferences { $0.matchTolerance = value }
            }
            seamControls
        }
    }

    private var frameSummary: String {
        let format = NSLocalizedString("stitch.video.frames.format", comment: "sampled, used")
        let used = model.sources.count - model.plan.skippedSourceIndices.count
        return String(format: format, model.sources.count, max(0, used))
    }

    // MARK: - Manual layout

    private var manualSection: some View {
        PanelSection(title: "stitch.section.layout") {
            HStack(spacing: 8) {
                ChipButton(title: "stitch.layout.column",
                           systemImage: "rectangle.grid.1x2",
                           isSelected: isColumn) {
                    model.updatePreferences { $0.layout = .verticalStack }
                }
                ChipButton(title: "stitch.layout.row",
                           systemImage: "rectangle.grid.2x1",
                           isSelected: isRow) {
                    model.updatePreferences { $0.layout = .horizontalStrip }
                }
                ChipButton(title: "stitch.layout.grid",
                           systemImage: "square.grid.2x2",
                           isSelected: model.preferences.layout.crossCount > 1) {
                    model.updatePreferences { $0.layout = .grid(columns: 2) }
                }
            }

            if model.preferences.layout.crossCount > 1 {
                Stepper(value: columnBinding, in: 2...6) {
                    Text(String(format: NSLocalizedString("stitch.layout.columns.format", comment: ""),
                                model.preferences.layout.crossCount))
                        .font(.subheadline)
                }
            }

            SliderRow(title: "stitch.layout.spacing",
                      value: Binding(get: { spacingDraft ?? Double(model.preferences.layout.spacing) },
                                     set: { spacingDraft = $0 }),
                      range: 0...80,
                      step: 2,
                      display: { String(format: "%.0f px", $0) }) { isEditing in
                guard !isEditing, let value = spacingDraft else { return }
                spacingDraft = nil
                model.updatePreferences { $0.layout.spacing = Int(value) }
            }

            SliderRow(title: "stitch.layout.padding",
                      value: Binding(get: { paddingDraft ?? Double(model.preferences.layout.padding) },
                                     set: { paddingDraft = $0 }),
                      range: 0...120,
                      step: 2,
                      display: { String(format: "%.0f px", $0) }) { isEditing in
                guard !isEditing, let value = paddingDraft else { return }
                paddingDraft = nil
                model.updatePreferences { $0.layout.padding = Int(value) }
            }

            Picker("stitch.layout.alignment", selection: alignmentBinding) {
                Text("stitch.layout.alignment.leading").tag(LayoutAlignment.leading)
                Text("stitch.layout.alignment.center").tag(LayoutAlignment.center)
                Text("stitch.layout.alignment.trailing").tag(LayoutAlignment.trailing)
            }
            .pickerStyle(.segmented)

            Toggle("stitch.layout.uniform", isOn: uniformBinding)
                .font(.subheadline)
        }
    }

    private var isColumn: Bool {
        model.preferences.layout.flow == .vertical && model.preferences.layout.crossCount == 1
    }

    private var isRow: Bool {
        model.preferences.layout.flow == .horizontal && model.preferences.layout.crossCount == 1
    }

    private var columnBinding: Binding<Int> {
        Binding(get: { model.preferences.layout.crossCount },
                set: { count in model.updatePreferences { $0.layout.crossCount = count } })
    }

    private var alignmentBinding: Binding<LayoutAlignment> {
        Binding(get: { model.preferences.layout.alignment },
                set: { value in model.updatePreferences { $0.layout.alignment = value } })
    }

    /// "Uniform" means every cell gets the same box and images are centre-cropped
    /// into it — the tidy look for a grid of screenshots of different lengths.
    private var uniformBinding: Binding<Bool> {
        Binding(get: { model.preferences.layout.scaleMode == .uniformCell },
                set: { isOn in
                    model.updatePreferences { preferences in
                        preferences.layout.scaleMode = isOn ? .uniformCell : .matchCross
                        preferences.layout.fit = isOn ? .fill : .fit
                    }
                })
    }

    // MARK: - Canvas

    private var canvasSection: some View {
        PanelSection(title: "stitch.section.canvas") {
            ColorSwatchRow(selection: Binding(get: { model.preferences.canvas.backgroundColor },
                                             set: { color in
                                                 model.updatePreferences { $0.canvas.backgroundColor = color }
                                             }))

            if model.mode == .manual {
                SliderRow(title: "stitch.canvas.margin",
                          value: Binding(get: { marginDraft ?? model.preferences.canvas.margin },
                                         set: { marginDraft = $0 }),
                          range: 0...0.1,
                          step: 0.005,
                          display: { String(format: "%.1f%%", $0 * 100) }) { isEditing in
                    guard !isEditing, let value = marginDraft else { return }
                    marginDraft = nil
                    model.updatePreferences { $0.canvas.margin = value }
                }

                SliderRow(title: "stitch.canvas.corner",
                          value: Binding(get: { cornerDraft ?? model.preferences.canvas.cornerRadius },
                                         set: { cornerDraft = $0 }),
                          range: 0...0.08,
                          step: 0.004,
                          display: { String(format: "%.1f%%", $0 * 100) }) { isEditing in
                    guard !isEditing, let value = cornerDraft else { return }
                    cornerDraft = nil
                    model.updatePreferences { $0.canvas.cornerRadius = value }
                }

                Toggle("stitch.canvas.shadow", isOn: shadowBinding)
                    .font(.subheadline)
            }
        }
    }

    private var shadowBinding: Binding<Bool> {
        Binding(get: { model.preferences.canvas.shadowOpacity > 0 },
                set: { isOn in
                    model.updatePreferences { preferences in
                        preferences.canvas.shadowOpacity = isOn ? 0.18 : 0
                        preferences.canvas.shadowRadius = isOn ? 0.012 : 0
                    }
                })
    }

    // MARK: - Sources

    private var sourceSection: some View {
        PanelSection(title: "stitch.section.sources") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(model.sources.enumerated()), id: \.offset) { index, image in
                        SourceThumbnail(image: image,
                                        index: index,
                                        isSkipped: model.plan.skippedSourceIndices.contains(index)) {
                            model.removeSource(at: index)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 12) {
                Button {
                    model.reverseSources()
                } label: {
                    Label("stitch.reverse", systemImage: "arrow.up.arrow.down")
                }
                Button {
                    Task { await model.restitch() }
                } label: {
                    Label("stitch.rebuild", systemImage: "arrow.clockwise")
                }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Warnings

    private var warningSection: some View {
        PanelSection(title: "stitch.section.warnings") {
            ForEach(Array(model.plan.warnings.enumerated()), id: \.offset) { _, warning in
                NoticeRow(level: .warning, text: Self.describe(warning))
            }
        }
    }

    static func describe(_ warning: StitchWarning) -> String {
        switch warning {
        case .lowConfidenceJoin(let nextIndex, let confidence):
            return String(format: NSLocalizedString("stitch.warning.lowConfidence", comment: ""),
                          nextIndex + 1,
                          Int((confidence * 100).rounded()))
        case .contentGap(_, let missingLength):
            return String(format: NSLocalizedString("stitch.warning.gap", comment: ""), missingLength)
        case .scrollDirectionReversed(let frameIndex):
            return String(format: NSLocalizedString("stitch.warning.reversed", comment: ""), frameIndex + 1)
        case .duplicateSource(let index):
            return String(format: NSLocalizedString("stitch.warning.duplicate", comment: ""), index + 1)
        case .mismatchedSourceSize(let index):
            return String(format: NSLocalizedString("stitch.warning.size", comment: ""), index + 1)
        }
    }

    // MARK: - Helpers

    private func boolBinding(_ keyPath: WritableKeyPath<AppSettings.StitchPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { model.preferences[keyPath: keyPath] },
                set: { value in model.updatePreferences { $0[keyPath: keyPath] = value } })
    }
}

private struct SourceThumbnail: View {
    let image: CGImage
    let index: Int
    let isSkipped: Bool
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 3) {
            Image(uiImage: UIImage(cgImage: image))
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(.separator), lineWidth: 0.5)
                }
                .opacity(isSkipped ? 0.35 : 1)
                .overlay(alignment: .topTrailing) {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 4, y: -4)
                }

            Text("\(index + 1)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isSkipped ? .tertiary : .secondary)
        }
        .accessibilityLabel(Text(String(format: NSLocalizedString("stitch.source.accessibility", comment: ""),
                                       index + 1)))
    }
}
