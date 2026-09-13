import SwiftUI

struct ExportFlowView: View {
    @ObservedObject var session: StudioSession
    @Environment(\.dismiss) private var dismiss
    @State private var sliced = false
    @State private var jpeg = false
    @State private var preview: UIImage?
    @State private var share = false
    @State private var destination: Destination?
    private enum Destination { case photos, share }
    private var geometry: ExportGeometry? {
        guard let size = session.composition?.size else { return nil }
        return try? ExportGeometry(canvas: size, crop: session.project.edit.crop, turns: session.project.edit.quarterTurns)
    }
    private var requiresSlices: Bool {
        guard let size = geometry?.size else { return true }
        return size.area > 32_000_000 || max(size.width, size.height) > 32760
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let image = preview {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 200)
                    } else { ProgressView("生成预览…").frame(maxWidth: .infinity, minHeight: 180) }
                    if let size = geometry?.size { LabeledContent("尺寸", value: "\(Int(size.width)) × \(Int(size.height)) px") }
                }
                Section {
                    Picker("格式", selection: $jpeg) { Text("PNG 无损").tag(false); Text("JPEG").tag(true) }.pickerStyle(.segmented)
                    Toggle("分段导出", isOn: $sliced).disabled(requiresSlices)
                    if requiresSlices { Text("长图已自动分段，保留全部内容。").font(.caption).foregroundStyle(.secondary) }
                }
                Section {
                    Button { generate(.photos) } label: {
                        Label("保存到相册", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity).padding(.vertical, 5)
                    }.disabled(preview == nil || session.busy).accessibilityIdentifier("save-export")
                    Button { generate(.share) } label: {
                        Label("分享 / 存入文件", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).padding(.vertical, 5)
                    }.disabled(preview == nil || session.busy).accessibilityIdentifier("share-export")
                } footer: {
                    Text("仅导出合成后的图片，不附带原图、编辑图层或定位信息。自动打码可能漏检，可返回画布补充。")
                }
            }
            .navigationTitle("导出图片").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回") { dismiss() }.disabled(session.busy) } }
            .overlay { WorkOverlay(session: session) }.interactiveDismissDisabled(session.busy).notice($session.notice)
        }.tint(.picAccent)
        .task {
            sliced = requiresSlices
            do { preview = try await MediaWorker.shared.preview(session.project, edits: true, final: true) }
            catch { session.notice = Notice(title: "预览失败", message: error.localizedDescription) }
        }
        .task(id: session.exportResult?.id) {
            guard let result = session.exportResult, let destination else { return }
            while session.busy { try? await Task.sleep(for: .milliseconds(20)); if Task.isCancelled { return } }
            self.destination = nil
            if destination == .photos { session.savePhotos(result.urls) }
            else { share = true }
        }
        .sheet(isPresented: $share) { if let result = session.exportResult { ShareSheet(urls: result.urls) } }
    }
    private func generate(_ target: Destination) {
        destination = target; session.exportResult = nil
        session.export(sliced: sliced, jpeg: jpeg, audit: false)
    }
}
struct ShareSheet: UIViewControllerRepresentable {
    var urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: urls, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
