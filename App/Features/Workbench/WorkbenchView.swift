import SwiftUI
import PicSigCore

enum InspectorTab: String, CaseIterable, Identifiable {
    case stitch
    case redact
    case annotate
    case adjust
    case export

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .stitch: return "square.stack.3d.up"
        case .redact: return "eye.slash"
        case .annotate: return "pencil.tip.crop.circle"
        case .adjust: return "slider.horizontal.3"
        case .export: return "square.and.arrow.up"
        }
    }

    var localizationKey: String { "inspector.\(rawValue)" }
}

struct WorkbenchView: View {
    let request: WorkbenchRequest

    @Environment(AppSettings.self) private var settings
    @State private var model: WorkbenchViewModel?
    @State private var tab: InspectorTab = .redact
    @State private var isSharePresented = false

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
            CanvasView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGray6))

            Divider()

            VStack(spacing: 10) {
                Picker("inspector.picker", selection: $tab) {
                    ForEach(InspectorTab.allCases) { item in
                        Label(LocalizedStringKey(item.localizationKey), systemImage: item.symbolName)
                            .labelStyle(.iconOnly)
                            .tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.top, 10)

                ScrollView {
                    inspector(model)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                }
                .frame(height: 250)
                // Leaving a panel with its tool still armed would keep the canvas
                // from scrolling, which reads as a frozen screen.
                .onChange(of: tab) { _, _ in model.activeTool = .none }
            }
            .background(Color(.systemBackground))
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
    }

    @ViewBuilder
    private func inspector(_ model: WorkbenchViewModel) -> some View {
        switch tab {
        case .stitch: StitchPanel(model: model)
        case .redact: RedactionPanel(model: model)
        case .annotate: AnnotatePanel(model: model)
        case .adjust: AdjustPanel(model: model)
        case .export: ExportPanel(model: model)
        }
    }
}
