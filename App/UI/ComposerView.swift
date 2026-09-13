import SwiftUI
import UniformTypeIdentifiers

struct StudioView: View {
    @ObservedObject var session: StudioSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var backToLayout = false
    var body: some View {
        NavigationStack {
            Group {
                if session.stage == .compose { ComposerView(session: session) }
                else { EditorView(session: session) }
            }
            .navigationTitle(session.stage == .compose ? "拼接工作台" : "隐私与编辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if session.stage == .edit {
                        Button { backToLayout = true } label: { Label("拼接", systemImage: "chevron.left") }.disabled(session.busy)
                    } else {
                        Button("完成") { close() }.disabled(session.busy)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if session.stage == .edit {
                        Menu {
                            Button("保存并关闭", systemImage: "checkmark") { close() }
                            Button("清空标记与裁剪", systemImage: "arrow.counterclockwise") { session.change { $0.edit = EditState() } }
                        } label: { Image(systemName: "ellipsis.circle") }.disabled(session.busy)
                    }
                }
            }
            .overlay { WorkOverlay(session: session) }
            .confirmationDialog("返回拼接工作台？", isPresented: $backToLayout, titleVisibility: .visible) {
                Button("返回拼接") { session.stage = .compose }
            } message: { Text("目前的标记会保留。之后若调整素材、顺序或布局，打码与标注会重置，避免错位；可用撤销恢复。") }
            .sheet(isPresented: $session.showExport) { ExportFlowView(session: session) }
            .notice($session.notice)
            .task {
                session.refreshPreview()
                if session.stage == .edit && !session.project.edit.scanFinished && session.project.edit.masks.isEmpty { session.scan() }
            }
            .onChange(of: phase) { _, value in if value == .background && session.busy { session.cancel() } }
        }.tint(.picAccent)
    }
    private func close() {
        Task {
            do { try await session.flush(); dismiss() }
            catch { session.notice = Notice(title: "未能保存", message: error.localizedDescription) }
        }
    }
}

