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

    /// Two overlapping "screenshots" of one tall page, the way a user would capture
    /// them: the second starts part way up the content the first already showed.
    static func overlappingPair(rows: [Row],
                                visibleRows: Int,
                                overlapRows: Int) -> (first: UIImage, second: UIImage, expectedRows: Int) {
        let full = make(rows: rows, topInset: 0)
        let rowHeight: CGFloat = 64
        let sliceHeight = rowHeight * CGFloat(visibleRows)
        let secondTop = rowHeight * CGFloat(visibleRows - overlapRows)

        func slice(top: CGFloat) -> UIImage {
            let rect = CGRect(x: 0, y: top, width: full.size.width, height: sliceHeight)
            guard let cropped = full.cgImage?.cropping(to: rect) else { return full }
            return UIImage(cgImage: cropped)
        }

        return (slice(top: 0), slice(top: secondTop), rows.count)
    }
}
