import Vision
import CoreGraphics
import PicSigCore

/// Wraps Vision text recognition and produces a `TextLayout` in top-left
/// normalised coordinates.
///
/// The tiling is the important part: a 1200 × 20000 long screenshot handed to
/// Vision in one piece comes back with badly recognised or entirely missed text,
/// because the request downsamples its input. Recognising 2000 pixel tall tiles
/// with an overlap and merging the results keeps small print readable — and small
/// print is exactly where phone numbers live.
struct TextRecognitionService {
    struct Options: Sendable {
        var recognitionLanguages: [String]
        var tileHeight: Int
        var tileOverlap: Int
        /// Character level boxes allow masking a substring instead of a whole
        /// line. Costs one extra Vision call per character.
        var computesCharacterBoxes: Bool
        /// Language correction "fixes" digits and would corrupt the very values we
        /// are looking for.
        var usesLanguageCorrection: Bool
        var minimumTextHeight: Float

        init(recognitionLanguages: [String] = ["zh-Hans", "en-US"],
             tileHeight: Int = 2200,
             tileOverlap: Int = 160,
             computesCharacterBoxes: Bool = true,
             usesLanguageCorrection: Bool = false,
             minimumTextHeight: Float = 0) {
            self.recognitionLanguages = recognitionLanguages
            self.tileHeight = max(400, tileHeight)
            self.tileOverlap = max(0, tileOverlap)
            self.computesCharacterBoxes = computesCharacterBoxes
            self.usesLanguageCorrection = usesLanguageCorrection
            self.minimumTextHeight = minimumTextHeight
        }

        static let `default` = Options()
    }

    var options: Options = .default

    func recognize(cgImage: CGImage) throws -> TextLayout {
        let imageSize = cgImage.pixelSize
        guard !imageSize.isEmpty else { return .empty }

        var lines = [RecognizedTextLine]()
        var nextID = 0

        for tile in tiles(for: imageSize) {
            guard let cropped = cgImage.cropping(to: tile.cgRect) else { continue }
            let observations = try perform(on: cropped)
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string
                guard !text.isEmpty else { continue }

                let box = absoluteRect(observation.boundingBox, tile: tile, imageSize: imageSize)
                let characterBoxes = options.computesCharacterBoxes
                    ? self.characterBoxes(for: candidate, tile: tile, imageSize: imageSize)
                    : nil

                // The overlap between tiles reports some rows twice.
                let isDuplicate = lines.contains { existing in
                    existing.text == text && existing.box.iou(box) > 0.4
                }
                guard !isDuplicate else { continue }

                lines.append(RecognizedTextLine(id: nextID,
                                                text: text,
                                                box: box,
                                                confidence: Double(candidate.confidence),
                                                characterBoxes: characterBoxes))
                nextID += 1
            }
        }

        lines.sort { lhs, rhs in
            abs(lhs.box.minY - rhs.box.minY) < 0.0005
                ? lhs.box.minX < rhs.box.minX
                : lhs.box.minY < rhs.box.minY
        }
        // Ids must stay in reading order for the "line above / line left of"
        // context lookups to be meaningful in debugging.
        let ordered = lines.enumerated().map { index, line in
            RecognizedTextLine(id: index,
                               text: line.text,
                               box: line.box,
                               confidence: line.confidence,
                               characterBoxes: line.characterBoxes)
        }
        return TextLayout(lines: ordered, imageSize: imageSize)
    }

    // MARK: - Internals

    private func perform(on image: CGImage) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = options.recognitionLanguages
        request.usesLanguageCorrection = options.usesLanguageCorrection
        request.minimumTextHeight = options.minimumTextHeight
        if #available(iOS 16.0, *) {
            request.automaticallyDetectsLanguage = false
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return request.results ?? []
    }

    func tiles(for imageSize: PixelSize) -> [PixelRect] {
        guard imageSize.height > options.tileHeight else {
            return [PixelRect(x: 0, y: 0, width: imageSize.width, height: imageSize.height)]
        }
        var result = [PixelRect]()
        var top = 0
        while top < imageSize.height {
            let height = min(options.tileHeight, imageSize.height - top)
            result.append(PixelRect(x: 0, y: top, width: imageSize.width, height: height))
            if top + height >= imageSize.height { break }
            top += max(1, options.tileHeight - options.tileOverlap)
        }
        return result
    }

    /// Vision reports normalised, bottom-left origin rects relative to the tile.
    private func absoluteRect(_ rect: CGRect, tile: PixelRect, imageSize: PixelSize) -> NormalizedRect {
        let inTile = NormalizedRect.fromBottomLeftOrigin(x: Double(rect.origin.x),
                                                        y: Double(rect.origin.y),
                                                        width: Double(rect.size.width),
                                                        height: Double(rect.size.height))
        let pixelX = Double(tile.x) + inTile.x * Double(tile.width)
        let pixelY = Double(tile.y) + inTile.y * Double(tile.height)
        let pixelWidth = inTile.width * Double(tile.width)
        let pixelHeight = inTile.height * Double(tile.height)
        return NormalizedRect(x: pixelX / Double(imageSize.width),
                              y: pixelY / Double(imageSize.height),
                              width: pixelWidth / Double(imageSize.width),
                              height: pixelHeight / Double(imageSize.height))
            .clampedToUnitSpace()
    }

    private func characterBoxes(for candidate: VNRecognizedText,
                                tile: PixelRect,
                                imageSize: PixelSize) -> [NormalizedRect]? {
        let text = candidate.string
        var boxes = [NormalizedRect]()
        boxes.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            guard let observation = try? candidate.boundingBox(for: index..<next) else { return nil }
            boxes.append(absoluteRect(observation.boundingBox, tile: tile, imageSize: imageSize))
            index = next
        }
        return boxes.count == text.count ? boxes : nil
    }
}
