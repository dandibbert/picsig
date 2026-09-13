import Foundation

/// One line of recognised text together with its position in the image.
public struct RecognizedTextLine: Identifiable, Equatable, Sendable {
    public let id: Int
    public let text: String
    /// Bounding box of the whole line, unit space, top-left origin.
    public let box: NormalizedRect
    public let confidence: Double
    /// Per character boxes. Vision can provide these, and using them is what
    /// allows masking only the sensitive part of a line.
    public let characterBoxes: [NormalizedRect]?

    public init(id: Int,
                text: String,
                box: NormalizedRect,
                confidence: Double = 1,
                characterBoxes: [NormalizedRect]? = nil) {
        self.id = id
        self.text = text
        self.box = box
        self.confidence = confidence
        self.characterBoxes = characterBoxes
    }

    public var characters: [Character] { Array(text) }

    /// Box covering `range` (indices into `characters`).
    ///
    /// When the recognizer supplied character boxes they are simply unioned.
    /// Otherwise the box is interpolated from the line box, weighting full width
    /// characters (CJK, full width punctuation) twice as wide as latin ones —
    /// without that weighting, masking a phone number inside a Chinese sentence
    /// lands visibly off to the side.
    public func box(forCharacterRange range: Range<Int>) -> NormalizedRect {
        let characters = self.characters
        guard !characters.isEmpty else { return box }
        let lower = max(0, min(range.lowerBound, characters.count))
        let upper = max(lower, min(range.upperBound, characters.count))
        guard upper > lower else { return NormalizedRect(x: box.x, y: box.y, width: 0, height: box.height) }

        if let boxes = characterBoxes, boxes.count == characters.count {
            var result = boxes[lower]
            for index in (lower + 1)..<upper {
                result = result.union(boxes[index])
            }
            return result
        }

        let weights = characters.map(Self.widthWeight)
        let total = weights.reduce(0, +)
        guard total > 0 else { return box }
        let leading = weights[0..<lower].reduce(0, +)
        let covered = weights[lower..<upper].reduce(0, +)
        return NormalizedRect(x: box.x + box.width * (leading / total),
                             y: box.y,
                             width: box.width * (covered / total),
                             height: box.height)
    }

    static func widthWeight(_ character: Character) -> Double {
        guard let scalar = character.unicodeScalars.first else { return 1 }
        switch scalar.value {
        case 0x1100...0x115F,            // Hangul Jamo
             0x2E80...0xA4CF,            // CJK radicals … Yi
             0xAC00...0xD7A3,            // Hangul syllables
             0xF900...0xFAFF,            // CJK compatibility ideographs
             0xFE30...0xFE6F,            // CJK compatibility forms
             0xFF00...0xFF60,            // Full width forms
             0xFFE0...0xFFE6:
            return 2
        case 0x0020...0x002F, 0x003A...0x0040:
            return 0.6                    // punctuation and spaces are narrow
        default:
            return 1
        }
    }
}

/// All recognised text of one image, plus the neighbourhood queries the context
/// analyser needs.
public struct TextLayout: Equatable, Sendable {
    public let lines: [RecognizedTextLine]
    public let imageSize: PixelSize

    public init(lines: [RecognizedTextLine], imageSize: PixelSize) {
        self.lines = lines
        self.imageSize = imageSize
    }

    public static let empty = TextLayout(lines: [], imageSize: .zero)

    public var plainText: String { lines.map(\.text).joined(separator: "\n") }

    /// Lines that visually sit on the same row (label on the left, value on the
    /// right — the layout of virtually every settings and profile screen).
    public func lines(onSameRowAs line: RecognizedTextLine, tolerance: Double = 0.5) -> [RecognizedTextLine] {
        lines.filter { candidate in
            guard candidate.id != line.id else { return false }
            let allowed = max(line.box.height, candidate.box.height) * tolerance
            return abs(candidate.box.midY - line.box.midY) <= allowed
        }
    }

    /// Closest line above, used for "label above value" layouts (forms, cards).
    public func line(above line: RecognizedTextLine) -> RecognizedTextLine? {
        lines
            .filter { $0.box.maxY <= line.box.minY + line.box.height * 0.2 && $0.id != line.id }
            .filter { $0.box.minX < line.box.maxX && $0.box.maxX > line.box.minX }
            .max { lhs, rhs in lhs.box.maxY < rhs.box.maxY }
    }

    /// Neighbouring text to the left on the same row.
    public func line(leftOf line: RecognizedTextLine) -> RecognizedTextLine? {
        lines(onSameRowAs: line)
            .filter { $0.box.maxX <= line.box.minX + line.box.width * 0.1 }
            .max { lhs, rhs in lhs.box.maxX < rhs.box.maxX }
    }
}
