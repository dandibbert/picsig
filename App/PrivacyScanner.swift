import Foundation
import UIKit
import Vision
import NaturalLanguage

struct ScanReport: Sendable { var masks: [PrivacyMask]; var warnings: [String]; var textLines: Int }

enum PrivacyScanner {
    private struct Line {
        let candidate: VNRecognizedText
        let bounds: CGRect
        let tile: Box
        var findings: [TextFinding]
    }
    private struct Entity: Hashable { let kind: SensitiveKind; let value: String }

    static func scan(_ project: Project, redacted: Bool = false, progress: WorkProgress) throws -> ScanReport {
        let size = try Composition.build(project).size
        let options = project.privacy
        let side = 1536.0, strideLength = 1376.0
        var tiles: [Box] = []
        for y in stride(from: 0.0, to: size.height, by: strideLength) {
            for x in stride(from: 0.0, to: size.width, by: strideLength) {
                tiles.append(Box(x, y, min(side, size.width - x), min(side, size.height - y)))
            }
        }
        var lines: [Line] = [], masks: [PrivacyMask] = [], warnings: [String] = []
        var groups: [String: String] = [:]
        func group(_ kind: SensitiveKind, _ value: String) -> String {
            var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if kind == .phone || kind == .bankCard { normalized = normalized.filter(\.isNumber) }
            else if kind != .secret { normalized = normalized.lowercased() }
            let key = "\(kind.rawValue):\(normalized)"
            if let existing = groups[key] { return existing }
            let id = UUID().uuidString; groups[key] = id; return id
        }

        for (index, tile) in tiles.enumerated() {
            try Task.checkCancellation()
            do {
                try autoreleasepool {
                    guard let image = try Renderer.render(project, region: tile, edits: redacted, finalGeometry: false, maxPixels: 3_000_000).cgImage else {
                        throw PicSigError.invalidImage
                    }
                    let text = VNRecognizeTextRequest()
                    text.recognitionLevel = .accurate
                    text.usesLanguageCorrection = false
                    text.automaticallyDetectsLanguage = true
                    text.minimumTextHeight = 0.005
                    let supported = try text.supportedRecognitionLanguages()
                    text.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ja"].filter { supported.contains($0) }
                    text.customWords = Array(options.keywords.prefix(200))
                    let faces = VNDetectFaceRectanglesRequest(), codes = VNDetectBarcodesRequest()
                    var requests: [VNRequest] = [text]
                    if options.enabledKinds.contains(.face) { requests.append(faces) }
                    if options.enabledKinds.contains(.code) { requests.append(codes) }
                    try VNImageRequestHandler(cgImage: image, orientation: .up).perform(requests)

                    for observation in text.results ?? [] {
                        guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { continue }
                        var findings = PrivacyRules.findings(in: candidate.string, options: options)
                        findings += linguisticFindings(candidate.string, options: options)
                        if options.enabledKinds.contains(.address), looksLikeResidentialAddress(candidate.string) {
                            let full = NSRange(candidate.string.startIndex..<candidate.string.endIndex, in: candidate.string)
                            if !findings.contains(where: { $0.kind == .address && $0.range == full }) {
                                findings.append(TextFinding(range: full, kind: .address, confidence: 0.86))
                            }
                        }
                        lines.append(Line(candidate: candidate, bounds: observation.boundingBox, tile: tile, findings: findings))
                    }
                    for face in faces.results ?? [] {
                        let rect = canvasBox(face.boundingBox, tile: tile, size: size, padding: options.padding, expansion: 0.15)
                        masks.append(PrivacyMask(rect: rect, kind: .face, confidence: Double(face.confidence)))
                    }
                    for code in codes.results ?? [] {
                        let rect = canvasBox(code.boundingBox, tile: tile, size: size, padding: options.padding, expansion: 0.12)
                        masks.append(PrivacyMask(rect: rect, kind: .code, confidence: Double(code.confidence),
                                                 groupID: group(.code, code.payloadStringValue ?? UUID().uuidString)))
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                warnings.append("第 \(index + 1) / \(tiles.count) 个区域识别失败，请手动检查该区域。")
            }
            guard lines.count <= 12000 else { throw PicSigError.storage("文字区域过多，请分成较小的项目进行隐私检查。") }
            progress(Double(index + 1) / Double(tiles.count) * 0.82, "本机隐私识别 \(index + 1) / \(tiles.count)")
        }

        protectAddressFollowers(&lines, options: options)

        var entities = Set<Entity>()
        for line in lines {
            for finding in line.findings {
                if let range = Range(finding.range, in: line.candidate.string) {
                    let value = String(line.candidate.string[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if value.count >= 2, value.count <= 160 { entities.insert(Entity(kind: finding.kind, value: value)) }
                }
            }
        }
        if options.linkRepeated, entities.count > 1000 {
            warnings.append("重复内容超过 1000 种，已识别的区域仍会遮挡；部分关联扩展需要手动检查。")
        }
        let linked = Array(entities.sorted { $0.value < $1.value }.prefix(1000))

        for (index, var line) in lines.enumerated() {
            try Task.checkCancellation()
            let string = line.candidate.string
            if options.linkRepeated {
                let ns = string as NSString
                for entity in linked {
                    var cursor = 0
                    while cursor < ns.length {
                        let range = ns.range(of: entity.value, options: entity.kind == .secret ? [] : .caseInsensitive,
                                             range: NSRange(location: cursor, length: ns.length - cursor))
                        if range.location == NSNotFound { break }
                        if !line.findings.contains(where: { $0.kind == entity.kind && $0.range == range }) {
                            line.findings.append(TextFinding(range: range, kind: entity.kind, confidence: 0.8))
                        }
                        cursor = range.location + max(1, range.length)
                    }
                }
            }
            for finding in line.findings {
                guard let range = Range(finding.range, in: string) else { continue }
                var bounds = line.bounds
                if !options.wholeLine, let found = try? line.candidate.boundingBox(for: range) { bounds = found.boundingBox }
                let padding = max(options.padding, line.bounds.height * line.tile.height * 0.16)
                let rect = canvasBox(bounds, tile: line.tile, size: size, padding: padding)
                masks.append(PrivacyMask(rect: rect, kind: finding.kind,
                                         confidence: min(1, Double(line.candidate.confidence) * finding.confidence),
                                         groupID: group(finding.kind, String(string[range]))))
            }
            if index % 40 == 0 {
                progress(0.82 + Double(index) / Double(max(1, lines.count)) * 0.15, "关联重复内容 · 构建遮挡区域")
            }
        }

        var unique: [PrivacyMask] = []
        for mask in masks where mask.rect.area > 0 {
            if redacted, mask.rect.intersection(project.edit.crop).area == 0 { continue }
            if redacted, project.edit.masks.contains(where: {
                !$0.enabled && $0.reviewed && $0.rect.intersection(mask.rect).area / max(0.0000001, mask.rect.area) > 0.65
            }) { continue }
            let duplicate = unique.contains { other in
                guard other.kind == mask.kind, other.groupID == mask.groupID || mask.kind == .face else { return false }
                let intersection = other.rect.intersection(mask.rect).area
                return intersection / max(0.0000001, other.rect.area + mask.rect.area - intersection) > 0.45
            }
            if !duplicate { unique.append(mask) }
        }
        guard unique.count <= 5000 else { throw PicSigError.storage("隐私标记过多，请缩短拼图后分别检查。") }
        progress(1, "识别完成 · \(unique.count) 处待复核")
        return ScanReport(masks: unique.sorted { $0.rect.y == $1.rect.y ? $0.rect.x < $1.rect.x : $0.rect.y < $1.rect.y }, warnings: warnings, textLines: lines.count)
    }

    private static func canvasBox(_ vision: CGRect, tile: Box, size: Size2D, padding: Double, expansion: Double = 0) -> Box {
        let rect = Box(tile.x + vision.minX * tile.width, tile.y + (1 - vision.maxY) * tile.height,
                       vision.width * tile.width, vision.height * tile.height)
        return rect.expanded(dx: padding + rect.width * expansion, dy: padding + rect.height * expansion)
            .normalized(to: size).intersection(.unit)
    }

    private static func lineBox(_ line: Line) -> Box {
        Box(line.tile.x + line.bounds.minX * line.tile.width,
            line.tile.y + (1 - line.bounds.maxY) * line.tile.height,
            line.bounds.width * line.tile.width,
            line.bounds.height * line.tile.height)
    }

    private static func protectAddressFollowers(_ lines: inout [Line], options: PrivacyOptions) {
        guard options.enabledKinds.contains(.address), lines.count > 1 else { return }
        let labels: Set<String> = [
            "地址", "住址", "家庭住址", "现住址", "收货地址", "收件地址", "寄件地址", "详细地址",
            "address", "home address", "shipping address", "delivery address"
        ]
        let ordered = lines.indices.sorted { lhs, rhs in
            let a = lineBox(lines[lhs]), b = lineBox(lines[rhs])
            if abs(a.y - b.y) < max(a.height, b.height) * 0.5 { return a.x < b.x }
            return a.y < b.y
        }

        for position in ordered.indices {
            let currentIndex = ordered[position]
            let raw = lines[currentIndex].candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = raw.trimmingCharacters(in: CharacterSet(charactersIn: ":：-— ")).lowercased()
            guard labels.contains(normalized), !lines[currentIndex].findings.contains(where: { $0.kind == .address }) else { continue }
            let current = lineBox(lines[currentIndex])

            for offset in 1...min(2, ordered.count - position - 1) {
                let nextIndex = ordered[position + offset]
                let next = lineBox(lines[nextIndex])
                let verticalGap = next.y - current.maxY
                if verticalGap < -current.height * 0.4 { continue }
                if verticalGap > max(96, current.height * 3.2) { break }
                let value = lines[nextIndex].candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard value.count >= 4, value.count <= 160 else { continue }
                let full = NSRange(value.startIndex..<value.endIndex, in: value)
                lines[nextIndex].findings.append(TextFinding(range: full, kind: .address, confidence: 0.84))
                break
            }
        }
    }

    static func looksLikeResidentialAddress(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6, trimmed.count <= 180 else { return false }
        let lower = trimmed.lowercased()
        let hasDigit = trimmed.contains(where: \.isNumber)

        let addressLabels = ["收货地址", "收件地址", "寄件地址", "详细地址", "家庭住址", "现住址", "住址", "地址", "shipping address", "home address", "delivery address", "address"]
        if addressLabels.contains(where: { lower.contains($0.lowercased()) }) && trimmed.count >= 8 { return true }

        if hasDigit {
            let adminMarkers = ["省", "自治区", "市", "区", "县", "旗", "街道", "镇", "乡"]
            let streetMarkers = ["路", "街", "巷", "弄", "胡同", "大道", "大街", "小区", "社区", "花园", "公寓", "家园", "新村"]
            let detailMarkers = ["号", "栋", "幢", "座", "单元", "室", "楼", "层", "户"]
            let adminCount = adminMarkers.reduce(0) { $0 + (trimmed.contains($1) ? 1 : 0) }
            if adminCount >= 2 && streetMarkers.contains(where: trimmed.contains) { return true }
            if streetMarkers.contains(where: trimmed.contains) && detailMarkers.contains(where: trimmed.contains) { return true }

            let latinStreetSuffixes = [" street", " st ", " road", " rd ", " avenue", " ave ", " boulevard", " blvd", " lane", " ln ", " drive", " dr ", " court", " ct ", " place", " pl ", " highway", " hwy", " way"]
            if trimmed.first?.isNumber == true && latinStreetSuffixes.contains(where: { lower.contains($0) }) { return true }

            let japanRegion = ["東京都", "北海道", "府", "県"].contains(where: trimmed.contains)
            let japanDetail = ["丁目", "番", "号"].contains(where: trimmed.contains)
            if japanRegion && japanDetail && ["市", "区", "町", "村"].contains(where: trimmed.contains) { return true }
        }
        return false
    }

    private static func linguisticFindings(_ text: String, options: PrivacyOptions) -> [TextFinding] {
        var findings: [TextFinding] = []
        if options.enabledKinds.contains(.address), let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue) {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) {
                findings.append(TextFinding(range: match.range, kind: .address, confidence: 0.78))
            }
        }
        if options.enabledKinds.contains(.name) {
            let tagger = NLTagger(tagSchemes: [.nameType]); tagger.string = text
            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                                 options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
                if tag == .personalName { findings.append(TextFinding(range: NSRange(range, in: text), kind: .name, confidence: 0.65)) }
                return true
            }
        }
        return findings
    }
}