struct ComposerView: View {
    @ObservedObject var session: StudioSession
    @State private var picker = false
    @State private var importingFiles = false
    @State private var pickerLoading = false
    @State private var videoSelection: VideoSelection?
    @State private var pendingVideo: URL?
    @State private var trimBars = true
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TextField("项目名称", text: Binding(get: { session.project.title }, set: { value in session.change({ $0.title = String(value.prefix(80)) }, coalesce: true) }))
                    .font(.title3.weight(.semibold)).accessibilityLabel("项目名称")
                preview
                if let note = session.note {
                    Label(note, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Menu {
                        Button("从照片选择", systemImage: "photo.on.rectangle") { picker = true }
                        Button("从文件导入", systemImage: "folder") { importingFiles = true }
                    } label: { Label(session.project.kind == .video ? "导入录屏" : "添加图片", systemImage: "plus").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("add-media")
                    Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(.bordered).controlSize(.large).disabled(session.undoCount == 0).accessibilityLabel("撤销")
                    Button { session.redo() } label: { Image(systemName: "arrow.uturn.forward") }.buttonStyle(.bordered).controlSize(.large).disabled(session.redoCount == 0).accessibilityLabel("重做")
                }
                if !session.project.images.isEmpty {
                    layoutControls
                    if session.project.kind.isScroll {
                        VStack(alignment: .leading, spacing: 14) {
                            Toggle("自动去除重复顶部 / 底部", isOn: $trimBars).font(.subheadline)
                            Text("仅识别固定外边缘，保留首张顶部和末张底部。复杂导航栏建议用单张裁剪微调。").font(.caption).foregroundStyle(.secondary)
                            Button { session.autoStitch(trimBars: trimBars) } label: { Label("重新自动拼接", systemImage: "wand.and.stars").frame(maxWidth: .infinity) }
                                .buttonStyle(.bordered).disabled(session.project.images.count < 2).accessibilityIdentifier("auto-stitch")
                        }.cardSurface()
                    }
                    HStack {
                        Text("素材与拼接缝").font(.headline)
                        Spacer()
                        Button("倒序") {
                            session.change({ project in project.images.reverse(); session.resetJoins(&project) }, layout: true)
                        }.font(.subheadline).disabled(session.project.images.count < 2)
                    }
                    ForEach(Array(session.project.images.enumerated()), id: \.element.id) { index, image in
                        SourceCard(session: session, source: image, index: index)
                            .dropDestination(for: String.self) { values, _ in
                                guard let text = values.first, let id = UUID(uuidString: text), id != image.id else { return false }
                                session.change({ project in
                                    guard let from = project.images.firstIndex(where: { $0.id == id }), let target = project.images.firstIndex(where: { $0.id == image.id }) else { return }
                                    let item = project.images.remove(at: from); project.images.insert(item, at: from < target ? target - 1 : target)
                                    session.resetJoins(&project)
                                }, layout: true)
                                return true
                            }
                    }
                }
            }.padding(20).frame(maxWidth: 900).frame(maxWidth: .infinity)
        }.background(Color.picCanvas)
        .safeAreaInset(edge: .bottom) {
            if !session.project.images.isEmpty {
                Button { session.enterEditor() } label: { Label("下一步 · 隐私与编辑", systemImage: "checkmark.shield").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 5) }
                    .buttonStyle(.borderedProminent).controlSize(.large).padding(16).background(.regularMaterial).disabled(session.busy).accessibilityIdentifier("enter-editor")
            }
        }
        .disabled(session.busy || pickerLoading)
        .overlay { if pickerLoading { ProgressView("正在从照片读取所选文件…").padding(25).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)) } }
        .sheet(isPresented: $picker, onDismiss: {
            if let url = pendingVideo { pendingVideo = nil; videoSelection = VideoSelection(url: url) }
        }) {
            MediaPicker(video: session.project.kind == .video, limit: max(1, 60 - session.project.images.count), started: { pickerLoading = true }) { result in
                pickerLoading = false
                switch result {
                case .success(let urls):
                    if session.project.kind == .video { pendingVideo = urls.first }
                    else if !urls.isEmpty { session.importImages(urls) }
                case .failure(let error): session.notice = Notice(title: "导入失败", message: error.localizedDescription)
                }
                picker = false
                // The controller may already have completed its dismissal while iCloud was downloading.
                if let url = pendingVideo {
                    pendingVideo = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { videoSelection = VideoSelection(url: url) }
                }
            }
        }
        .sheet(item: $videoSelection) { selection in
            VideoImportView(url: selection.url) { session.importVideo(selection.url, options: $0) }
        }
        .fileImporter(isPresented: $importingFiles, allowedContentTypes: session.project.kind == .video ? [.movie] : [.image], allowsMultipleSelection: session.project.kind != .video) { result in
            switch result {
            case .success(let urls):
                if session.project.kind == .video, let first = urls.first { videoSelection = VideoSelection(url: first) }
                else { session.importImages(urls) }
            case .failure(let error): session.notice = Notice(title: "导入失败", message: error.localizedDescription)
            }
        }
    }
    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("画布预览").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if let size = session.composition?.size { Text("\(Int(size.width)) × \(Int(size.height)) px").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            if let image = session.preview, let size = session.composition?.size {
                ZoomCanvas(image: image, canvas: size).frame(height: 280).clipShape(RoundedRectangle(cornerRadius: 16))
                Text("双指缩放 · 上下或左右滑动检查拼接缝").font(.caption2).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: session.project.kind.symbol).font(.system(size: 44, weight: .light)).foregroundStyle(Color.picAccent.opacity(0.6))
                    Text(session.project.images.isEmpty ? "添加素材，开始拼接" : "正在生成预览…").font(.subheadline).foregroundStyle(.secondary)
                    if session.project.images.isEmpty { Text(session.project.kind == .video ? "支持从相册或文件导入系统录屏" : "按顺序多选图片，之后仍可自由调整").font(.caption).foregroundStyle(.tertiary) }
                }.frame(maxWidth: .infinity).frame(height: 230).background(Color.picAccent.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
            }
        }.cardSurface()
    }
    private var layoutControls: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("布局").font(.headline)
            Picker("布局方式", selection: Binding(get: { session.project.kind }, set: { kind in
                session.change({ project in
                    project.kind = kind; project.layout.gap = kind.isScroll ? 0 : 20; project.layout.margin = kind.isScroll ? 0 : 32
                    project.layout.cornerRadius = kind.isScroll ? 0 : 16; session.resetJoins(&project)
                }, layout: true)
            })) {
                Text(session.project.kind == .video ? "录屏长图" : "截图长拼").tag(session.project.kind == .video ? ProjectKind.video : .scroll)
                Text("竖向拼图").tag(ProjectKind.vertical); Text("横向拼图").tag(ProjectKind.horizontal)
            }.pickerStyle(.segmented)
            HStack {
                Text(session.project.kind == .horizontal ? "统一高度" : "输出宽度").font(.subheadline)
                Spacer()
                Picker("输出尺寸", selection: Binding(get: { Int(session.project.layout.breadth) }, set: { value in session.change({ $0.layout.breadth = Double(value) }, layout: true) })) {
                    ForEach(Array(Set([720, 1080, 1440, 2160, Int(session.project.layout.breadth)])).sorted(), id: \.self) { Text("\($0) px").tag($0) }
                }.labelsHidden()
            }
            if !session.project.kind.isScroll {
                settingSlider("图片间距", key: \.gap, range: 0...100)
                settingSlider("外边距", key: \.margin, range: 0...160)
                settingSlider("圆角", key: \.cornerRadius, range: 0...80)
                Picker("背景", selection: Binding(get: { session.project.layout.paper }, set: { paper in session.change({ $0.layout.paper = paper }, layout: true) })) {
                    ForEach(PaperColor.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
        }.cardSurface()
    }
    private func settingSlider(_ title: String, key: WritableKeyPath<LayoutOptions, Double>, range: ClosedRange<Double>) -> some View {
        VStack(spacing: 5) {
            HStack { Text(title); Spacer(); Text("\(Int(session.project.layout[keyPath: key])) px").monospacedDigit().foregroundStyle(.secondary) }.font(.caption)
            Slider(value: Binding(get: { session.project.layout[keyPath: key] }, set: { value in session.change({ $0.layout[keyPath: key] = value }, layout: true, coalesce: true) }), in: range, step: 1)
        }
    }
}

