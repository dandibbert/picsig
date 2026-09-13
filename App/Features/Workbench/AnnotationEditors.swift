import SwiftUI
import UIKit
import PicSigCore

// MARK: - History

/// Every mark on the canvas, newest last. Tapping a row opens it for editing;
/// the trailing button removes it.
struct AnnotationHistoryView: View {
    let model: WorkbenchViewModel
    let onEdit: (UUID) -> Void

    var body: some View {
        let annotations = model.document.state.annotations
        VStack(alignment: .leading, spacing: 8) {
            if annotations.isEmpty {
                Text("annotate.empty")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 30)
            } else {
                Text("annotate.history.hint")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                ForEach(annotations) { annotation in
                    AnnotationRow(annotation: annotation) {
                        model.removeAnnotation(annotation.id)
                    }
                    .onTapGesture { onEdit(annotation.id) }
                }

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
                }
                .font(.footnote)
                .buttonStyle(.borderless)
                .padding(.top, 6)
            }
        }
        .padding(.top, 8)
    }
}

private struct AnnotationRow: View {
    let annotation: Annotation
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 34, height: 34)
                Image(systemName: AnnotateStrip.symbol(for: annotation.tool))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(annotation.color.uiColor))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Button(action: onRemove) {
                Image(systemName: "trash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("common.delete")
        }
        .padding(8)
        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }

    private var title: String {
        if annotation.tool == .text, !annotation.text.isEmpty { return annotation.text }
        if let number = annotation.number { return "#\(number)" }
        return NSLocalizedString(annotation.tool.localizationKey, comment: "")
    }

    private var detail: String {
        switch annotation.tool {
        case .text:
            return AnnotationFonts.displayName(for: annotation.fontName)
                + " · " + String(format: "%.0f", annotation.fontSize * 1000)
        case .numberBadge:
            return String(format: "%.0f", annotation.fontSize * 1000)
        case .rectangle, .ellipse:
            let fill = NSLocalizedString(annotation.isFilled ? "annotate.filled" : "annotate.outline", comment: "")
            return String(format: "%.1f", annotation.lineWidth * 1000) + " · " + fill
        default:
            return String(format: "%.1f", annotation.lineWidth * 1000)
        }
    }
}

// MARK: - Edit an existing mark

/// Routes to the right editor for the mark's kind.
struct AnnotationEditorSheet: View {
    let model: WorkbenchViewModel
    let annotationID: UUID

    var body: some View {
        if let annotation = model.annotation(annotationID) {
            if annotation.tool == .text {
                TextAnnotationEditor(model: model, mode: .edit(annotationID))
            } else {
                AnnotationStyleEditor(model: model, annotationID: annotationID)
            }
        } else {
            Text("annotate.missing")
                .foregroundStyle(.secondary)
                .presentationDetents([.medium])
        }
    }
}

