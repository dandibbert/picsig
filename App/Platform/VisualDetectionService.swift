import Vision
import CoreGraphics
import PicSigCore

/// Finds private information that is not text: faces, avatars, QR codes and
/// barcodes. Picsew leaves all of these to the user; a screenshot of a chat is
/// rarely safe to share with the avatars intact.
struct VisualDetectionService {
    struct Options: Sendable {
        var detectsFaces: Bool
        var detectsBarcodes: Bool
        /// Tallest slice handed to Vision in one pass. Detection runs at full
        /// resolution on purpose — downscaling a long screenshot is what makes a
        /// small avatar or QR code fall below Vision's detection threshold — so the
        /// image is split instead, bounding the cost of any single pass.
        var maxAnalysisTileHeight: Int
        var minimumFaceConfidence: Float

        init(detectsFaces: Bool = true,
             detectsBarcodes: Bool = true,
             maxAnalysisTileHeight: Int = 4000,
             minimumFaceConfidence: Float = 0.4) {
            self.detectsFaces = detectsFaces
            self.detectsBarcodes = detectsBarcodes
            self.maxAnalysisTileHeight = maxAnalysisTileHeight
            self.minimumFaceConfidence = minimumFaceConfidence
        }

        static let `default` = Options()
    }

    var options: Options = .default

    func detect(cgImage: CGImage, enabledCategories: Set<SensitiveCategory>) -> [SensitiveMatch] {
        let wantsFaces = options.detectsFaces && enabledCategories.contains(.face)
        let wantsBarcodes = options.detectsBarcodes && enabledCategories.contains(.barcode)
        guard wantsFaces || wantsBarcodes else { return [] }

        var matches = [SensitiveMatch]()
        let tiles = analysisTiles(for: cgImage.pixelSize)

        for tile in tiles {
            guard let cropped = cgImage.cropping(to: tile.cgRect) else { continue }
            var requests = [VNRequest]()
            let faceRequest = VNDetectFaceRectanglesRequest()
            let barcodeRequest = VNDetectBarcodesRequest()
            if wantsFaces { requests.append(faceRequest) }
            if wantsBarcodes { requests.append(barcodeRequest) }

            let handler = VNImageRequestHandler(cgImage: cropped, options: [:])
            do {
                try handler.perform(requests)
            } catch {
                continue
            }

            for face in faceRequest.results ?? [] where face.confidence >= options.minimumFaceConfidence {
                // Faces are grown generously: hair and chin identify a person too.
                let detected = absoluteRect(face.boundingBox, tile: tile, imageSize: cgImage.pixelSize)
                let box = detected.expanded(byX: detected.width * 0.08, byY: detected.height * 0.16)
                matches.append(SensitiveMatch(category: .face,
                                              ruleID: "vision.face",
                                              lineID: nil,
                                              value: "face",
                                              characterRange: 0..<0,
                                              box: box,
                                              confidence: Double(face.confidence),
                                              contextLabel: nil))
            }

            for barcode in barcodeRequest.results ?? [] {
                let box = absoluteRect(barcode.boundingBox, tile: tile, imageSize: cgImage.pixelSize)
                matches.append(SensitiveMatch(category: .barcode,
                                              ruleID: "vision.barcode." + (barcode.symbology.rawValue),
                                              lineID: nil,
                                              value: barcode.payloadStringValue ?? "barcode",
                                              characterRange: 0..<0,
                                              box: box,
                                              confidence: Double(barcode.confidence),
                                              contextLabel: nil))
            }
        }

        return deduplicate(matches)
    }

    /// Barcodes and faces are searched tile by tile, like the text pass: a small QR
    /// code in a very long screenshot is below Vision's detection threshold once the
    /// whole image is scaled to fit. Tiles overlap so a face on a tile boundary is
    /// still whole in one of them.
    private func analysisTiles(for size: PixelSize) -> [PixelRect] {
        guard size.height > options.maxAnalysisTileHeight else {
            return [PixelRect(x: 0, y: 0, width: size.width, height: size.height)]
        }
        var result = [PixelRect]()
        var top = 0
        let overlap = 200
        while top < size.height {
            let height = min(options.maxAnalysisTileHeight, size.height - top)
            result.append(PixelRect(x: 0, y: top, width: size.width, height: height))
            if top + height >= size.height { break }
            top += max(1, options.maxAnalysisTileHeight - overlap)
        }
        return result
    }

    private func absoluteRect(_ rect: CGRect, tile: PixelRect, imageSize: PixelSize) -> NormalizedRect {
        let inTile = NormalizedRect.fromBottomLeftOrigin(x: Double(rect.origin.x),
                                                        y: Double(rect.origin.y),
                                                        width: Double(rect.size.width),
                                                        height: Double(rect.size.height))
        let pixelX = Double(tile.x) + inTile.x * Double(tile.width)
        let pixelY = Double(tile.y) + inTile.y * Double(tile.height)
        return NormalizedRect(x: pixelX / Double(imageSize.width),
                              y: pixelY / Double(imageSize.height),
                              width: inTile.width * Double(tile.width) / Double(imageSize.width),
                              height: inTile.height * Double(tile.height) / Double(imageSize.height))
            .clampedToUnitSpace()
    }

    private func deduplicate(_ matches: [SensitiveMatch]) -> [SensitiveMatch] {
        var result = [SensitiveMatch]()
        for match in matches {
            let duplicate = result.contains { $0.category == match.category && $0.box.iou(match.box) > 0.5 }
            if !duplicate { result.append(match) }
        }
        return result
    }
}
