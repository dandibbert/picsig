import UIKit
import Photos
import ImageIO
import UniformTypeIdentifiers
import PicSigCore

enum ExportError: LocalizedError {
    case noImage
    case encodingFailed
    case photoLibraryDenied

    var errorDescription: String? {
        switch self {
        case .noImage: return NSLocalizedString("export.error.noImage", comment: "")
        case .encodingFailed: return NSLocalizedString("export.error.encoding", comment: "")
        case .photoLibraryDenied: return NSLocalizedString("export.error.photoDenied", comment: "")
        }
    }
}

/// Encoding, page splitting, saving and PDF export.
enum ImageExporter {
    struct Output {
        var pages: [UIImage]
        var files: [URL]
        var pdf: URL?
    }

    /// Splits a long image into pages, cutting at the quietest rows.
    static func pages(of image: UIImage, options: ExportOptions) -> [UIImage] {
        guard options.splitsIntoPages, let cgImage = image.cgImage else { return [image] }
        let size = cgImage.pixelSize
        let activity = cgImage.grayImage(maxWidth: 320)?.rowActivityProfile(stride: 2)
        // The activity profile was measured on a downscaled copy; map it back.
        let scaledActivity: [Double]? = activity.map { profile in
            guard profile.count != size.height, !profile.isEmpty else { return profile }
            return (0..<size.height).map { row in
                profile[min(profile.count - 1, row * profile.count / max(1, size.height))]
            }
        }

        let splitterOptions = PageSplitter.Options(pageHeight: options.pageHeight,
                                                  overlap: options.pageOverlap)
        let ranges = PageSplitter.pages(imageHeight: size.height,
                                        activity: scaledActivity,
                                        options: splitterOptions)
        guard ranges.count > 1 else { return [image] }

        return ranges.compactMap { range in
            let rect = PixelRect(x: 0, y: range.lowerBound, width: size.width, height: range.count)
            guard let cropped = cgImage.cropping(to: rect.cgRect) else { return nil }
            return UIImage(cgImage: cropped)
        }
    }

    static func encode(_ image: UIImage, options: ExportOptions) throws -> Data {
        guard let cgImage = image.cgImage else { throw ExportError.noImage }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData,
                                                                options.format.utType as CFString,
                                                                1,
                                                                nil) else {
            throw ExportError.encodingFailed
        }
        var properties: [CFString: Any] = [:]
        if options.format.supportsQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = options.quality
        }

        if options.stripsMetadata {
            // Everything here is freshly rasterised, so there is no EXIF to begin
            // with — but writing an explicitly empty metadata block also drops the
            // orientation and creation date that ImageIO would add on its own.
            let metadata = CGImageMetadataCreateMutable()
            CGImageDestinationAddImageAndMetadata(destination, cgImage, metadata, properties as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else { throw ExportError.encodingFailed }
        return data as Data
    }

    /// Writes the pages (and optionally a PDF) into a temporary directory, ready
    /// for the share sheet.
    static func write(_ image: UIImage, options: ExportOptions, baseName: String) throws -> Output {
        let scaled = scaledImage(image, options: options)
        let pageImages = pages(of: scaled, options: options)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicSigExport-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var files = [URL]()
        for (index, page) in pageImages.enumerated() {
            let data = try encode(page, options: options)
            let suffix = pageImages.count > 1 ? "-\(index + 1)" : ""
            let url = directory.appendingPathComponent("\(baseName)\(suffix).\(options.format.fileExtension)")
            try data.write(to: url, options: .atomic)
            files.append(url)
        }

        var pdfURL: URL?
        if options.includesPDF {
            let url = directory.appendingPathComponent("\(baseName).pdf")
            try writePDF(pages: pageImages, to: url)
            pdfURL = url
        }
        return Output(pages: pageImages, files: files, pdf: pdfURL)
    }

    static func scaledImage(_ image: UIImage, options: ExportOptions) -> UIImage {
        let current = PixelSize(width: Int(image.size.width), height: Int(image.size.height))
        let target = options.scale.targetSize(for: current)
        return target == current ? image : image.resized(to: target)
    }

    static func writePDF(pages: [UIImage], to url: URL) throws {
        guard let first = pages.first else { throw ExportError.noImage }
        let format = UIGraphicsPDFRendererFormat()
        let bounds = CGRect(origin: .zero, size: first.size)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)
        try renderer.writePDF(to: url) { context in
            for page in pages {
                context.beginPage(withBounds: CGRect(origin: .zero, size: page.size), pageInfo: [:])
                page.draw(in: CGRect(origin: .zero, size: page.size))
            }
        }
    }

    static func saveToPhotoLibrary(_ images: [UIImage], options: ExportOptions) async throws {
        let status = await requestAddAuthorization()
        guard status == .authorized || status == .limited else { throw ExportError.photoLibraryDenied }

        for image in images {
            let data = try encode(image, options: options)
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let resourceOptions = PHAssetResourceCreationOptions()
                resourceOptions.originalFilename = "PicSig-\(Int(Date().timeIntervalSince1970)).\(options.format.fileExtension)"
                request.addResource(with: .photo, data: data, options: resourceOptions)
            }
        }
    }

    private static func requestAddAuthorization() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }
}
