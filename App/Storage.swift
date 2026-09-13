import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers

extension Box {
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    init(_ rect: CGRect) { self.init(rect.minX, rect.minY, rect.width, rect.height) }
}
extension Size2D { var cgSize: CGSize { CGSize(width: width, height: height) } }
extension Point2D { var cgPoint: CGPoint { CGPoint(x: x, y: y) } }

struct ProjectListing: Sendable { var projects: [Project]; var unreadableCount: Int }

enum ProjectStore {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PicSig", isDirectory: true)
    }
    static var projectsRoot: URL { root.appendingPathComponent("Projects", isDirectory: true) }
    static func directory(_ id: UUID) -> URL { projectsRoot.appendingPathComponent(id.uuidString, isDirectory: true) }
    static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.protectionKey: FileProtectionType.complete])
        var url = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    static func sourceURL(_ image: SourceImage, in project: UUID) throws -> URL {
        guard image.file == (image.file as NSString).lastPathComponent, !image.file.isEmpty, !image.file.hasPrefix(".") else {
            throw PicSigError.invalidImage
        }
        return directory(project).appendingPathComponent("Sources", isDirectory: true).appendingPathComponent(image.file)
    }
    static func save(_ project: Project) throws {
        let directory = directory(project.id); try prepare(directory)
        let manifest = directory.appendingPathComponent("project.json")
        if let data = try? Data(contentsOf: manifest), let current = try? JSONDecoder().decode(Project.self, from: data), current.updatedAt > project.updatedAt { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(project).write(to: directory.appendingPathComponent("project.json"), options: [.atomic, .completeFileProtection])
    }
    static func list() throws -> ProjectListing {
        try prepare(projectsRoot)
        let directories = try FileManager.default.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var result: [Project] = [], unreadable = 0
        for folder in directories {
            guard UUID(uuidString: folder.lastPathComponent) != nil else { continue }
            let manifest = folder.appendingPathComponent("project.json")
            guard FileManager.default.fileExists(atPath: manifest.path) else { continue }
            do {
                let project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: manifest))
                guard project.schemaVersion == 1, project.id.uuidString == folder.lastPathComponent else { unreadable += 1; continue }
                result.append(project)
            } catch { unreadable += 1 }
        }
        return ProjectListing(projects: result.sorted { $0.updatedAt > $1.updatedAt }, unreadableCount: unreadable)
    }
    static func delete(_ id: UUID) throws { try FileManager.default.removeItem(at: directory(id)) }
    static func loadPrivacy() -> PrivacyOptions {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("privacy.json")),
              let options = try? JSONDecoder().decode(PrivacyOptions.self, from: data) else { return PrivacyOptions() }
        return options
    }
    static func savePrivacy(_ options: PrivacyOptions) throws {
        try prepare(root)
        try JSONEncoder().encode(options).write(to: root.appendingPathComponent("privacy.json"), options: [.atomic, .completeFileProtection])
    }
    static func image(_ source: SourceImage, project: UUID, maximum: Int? = nil) throws -> CGImage {
        let url = try sourceURL(source, in: project)
        guard let raw = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw PicSigError.invalidImage }
        if let maximum = maximum {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                           kCGImageSourceCreateThumbnailWithTransform: true,
                                           kCGImageSourceThumbnailMaxPixelSize: maximum,
                                           kCGImageSourceShouldCacheImmediately: true]
            guard let image = CGImageSourceCreateThumbnailAtIndex(raw, 0, options as CFDictionary) else { throw PicSigError.invalidImage }
            return image
        }
        guard let image = CGImageSourceCreateImageAtIndex(raw, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw PicSigError.invalidImage }
        return image
    }
    /// Decode orientation once; keep originals out of export and never copy EXIF/GPS properties.
    static func importImage(_ url: URL, project: UUID) throws -> SourceImage {
        guard let raw = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(raw, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0, width.isFinite, height.isFinite else { throw PicSigError.invalidImage }
        let ratio = min(1, 32768 / max(width, height), sqrt(36_000_000 / (width * height)))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: max(1, Int(max(width, height) * ratio)),
                                      kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(raw, 0, options as CFDictionary) else { throw PicSigError.invalidImage }
        return try addImage(image, project: project)
    }
    static func addImage(_ image: CGImage, project: UUID) throws -> SourceImage {
        let source = SourceImage(file: "\(UUID().uuidString).png", size: Size2D(Double(image.width), Double(image.height)))
        let url = try sourceURL(source, in: project)
        try prepare(url.deletingLastPathComponent())
        try writeImage(image, to: url)
        return source
    }
    static func writeImage(_ image: CGImage, to url: URL, jpeg: Bool = false) throws {
        guard let writer = CGImageDestinationCreateWithURL(url as CFURL, (jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil) else {
            throw PicSigError.storage("无法创建图片文件，请检查存储空间。")
        }
        // Do NOT use CGImageDestinationAddImageFromSource: that would preserve source metadata.
        let properties: [CFString: Any] = jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.94] : [:]
        CGImageDestinationAddImage(writer, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw PicSigError.storage("图片写入失败，请检查存储空间后重试。") }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    }
    static var importsRoot: URL { root.appendingPathComponent("Imports", isDirectory: true) }
    static func discardImports(_ urls: [URL]) {
        let prefix = importsRoot.standardizedFileURL.path + "/"
        for url in urls where url.standardizedFileURL.path.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }
    static func clearImports() throws {
        if FileManager.default.fileExists(atPath: importsRoot.path) { try FileManager.default.removeItem(at: importsRoot) }
    }
    static func discardSources(_ images: [SourceImage], project: UUID) {
        for source in images { if let url = try? sourceURL(source, in: project) { try? FileManager.default.removeItem(at: url) } }
    }
    static var exportRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("PicSigExports", isDirectory: true)
    }
    static func cleanExports() throws {
        try prepare(exportRoot)
        for url in try FileManager.default.contentsOfDirectory(at: exportRoot, includingPropertiesForKeys: [.creationDateKey]) {
            let date = try url.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
            if date < Date().addingTimeInterval(-24 * 3600) { try FileManager.default.removeItem(at: url) }
        }
    }
    static func clearExports() throws {
        if FileManager.default.fileExists(atPath: exportRoot.path) { try FileManager.default.removeItem(at: exportRoot) }
        try prepare(exportRoot)
    }
}
