import SwiftUI
import PicSigCore

enum InspectorTab: String, CaseIterable, Identifiable {
    case stitch
    case redact
    case annotate
    case adjust

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .stitch: return "square.stack.3d.up"
        case .redact: return "eye.slash"
        case .annotate: return "pencil.tip.crop.circle"
        case .adjust: return "slider.horizontal.3"
        }
    }

    var localizationKey: String { "inspector.\(rawValue)" }
}

/// Sheets the tool strip can open. Each one is a *detail* of the current tab;
/// the strip itself never grows.
enum WorkbenchSheet: Identifiable, Hashable {
    case stitchSettings
    case sources
    case redactionResults
    case annotationHistory
    /// A new text mark at this point.
    case newText(NormalizedPoint)
    /// Change an existing mark.
    case editAnnotation(UUID)
    case tone
    case watermark
    case exportOptions

    var id: String {
        switch self {
        case .stitchSettings: return "stitchSettings"
        case .sources: return "sources"
        case .redactionResults: return "redactionResults"
        case .annotationHistory: return "annotationHistory"
        case .newText(let point): return "newText-\(point.x)-\(point.y)"
        case .editAnnotation(let id): return "edit-\(id.uuidString)"
        case .tone: return "tone"
        case .watermark: return "watermark"
        case .exportOptions: return "exportOptions"
        }
    }
}

/// The editing screen.
///
/// The canvas owns the screen. Under it sits one row of tools for the current
/// tab — always the same height, never a drawer to pull — and under that the tab
/// bar. Anything with more than a tap's worth of controls (a slider, a list, a
/// form) opens as a sheet that stops at half height with the canvas still live
/// behind it. Export lives in the navigation bar, and only there.
struct WorkbenchView: View {
    let request: WorkbenchRequest

    @Environment(AppSettings.self) private var settings
    @State private var model: WorkbenchViewModel?
    @State private var tab: InspectorTab
    @State private var sheet: WorkbenchSheet?
    @State private var isSharePresented = false

    init(request: WorkbenchRequest) {
        self.request = request
        _tab = State(initialValue: request.intent == .redact ? .redact : .stitch)
    }

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .navigationTitle("workbench.title")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard model == nil else { return }
            let created = WorkbenchViewModel(settings: settings)
            model = created
            await created.load(request)
        }
    }

    private func content(_ model: WorkbenchViewModel) -> some View {
        VStack(spacing: 0) {
            CanvasView(model: model, sheet: $sheet)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGray6))

            toolStrip(model)
            tabBar(model)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    model.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!model.document.canUndo)

                Button {
                    model.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!model.document.canRedo)

                exportMenu(model)
            }
        }
        .overlay {
            if let statusKey = model.statusKey {
                ProgressOverlay(title: statusKey, progress: model.progress)
            }
        }
        .alert("common.error",
               isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button("common.ok", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: model.exportedFiles) { _, files in
            isSharePresented = !files.isEmpty
        }
        .sheet(isPresented: $isSharePresented) {
            ActivityView(items: model.exportedFiles)
        }
        .sheet(item: $sheet) { sheet in
            detail(sheet, model: model)
        }
        // Leaving a tab with its tool still armed would keep the canvas from
        // scrolling, which reads as a frozen screen.
        .onChange(of: tab) { _, _ in model.activeTool = .none }
    }

    // MARK: - Export

    private func exportMenu(_ model: WorkbenchViewModel) -> some View {
        Menu {
            Button {
                Task { await model.export(saveToPhotos: true) }
            } label: {
                Label("export.saveToPhotos", systemImage: "square.and.arrow.down")
            }
            Button {
                Task { await model.export(saveToPhotos: false) }
            } label: {
                Label("export.share", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button {
                sheet = .exportOptions
            } label: {
                Label("export.options", systemImage: "slider.horizontal.3")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .fontWeight(.semibold)
        }
        .disabled(model.isBusy || model.stitched == nil)
        .accessibilityLabel("inspector.export")
    }

    // MARK: - Tool strip

    @ViewBuilder
    private func toolStrip(_ model: WorkbenchViewModel) -> some View {
        Group {
            switch tab {
            case .stitch: StitchStrip(model: model, sheet: $sheet)
            case .redact: RedactStrip(model: model, sheet: $sheet)
            case .annotate: AnnotateStrip(model: model, sheet: $sheet)
            case .adjust: AdjustStrip(model: model, sheet: $sheet)
            }
        }
        .frame(height: 78)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Tab bar

    private func tabBar(_ model: WorkbenchViewModel) -> some View {
        HStack(spacing: 0) {
            ForEach(InspectorTab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbolName)
                            .font(.system(size: 19, weight: .medium))
                            .frame(height: 22)
                        Text(LocalizedStringKey(item.localizationKey))
                            .font(.caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(tab == item ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Sheets

    @ViewBuilder
    private func detail(_ sheet: WorkbenchSheet, model: WorkbenchViewModel) -> some View {
        switch sheet {
        case .stitchSettings:
            DetailSheet(title: "stitch.sheet.settings") { StitchPanel(model: model, showsSources: false) }
        case .sources:
            DetailSheet(title: "stitch.section.sources") { SourceListView(model: model) }
        case .redactionResults:
            DetailSheet(title: "redact.sheet.results") { RedactionPanel(model: model) }
        case .annotationHistory:
            DetailSheet(title: "annotate.section.marks") {
                AnnotationHistoryView(model: model) { id in self.sheet = .editAnnotation(id) }
            }
        case .newText(let point):
            TextAnnotationEditor(model: model, mode: .create(at: point))
        case .editAnnotation(let id):
            AnnotationEditorSheet(model: model, annotationID: id)
        case .tone:
            DetailSheet(title: "adjust.section.tone") { AdjustPanel(model: model, section: .tone) }
        case .watermark:
            DetailSheet(title: "adjust.section.watermark") { AdjustPanel(model: model, section: .watermark) }
        case .exportOptions:
            DetailSheet(title: "export.options") { ExportPanel(model: model) }
        }
    }
}
