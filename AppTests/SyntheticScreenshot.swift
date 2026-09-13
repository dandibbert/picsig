import UIKit
import PicSigCore

/// Builds screenshot-like images at runtime so the tests do not depend on binary
/// fixtures, and so a failure points at the pipeline rather than at a stale asset.
enum SyntheticScreenshot {
    struct Row {
        let label: String
        let value: String

        init(label: String = "", value: String) {
            self.label = label
            self.value = value
        }
    }

    /// Renders rows of `label: value` text on a light background, at a font size and
    /// spacing close to a real iOS chat or order screen.
    ///
    /// The point size matters: Vision's accurate path needs roughly 20px of glyph
    /// height to read digits reliably, and testing against text far larger than a
    /// real screenshot would hide exactly the failure this suite is looking for.
    static func make(rows: [Row],
                     width: CGFloat = 750,
                     rowHeight: CGFloat = 64,
                     fontSize: CGFloat = 26,
                     topInset: CGFloat = 40) -> UIImage {
        let height = topInset * 2 + rowHeight * CGFloat(rows.count)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
            .image { context in
                UIColor.white.setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))

                let font = UIFont.systemFont(ofSize: fontSize)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: UIColor.black
                ]

                for (index, row) in rows.enumerated() {
                    let text = row.label.isEmpty ? row.value : "\(row.label)：\(row.value)"
                    let origin = CGPoint(x: 32, y: topInset + rowHeight * CGFloat(index))
                    (text as NSString).draw(at: origin, withAttributes: attributes)
                }
            }
    }

    /// Marker text that survives OCR unambiguously.
    ///
    /// Zero padded because a bare `line 1` is a substring of `line 10`, which makes
    /// "appears exactly once" impossible to count; wrapped in brackets with no inner
    /// space because Vision drops spaces between a glyph run and a digit often enough
    /// to matter.
    static func marker(_ index: Int) -> String {
        String(format: "[R%02d]", index)
    }

    /// Two overlapping screenshots of one tall page, the way a user captures them:
    /// the second starts part way up the content the first already showed.
    ///
    /// The page is sized so the two slices cover it exactly, with `overlapRows` shared
    /// between them — otherwise trailing rows appear in neither input and look like a
    /// stitching bug when they go missing from the result.
    static func verticalPair(visibleRows: Int,
                             overlapRows: Int) -> (first: UIImage, second: UIImage, rowCount: Int) {
        precondition(visibleRows > overlapRows)
        let rowCount = visibleRows * 2 - overlapRows
        let rows = (1...rowCount).map { Row(value: "\(marker($0)) 第 \($0) 行") }
        let full = make(rows: rows, topInset: 0)

        let rowHeight: CGFloat = 64
        let sliceHeight = rowHeight * CGFloat(visibleRows)
        let secondTop = rowHeight * CGFloat(visibleRows - overlapRows)

        func slice(top: CGFloat) -> UIImage {
            let rect = CGRect(x: 0, y: top, width: full.size.width, height: sliceHeight)
            guard let cropped = full.cgImage?.cropping(to: rect) else { return full }
            return UIImage(cgImage: cropped)
        }

        return (slice(top: 0), slice(top: secondTop), rowCount)
    }

    /// Two screenshots that overlap horizontally, for the horizontal stitch path.
    ///
    /// The content is a deterministic scatter of vertical bars rather than evenly
    /// spaced text. Regularly spaced marks give every column the same signature, and a
    /// page like that genuinely has several equally good alignments — the ambiguity
    /// would be the fixture's fault, not the planner's.
    static func horizontalPair(width: CGFloat = 900,
                               overlap: CGFloat = 300) -> (first: UIImage, second: UIImage, fullWidth: Int) {
        let fullWidth = width * 2 - overlap
        let height: CGFloat = 320
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true

        var seed: UInt64 = 0x5DEECE66D
        func nextUnit() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) % 1000) / 1000
        }

        let full = UIGraphicsImageRenderer(size: CGSize(width: fullWidth, height: height), format: format)
            .image { context in
                UIColor.white.setFill()
                context.fill(CGRect(x: 0, y: 0, width: fullWidth, height: height))

                var x: CGFloat = 4
                while x < fullWidth - 12 {
                    let barWidth = 2 + nextUnit() * 7
                    let top = nextUnit() * height * 0.4
                    let barHeight = height * (0.3 + nextUnit() * 0.6) - top
                    UIColor(white: nextUnit() * 0.5, alpha: 1).setFill()
                    context.fill(CGRect(x: x, y: top, width: barWidth, height: max(8, barHeight)))
                    x += barWidth + 2 + nextUnit() * 10
                }
            }

        func slice(left: CGFloat) -> UIImage {
            let rect = CGRect(x: left, y: 0, width: width, height: height)
            guard let cropped = full.cgImage?.cropping(to: rect) else { return full }
            return UIImage(cgImage: cropped)
        }

        return (slice(left: 0), slice(left: fullWidth - width), Int(fullWidth))
    }
}