/// Colour, width, fill and size of a shape, stroke or badge — previewed live on
/// the canvas and committed as one undo step.
struct AnnotationStyleEditor: View {
    let model: WorkbenchViewModel
    let annotationID: UUID

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let annotation = model.annotation(annotationID) {
                    Section("annotate.color") {
                        ColorSwatchRow(selection: Binding(get: { annotation.color },
                                                         set: { color in update { $0.color = color } }))
                            .padding(.vertical, 4)
                    }

                    if annotation.tool != .numberBadge {
                        Section {
                            SliderRow(title: "annotate.width",
                                      value: Binding(get: { annotation.lineWidth },
                                                     set: { value in update { $0.lineWidth = value } }),
                                      range: 0.001...0.03,
                                      step: 0.001,
                                      display: { String(format: "%.1f", $0 * 1000) })
                        }
                    }

                    if annotation.tool == .numberBadge {
                        Section {
                            SliderRow(title: "annotate.fontSize",
                                      value: Binding(get: { annotation.fontSize },
                                                     set: { value in update { $0.fontSize = value } }),
                                      range: 0.015...0.09,
                                      step: 0.005,
                                      display: { String(format: "%.1f", $0 * 1000) })
                            Stepper(value: Binding(get: { annotation.number ?? 1 },
                                                   set: { value in update { $0.number = value } }),
                                    in: 1...999) {
                                Text("#\(annotation.number ?? 1)")
                                    .font(.subheadline.monospacedDigit())
                            }
                        }
                    }

                    if annotation.tool == .rectangle || annotation.tool == .ellipse {
                        Section {
                            Toggle("annotate.filled", isOn: Binding(get: { annotation.isFilled },
                                                                    set: { value in update { $0.isFilled = value } }))
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            model.endEditingAnnotation(annotationID, commit: false)
                            model.removeAnnotation(annotationID)
                            dismiss()
                        } label: {
                            Label("common.delete", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(LocalizedStringKey(model.annotation(annotationID)?.tool.localizationKey ?? ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") {
                        model.endEditingAnnotation(annotationID, commit: false)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") {
                        model.endEditingAnnotation(annotationID, commit: true)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear { model.beginEditingAnnotation(annotationID) }
        // Swiping the sheet away counts as "keep what I see".
        .onDisappear { model.endEditingAnnotation(annotationID, commit: true) }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    private func update(_ mutate: (inout Annotation) -> Void) {
        model.previewAnnotation(annotationID, mutate)
    }
}

// MARK: - Text

/// Writes a new text mark or edits an existing one: the words, the font (any
/// installed on the device, profile fonts included), its size and colour, with
/// a live preview in the chosen font.
struct TextAnnotationEditor: View {
    enum Mode: Hashable {
        case create(at: NormalizedPoint)
        case edit(UUID)
    }

    let model: WorkbenchViewModel
    let mode: Mode

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isTextFocused: Bool

    @State private var text = ""
    @State private var fontName: String?
    @State private var fontSize: Double = 0.035
    @State private var color: RGBAColor = .red
    @State private var didLoad = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("annotate.text.placeholder", text: $text, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($isTextFocused)
                        .font(.body)
                }

                Section("annotate.text.preview") {
                    Text(text.isEmpty ? NSLocalizedString("annotate.text.placeholder", comment: "") : text)
                        .font(Font(AnnotationFonts.font(named: fontName, size: 24) as CTFont))
                        .foregroundStyle(text.isEmpty ? Color.secondary : Color(color.uiColor))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }

                Section {
                    NavigationLink {
                        FontPickerView(selection: $fontName)
                    } label: {
                        HStack {
                            Text("annotate.font")
                            Spacer()
                            Text(AnnotationFonts.displayName(for: fontName))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    SliderRow(title: "annotate.fontSize",
                              value: $fontSize,
                              range: 0.015...0.12,
                              step: 0.005,
                              display: { String(format: "%.1f", $0 * 1000) })
                }

                Section("annotate.color") {
                    ColorSwatchRow(selection: $color)
                        .padding(.vertical, 4)
                }

                if case .edit(let id) = mode {
                    Section {
                        Button(role: .destructive) {
                            model.removeAnnotation(id)
                            dismiss()
                        } label: {
                            Label("common.delete", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("tool.text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") {
                        commit()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear(perform: load)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        switch mode {
        case .create:
            fontName = model.fontName
            fontSize = model.fontSize
            color = model.strokeColor
            isTextFocused = true
        case .edit(let id):
            guard let annotation = model.annotation(id) else { return }
            text = annotation.text
            fontName = annotation.fontName
            fontSize = annotation.fontSize
            color = annotation.color
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch mode {
        case .create(let point):
            // The choices become the defaults for the next text mark.
            model.fontName = fontName
            model.fontSize = fontSize
            model.strokeColor = color
            model.commitAnnotation(Annotation(tool: .text,
                                              points: [point],
                                              color: color,
                                              lineWidth: model.strokeWidth,
                                              text: trimmed,
                                              fontSize: fontSize,
                                              fontName: fontName))
        case .edit(let id):
            model.updateAnnotation(id) { annotation in
                annotation.text = trimmed
                annotation.fontName = fontName
                annotation.fontSize = fontSize
                annotation.color = color
            }
        }
    }
}

// MARK: - Fonts

/// Every font family on the device, each row drawn in its own face. Fonts the
/// user installed (configuration profiles, the Fonts settings pane) are listed
/// first under their own heading so they are not lost among the system's
/// hundred families.
struct FontPickerView: View {
    @Binding var selection: String?

    @Environment(\.dismiss) private var dismiss
    @State private var families: [AnnotationFonts.Family] = []
    @State private var query = ""

    var body: some View {
        List {
            Section {
                row(title: NSLocalizedString("font.system", comment: ""),
                    face: nil,
                    isSelected: selection == nil)
            }

            let visible = filtered
            let installed = visible.filter(\.isUserInstalled)
            if !installed.isEmpty {
                Section("font.section.installed") {
                    ForEach(installed) { family in familyRow(family) }
                }
            }
            Section(LocalizedStringKey(installed.isEmpty ? "font.section.all" : "font.section.system")) {
                ForEach(visible.filter { !$0.isUserInstalled }) { family in familyRow(family) }
            }
            if installed.isEmpty, query.isEmpty {
                Section {
                    Text("font.installed.hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: Text("font.search"))
        .navigationTitle("annotate.font")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if families.isEmpty { families = AnnotationFonts.installedFamilies() }
        }
    }

    private var filtered: [AnnotationFonts.Family] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return families }
        return families.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    @ViewBuilder
    private func familyRow(_ family: AnnotationFonts.Family) -> some View {
        let isSelected = selection.map { family.faces.contains($0) } ?? false
        if family.faces.count > 1 {
            NavigationLink {
                FaceListView(family: family, selection: $selection)
            } label: {
                rowLabel(title: family.name, face: family.preferredFace, isSelected: isSelected)
            }
        } else {
            row(title: family.name, face: family.preferredFace, isSelected: isSelected)
        }
    }

    private func row(title: String, face: String?, isSelected: Bool) -> some View {
        Button {
            selection = face
            dismiss()
        } label: {
            rowLabel(title: title, face: face, isSelected: isSelected)
        }
        .buttonStyle(.plain)
    }

    private func rowLabel(title: String, face: String?, isSelected: Bool) -> some View {
        HStack {
            Text(title)
                .font(Font(AnnotationFonts.font(named: face, size: 17) as CTFont))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The individual weights and styles of one family.
private struct FaceListView: View {
    let family: AnnotationFonts.Family
    @Binding var selection: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(family.faces, id: \.self) { face in
            Button {
                selection = face
                dismiss()
            } label: {
                HStack {
                    Text(AnnotationFonts.displayName(for: face))
                        .font(Font(AnnotationFonts.font(named: face, size: 17) as CTFont))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    if selection == face {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listStyle(.insetGrouped)
        .navigationTitle(family.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Sources

/// The input images: reorder by drag, remove, reverse. Skipped frames are dimmed.
struct SourceListView: View {
    let model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                Spacer()
                Text("\(model.sources.count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
            .buttonStyle(.borderless)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 10)], spacing: 12) {
                ForEach(Array(model.sources.enumerated()), id: \.offset) { index, image in
                    VStack(spacing: 4) {
                        Image(uiImage: UIImage(cgImage: image))
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 72, height: 104)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color(.separator), lineWidth: 0.5)
                            }
                            .opacity(model.plan.skippedSourceIndices.contains(index) ? 0.35 : 1)
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    model.removeSource(at: index)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.body)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.55))
                                }
                                .buttonStyle(.plain)
                                .offset(x: 6, y: -6)
                            }
                        Text("\(index + 1)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.top, 8)
    }
}
