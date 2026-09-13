import Foundation

public enum LayoutScaleMode: String, Codable, CaseIterable, Sendable {
    /// Scale every image so that its cross-axis length matches the cell
    /// (the classic "same width, stacked vertically" collage).
    case matchCross
    /// Keep the original pixel size and only align the images.
    case original
    /// Every cell has the same size; images are fitted or filled into it.
    case uniformCell
}

/// Which input decides the cell size.
public enum LayoutReference: Equatable, Codable, Sendable {
    case smallest
    case largest
    case first
    case fixed(Int)

    func resolve(_ values: [Int]) -> Int {
        switch self {
        case .smallest: return values.min() ?? 0
        case .largest: return values.max() ?? 0
        case .first: return values.first ?? 0
        case .fixed(let value): return max(1, value)
        }
    }
}

public enum LayoutAlignment: String, Codable, CaseIterable, Sendable {
    case leading
    case center
    case trailing
}

public enum LayoutFit: String, Codable, CaseIterable, Sendable {
    /// Whole image visible, empty space around it.
    case fit
    /// Cell completely covered, the image is centre-cropped.
    case fill
}

/// Everything the user can tweak for a hand-made collage: vertical, horizontal
/// or grid, with spacing, padding, scaling and alignment.
public struct ManualLayoutOptions: Equatable, Codable, Sendable {
    /// Direction in which images are appended.
    public var flow: StitchAxis
    /// Number of images per line across the flow direction. 1 gives a plain
    /// column (vertical flow) or row (horizontal flow).
    public var crossCount: Int
    public var spacing: Int
    /// Extra spacing along the flow direction, when it should differ.
    public var lineSpacing: Int?
    public var padding: Int
    public var scaleMode: LayoutScaleMode
    public var reference: LayoutReference
    public var alignment: LayoutAlignment
    public var fit: LayoutFit

    public init(flow: StitchAxis = .vertical,
                crossCount: Int = 1,
                spacing: Int = 0,
                lineSpacing: Int? = nil,
                padding: Int = 0,
                scaleMode: LayoutScaleMode = .matchCross,
                reference: LayoutReference = .largest,
                alignment: LayoutAlignment = .center,
                fit: LayoutFit = .fit) {
        self.flow = flow
        self.crossCount = max(1, crossCount)
        self.spacing = spacing
        self.lineSpacing = lineSpacing
        self.padding = padding
        self.scaleMode = scaleMode
        self.reference = reference
        self.alignment = alignment
        self.fit = fit
    }

    public static let verticalStack = ManualLayoutOptions()
    public static let horizontalStrip = ManualLayoutOptions(flow: .horizontal)
    public static func grid(columns: Int, spacing: Int = 12, padding: Int = 12) -> ManualLayoutOptions {
        ManualLayoutOptions(flow: .vertical,
                            crossCount: columns,
                            spacing: spacing,
                            padding: padding,
                            scaleMode: .uniformCell,
                            reference: .smallest,
                            alignment: .center,
                            fit: .fill)
    }
}

