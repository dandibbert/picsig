import XCTest
import UIKit
@testable import PicSig
import PicSigCore

/// The text tool lets the user pick any font the device knows. These pin down
/// the lookup, the fallback and that the chosen font really reaches the export.
final class AnnotationFontsTests: XCTestCase {
    func testUnknownFontFallsBackToTheSystemFont() {
        let fallback = AnnotationFonts.font(named: "NoSuchFont-Regular", size: 20)
        XCTAssertEqual(fallback.pointSize, 20)
        XCTAssertEqual(fallback.familyName, UIFont.systemFont(ofSize: 20).familyName)
        XCTAssertEqual(AnnotationFonts.font(named: nil, size: 12).familyName, UIFont.systemFont(ofSize: 12).familyName)
    }

    func testKnownFontIsResolvedByPostScriptName() {
        let courier = AnnotationFonts.font(named: "Courier", size: 18)
        XCTAssertEqual(courier.familyName, "Courier")
        XCTAssertEqual(AnnotationFonts.displayName(for: "Courier-Bold"), "Courier Bold")
    }

    func testAvailabilityAndRequestOfKnownFonts() {
        XCTAssertTrue(AnnotationFonts.isAvailable(nil))
        XCTAssertTrue(AnnotationFonts.isAvailable("Helvetica"))
        XCTAssertFalse(AnnotationFonts.isAvailable("NoSuchFont-Regular"))

        let done = expectation(description: "request completes")
        AnnotationFonts.request(["Helvetica"]) { missing in
            XCTAssertTrue(missing.isEmpty, "an already available font needs no request")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testChosenFontChangesTheRenderedMark() {
        let size = CGSize(width: 400, height: 120)
        func render(_ fontName: String?) -> [UInt8] {
            let annotation = Annotation(tool: .text,
                                        points: [NormalizedPoint(x: 0.05, y: 0.2)],
                                        color: .black,
                                        text: "Hello 你好",
                                        fontSize: 0.09,
                                        fontName: fontName)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                AnnotationRenderer.draw(annotations: [annotation], in: size, context: context)
            }
            guard let cgImage = image.cgImage else { return [] }
            var pixels = [UInt8](repeating: 0, count: Int(size.width * size.height) * 4)
            let space = CGColorSpaceCreateDeviceRGB()
            pixels.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress,
                                        width: Int(size.width),
                                        height: Int(size.height),
                                        bitsPerComponent: 8,
                                        bytesPerRow: Int(size.width) * 4,
                                        space: space,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.draw(cgImage, in: CGRect(origin: .zero, size: size))
            }
            return pixels
        }

        let system = render(nil)
        let courier = render("Courier")
        XCTAssertFalse(system.isEmpty)
        XCTAssertNotEqual(system, courier, "a different font must draw different pixels")
        XCTAssertEqual(render("NoSuchFont"), system, "an unknown font draws exactly like the system font")
    }
}
