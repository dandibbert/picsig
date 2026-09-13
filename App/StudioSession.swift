import Foundation
import SwiftUI
import UIKit

struct Notice: Identifiable { let id = UUID(); let title: String; let message: String }
struct DetailPatch { var region: Box; var image: UIImage }
enum StudioStage { case compose, edit }

@MainActor final class LibraryModel: ObservableObject {
    @Published var projects: [Project] = []
    @Published var unreadableCount = 0
    @Published var defaults = PrivacyOptions()
    @Published var active: StudioSession?
    @Published var notice: Notice?
    @Published var thumbnails: [UUID: UIImage] = [:]
    private var didLoad = false
    func reload() async {
        do {
            let result = try await MediaWorker.shared.list()
            projects = result.projects; unreadableCount = result.unreadableCount
            defaults = await MediaWorker.shared.loadPrivacy()
            for project in projects.prefix(20) where thumbnails[project.id] == nil {
                // Draft covers are deliberately decorative, not miniature unredacted source images.
                thumbnails[project.id] = nil
            }
            if !didLoad {
                didLoad = true; try await MediaWorker.shared.cleanExports(); try await MediaWorker.shared.clearImports()
                if ProcessInfo.processInfo.arguments.contains("--demo-editor") { await openDemo(edit: true) }
            }
        } catch { notice = Notice(title: "无法读取项目", message: error.localizedDescription) }
    }
    func create(_ kind: ProjectKind) {
        let title = "\(kind.title) · \(Date().formatted(.dateTime.month().day().hour().minute()))"
        var project = Project(title: title, kind: kind); project.privacy = defaults
        active = StudioSession(project: project)
    }
    func open(_ project: Project) { active = StudioSession(project: project, stage: project.edit.hasChanges || project.edit.scanFinished ? .edit : .compose) }
    func openDemo(edit: Bool = false) async {
        do {
            let project = try await MediaWorker.shared.demo()
            let session = StudioSession(project: project)
            active = session
            if edit { session.stage = .edit }
        } catch { notice = Notice(title: "示例创建失败", message: error.localizedDescription) }
    }
    func delete(_ project: Project) async {
        do { try await MediaWorker.shared.delete(project.id); await reload() }
        catch { notice = Notice(title: "删除失败", message: error.localizedDescription) }
    }
    func saveDefaults() async {
        do { try await MediaWorker.shared.savePrivacy(defaults) }
        catch { notice = Notice(title: "设置未保存", message: error.localizedDescription) }
    }
}

@MainActor final class StudioSession: ObservableObject, Identifiable {
    let id: UUID
    @Published var project: Project
    @Published var stage: StudioStage
    @Published var preview: UIImage?
    @Published var detail: DetailPatch?
    @Published var thumbnails: [UUID: UIImage] = [:]
    @Published var busy = false
    @Published var progress = 0.0
    @Published var workLabel = ""
    @Published var note: String?
    @Published var notice: Notice?
    @Published var selectedMask: UUID?
    @Published var exportResult: ExportResult?
    @Published var showExport = false
    @Published private(set) var undoCount = 0
    @Published private(set) var redoCount = 0
    private var history: [Project] = [], future: [Project] = []
    private var work: Task<Void, Never>?, renderTask: Task<Void, Never>?, saveTask: Task<Void, Never>?, detailTask: Task<Void, Never>?
    private var operation = UUID(), renderVersion = UUID(), detailVersion = UUID()
    private var lastCheckpoint = Date.distantPast
    var composition: Composition? { try? Composition.build(project) }
    var mask: PrivacyMask? { project.edit.masks.first { $0.id == selectedMask } }
    var activeMasks: Int { project.edit.masks.filter(\.enabled).count }
    init(project: Project, stage: StudioStage = .compose) { self.id = project.id; self.project = project; self.stage = stage }
    deinit { work?.cancel(); renderTask?.cancel(); detailTask?.cancel(); saveTask?.cancel() }

