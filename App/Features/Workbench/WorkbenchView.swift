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

/// The editing screen.
///
/// The canvas owns the screen. The panel underneath opens at a height that shows
/// a tab's primary controls and can be pulled up for the rest, because the image
/// is the thing being worked on — a settings sheet that hides half of it makes the
/// result impossible to judge. Export lives in the navigation bar so it is one tap
/// away from every tab.
struct WorkbenchView: View {
    let request: WorkbenchRequest

    @Environment(AppSettings.self) private var settings
    @State private var model: WorkbenchViewModel?
    @State private var tab: InspectorTab
    @State private var isSharePresented = false
    @State private var isPanelExpanded = false

    init(request: WorkbenchRequest) {
        self.request = request
        _tab = State(initialValue: request.intent == .redact ? .redact : .stitch)
    }

    private let collapsedPanelHeight: CGFloat = 150

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
        GeometryReader { proxy in
            VStack(spacing: 0) {
                CanvasView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGray6))

                panel(model, availableHeight: proxy.size.height)
                tabBar(model)
            }
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
                        tab = .export
                        isPanelExpanded = true
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

    // MARK: - Panel

    private func panel(_ model: WorkbenchViewModel, availableHeight: CGFloat) -> some View {
        let expandedHeight = min(460, availableHeight * 0.55)
        return VStack(spacing: 0) {
            grabber
            ScrollView {
                inspector(model)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
        .frame(height: isPanelExpanded ? expandedHeight : collapsedPanelHeight)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .clipped()
        .overlay(alignment: .top) { Divider() }
        // Leaving a panel with its tool still armed would keep the canvas from
        // scrolling, which reads as a frozen screen.
        .onChange(of: tab) { _, _ in model.activeTool = .none }
    }

    /// Pull handle: tap or drag to switch between the compact and the full panel.
    private var grabber: some View {
        Capsule()
            .fill(Color(.tertiaryLabel))
            .frame(width: 36, height: 5)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { togglePanel() }
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onEnded { value in
                        if value.translation.height < -20 { setPanelExpanded(true) }
                        if value.translation.height > 20 { setPanelExpanded(false) }
                    }
            )
            .accessibilityLabel(isPanelExpanded ? "inspector.collapse" : "inspector.expand")
            .accessibilityAddTraits(.isButton)
    }

    private func togglePanel() { setPanelExpanded(!isPanelExpanded) }

    private func setPanelExpanded(_ expanded: Bool) {
        withAnimation(.snappy(duration: 0.28)) { isPanelExpanded = expanded }
    }

    // MARK: - Tab bar

    private func tabBar(_ model: WorkbenchViewModel) -> some View {
        HStack(spacing: 0) {
            ForEach(InspectorTab.allCases) { item in
                Button {
                    if tab == item {
                        togglePanel()
                    } else {
                        tab = item
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbolName)
                            .font(.system(size: 19, weight: .medium))
                            .frame(height: 22)
                        Text(LocalizedStringKey(item.localizationKey))
                            .font(.caption2)
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
