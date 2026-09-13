import SwiftUI

struct ExportFlowView: View {
    @ObservedObject var session: StudioSession
    @Environment(\.dismiss) private var dismiss
    @State private var sliced = false
    @State private var jpeg = false
    @State private var audit = true
    @State private var acknowledged = false
    @State private var preview: UIImage?
    @State private var share = false
    private var geometry: ExportGeometry? {
        guard let size = session.composition?.size else { return nil }
        return try? ExportGeometry(canvas: size, crop: session.project.edit.crop, turns: session.project.edit.quarterTurns)
    }
    private var requiresSlices: Bool { guard let size = geometry?.size else { return true }; return size.area > 32_000_000 || max(size.width, size.height) > 32760 }
    var body: some View {
        NavigationStack {
            Group {
                if let result = session.exportResult { resultView(result) }
                else { optionsView }
            }.navigationTitle(session.exportResult == nil ? "分享前，再看一眼" : "已生成分享副本")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() }.disabled(session.busy) } }
                .overlay { WorkOverlay(session: session) }
                .interactiveDismissDisabled(session.busy)
                .notice($session.notice)
        }.tint(.picAccent)
        .task {
            sliced = requiresSlices
            do { preview = try await MediaWorker.shared.preview(session.project, edits: true, final: true) }
            catch { session.notice = Notice(title: "无法生成预览", message: error.localizedDescription) }
        }
    }
    private var optionsView: some View {
        Form {
            Section {
                if let image = preview { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 220) }
                else { ProgressView("正在生成最终预览…").frame(maxWidth: .infinity).frame(height: 140) }
                if let size = geometry?.size { LabeledContent("输出尺寸", value: "\(Int(size.width)) × \(Int(size.height)) px") }
                LabeledContent("遮挡区域", value: "\(session.activeMasks) 处")
                LabeledContent("未遮挡但已知的区域", value: "\(session.project.edit.masks.filter { !$0.enabled }.count) 处")
            }
            Section("导出方式") {
                Picker("图片格式", selection: $jpeg) { Text("PNG · 无损").tag(false); Text("JPEG · 较小文件").tag(true) }.pickerStyle(.segmented)
                Toggle("分段导出", isOn: $sliced).disabled(requiresSlices)
                if requiresSlices { Text("这张图较长，已启用分段导出以控制内存和图片尺寸。不会丢掉后面的内容。").font(.caption).foregroundStyle(.secondary) }
                if sliced, let count = geometry?.slices().count { Text("将按内容方向依次导出 \(count) 张，不重叠、不留缝。").font(.caption).foregroundStyle(.secondary) }
            }
            Section("最后一道检查") {
                Toggle("导出前再次识别未遮挡内容", isOn: $audit)
                Text("复检会包含新增标注；若发现遗漏，将返回编辑器补充遮挡。已明确保留并复核的区域会尊重你的选择。").font(.caption).foregroundStyle(.secondary)
                if !session.project.edit.scanFinished {
                    Label("尚未完成自动隐私检查。请开启复检，或逐处人工检查后再导出。", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                }
                Toggle("我已检查画面，了解自动识别可能遗漏", isOn: $acknowledged).font(.subheadline)
                Text("只导出压平后的像素，不携带原始图片、可撤销图层、文字识别结果或来源 EXIF / GPS。检测完整性仍由人工复核把关。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button { session.export(sliced: sliced, jpeg: jpeg, audit: audit) } label: {
                    Label("生成导出文件", systemImage: "square.and.arrow.up").fontWeight(.semibold).frame(maxWidth: .infinity)
                }.disabled(!acknowledged || preview == nil || session.busy).accessibilityIdentifier("generate-export")
            }
        }
    }
    private func resultView(_ result: ExportResult) -> some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "checkmark.shield.fill").font(.system(size: 42)).foregroundStyle(Color.picMint).padding(.top, 12)
                VStack(spacing: 8) {
                    Text("编辑已压平，副本已就绪。").font(.title2.weight(.bold))
                    Text("已生成 \(result.urls.count) 个图片文件，原始照片未被修改。").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                Image(uiImage: result.preview).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 280).padding(14).background(Color.picCanvas, in: RoundedRectangle(cornerRadius: 20))
                Button { session.savePhotos(result.urls) } label: { Label("保存到照片", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button { share = true } label: { Label("分享或存入文件", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large).accessibilityIdentifier("share-export")
                Text("最终预览同样需要检查。已经分享出去的副本，无法通过删除本机项目来撤回。").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(24).frame(maxWidth: 700).frame(maxWidth: .infinity)
        }.sheet(isPresented: $share) { ShareSheet(urls: result.urls) }
    }
}
struct ShareSheet: UIViewControllerRepresentable {
    var urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: urls, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