/// Places images without any overlap detection: the "just put them next to each
/// other" mode, including grids.
///
/// The maths is written once in (main, cross) space and mapped to image
/// coordinates at the end, so vertical and horizontal flows cannot drift apart.
public enum ManualLayoutPlanner {
    public static func plan(sizes: [PixelSize], options: ManualLayoutOptions) -> StitchPlan {
        let usable = sizes.enumerated().filter { !$0.element.isEmpty }
        guard !usable.isEmpty else { return .empty }

        let vertical = options.flow.isVertical
        func cross(_ size: PixelSize) -> Int { vertical ? size.width : size.height }
        func main(_ size: PixelSize) -> Int { vertical ? size.height : size.width }

        let crossCount = min(max(1, options.crossCount), usable.count)
        let lineSpacing = options.lineSpacing ?? options.spacing

        // Cell size across the flow.
        let crossCell: Int
        switch options.scaleMode {
        case .matchCross, .uniformCell:
            crossCell = max(1, options.reference.resolve(usable.map { cross($0.element) }))
        case .original:
            crossCell = max(1, usable.map { cross($0.element) }.max() ?? 1)
        }

        /// Size an image occupies inside its cell before alignment.
        func scaledSize(_ size: PixelSize) -> (cross: Int, main: Int) {
            switch options.scaleMode {
            case .original:
                return (cross(size), main(size))
            case .matchCross, .uniformCell:
                let scale = Double(crossCell) / Double(max(1, cross(size)))
                return (crossCell, max(1, Int((Double(main(size)) * scale).rounded())))
            }
        }

        let scaled = usable.map { scaledSize($0.element) }
        let uniformMainCell: Int? = options.scaleMode == .uniformCell
            ? max(1, options.reference.resolve(scaled.map(\.main)))
            : nil

        // Group into lines and measure each line.
        var lines = [[Int]]()
        var current = [Int]()
        for index in usable.indices {
            current.append(index)
            if current.count == crossCount {
                lines.append(current)
                current = []
            }
        }
        if !current.isEmpty { lines.append(current) }

        let lineMainLengths: [Int] = lines.map { line in
            if let uniform = uniformMainCell { return uniform }
            return line.map { scaled[$0].main }.max() ?? 0
        }

        let contentCrossLength = crossCell * crossCount + options.spacing * (crossCount - 1)
        let contentMainLength = lineMainLengths.reduce(0, +) + lineSpacing * max(0, lines.count - 1)
        let canvasCross = contentCrossLength + options.padding * 2
        let canvasMain = contentMainLength + options.padding * 2

        func makeRect(mainOffset: Int, crossOffset: Int, mainLength: Int, crossLength: Int) -> PixelRect {
            vertical
                ? PixelRect(x: crossOffset, y: mainOffset, width: crossLength, height: mainLength)
                : PixelRect(x: mainOffset, y: crossOffset, width: mainLength, height: crossLength)
        }

        var segments = [StitchSegment]()
        var mainOffset = options.padding

        for (lineIndex, line) in lines.enumerated() {
            let lineMain = lineMainLengths[lineIndex]
            for (columnIndex, index) in line.enumerated() {
                let source = usable[index]
                let cellCrossOffset = options.padding + columnIndex * (crossCell + options.spacing)
                let cell = makeRect(mainOffset: mainOffset,
                                    crossOffset: cellCrossOffset,
                                    mainLength: lineMain,
                                    crossLength: crossCell)
                let placement = place(sourceSize: source.element,
                                      in: cell,
                                      scaleMode: options.scaleMode,
                                      fit: options.fit,
                                      alignment: options.alignment,
                                      vertical: vertical)
                segments.append(StitchSegment(sourceIndex: source.offset,
                                              sourceRect: placement.source,
                                              destinationRect: placement.destination,
                                              kind: .placement))
            }
            mainOffset += lineMain + lineSpacing
        }

        let canvasSize = vertical
            ? PixelSize(width: canvasCross, height: canvasMain)
            : PixelSize(width: canvasMain, height: canvasCross)

        return StitchPlan(axis: options.flow,
                          canvasSize: canvasSize,
                          segments: segments)
    }

    // MARK: - Cell placement

    private struct Placement {
        let source: PixelRect
        let destination: PixelRect
    }

    private static func place(sourceSize: PixelSize,
                              in cell: PixelRect,
                              scaleMode: LayoutScaleMode,
                              fit: LayoutFit,
                              alignment: LayoutAlignment,
                              vertical: Bool) -> Placement {
        let sourceBounds = PixelRect(x: 0, y: 0, width: sourceSize.width, height: sourceSize.height)
        guard !cell.isEmpty, !sourceSize.isEmpty else {
            return Placement(source: sourceBounds, destination: cell)
        }

        switch fit {
        case .fill:
            // Centre-crop the source to the cell's aspect ratio.
            let cellAspect = Double(cell.width) / Double(cell.height)
            let sourceAspect = Double(sourceSize.width) / Double(sourceSize.height)
            var cropWidth = sourceSize.width
            var cropHeight = sourceSize.height
            if sourceAspect > cellAspect {
                cropWidth = max(1, Int((Double(sourceSize.height) * cellAspect).rounded()))
            } else if sourceAspect < cellAspect {
                cropHeight = max(1, Int((Double(sourceSize.width) / cellAspect).rounded()))
            }
            let crop = PixelRect(x: (sourceSize.width - cropWidth) / 2,
                                 y: (sourceSize.height - cropHeight) / 2,
                                 width: cropWidth,
                                 height: cropHeight)
                .clamped(to: sourceSize)
            return Placement(source: crop, destination: cell)

        case .fit:
            let scale: Double
            switch scaleMode {
            case .original:
                scale = 1
            case .matchCross, .uniformCell:
                scale = min(Double(cell.width) / Double(sourceSize.width),
                            Double(cell.height) / Double(sourceSize.height))
            }
            let drawWidth = min(cell.width, max(1, Int((Double(sourceSize.width) * scale).rounded())))
            let drawHeight = min(cell.height, max(1, Int((Double(sourceSize.height) * scale).rounded())))
            let freeCross = vertical ? cell.width - drawWidth : cell.height - drawHeight
            let crossShift: Int
            switch alignment {
            case .leading: crossShift = 0
            case .center: crossShift = freeCross / 2
            case .trailing: crossShift = freeCross
            }
            let mainShift = vertical ? (cell.height - drawHeight) / 2 : (cell.width - drawWidth) / 2
            let destination = vertical
                ? PixelRect(x: cell.x + crossShift, y: cell.y + mainShift, width: drawWidth, height: drawHeight)
                : PixelRect(x: cell.x + mainShift, y: cell.y + crossShift, width: drawWidth, height: drawHeight)
            return Placement(source: sourceBounds, destination: destination)
        }
    }
}
