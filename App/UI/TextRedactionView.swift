import SwiftUI
import Vision

/// OCR plaintext is intentionally session-only. This type is never Codable and is never attached to Project.
struct RecognizedTextItem: Identifiable, Sendable, Hashable {
    let id: UUID
    let text: String
    let rect: Box
    let confidence: Double

    init(id: UUID = UUID(), text: String, rect: Box, confidence: Double) {
        self.id = id
        self.text = text
        self.rect = rect
        self.confidence = confidence
    }
}

extension PrivacyScanner {
    /// Recognize visible text without applying any sensitive-information rules.
    /// The returned plaintext exists only in memory so users can explicitly choose what to redact.
    static func recognizedText(_ project: Project) throws -> [RecognizedTextItem] {
        let size = try Composition.build(project).size
        let side = 1536.0
        let strideLength = 1376.0
        var tiles: [Box] = []
        for y in stride(from: 0.0, to: size.height, by: strideLength) {
            for x in stride(from: 0.0, to: size.width, by: strideLength) {
                tiles.append(Box(x, y, min(side, size.width - x), min(side, size.height - y)))
            }
        }

        var output: [RecognizedTextItem] = []
        for tile in tiles {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let image = try Renderer.render(project, region: tile, edits: false, finalGeometry: false, maxPixels: 3_000_000).cgImage else {
                    throw PicSigError.invalidImage
                }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.automaticallyDetectsLanguage = true
                request.minimumTextHeight = 0.005
                let supported = try request.supportedRecognitionLanguages()
                request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ja"].filter { supported.contains($0) }
                try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])

                for observation in request.results ?? [] {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let value = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { continue }
                    let vision = observation.boundingBox
                    let absolute = Box(
                        tile.x + vision.minX * tile.width,
                        tile.y + (1 - vision.maxY) * tile.height,
                        vision.width * tile.width,
                        vision.height * tile.height
                    )
                    let padding = max(3.0, absolute.height * 0.10)
                    let rect = absolute.expanded(dx: padding, dy: padding * 0.65).normalized(to: size).intersection(.unit)
                    guard rect.isValid else { continue }
                    let item = RecognizedTextItem(text: value, rect: rect, confidence: Double(candidate.confidence))
                    if !output.contains(where: { duplicate($0, item) }) {
                        output.append(item)
                    }
                }
            }
            guard output.count <= 5000 else {
                throw PicSigError.storage("识别到的文字区域过多，请把长图分段处理。")
            }
        }

        return output.sorted { lhs, rhs in
            if abs(lhs.rect.y - rhs.rect.y) < max(lhs.rect.height, rhs.rect.height) * 0.45 {
                return lhs.rect.x < rhs.rect.x
            }
            return lhs.rect.y < rhs.rect.y
        }
    }

    private static func duplicate(_ lhs: RecognizedTextItem, _ rhs: RecognizedTextItem) -> Bool {
        guard lhs.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == rhs.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        let intersection = lhs.rect.intersection(rhs.rect).area
        let union = lhs.rect.area + rhs.rect.area - intersection
        return intersection / max(0.0000001, union) > 0.38
    }
}

extension MediaWorker {
    func recognizedText(_ project: Project) throws -> [RecognizedTextItem] {
        try PrivacyScanner.recognizedText(project)
    }
}

@MainActor
extension StudioSession {
    private func coverage(of item: RecognizedTextItem, by mask: PrivacyMask) -> Double {
        mask.rect.intersection(item.rect).area / max(0.0000001, item.rect.area)
    }

    func textTapMask(for item: RecognizedTextItem) -> PrivacyMask? {
        project.edit.masks.first {
            $0.enabled && $0.kind == .manual && $0.groupID.hasPrefix("ocrTap:") && coverage(of: item, by: $0) > 0.55
        }
    }

    func coveringMask(for item: RecognizedTextItem) -> PrivacyMask? {
        project.edit.masks.first { $0.enabled && coverage(of: item, by: $0) > 0.55 }
    }

    func toggleTextRedaction(_ item: RecognizedTextItem) {
        if let existing = textTapMask(for: item) {
            change { project in
                project.edit.masks.removeAll { $0.id == existing.id }
            }
            if selectedMask == existing.id { selectedMask = nil }
            return
        }
        if let existing = coveringMask(for: item) {
            selectedMask = existing.id
            return
        }
        var mask = PrivacyMask(rect: item.rect.intersection(.unit), kind: .manual, groupID: "ocrTap:\(UUID().uuidString)")
        mask.reviewed = true
        change { $0.edit.masks.append(mask) }
        selectedMask = mask.id
    }
}

struct TextRedactionView: View {
    @ObservedObject var session: StudioSession
    @Environment(\.dismiss) private var dismiss
    @State private var items: [RecognizedTextItem] = []
    @State private var query = ""
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var generation = UUID()

    private var visible: [RecognizedTextItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return items }
        return items.filter { $0.text.localizedCaseInsensitiveContains(term) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("正在本机识别文字…").font(.subheadline).foregroundStyle(.secondary)
                        Text("识别结果只保存在当前编辑会话，不写入项目文件。")
                            .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    }
                    .padding(30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    ContentUnavailableView("文字识别失败", systemImage: "text.viewfinder", description: Text(errorMessage))
                } else if visible.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "没有识别到文字" : "没有匹配的文字",
                        systemImage: "text.magnifyingglass",
                        description: Text(query.isEmpty ? "可以继续使用手动画框遮挡。" : "换个关键词再试。")
                    )
                } else {
                    List {
                        Section {
                            Text("点一段文字即可直接打码；再点一次可撤销由这里创建的遮挡。已经被智能打码或手动画框覆盖的文字会显示为已遮挡。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Section("识别到 \(items.count) 段文字") {
                            ForEach(visible) { item in
                                row(item)
                            }
                        }
                    }
                    .accessibilityIdentifier("recognized-text-list")
                }
            }
            .navigationTitle("文字打码")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索识别文字")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { rescan() } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(loading)
                        .accessibilityLabel("重新识别文字")
                }
            }
            .task { await load(generation) }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ item: RecognizedTextItem) -> some View {
        let textMask = session.textTapMask(for: item)
        let covered = session.coveringMask(for: item)
        return Button {
            session.toggleTextRedaction(item)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: textMask != nil ? "checkmark.circle.fill" : covered != nil ? "checkmark.shield.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(textMask != nil ? Color.picAccent : covered != nil ? Color.picMint : Color.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.text)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(4)
                    Text(textMask != nil ? "已通过文字打码 · 点击撤销" : covered != nil ? "已被其他遮挡覆盖" : "点击直接打码")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text("\(Int((item.confidence * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("recognized-text-row")
    }

    private func rescan() {
        generation = UUID()
        items = []
        errorMessage = nil
        loading = true
        let token = generation
        Task { await load(token) }
    }

    @MainActor
    private func load(_ token: UUID) async {
        let snapshot = session.project
        do {
            let result = try await MediaWorker.shared.recognizedText(snapshot)
            guard token == generation, !Task.isCancelled else { return }
            items = result
            loading = false
        } catch is CancellationError {
            // Sheet dismissal cancels the task; no user-facing error is needed.
        } catch {
            guard token == generation else { return }
            errorMessage = error.localizedDescription
            loading = false
        }
    }
}
