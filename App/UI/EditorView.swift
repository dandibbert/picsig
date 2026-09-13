import SwiftUI

private struct TextIndexKey: Hashable {
    var enabled: Bool
    var images: [SourceImage]
    var layout: LayoutOptions
}

struct EditorView: View {
    @ObservedObject var session: StudioSession
    @Environment(\.dismiss) private var dismiss
    @State private var tool: CanvasTool = .navigate
    @State private var settings = false
    @State private var textDraft: Annotation?
    @State private var color = "coral"
    @State private var lineWidth = 8.0
    @State private var textRegions: [RecognizedTextItem] = []
    @State private var indexedImages: [SourceImage] = []
    @State private var indexedLayout: LayoutOptions?
    @State private var indexing = false
    @State private var indexError: String?
    private var selectedMark: Annotation? { session.project.edit.annotations.first { $0.id == session.selectedAnnotation } }
    private var textIndexKey: TextIndexKey { TextIndexKey(enabled: tool == .textMask, images: session.project.images, layout: session.project.layout) }
    var body: some View {
        VStack(spacing: 0) {
            if session.project.images.contains(where: { $0.matchConfidence == 0 }) {
                Button { session.stage = .compose } label: {
                    Label("有接缝未匹配，点此调整", systemImage: "exclamationmark.triangle")
                        .font(.caption).padding(10).frame(maxWidth: .infinity)
                }.foregroundStyle(.orange).background(Color.orange.opacity(0.08))
            }
            if let image = session.preview, let canvas = session.composition?.size {
                ZoomCanvas(image: image, canvas: canvas, edit: session.project.edit, tool: tool,
                           selected: session.selectedMask, selectedAnnotation: session.selectedAnnotation,
                           textRegions: textRegions, color: color, lineWidth: lineWidth,
                           detail: session.detail, action: handle, requestDetail: session.requestDetail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { ProgressView("正在准备画布…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            VStack(spacing: 8) {
                if let mask = session.mask, tool != .textMask { maskInspector(mask) }
                else if let mark = selectedMark { markInspector(mark) }
                else if [.pen, .arrow, .rectangle].contains(tool) {
                    HStack { swatches(color: $color); Slider(value: $lineWidth, in: 2...24).accessibilityLabel("线条粗细") }
                } else if tool == .crop {
                    HStack {
                        Text("拖动画框；拖动四角修改裁剪").font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button("还原") { session.change { $0.edit.crop = .unit } }.fixedSize()
                        Button { session.change { $0.edit.quarterTurns = ($0.edit.quarterTurns + 1) % 4 } } label: { Image(systemName: "rotate.right").frame(width: 36, height: 36) }.accessibilityLabel("旋转90度")
                    }
                }
                HStack(spacing: 8) {
                    if indexing { ProgressView().controlSize(.small) }
                    Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 6)
                    Button { session.scan() } label: {
                        Label("智能打码", systemImage: "sparkles").font(.caption.weight(.semibold)).fixedSize()
                    }.buttonStyle(.bordered).accessibilityIdentifier("scan-privacy")
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(CanvasTool.toolbar, id: \.self) { item in
                            Button {
                                tool = item; session.selectedMask = nil; session.selectedAnnotation = nil
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: item.symbol).font(.system(size: 20))
                                    Text(item.title).font(.system(size: 11, weight: .medium)).lineLimit(1).fixedSize()
                                }.frame(width: 68, height: 54)
                                    .foregroundStyle(tool == item ? Color.picAccent : Color.primary)
                                    .background(tool == item ? Color.picAccent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain).accessibilityIdentifier(item == .textMask ? "text-redaction" : "tool-\(item.rawValue)")
                        }
                    }
                }
                Text("\(session.activeMasks) 处打码 · \(session.project.edit.annotations.count) 个标注")
                    .font(.system(size: 10)).foregroundStyle(.secondary).accessibilityIdentifier("selection-count")
            }.padding(.horizontal, 12).padding(.vertical, 8).background(.regularMaterial)
        }.background(Color.picCanvas).disabled(session.busy)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(session.undoCount == 0 || session.busy).accessibilityLabel("撤销")
                Button { session.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(session.redoCount == 0 || session.busy).accessibilityLabel("重做")
                Menu {
                    Button("打码规则") { settings = true }
                    Button("保存并关闭") {
                        Task {
                            do { try await session.flush(); dismiss() }
                            catch { session.notice = Notice(title: "保存失败", message: error.localizedDescription) }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("更多")
                Button("导出") { session.exportResult = nil; session.showExport = true }
                    .fontWeight(.semibold).fixedSize().disabled(session.busy).accessibilityIdentifier("open-export")
            }
        }
        .sheet(item: $textDraft) { draft in
            TextAnnotationSheet(annotation: draft) { updated in
                session.change { p in
                    if let i = p.edit.annotations.firstIndex(where: { $0.id == updated.id }) { p.edit.annotations[i] = updated }
                    else { p.edit.annotations.append(updated) }
                }
                session.selectedAnnotation = updated.id; session.selectedMask = nil; tool = .navigate
            }
        }
        .sheet(isPresented: $settings) {
            NavigationStack {
                PrivacySettingsView(options: Binding(get: { session.project.privacy }, set: { value in session.change { $0.privacy = value; $0.edit.scanFinished = false } }))
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { settings = false } } }
            }
        }
        .task(id: textIndexKey) {
            guard tool == .textMask else { indexing = false; return }
            guard indexedImages != session.project.images || indexedLayout != session.project.layout else { return }
            let snapshot = session.project
            indexing = true; indexError = nil; textRegions = []
            do {
                let result = try await MediaWorker.shared.recognizedText(snapshot)
                try Task.checkCancellation()
                textRegions = result; indexedImages = snapshot.images; indexedLayout = snapshot.layout; indexing = false
            } catch is CancellationError {} catch { indexing = false; indexError = "未能定位文字，可切换框选打码" }
        }
        .onChange(of: session.busy) { oldValue, newValue in
            if oldValue && !newValue && session.preview == nil { session.refreshPreview() }
        }
    }
    private var hint: String {
        switch tool {
        case .textMask: return indexing ? "正在定位图片上的文字…" : (indexError ?? "点图片上的文字打码，再点取消；单指滚动")
        case .text: return "点图片上需要加字的位置；已有文字可双击修改"
        case .crop: return "裁剪可随时修改，原图不会被删除"
        case .navigate: return selectedMark != nil || session.mask != nil ? "拖动移动，四角缩放" : "点选标注可修改，双指缩放"
        default: return "单指绘制，双指移动画布"
        }
    }
    private func maskInspector(_ mask: PrivacyMask) -> some View {
        HStack(spacing: 10) {
            Picker("遮挡样式", selection: Binding(get: { mask.style }, set: { value in session.change { p in if let i = p.edit.masks.firstIndex(where: { $0.id == mask.id }) { p.edit.masks[i].style = value; p.edit.masks[i].reviewed = true } } })) {
                ForEach(MaskStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.menu).labelsHidden()
            Button("扩边") {
                if let size = session.composition?.size { session.adjustMask(mask.id, rect: mask.rect.expanded(dx: 4 / size.width, dy: 4 / size.height)) }
            }.fixedSize()
            Spacer(minLength: 0)
            Button(role: .destructive) { session.toggleMask(mask.id, enabled: false); session.selectedMask = nil } label: { Image(systemName: "trash").frame(width: 36, height: 36) }.accessibilityLabel("删除遮挡")
            Button { session.selectedMask = nil } label: { Image(systemName: "xmark").frame(width: 36, height: 36) }.accessibilityLabel("取消选择")
        }.font(.caption)
    }
    private func markInspector(_ mark: Annotation) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                swatches(color: Binding(get: { selectedMark?.color ?? mark.color }, set: { value in updateSelected { $0.color = value } }))
                Spacer(minLength: 0)
                if mark.kind == .text { Button("编辑文字") { textDraft = mark }.font(.caption).fixedSize().accessibilityIdentifier("edit-selected-text") }
                Button(role: .destructive) {
                    session.change { $0.edit.annotations.removeAll { $0.id == mark.id } }; session.selectedAnnotation = nil
                } label: { Image(systemName: "trash").frame(width: 36, height: 36) }.accessibilityLabel("删除标注")
                Button { session.selectedAnnotation = nil } label: { Image(systemName: "xmark").frame(width: 36, height: 36) }.accessibilityLabel("取消选择")
            }
            HStack {
                Text(mark.kind == .text ? "字号" : "粗细").font(.caption).fixedSize()
                Slider(value: Binding(get: { selectedMark?.width ?? mark.width }, set: { value in updateSelected { $0.width = value } }), in: mark.kind == .text ? 3.6...40 : 1...40)
                Text("\(Int(mark.width * (mark.kind == .text ? 5 : 1)))").font(.caption.monospacedDigit()).frame(width: 32)
            }
        }
    }
    private func updateSelected(_ body: (inout Annotation) -> Void) {
        guard let id = session.selectedAnnotation else { return }
        session.change({ p in if let i = p.edit.annotations.firstIndex(where: { $0.id == id }) { body(&p.edit.annotations[i]) } }, coalesce: true)
    }
    private func swatches(color: Binding<String>) -> some View {
        HStack(spacing: 2) {
            ForEach(["coral", "violet", "mint", "ink"], id: \.self) { value in
                Button { color.wrappedValue = value } label: {
                    Circle().fill(Color(uiColor: Renderer.markColor(value))).frame(width: 20, height: 20).padding(6)
                        .overlay(Circle().stroke(color.wrappedValue == value ? Color.primary : .clear, lineWidth: 1))
                }.buttonStyle(.plain).accessibilityLabel("标注颜色 \(value)")
            }
        }
    }
    private func handle(_ action: CanvasAction) {
        switch action {
        case .redactText(let item): session.toggleTextRedaction(item); session.selectedAnnotation = nil
        case .mask(let box): session.addMask(box); session.selectedAnnotation = nil; tool = .navigate
        case .adjust(let id, let box): session.adjustMask(id, rect: box)
        case .annotation(let mark):
            session.change { $0.edit.annotations.append(mark) }; session.selectedAnnotation = mark.id; session.selectedMask = nil; tool = .navigate
        case .updateAnnotation(let mark): session.change { p in if let i = p.edit.annotations.firstIndex(where: { $0.id == mark.id }) { p.edit.annotations[i] = mark } }
        case .crop(let box): session.change { $0.edit.crop = box }
        case .select(let id): session.selectedMask = id; if id != nil { session.selectedAnnotation = nil; tool = .navigate }
        case .selectAnnotation(let id): session.selectedAnnotation = id; if id != nil { session.selectedMask = nil; tool = .navigate }
        case .text(let point): textDraft = Annotation(kind: .text, points: [point], width: 8, color: color)
        case .editText(let id): textDraft = session.project.edit.annotations.first { $0.id == id }
        case .erase(let point):
            if let mask = session.project.edit.masks.last(where: { $0.rect.contains(point) }) { session.toggleMask(mask.id, enabled: false) }
            else if let size = session.composition?.size,
                    let mark = session.project.edit.annotations.last(where: { Renderer.hitAnnotation($0, at: point, canvas: size, tolerance: Size2D(0.01, 0.005)) }) {
                session.change { $0.edit.annotations.removeAll { $0.id == mark.id } }
            }
        }
    }
}

