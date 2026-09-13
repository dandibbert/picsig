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
            toggleMask(existing.id, enabled: false)
            selectedMask = nil
            return
        }
        var mask = PrivacyMask(rect: item.rect.intersection(.unit), kind: .manual, groupID: "ocrTap:\(UUID().uuidString)")
        mask.reviewed = true
        change { $0.edit.masks.append(mask) }
        selectedMask = nil
    }
}
