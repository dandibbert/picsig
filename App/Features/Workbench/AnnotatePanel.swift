import SwiftUI
import UIKit
import PicSigCore

/// Drawing tools. Arming a tool disables canvas scrolling so a stroke cannot be
/// mistaken for a pan.
struct AnnotatePanel: View {
    let model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            toolSection
            styleSection
            historySection
        }
    }

    private var toolSection: some View {
        PanelSection(title: "annotate.section.tools") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AnnotationTool.allCases, id: \.self) { tool in
                        ChipButton(title: LocalizedStringKey(tool.localizationKey),
                                   systemImage: symbol(for: tool),
                                   isSelected: model.activeTool == .annotation(tool)) {
                            model.activeTool = model.activeTool == .annotation(tool)
                                ? .none
                                : .annotation(tool)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            if model.activeTool == .none {
                Text("annotate.pickTool")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func symbol(for tool: AnnotationTool) -> String {
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

    private var styleSection: some View {
        PanelSection(title: "annotate.section.style") {
            ColorSwatchRow(selection: Binding(get: { model.strokeColor },
                                             set: { model.strokeColor = $0 }))

            SliderRow(title: "annotate.width",
                      value: Binding(get: { model.strokeWidth }, set: { model.strokeWidth = $0 }),
                      range: 0.001...0.03,
                      step: 0.001,
                      display: { String(format: "%.1f", $0 * 1000) })

            if usesFontSize {
                SliderRow(title: "annotate.fontSize",
                          value: Binding(get: { model.fontSize }, set: { model.fontSize = $0 }),
                          range: 0.015...0.09,
                          step: 0.005,
                          display: { String(format: "%.1f", $0 * 1000) })
            }

            if usesFill {
                Toggle("annotate.filled", isOn: Binding(get: { model.isShapeFilled },
                                                        set: { model.isShapeFilled = $0 }))
                    .font(.subheadline)
            }
        }
    }

    private var usesFontSize: Bool {
        switch model.activeTool.annotationTool {
        case .text, .numberBadge: return true
        default: return false
        }
    }

    private var usesFill: Bool {
        switch model.activeTool.annotationTool {
        case .rectangle, .ellipse: return true
        default: return false
        }
    }

    private var historySection: some View {
        PanelSection(title: "annotate.section.marks") {
            let annotations = model.document.state.annotations
            HStack(spacing: 14) {
                Button {
                    model.undoLastStroke()
                } label: {
                    Label("annotate.undoStroke", systemImage: "eraser")
                }
                .disabled(!annotations.contains { $0.tool == .pen || $0.tool == .highlighter })

                Button(role: .destructive) {
                    model.clearAnnotations()
                } label: {
                    Label("annotate.clear", systemImage: "trash")
                }
                .disabled(annotations.isEmpty)
            }
            .font(.caption)
            .buttonStyle(.borderless)

            if annotations.isEmpty {
                Text("annotate.empty")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(annotations) { annotation in
                    HStack(spacing: 8) {
                        Image(systemName: symbol(for: annotation.tool))
                            .font(.caption2)
                            .foregroundStyle(Color(annotation.color.uiColor))
                        Text(label(for: annotation))
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            model.removeAnnotation(annotation.id)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private func label(for annotation: Annotation) -> String {
        if annotation.tool == .text, !annotation.text.isEmpty { return annotation.text }
        if let number = annotation.number { return "#\(number)" }
        return NSLocalizedString(annotation.tool.localizationKey, comment: "")
    }
}