private struct TextAnnotationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State var annotation: Annotation
    var save: (Annotation) -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                TextField("输入文字", text: $annotation.text, axis: .vertical)
                    .font(.system(size: 22)).lineLimit(3...6).focused($focused)
                    .padding(14).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("annotation-text-input")
                HStack {
                    Text("字号").font(.subheadline)
                    Slider(value: $annotation.width, in: 3.6...40)
                    Text("\(Int(annotation.width * 5))").monospacedDigit().frame(width: 40)
                }
                HStack(spacing: 16) {
                    ForEach(["coral", "violet", "mint", "ink"], id: \.self) { value in
                        Button { annotation.color = value } label: {
                            Circle().fill(Color(uiColor: Renderer.markColor(value))).frame(width: 30, height: 30)
                                .overlay(Circle().strokeBorder(annotation.color == value ? Color.primary : .clear, lineWidth: 3))
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }
                Text(annotation.text.isEmpty ? "文字预览" : annotation.text)
                    .font(.system(size: min(36, annotation.width * 5), weight: .semibold)).foregroundStyle(Color(uiColor: Renderer.markColor(annotation.color)))
                    .lineLimit(2).frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                Spacer(minLength: 0)
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively)
                .navigationTitle("编辑文字").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { annotation.text = String(annotation.text.prefix(300)); save(annotation); dismiss() }
                            .disabled(annotation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("save-annotation-text")
                    }
                }
                .onAppear { focused = true }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}