    private func checkpoint(coalesce: Bool = false) {
        if !coalesce || Date().timeIntervalSince(lastCheckpoint) > 0.6 {
            history.append(project); if history.count > 40 { history.removeFirst() }
            lastCheckpoint = Date()
        }
        future = []; undoCount = history.count; redoCount = 0
    }
    func change(_ body: (inout Project) -> Void, layout: Bool = false, coalesce: Bool = false) {
        guard !busy else { return }
        checkpoint(coalesce: coalesce); body(&project)
        project.updatedAt = Date()
        if layout { project.edit = EditState(); selectedMask = nil; refreshPreview() }
        persist()
    }
    func undo() {
        guard !busy, var old = history.popLast() else { return }
        future.append(project); old.updatedAt = Date(); project = old
        undoCount = history.count; redoCount = future.count; selectedMask = nil
        persist(); refreshPreview()
    }
    func redo() {
        guard !busy, var next = future.popLast() else { return }
        history.append(project); next.updatedAt = Date(); project = next
        undoCount = history.count; redoCount = future.count; selectedMask = nil
        persist(); refreshPreview()
    }
    func persist() {
        saveTask?.cancel(); let snapshot = project
        guard !snapshot.images.isEmpty else { return }
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)); try Task.checkCancellation(); try await MediaWorker.shared.save(snapshot) }
            catch is CancellationError {} catch { self?.notice = Notice(title: "项目未保存", message: error.localizedDescription) }
        }
    }
    func flush() async throws {
        saveTask?.cancel()
        if !project.images.isEmpty { try await MediaWorker.shared.save(project) }
    }
    func refreshPreview() {
        renderTask?.cancel(); detailTask?.cancel(); detail = nil
        guard !project.images.isEmpty else { preview = nil; return }
        let version = UUID(); renderVersion = version; let snapshot = project
        renderTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                let image = try await MediaWorker.shared.preview(snapshot)
                guard let self = self, self.renderVersion == version, !Task.isCancelled else { return }
                self.preview = image
                for source in snapshot.images where self.thumbnails[source.id] == nil {
                    let thumb = try await MediaWorker.shared.thumbnail(source, project: snapshot.id)
                    guard self.renderVersion == version, !Task.isCancelled else { return }
                    self.thumbnails[source.id] = thumb
                }
            } catch is CancellationError {} catch { self?.notice = Notice(title: "预览失败", message: error.localizedDescription) }
        }
    }
    func requestDetail(_ region: Box) {
        guard !busy, let composition = composition, composition.size.area > 5_000_000 else { return }
        detailTask?.cancel(); let snapshot = project, version = UUID(); detailVersion = version
        detailTask = Task { [weak self] in
            do {
                let image = try await MediaWorker.shared.detail(snapshot, region: region)
                guard let self = self, self.detailVersion == version, !Task.isCancelled else { return }
                self.detail = DetailPatch(region: region, image: image)
            } catch { /* The low-resolution preview remains available; no edit is lost. */ }
        }
    }
    private func sink(_ token: UUID) -> WorkProgress {
        { [weak self] fraction, label in
            Task { @MainActor in
                guard let self = self, self.operation == token, self.busy else { return }
                self.progress = fraction; self.workLabel = label
            }
        }
    }
    private func run(_ label: String, body: @escaping @MainActor (WorkProgress) async throws -> Void) {
        guard !busy else { return }
        renderTask?.cancel(); detailTask?.cancel()
        busy = true; progress = 0; workLabel = label
        let token = UUID(); operation = token
        work = Task { [weak self] in
            guard let self = self else { return }
            do { try await body(self.sink(token)) }
            catch is CancellationError { self.note = "操作已取消，已完成的编辑仍保留。" }
            catch { self.notice = Notice(title: "未能完成", message: error.localizedDescription) }
            guard self.operation == token else { return }
            self.busy = false; self.work = nil
        }
    }
    func cancel() { work?.cancel(); workLabel = "正在停止当前步骤…" }
    func importImages(_ urls: [URL]) {
        let original = project
        run("导入图片") { [self] progress in
            let result = try await MediaWorker.shared.importImages(urls, into: original, progress: progress)
            checkpoint(); project = result.0; refreshPreview()
            note = result.1 == 0 ? "已按选择顺序导入 \(urls.count) 张图片。" : "已导入可用图片；\(result.1) 张未能读取。"
        }
    }
    func importVideo(_ url: URL, options: VideoOptions) {
        let original = project
        run("读取录屏") { [self] progress in
            let frames = try await MediaWorker.shared.extractVideo(url, options: options, into: original, progress: progress)
            checkpoint(); project = frames
            defer { refreshPreview() }
            let report = try await MediaWorker.shared.stitch(frames, trimBars: true, progress: progress)
            project = report.project; refreshPreview()
            note = "保留 \(project.images.count) 个画面，\(report.uncertain) 处拼接缝需检查。"
        }
    }
    func autoStitch(trimBars: Bool) {
        let original = project
        run("自动拼接") { [self] progress in
            let report = try await MediaWorker.shared.stitch(original, trimBars: trimBars, progress: progress)
            checkpoint(); project = report.project; refreshPreview()
            note = "已跳过 \(report.duplicates) 张重复图；\(report.uncertain) 处未可靠匹配，已保留完整内容。"
        }
    }
    func rotateSource(_ id: UUID) {
        let snapshot = project
        run("旋转图片") { [self] _ in
            let result = try await MediaWorker.shared.rotate(id, in: snapshot)
            checkpoint(); project = result; refreshPreview()
        }
    }
    func resetJoins(_ project: inout Project) {
        for index in project.images.indices { project.images[index].leadingCut = 0; project.images[index].automaticCrop = nil; project.images[index].matchConfidence = nil }
    }
    func enterEditor() {
        guard !project.images.isEmpty else { return }
        stage = .edit
        if !project.edit.scanFinished && project.edit.masks.isEmpty { scan() }
    }
    func scan() {
        let snapshot = project
        run("本机隐私识别") { [self] progress in
            let report = try await MediaWorker.shared.scan(snapshot, progress: progress)
            checkpoint()
            project.edit.masks = project.edit.masks.filter { $0.kind == .manual } + report.masks
            project.edit.scanFinished = report.warnings.isEmpty; project.edit.scanWarnings = report.warnings
            project.updatedAt = Date(); selectedMask = nil; persist()
            note = "已检查 \(report.textLines) 个文字区域，标记 \(report.masks.count) 处。自动识别仍可能遗漏，请逐处复核。"
            if !report.warnings.isEmpty { notice = Notice(title: "识别未完全完成", message: report.warnings.joined(separator: "\n")) }
        }
    }
    func toggleMask(_ id: UUID, enabled: Bool, linked: Bool = false) {
        guard let item = project.edit.masks.first(where: { $0.id == id }) else { return }
        change { project in
            for index in project.edit.masks.indices where project.edit.masks[index].id == id || (linked && project.edit.masks[index].groupID == item.groupID) {
                project.edit.masks[index].enabled = enabled; project.edit.masks[index].reviewed = true
            }
        }
    }
    func addMask(_ rect: Box) {
        let mask = PrivacyMask(rect: rect.intersection(.unit), kind: .manual)
        change { $0.edit.masks.append(mask) }; selectedMask = mask.id
    }
    func adjustMask(_ id: UUID, rect: Box) {
        change { p in
            guard let index = p.edit.masks.firstIndex(where: { $0.id == id }) else { return }
            p.edit.masks[index].rect = rect.intersection(.unit); p.edit.masks[index].reviewed = true
        }
    }
    func export(sliced: Bool, jpeg: Bool, audit: Bool) {
        let snapshot = project
        run("导出前隐私复检") { [self] progress in
            if audit {
                let report = try await MediaWorker.shared.scan(snapshot, redacted: true, progress: progress)
                guard report.warnings.isEmpty else { throw PicSigError.storage("导出复检未完成。请重试，或在人工检查后关闭复检再导出。") }
                if !report.masks.isEmpty {
                    checkpoint(); project.edit.masks += report.masks; project.updatedAt = Date(); persist()
                    showExport = false; selectedMask = report.masks.first?.id
                    notice = Notice(title: "复检发现新的敏感区域", message: "已补充遮挡 \(report.masks.count) 处，包括编辑后新增的内容。请检查后再次导出。")
                    return
                }
            }
            let result = try await MediaWorker.shared.export(snapshot, sliced: sliced, jpeg: jpeg, progress: progress)
            exportResult = result
        }
    }
    func savePhotos(_ urls: [URL]) {
        run("保存到照片") { [self] _ in
            try await MediaWorker.shared.saveToPhotos(urls)
            notice = Notice(title: "已保存", message: "已将 \(urls.count) 张处理后的图片添加到相册。原始照片没有被修改。")
        }
    }
}

