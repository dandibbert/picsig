import Foundation
import UIKit
import AVFoundation
import Photos

typealias WorkProgress = @Sendable (Double, String) -> Void
struct VideoOptions: Sendable {
    var start: Double = 0
    var end: Double = 30
    var interval: Double = 0.5
    var reverse: Bool = false
}
struct StitchReport: Sendable { var project: Project; var duplicates: Int; var uncertain: Int }
struct ExportResult: Identifiable { var id = UUID(); var urls: [URL]; var preview: UIImage; var size: Size2D }

/// All image decoding, Vision work and filesystem mutations are serialized off the main actor.
actor MediaWorker {
    static let shared = MediaWorker()
    func list() throws -> ProjectListing { try ProjectStore.list() }
    func save(_ project: Project) throws { try ProjectStore.save(project) }
    func delete(_ id: UUID) throws { try ProjectStore.delete(id) }
    func clearImports() throws { try ProjectStore.clearImports() }
    func loadPrivacy() -> PrivacyOptions { ProjectStore.loadPrivacy() }
    func savePrivacy(_ options: PrivacyOptions) throws { try ProjectStore.savePrivacy(options) }
    func cleanExports(all: Bool = false) throws { if all { try ProjectStore.clearExports() } else { try ProjectStore.cleanExports() } }
    func preview(_ project: Project, edits: Bool = false, final: Bool = false) throws -> UIImage {
        try Renderer.preview(project, edits: edits, finalGeometry: final)
    }
    func thumbnail(_ source: SourceImage, project: UUID) throws -> UIImage { UIImage(cgImage: try ProjectStore.image(source, project: project, maximum: 320)) }
    func detail(_ project: Project, region: Box) throws -> UIImage {
        let size = try Composition.build(project).size
        let pixels = region.intersection(.unit).scaled(to: size)
        return try Renderer.render(project, region: pixels, scale: min(1, sqrt(4_000_000 / max(1, pixels.area))), edits: false, finalGeometry: false)
    }
    func importImages(_ urls: [URL], into original: Project, progress: WorkProgress) throws -> (Project, Int) {
        defer { ProjectStore.discardImports(urls) }
        guard original.images.count + urls.count <= 60 else { throw PicSigError.storage("图片项目最多支持 60 张，请分批拼接。") }
        var project = original, failed = 0, committed = false
        defer {
            if !committed { ProjectStore.discardSources(Array(project.images.dropFirst(original.images.count)), project: original.id) }
        }
        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do { try autoreleasepool { project.images.append(try ProjectStore.importImage(url, project: project.id)) } }
            catch { failed += 1 }
            progress(Double(index + 1) / Double(max(1, urls.count)), "导入图片 \(index + 1) / \(urls.count)")
        }
        guard project.images.count > original.images.count else { throw PicSigError.invalidImage }
        if original.images.isEmpty {
            let largest = project.images.map { project.kind == .horizontal ? $0.size.height : $0.size.width }.max() ?? 1440
            project.layout.breadth = min(2160, max(128, largest))
        }
        project.updatedAt = Date(); project.edit = EditState()
        try Task.checkCancellation(); try ProjectStore.save(project); committed = true
        return (project, failed)
    }
    func rotate(_ sourceID: UUID, in original: Project) throws -> Project {
        var project = original
        guard let index = project.images.firstIndex(where: { $0.id == sourceID }) else { return project }
        let source = try ProjectStore.image(project.images[index], project: project.id)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: source.height, height: source.width), format: format).image { output in
            output.cgContext.translateBy(x: CGFloat(source.height), y: 0); output.cgContext.rotate(by: .pi / 2)
            UIImage(cgImage: source).draw(in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        }
        guard let result = image.cgImage else { throw PicSigError.invalidImage }
        project.images[index] = try ProjectStore.addImage(result, project: project.id)
        for i in project.images.indices { project.images[i].leadingCut = 0; project.images[i].automaticCrop = nil; project.images[i].matchConfidence = nil }
        project.edit = EditState(); project.updatedAt = Date()
        try ProjectStore.save(project)
        return project
    }
    static func raster(_ image: CGImage, crop: Box = .unit, yScale: Double = 1) throws -> GrayRaster {
        let rect = crop.intersection(.unit).scaled(to: Size2D(Double(image.width), Double(image.height)))
        guard let cropped = image.cropping(to: rect.cgRect.integral) else { throw PicSigError.invalidImage }
        let width = 64, height = min(8192, max(8, Int(Double(cropped.height) * yScale)))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let success = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { throw PicSigError.invalidImage }
        return try GrayRaster(width: width, height: height, pixels: pixels)
    }
    func stitch(_ original: Project, trimBars: Bool, progress: WorkProgress) throws -> StitchReport {
        guard original.kind.isScroll, original.images.count > 1 else { return StitchReport(project: original, duplicates: 0, uncertain: 0) }
        var project = original
        let maxHeight = project.images.map { $0.crop.height * $0.size.height }.max() ?? 1
        let yScale = min(1, 4096 / maxHeight)
        var images: [SourceImage] = [], rasters: [GrayRaster] = [], duplicates = 0
        for (index, var source) in project.images.enumerated() {
            try Task.checkCancellation()
            source.leadingCut = 0; source.automaticCrop = nil; source.matchConfidence = nil
            let raster = try autoreleasepool { try Self.raster(ProjectStore.image(source, project: project.id), crop: source.crop, yScale: yScale) }
            if let previous = rasters.last, OverlapDetector.difference(previous, raster) < 1.1 { duplicates += 1 }
            else { images.append(source); rasters.append(raster) }
            progress(Double(index + 1) / Double(project.images.count) * 0.3, "分析图片轮廓")
        }
        var top = 0, bottom = 0
        if trimBars, rasters.count > 1 {
            let values = (1..<min(rasters.count, 5)).map { OverlapDetector.fixedInsets(rasters[$0 - 1], rasters[$0]) }
            top = values.map(\.top).min() ?? 0; bottom = values.map(\.bottom).min() ?? 0
        }
        var accepted: [SourceImage] = [], content: [GrayRaster] = [], cuts: [Int] = [], uncertain = 0
        for (index, var source) in images.enumerated() {
            try Task.checkCancellation()
            let raster = try rasters[index].removing(top: top, bottom: bottom)
            var cut = 0
            if let previous = content.last, let last = accepted.last {
                let widthRatio = source.crop.width * source.size.width / (last.crop.width * last.size.width)
                let match = abs(widthRatio - 1) < 0.025 ? OverlapDetector.match(previous, raster) : nil
                if let match = match {
                    if match.duplicate { duplicates += 1; continue }
                    cut = match.rows; source.matchConfidence = match.confidence
                } else { source.matchConfidence = 0; uncertain += 1 }
            }
            accepted.append(source); content.append(raster); cuts.append(cut)
            progress(0.3 + Double(index + 1) / Double(images.count) * 0.7, "匹配拼接缝 \(index + 1) / \(images.count)")
        }
        for index in accepted.indices {
            let originalCrop = accepted[index].crop.scaled(to: accepted[index].size)
            let topPixels = index == 0 ? 0 : Double(top) / yScale
            let bottomPixels = index == accepted.count - 1 ? 0 : Double(bottom) / yScale
            let rect = Box(originalCrop.x, originalCrop.y + topPixels, originalCrop.width, originalCrop.height - topPixels - bottomPixels)
            accepted[index].automaticCrop = rect.normalized(to: accepted[index].size)
            accepted[index].leadingCut = Double(cuts[index]) / yScale / max(1, rect.height)
        }
        project.images = accepted; project.edit = EditState(); project.updatedAt = Date()
        _ = try Composition.build(project); try Task.checkCancellation(); try ProjectStore.save(project)
        return StitchReport(project: project, duplicates: duplicates, uncertain: uncertain)
    }
    func videoDuration(_ url: URL) async throws -> Double {
        let accessing = url.startAccessingSecurityScopedResource(); defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw PicSigError.unsupportedVideo }
        return duration
    }
    func extractVideo(_ url: URL, options: VideoOptions, into original: Project, progress: WorkProgress) async throws -> Project {
        defer { ProjectStore.discardImports([url]) }
        guard options.start.isFinite, options.end.isFinite, options.interval.isFinite,
              options.start >= 0, options.end > options.start, options.end - options.start <= 120.1,
              options.interval >= 0.25, options.interval <= 2 else { throw PicSigError.unsupportedVideo }
        let accessing = url.startAccessingSecurityScopedResource(); defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, options.start < duration else { throw PicSigError.unsupportedVideo }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 2160, height: 3840)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.04, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.04, preferredTimescale: 600)
        defer { generator.cancelAllCGImageGeneration() }
        let end = min(options.end, max(options.start, duration - 0.02))
        var times = Array(stride(from: options.start, through: end, by: options.interval))
        if let last = times.last, end - last > 0.08 { times.append(end) }
        if options.reverse { times.reverse() }
        var project = original, previous: GrayRaster?, frameFailures = 0, committed = false
        defer {
            if !committed { ProjectStore.discardSources(project.images, project: project.id) }
        }
        project.images = []
        for (index, time) in times.enumerated() {
            try Task.checkCancellation()
            do {
                let result = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
                try autoreleasepool {
                    let raster = try Self.raster(result.image, yScale: min(1, 1800 / Double(result.image.height)))
                    if let previous = previous {
                        if OverlapDetector.difference(previous, raster) < 2.5 { return }
                        if let match = OverlapDetector.match(previous, raster), !match.duplicate,
                           Double(match.rows) / Double(raster.height) > 0.90, index != times.count - 1 { return }
                    }
                    guard project.images.count < 120 else { throw PicSigError.storage("有效画面超过 120 张，请缩短录屏范围后重试，避免遗漏后半段内容。") }
                    var source = try ProjectStore.addImage(result.image, project: project.id)
                    source.timestamp = result.actualTime.seconds
                    project.images.append(source); previous = raster
                }
            } catch let error as PicSigError { throw error }
            catch is CancellationError { throw CancellationError() }
            catch { frameFailures += 1 }
            progress(Double(index + 1) / Double(max(1, times.count)), "提取画面 \(index + 1) / \(times.count) · 已保留 \(project.images.count) 张")
        }
        guard !project.images.isEmpty else { throw PicSigError.unsupportedVideo }
        // A failed frame is not silently accepted: the user can retry a shorter or different range.
        guard frameFailures == 0 else { throw PicSigError.storage("有 \(frameFailures) 个采样画面无法解码，未覆盖原项目。请更换录屏或缩短范围重试。") }
        project.layout.breadth = min(2160, project.images.first?.size.width ?? 1440)
        project.edit = EditState(); project.updatedAt = Date()
        try Task.checkCancellation(); try ProjectStore.save(project); committed = true
        return project
    }
    func scan(_ project: Project, redacted: Bool = false, progress: WorkProgress) throws -> ScanReport { try PrivacyScanner.scan(project, redacted: redacted, progress: progress) }
    func export(_ project: Project, sliced: Bool, jpeg: Bool, progress: WorkProgress) throws -> ExportResult {
        let canvas = try Composition.build(project).size
        let geometry = try ExportGeometry(canvas: canvas, crop: project.edit.crop, turns: project.edit.quarterTurns)
        guard sliced || (geometry.size.area <= 32_000_000 && max(geometry.size.width, geometry.size.height) <= 32760) else { throw PicSigError.tooLarge }
        let folder = ProjectStore.exportRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try ProjectStore.prepare(folder)
        var completed = false; defer { if !completed { try? FileManager.default.removeItem(at: folder) } }
        let regions = sliced ? geometry.slices() : [Box(0, 0, geometry.size.width, geometry.size.height)]
        var urls: [URL] = []
        for (index, region) in regions.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let image = try Renderer.render(project, region: region).cgImage else { throw PicSigError.invalidImage }
                let name = String(format: "PicSig-%03d.%@", index + 1, jpeg ? "jpg" : "png")
                let url = folder.appendingPathComponent(name)
                try ProjectStore.writeImage(image, to: url, jpeg: jpeg); urls.append(url)
            }
            progress(Double(index + 1) / Double(regions.count), "安全导出 \(index + 1) / \(regions.count)")
        }
        let preview = try Renderer.preview(project, edits: true, finalGeometry: true)
        completed = true
        return ExportResult(urls: urls, preview: preview, size: geometry.size)
    }
    func saveToPhotos(_ urls: [URL]) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw PicSigError.storage("未获得保存相册权限。可在系统设置中允许添加照片，或使用分享按钮存入「文件」。") }
        try await PHPhotoLibrary.shared().performChanges {
            for url in urls { PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url) }
        }
    }
}
