import SwiftUI
import PicSigCore

/// Output settings plus the two ways out of the app: the photo library and the
/// share sheet.
struct ExportPanel: View {
    let model: WorkbenchViewModel

    /// Scale choices worth a one-tap chip. 4096 px is the limit a few chat apps
    /// still silently downsample past.
    private static let scaleChoices: [(key: LocalizedStringKey, scale: ExportScale)] = [
        ("export.scale.original", .original),
        ("export.scale.75", .fraction(0.75)),
        ("export.scale.50", .fraction(0.5)),
        ("export.scale.4096", .longestEdge(4096))
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            formatSection
            sizeSection
            pageSection
            privacySection
            actionSection
        }
    }

    // MARK: - Format

    private var formatSection: some View {
        PanelSection(title: "export.section.format") {
            Picker("export.format", selection: option(\.format)) {
                ForEach(ImageFileFormat.allCases, id: \.self) { format in
                    Text(format.fallbackTitle).tag(format)
                }
            }
            .pickerStyle(.segmented)

            if model.exportOptions.format.supportsQuality {
                SliderRow(title: "export.quality",
                          value: option(\.quality),
                          range: 0.5...1,
                          step: 0.02,
                          display: { String(format: "%.0f%%", $0 * 100) })
            }
        }
    }

    // MARK: - Size

    private var sizeSection: some View {
        PanelSection(title: "export.section.size") {
            HStack(spacing: 8) {
                ForEach(Array(Self.scaleChoices.enumerated()), id: \.offset) { _, choice in
                    ChipButton(title: choice.key,
                               isSelected: model.exportOptions.scale == choice.scale) {
                        var options = model.exportOptions
                        options.scale = choice.scale
                        model.exportOptions = options
                    }
                }
            }

            Text(sizeSummary)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var sizeSummary: String {
        let size = model.exportSize
        return String(format: NSLocalizedString("export.size.format", comment: "width, height"),
                      size.width,
                      size.height)
    }

    // MARK: - Pages

    private var pageSection: some View {
        PanelSection(title: "export.section.pages",
                     footnote: "export.pages.hint") {
            Toggle("export.split", isOn: option(\.splitsIntoPages))
                .font(.subheadline)

            if model.exportOptions.splitsIntoPages {
                SliderRow(title: "export.pageHeight",
                          value: Binding(get: { Double(model.exportOptions.pageHeight) },
                                         set: { value in
                                             var options = model.exportOptions
                                             options.pageHeight = Int(value)
                                             model.exportOptions = options
                                         }),
                          range: 1200...8000,
                          step: 200,
                          display: { String(format: "%.0f px", $0) })

                SliderRow(title: "export.pageOverlap",
                          value: Binding(get: { Double(model.exportOptions.pageOverlap) },
                                         set: { value in
                                             var options = model.exportOptions
                                             options.pageOverlap = Int(value)
                                             model.exportOptions = options
                                         }),
                          range: 0...200,
                          step: 10,
                          display: { String(format: "%.0f px", $0) })
            }

            Toggle("export.pdf", isOn: option(\.includesPDF))
                .font(.subheadline)
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        PanelSection(title: "export.section.privacy") {
            Toggle("export.stripMetadata", isOn: option(\.stripsMetadata))
                .font(.subheadline)
            Text("export.stripMetadata.hint")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if let audit = model.audit, !audit.isClean {
                NoticeRow(level: .problem, text: NSLocalizedString("export.auditWarning", comment: ""))
            }
        }
    }

    // MARK: - Actions

    private var actionSection: some View {
        PanelSection(title: "export.section.actions") {
            HStack(spacing: 10) {
                Button {
                    Task { await model.export(saveToPhotos: true) }
                } label: {
                    Label("export.saveToPhotos", systemImage: "square.and.arrow.down")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task { await model.export(saveToPhotos: false) }
                } label: {
                    Label("export.share", systemImage: "square.and.arrow.up")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.regular)
            .disabled(model.isBusy)
        }
    }

    // MARK: - Helpers

    private func option<Value>(_ keyPath: WritableKeyPath<ExportOptions, Value>) -> Binding<Value> {
        Binding(get: { model.exportOptions[keyPath: keyPath] },
                set: { value in
                    var options = model.exportOptions
                    options[keyPath: keyPath] = value
                    model.exportOptions = options
                })
    }
}