private struct SourceCard: View {
    @ObservedObject var session: StudioSession
    var source: SourceImage
    var index: Int
    private var extent: Double {
        let crop = source.automaticCrop ?? source.crop
        return session.project.kind == .horizontal ? source.size.width * crop.width : source.size.height * crop.height
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 13) {
                if let thumb = session.thumbnails[source.id] {
                    Image(uiImage: thumb).resizable().scaledToFill().frame(width: 52, height: 70).clipped().clipShape(RoundedRectangle(cornerRadius: 9)).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("第 \(index + 1) 张").font(.subheadline.weight(.semibold))
                    Text("\(Int(source.size.width)) × \(Int(source.size.height))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    if let time = source.timestamp { Text(String(format: "录屏 %.1f 秒", time)).font(.caption2).foregroundStyle(.secondary) }
                    if let confidence = source.matchConfidence {
                        Text(confidence < 0.4 ? "需手动调整拼接缝" : "已匹配重叠区域").font(.caption2).foregroundStyle(confidence < 0.4 ? Color.orange : Color.picMint)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "line.3.horizontal").font(.title3).foregroundStyle(.secondary).frame(width: 44, height: 44).draggable(source.id.uuidString).accessibilityLabel("拖动调整图片顺序")
                Menu {
                    Button("上移", systemImage: "arrow.up") { move(-1) }.disabled(index == 0)
                    Button("下移", systemImage: "arrow.down") { move(1) }.disabled(index == session.project.images.count - 1)
                    Button("旋转 90°", systemImage: "rotate.right") { session.rotateSource(source.id) }
                    Button("删除图片", systemImage: "trash", role: .destructive) {
                        session.change({ project in project.images.removeAll { $0.id == source.id }; session.resetJoins(&project) }, layout: true)
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("图片操作")
            }
            if index > 0 {
                VStack(spacing: 6) {
                    HStack { Text("去除与上一张的重叠"); Spacer(); Text("\(Int((source.leadingCut * extent).rounded())) px").monospacedDigit() }.font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button { adjustPixel(-1) } label: { Image(systemName: "minus").frame(width: 32, height: 36) }.buttonStyle(.bordered).accessibilityLabel("减少一像素重叠")
                        Slider(value: Binding(get: { min(0.95, source.leadingCut) }, set: { value in modify { $0.leadingCut = value; $0.matchConfidence = nil } }), in: 0...0.95)
                        Button { adjustPixel(1) } label: { Image(systemName: "plus").frame(width: 32, height: 36) }.buttonStyle(.bordered).accessibilityLabel("增加一像素重叠")
                    }
                }
            }
            DisclosureGroup("裁剪单张") {
                VStack(spacing: 10) { trimSlider("顶部", side: 0); trimSlider("底部", side: 1); trimSlider("左侧", side: 2); trimSlider("右侧", side: 3) }.padding(.top, 10)
            }.font(.caption)
        }.cardSurface()
    }
    private func modify(_ body: (inout SourceImage) -> Void) {
        session.change({ project in
            guard let i = project.images.firstIndex(where: { $0.id == source.id }) else { return }
            body(&project.images[i])
        }, layout: true, coalesce: true)
    }
    private func move(_ delta: Int) {
        session.change({ project in
            guard let i = project.images.firstIndex(where: { $0.id == source.id }), project.images.indices.contains(i + delta) else { return }
            project.images.swapAt(i, i + delta); session.resetJoins(&project)
        }, layout: true)
    }
    private func adjustPixel(_ delta: Double) { modify { $0.leadingCut = min(0.95, max(0, $0.leadingCut + delta / max(1, extent))); $0.matchConfidence = nil } }
    private func trimSlider(_ title: String, side: Int) -> some View {
        let value: Double = side == 0 ? source.crop.y : side == 1 ? 1 - source.crop.maxY : side == 2 ? source.crop.x : 1 - source.crop.maxX
        return HStack {
            Text(title).frame(width: 30)
            Slider(value: Binding(get: { min(0.45, max(0, value)) }, set: { value in
                modify { image in
                    switch side {
                    case 0: let bottom = image.crop.maxY; image.crop.y = value; image.crop.height = bottom - value
                    case 1: image.crop.height = 1 - image.crop.y - value
                    case 2: let right = image.crop.maxX; image.crop.x = value; image.crop.width = right - value
                    default: image.crop.width = 1 - image.crop.x - value
                    }
                    image.automaticCrop = nil; image.matchConfidence = nil
                }
            }), in: 0...0.45)
            Text("\(Int(value * 100))%").monospacedDigit().frame(width: 35)
        }
    }
}