extension MediaWorker {
    func demo() throws -> Project {
        var project = Project(title: "慢一点，也很好 · 示例", kind: .scroll)
        project.layout.breadth = 1000; project.privacy.keywords = ["小满"]
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 4200), format: format).image { output in
            UIColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1).setFill(); output.fill(CGRect(x: 0, y: 0, width: 1000, height: 4200))
            func text(_ value: String, _ y: CGFloat, _ size: CGFloat, _ weight: UIFont.Weight = .regular, color: UIColor = .darkText) {
                (value as NSString).draw(in: CGRect(x: 80, y: y, width: 840, height: 140), withAttributes: [.font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
            }
            text("WEEKEND NOTES", 100, 26, .bold, color: .systemIndigo)
            text("慢一点，也很好。", 165, 68, .bold)
            text("把散落的片段，拼成完整的一天。", 275, 30, color: .gray)
            for index in 0..<11 {
                let y = CGFloat(440 + index * 310)
                UIColor.white.setFill(); UIBezierPath(roundedRect: CGRect(x: 52, y: y, width: 896, height: 265), cornerRadius: 26).fill()
                text(String(format: "%02d   %@", index + 1, ["给生活留一点空白", "分享之前，记得保护隐私", "内容留下，秘密藏好"][index % 3]), y + 26, 32, .semibold)
                let values = ["去公园走走，读一本喜欢的书。", "邮箱：hello@example.test", "电话：+1 (415) 555-0132", "收件人：小满", "姓名：小满", "卡号：4111 1111 1111 1111", "地址：示例市示例路 100 号", "API key: sk-demo0123456789012345", "服务器：192.0.2.42", "验证码：123456", "不赶时间，也不辜负这一刻。"]
                text(values[index], y + 105, 30, color: .darkGray)
                text("这是本机生成的演示内容，不是真实个人信息。", y + 183, 23, color: .gray)
            }
            text("MADE WITH PICSIG", 3980, 28, .bold, color: .systemIndigo)
        }
        guard let cg = image.cgImage else { throw PicSigError.invalidImage }
        for rect in [CGRect(x: 0, y: 0, width: 1000, height: 1900), CGRect(x: 0, y: 1400, width: 1000, height: 1900), CGRect(x: 0, y: 2800, width: 1000, height: 1400)] {
            guard let crop = cg.cropping(to: rect) else { throw PicSigError.invalidImage }
            project.images.append(try ProjectStore.addImage(crop, project: project.id))
        }
        return try stitch(project, trimBars: false, progress: { _, _ in }).project
    }
}
