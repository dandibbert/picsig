import SwiftUI
import UIKit
import PicSigCore

/// Horizontal, single-height row of `StripButton`s. Scrolls sideways when a tab
/// has more tools than fit, instead of wrapping or shrinking anything.
private struct Strip<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    content
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(minWidth: proxy.size.width, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

// MARK: - Stitch

struct StitchStrip: View {
    let model: WorkbenchViewModel
    @Binding var sheet: WorkbenchSheet?

    var body: some View {
        Strip {
            modeMenu
            if model.mode != .manual {
                StripButton(title: axisTitle,
                            systemImage: model.preferences.axis.isVertical ? "arrow.down" : "arrow.right") {
                    setAxis(model.preferences.axis.isVertical ? .horizontal : .vertical)
                }
                StripButton(title: "stitch.showSeams.short",
                            systemImage: "rectangle.split.1x2",
                            isSelected: model.showsSeams,
                            isEnabled: !model.plan.joins.isEmpty) {
                    model.showsSeams.toggle()
                }
            } else {
                layoutMenu
            }
            StripButton(title: "stitch.section.sources",
                        systemImage: "photo.on.rectangle",
                        badge: model.sources.count) {
                sheet = .sources
            }
            StripButton(title: "stitch.rebuild",
                        systemImage: "arrow.clockwise",
                        isEnabled: !model.isBusy) {
                Task { await model.restitch() }
            }
            StripButton(title: "common.settings",
                        systemImage: "slider.horizontal.3",
                        badge: model.plan.warnings.count) {
                sheet = .stitchSettings
            }
        }
    }

    private var axisTitle: LocalizedStringKey {
        model.preferences.axis.isVertical ? "stitch.axis.vertical" : "stitch.axis.horizontal"
    }

    private func setAxis(_ axis: StitchAxis) {
        model.updatePreferences { preferences in
            preferences.axis = axis
            preferences.layout.flow = axis
        }
    }

    private var availableModes: [StitchMode] {
        model.videoURL == nil ? [.auto, .manual] : [.video, .manual]
    }

    private var modeMenu: some View {
        Menu {
            ForEach(availableModes) { mode in
                Button {
                    model.setMode(mode)
                } label: {
                    Label(LocalizedStringKey(mode.localizationKey),
                          systemImage: model.mode == mode ? "checkmark" : symbol(for: mode))
                }
            }
        } label: {
            StripItemLabel(title: LocalizedStringKey(model.mode.localizationKey),
                           systemImage: symbol(for: model.mode),
                           isSelected: true)
        }
    }

    private func symbol(for mode: StitchMode) -> String {
        switch mode {
        case .auto: return "wand.and.stars"
        case .manual: return "square.grid.2x2"
        case .video: return "film"
        }
    }

    private var layoutMenu: some View {
        Menu {
            Button {
                model.updatePreferences { $0.layout = .verticalStack }
            } label: {
                Label("stitch.layout.column", systemImage: "rectangle.grid.1x2")
            }
            Button {
                model.updatePreferences { $0.layout = .horizontalStrip }
            } label: {
                Label("stitch.layout.row", systemImage: "rectangle.grid.2x1")
            }
            Button {
                model.updatePreferences { $0.layout = .grid(columns: 2) }
            } label: {
                Label("stitch.layout.grid", systemImage: "square.grid.2x2")
            }
        } label: {
            StripItemLabel(title: "stitch.section.layout", systemImage: layoutSymbol)
        }
    }

    private var layoutSymbol: String {
        let layout = model.preferences.layout
        if layout.crossCount > 1 { return "square.grid.2x2" }
        return layout.flow == .vertical ? "rectangle.grid.1x2" : "rectangle.grid.2x1"
    }
}

// MARK: - Redact

struct RedactStrip: View {
    let model: WorkbenchViewModel
    @Binding var sheet: WorkbenchSheet?

    var body: some View {
        Strip {
            StripButton(title: model.hasScannedOnce ? "redact.rescan" : "redact.scan",
                        systemImage: "sparkle.magnifyingglass",
                        style: .prominent,
                        isEnabled: !model.isScanning && !model.isBusy) {
                Task { await model.scanForSensitiveInformation() }
            }
            StripButton(title: "redact.sheet.results",
                        systemImage: "checklist",
                        badge: model.matches.count,
                        isEnabled: model.hasScannedOnce || !model.document.state.redactions.isEmpty) {
                sheet = .redactionResults
            }
            StripButton(title: "redact.pickText",
                        systemImage: "text.viewfinder",
                        isSelected: model.activeTool == .textPick) {
                Task { await model.startTextPicking() }
            }
            StripButton(title: "redact.drawBox",
                        systemImage: "rectangle.dashed",
                        isSelected: model.activeTool == .redactionBox) {
                model.activeTool = model.activeTool == .redactionBox ? .none : .redactionBox
            }
            styleMenu
            StripButton(title: "redact.highlight",
                        systemImage: model.highlightsMatches ? "eye" : "eye.slash",
                        isSelected: model.highlightsMatches,
                        isEnabled: !model.matches.isEmpty) {
                model.highlightsMatches.toggle()
            }
        }
    }

    private var styleMenu: some View {
        Menu {
            ForEach(RedactionStyle.allCases, id: \.self) { style in
                Button {
                    model.setDefaultMaskingStyle(style)
                    model.setStyleForAllCategories(style)
                } label: {
                    Label(LocalizedStringKey(style.localizationKey),
                          systemImage: model.defaultMaskingStyle == style ? "checkmark" : symbol(for: style))
                }
            }
        } label: {
            StripItemLabel(title: LocalizedStringKey(model.defaultMaskingStyle.localizationKey),
                           systemImage: symbol(for: model.defaultMaskingStyle))
        }
    }

    private func symbol(for style: RedactionStyle) -> String {
        switch style {
        case .solid: return "rectangle.fill"
        case .mosaic: return "checkerboard.rectangle"
        case .blur: return "drop.halffull"
        case .sticker: return "face.smiling"
        case .replacement: return "textformat.abc.dottedunderline"
        }
    }
}

// MARK: - Annotate

struct AnnotateStrip: View {
    let model: WorkbenchViewModel
    @Binding var sheet: WorkbenchSheet?

    @State private var isColorPopoverPresented = false
    @State private var isWidthPopoverPresented = false

    var body: some View {
        Strip {
            ForEach(AnnotationTool.allCases, id: \.self) { tool in
                StripButton(title: LocalizedStringKey(tool.localizationKey),
                            systemImage: Self.symbol(for: tool),
                            isSelected: model.activeTool == .annotation(tool)) {
                    model.activeTool = model.activeTool == .annotation(tool) ? .none : .annotation(tool)
                }
            }

            Button {
                isColorPopoverPresented = true
            } label: {
                StripItemLabel(title: "annotate.color",
                               systemImage: "circle.fill",
                               swatch: Color(model.strokeColor.uiColor))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isColorPopoverPresented, arrowEdge: .bottom) {
                ColorSwatchRow(selection: Binding(get: { model.strokeColor },
                                                 set: { model.strokeColor = $0 }))
                    .padding(14)
                    .presentationCompactAdaptation(.popover)
            }

            Button {
                isWidthPopoverPresented = true
            } label: {
                StripItemLabel(title: "annotate.width", systemImage: "lineweight")
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isWidthPopoverPresented, arrowEdge: .bottom) {
                StrokeSettingsPopover(model: model)
                    .presentationCompactAdaptation(.popover)
            }

            StripButton(title: "annotate.section.marks",
                        systemImage: "list.bullet.rectangle",
                        badge: model.document.state.annotations.count) {
                sheet = .annotationHistory
            }
        }
    }

    static func symbol(for tool: AnnotationTool) -> String {
        switch tool {
        case .pen: return "scribble"
        case .highlighter: return "highlighter"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "textformat"
        case .numberBadge: return "1.circle"
        }
    }
}

/// Width, fill and text size for the *next* mark.
private struct StrokeSettingsPopover: View {
    let model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SliderRow(title: "annotate.width",
                      value: Binding(get: { model.strokeWidth }, set: { model.strokeWidth = $0 }),
                      range: 0.001...0.03,
                      step: 0.001,
                      display: { String(format: "%.1f", $0 * 1000) })
            SliderRow(title: "annotate.fontSize",
                      value: Binding(get: { model.fontSize }, set: { model.fontSize = $0 }),
                      range: 0.015...0.09,
                      step: 0.005,
                      display: { String(format: "%.1f", $0 * 1000) })
            Toggle("annotate.filled", isOn: Binding(get: { model.isShapeFilled },
                                                    set: { model.isShapeFilled = $0 }))
                .font(.subheadline)
        }
        .padding(14)
        .frame(width: 280)
    }
}

// MARK: - Adjust

struct AdjustStrip: View {
    let model: WorkbenchViewModel
    @Binding var sheet: WorkbenchSheet?

    var body: some View {
        Strip {
            StripButton(title: "adjust.crop",
                        systemImage: "crop",
                        isSelected: model.activeTool == .cropBox) {
                model.activeTool = model.activeTool == .cropBox ? .none : .cropBox
            }
            StripButton(title: "adjust.rotate", systemImage: "rotate.right") {
                model.rotate()
            }
            StripButton(title: "adjust.mirror", systemImage: "flip.horizontal") {
                model.mirror()
            }
            StripButton(title: "adjust.resetCrop",
                        systemImage: "arrow.counterclockwise",
                        isEnabled: model.isCropped) {
                model.resetCrop()
            }
            StripButton(title: "adjust.section.tone",
                        systemImage: "sun.max",
                        isSelected: !model.document.state.adjustments.isNeutral) {
                sheet = .tone
            }
            StripButton(title: "adjust.section.watermark",
                        systemImage: "signature",
                        isSelected: !(model.document.state.watermark?.isEmpty ?? true)) {
                sheet = .watermark
            }
        }
    }
}
