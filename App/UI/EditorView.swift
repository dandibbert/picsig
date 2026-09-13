import SwiftUI

struct EditorView: View {
    @ObservedObject var session: StudioSession
    @Environment(\.scenePhase) private var phase
    @State private var tool: CanvasTool = .navigate
    @State private var reveal = false
    @State private var review = false
    @State private var textRedaction = false
    @State private var settings = false
    @State private var rescan = false
    @State private var textPoint: Point2D?
    @State private var text = ""
    @State private var color = "coral"
    @State private var lineWidth = 8.0
    var body: some View {
        VStack(spacing: 0) {
            statusBar
            if let image = session.preview, let canvas = session.composition?.size {
                ZoomCanvas(image: image, canvas: canvas, edit: session.project.edit, tool: tool,
                           selected: session.selectedMask, reveal: reveal, color: color, lineWidth: lineWidth,
                           detail: session.detail, action: handle, requestDetail: session.requestDetail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("editor-canvas")
            } else { ProgressView("正在准备画布…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 34, height: 34) }.disabled(session.undoCount == 0).accessibilityLabel("撤销")
                    Button { session.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 34, height: 34) }.disabled(session.redoCount == 0).accessibilityLabel("重做")
                    Spacer(minLength: 4)
                    Text("按住查看原图").font(.caption).foregroundStyle(reveal ? Color.orange : Color.secondary)
                        .padding(.horizontal, 12).frame(height: 34).background(Color.primary.opacity(0.05), in: Capsule())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in reveal = true }.onEnded { _ in reveal = false })
                        .accessibilityLabel("按住查看未遮挡原图，松开恢复")
                    Button { settings = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 34, height: 34) }.accessibilityLabel("识别规则")
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(CanvasTool.allCases, id: \.self) { item in
                            Button { tool = item; reveal = false } label: {
                                VStack(spacing: 6) { Image(systemName: item.symbol).font(.system(size: 19)); Text(item.title).font(.caption2) }
                                    .frame(width: 55, height: 57).background(tool == item ? Color.picAccent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 13))
                                    .foregroundStyle(tool == item ? Color.picAccent : Color.secondary)
                            }.buttonStyle(.plain).accessibilityIdentifier("tool-\(item.rawValue)")
                        }
                    }
                }
                if let mask = session.mask { maskInspector(mask) }
                else if [.pen, .arrow, .rectangle, .text].contains(tool) { markControls }
                else if tool == .crop { cropControls }
                else { Text(tool == .navigate ? "点击遮挡区域可复核 · 双指缩放" : "单指操作 · 双指平移与缩放").font(.caption2).foregroundStyle(.secondary) }
                HStack(spacing: 8) {
                    Button { textRedaction = true } label: {
                        Label("文字", systemImage: "text.viewfinder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("text-redaction")
                    Button { if session.project.edit.masks.isEmpty { session.scan() } else { rescan = true } } label: {
                        Label("智能", systemImage: "sparkles").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("scan-privacy")
                    Button { review = true } label: {
                        Label("复核 \(session.project.edit.masks.count)", systemImage: "checklist").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("review-masks")
                }.controlSize(.large)
            }.padding(.horizontal, 16).padding(.vertical, 12).background(.regularMaterial)
        }.background(Color.picCanvas).disabled(session.busy)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("导出") { reveal = false; session.exportResult = nil; session.showExport = true }.fontWeight(.semibold).disabled(session.busy).accessibilityIdentifier("open-export")
            }
        }
        .sheet(isPresented: $textRedaction) {
            TextRedactionView(session: session)
        }
        .sheet(isPresented: $review) {
            MaskReviewView(session: session) { id in session.selectedMask = id; tool = .adjust; review = false }
        }
        .sheet(isPresented: $settings) {
            NavigationStack {
                PrivacySettingsView(options: Binding(get: { session.project.privacy }, set: { value in session.change { $0.privacy = value; $0.edit.scanFinished = false } }))
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { settings = false } } }
            }
        }
        .confirmationDialog("重新识别隐私？", isPresented: $rescan, titleVisibility: .visible) {
            Button("重新识别，保留手动画框") { session.scan() }
        } message: { Text("将替换自动识别的标记及其复核状态，不删除手动添加的遮挡。旧状态可撤销。") }
        .alert("添加文字", isPresented: Binding(get: { textPoint != nil }, set: { if !$0 { textPoint = nil; text = "" } })) {
            TextField("输入标注文字", text: $text)
            Button("取消", role: .cancel) { textPoint = nil; text = "" }
            Button("添加") {
                if let point = textPoint, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let mark = Annotation(kind: .text, points: [point], text: String(text.prefix(300)), width: lineWidth, color: color)
                    session.change { $0.edit.annotations.append(mark) }
                }
                textPoint = nil; text = ""
            }
        }
        .onChange(of: session.busy) { oldValue, newValue in
            if oldValue, !newValue, session.preview == nil {
                session.refreshPreview()
            }
        }
        .onChange(of: phase) { _, value in if value != .active { reveal = false } }
        .onDisappear { reveal = false }
    }
    private var statusBar: some View {
        HStack(spacing: 10) {
            Image(systemName: session.project.edit.scanFinished ? "shield.lefthalf.filled" : "shield").foregroundStyle(session.project.edit.scanFinished ? Color.picMint : Color.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.project.edit.scanFinished ? "\(session.activeMasks) 处已遮挡 · 分享前请复核" : "隐私检查尚未完成").font(.caption.weight(.semibold))
                Text("自动识别可能遗漏，也可用「文字」直接点选 OCR 结果打码。").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if session.project.edit.quarterTurns != 0 { Text("导出 ↻\(session.project.edit.quarterTurns * 90)°").font(.caption2).foregroundStyle(.secondary) }
        }.padding(.horizontal, 18).padding(.vertical, 10).background(.background)
    }
    private func maskInspector(_ mask: PrivacyMask) -> some View {
        VStack(spacing: 8) {
            HStack {
                Label(mask.kind.title, systemImage: mask.kind.symbol).font(.caption.weight(.semibold))
                Spacer()
                Button { session.selectedMask = nil; tool = .navigate } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("关闭遮挡调整")
            }
            HStack {
                Toggle("遮挡", isOn: Binding(get: { mask.enabled }, set: { session.toggleMask(mask.id, enabled: $0) })).font(.caption).fixedSize()
                Spacer()
                Picker("遮挡样式", selection: Binding(get: { mask.style }, set: { style in session.change { project in if let i = project.edit.masks.firstIndex(where: { $0.id == mask.id }) { project.edit.masks[i].style = style } } })) {
                    ForEach(MaskStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().pickerStyle(.menu)
                Menu {
                    Button("遮挡所有相同内容") { session.toggleMask(mask.id, enabled: true, linked: true) }
                    Button("保留所有相同内容", role: .destructive) { session.toggleMask(mask.id, enabled: false, linked: true) }
                } label: { Text("关联 \(session.project.edit.masks.filter { $0.groupID == mask.groupID }.count) 处").font(.caption) }
            }
            HStack {
                Button("扩边 +4 px") {
                    guard let size = session.composition?.size else { return }
                    session.adjustMask(mask.id, rect: mask.rect.expanded(dx: 4 / size.width, dy: 4 / size.height))
                }
                Spacer()
                Button(mask.reviewed ? "已复核 ✓" : "标为已复核") { session.toggleMask(mask.id, enabled: mask.enabled) }
                Button("拖动调框") { tool = .adjust }
            }.font(.caption)
            if tool == .adjust { Text("拖动框体移动位置；拖动四角调整大小。双指平移画布。").font(.caption2).foregroundStyle(.secondary) }
        }.padding(12).background(Color.picAccent.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }
    private var markControls: some View {
        HStack(spacing: 13) {
            ForEach(["coral", "violet", "mint", "ink"], id: \.self) { value in
                Button { color = value } label: {
                    Circle().fill(Color(uiColor: Renderer.markColor(value))).frame(width: 23, height: 23)
                        .padding(4).overlay(Circle().stroke(color == value ? Color.primary : .clear, lineWidth: 1.5))
                }.accessibilityLabel(["coral": "红色", "violet": "紫色", "mint": "青色", "ink": "黑色"][value] ?? value)
            }
            Slider(value: $lineWidth, in: 2...18, step: 1).accessibilityLabel(tool == .text ? "文字大小" : "线条粗细")
        }
    }
    private var cropControls: some View {
        HStack {
            Text("画框选择导出范围").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("还原") { session.change { $0.edit.crop = .unit } }.font(.caption)
            Button { session.change { $0.edit.quarterTurns = ($0.edit.quarterTurns + 1) % 4 } } label: { Label("90°", systemImage: "rotate.right").font(.caption) }
        }
    }
    private func handle(_ action: CanvasAction) {
        switch action {
        case .mask(let box): session.addMask(box); tool = .adjust
        case .adjust(let id, let box): session.adjustMask(id, rect: box)
        case .annotation(let annotation): session.change { $0.edit.annotations.append(annotation) }
        case .crop(let box): session.change { $0.edit.crop = box }
        case .select(let id): session.selectedMask = id
        case .text(let point): textPoint = point
        case .erase(let point):
            if let mask = session.project.edit.masks.last(where: { $0.rect.contains(point) }) {
                if mask.kind == .manual { session.change { $0.edit.masks.removeAll { $0.id == mask.id } } }
                else { session.toggleMask(mask.id, enabled: false) }
                session.selectedMask = nil
            } else {
                session.change { project in
                    if let index = project.edit.annotations.lastIndex(where: { mark in
                        let xs = mark.points.map(\.x), ys = mark.points.map(\.y)
                        let box = Box(xs.min() ?? 0, ys.min() ?? 0, max(0.04, (xs.max() ?? 0) - (xs.min() ?? 0)), max(0.02, (ys.max() ?? 0) - (ys.min() ?? 0)))
                        return box.expanded(dx: 0.025, dy: 0.01).contains(point)
                    }) { project.edit.annotations.remove(at: index) }
                }
            }
        }
    }
}

struct MaskReviewView: View {
    @ObservedObject var session: StudioSession
    var locate: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var filter = 0
    private var visible: [PrivacyMask] { session.project.edit.masks.filter { filter == 0 || (filter == 1 ? !$0.reviewed : !$0.enabled) } }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("识别结果不是安全保证。请检查截图里的姓名、地址、头像和业务信息；遗漏的区域可用「文字」直接点选，或用「遮挡」手动画框。").font(.footnote).foregroundStyle(.secondary)
                    Picker("筛选", selection: $filter) { Text("全部").tag(0); Text("待复核").tag(1); Text("已保留").tag(2) }.pickerStyle(.segmented)
                }
                if visible.isEmpty { ContentUnavailableView("没有对应标记", systemImage: "checklist", description: Text("这不表示图中没有敏感内容。可以返回画布继续人工检查。")) }
                ForEach(visible) { mask in
                    HStack(spacing: 14) {
                        Button { locate(mask.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: mask.kind.symbol).foregroundStyle(Color.picAccent).frame(width: 26)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(mask.kind.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                    Text("\(mask.reviewed ? "已复核" : "待复核") · \(Int(mask.confidence * 100))% 参考置信度").font(.caption2).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        Toggle("遮挡\(mask.kind.title)", isOn: Binding(get: { mask.enabled }, set: { session.toggleMask(mask.id, enabled: $0) })).labelsHidden()
                    }.padding(.vertical, 4)
                }
            }.navigationTitle("隐私复核").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("全部遮挡并标为已复核") { session.change { p in for i in p.edit.masks.indices { p.edit.masks[i].enabled = true; p.edit.masks[i].reviewed = true } } }
                            Button("保持当前选择，全部标为已复核") { session.change { p in for i in p.edit.masks.indices { p.edit.masks[i].reviewed = true } } }
                        } label: { Image(systemName: "checkmark.circle") }
                    }
                }
        }.presentationDetents([.medium, .large])
    }
}