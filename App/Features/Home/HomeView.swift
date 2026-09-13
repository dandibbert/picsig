import SwiftUI
import PhotosUI
import PicSigCore

struct HomeView: View {
    @Environment(AppSettings.self) private var settings

    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var videoSelection: PhotosPickerItem?
    @State private var isPhotoPickerPresented = false
    @State private var isVideoPickerPresented = false
    @State private var isSettingsPresented = false
    @State private var isImporting = false
    @State private var importError: String?
    @State private var request: WorkbenchRequest?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    actionCards
                    presetSection
                    privacyNote
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("app.name")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isSettingsPresented = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("settings.title")
                }
            }
            .navigationDestination(item: $request) { request in
                WorkbenchView(request: request)
            }
            .sheet(isPresented: $isSettingsPresented) {
                SettingsView()
            }
            .photosPicker(isPresented: $isPhotoPickerPresented,
                          selection: $photoSelection,
                          maxSelectionCount: 40,
                          selectionBehavior: .ordered,
                          matching: .images,
                          photoLibrary: .shared())
            .photosPicker(isPresented: $isVideoPickerPresented,
                          selection: $videoSelection,
                          matching: .videos,
                          photoLibrary: .shared())
            .onChange(of: photoSelection) { _, items in
                guard !items.isEmpty else { return }
                importImages(items)
            }
            .onChange(of: videoSelection) { _, item in
                guard let item else { return }
                importVideo(item)
            }
            .overlay {
                if isImporting {
                    ProgressOverlay(title: "home.importing")
                }
            }
            .alert("common.error", isPresented: Binding(get: { importError != nil },
                                                        set: { if !$0 { importError = nil } })) {
                Button("common.ok", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("home.tagline")
                .font(.title2.bold())
            Text("home.subtitle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionCards: some View {
        VStack(spacing: 12) {
            ActionCard(icon: "square.stack.3d.up",
                       title: "home.action.stitch.title",
                       subtitle: "home.action.stitch.subtitle",
                       tint: .blue) {
                isPhotoPickerPresented = true
            }
            ActionCard(icon: "record.circle",
                       title: "home.action.video.title",
                       subtitle: "home.action.video.subtitle",
                       tint: .pink) {
                isVideoPickerPresented = true
            }
            ActionCard(icon: "eye.slash",
                       title: "home.action.redact.title",
                       subtitle: "home.action.redact.subtitle",
                       tint: .indigo) {
                isPhotoPickerPresented = true
            }
        }
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("home.preset.title")
                .font(.headline)
            Text("home.preset.subtitle")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(RedactionPreset.all) { preset in
                        PresetChip(preset: preset, isSelected: settings.presetID == preset.id) {
                            settings.apply(preset: preset)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.green)
            Text("home.privacy")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Import

    private func importImages(_ items: [PhotosPickerItem]) {
        isImporting = true
        Task {
            let images = await MediaImporter.loadImages(from: items)
            await MainActor.run {
                isImporting = false
                photoSelection = []
                guard !images.isEmpty else {
                    importError = NSLocalizedString("home.error.noImages", comment: "")
                    return
                }
                request = .images(images.map(CGImageBox.init))
            }
        }
    }

    private func importVideo(_ item: PhotosPickerItem) {
        isImporting = true
        Task {
            do {
                let url = try await MediaImporter.loadVideo(from: item)
                await MainActor.run {
                    isImporting = false
                    videoSelection = nil
                    guard let url else {
                        importError = NSLocalizedString("home.error.noVideo", comment: "")
                        return
                    }
                    request = .video(url)
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    videoSelection = nil
                    importError = error.localizedDescription
                }
            }
        }
    }
}

/// What the workbench should open with. Identity is the request itself, not its
/// payload, so pushing the same photos twice really opens a new session.
struct WorkbenchRequest: Identifiable, Hashable {
    enum Source {
        case images([CGImageBox])
        case video(URL)
    }

    let id = UUID()
    let source: Source

    static func images(_ boxes: [CGImageBox]) -> WorkbenchRequest {
        WorkbenchRequest(source: .images(boxes))
    }

    static func video(_ url: URL) -> WorkbenchRequest {
        WorkbenchRequest(source: .video(url))
    }

    static func == (lhs: WorkbenchRequest, rhs: WorkbenchRequest) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private struct ActionCard: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

private struct PresetChip: View {
    let preset: RedactionPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: preset.symbolName)
                    .font(.title3)
                Text(LocalizedStringKey(preset.titleKey))
                    .font(.subheadline.weight(.semibold))
                Text(LocalizedStringKey(preset.subtitleKey))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .multilineTextAlignment(.leading)
            .frame(width: 150, alignment: .leading)
            .padding(12)
            .background(isSelected ? Color.accentColor.opacity(0.16) : Color(.tertiarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
    }
}
