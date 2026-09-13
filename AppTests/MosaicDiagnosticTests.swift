import XCTest
import UIKit
@testable import PicSig
import PicSigCore

/// Temporary: reports every intermediate value of the mosaic path in one CI run.
final class MosaicDiagnosticTests: XCTestCase {
    func testReportMosaicInternals() throws {
        let image = SyntheticScreenshot.make(rows: [.init(label: "联系电话", value: "13812345678")])
        let cgImage = try XCTUnwrap(image.cgImage)
        let rect = CGRect(x: 32, y: 36, width: 320, height: 40)
        var report = [String]()
        report.append("source: \(cgImage.width)x\(cgImage.height) bpc=\(cgImage.bitsPerComponent) bpp=\(cgImage.bitsPerPixel) alpha=\(cgImage.alphaInfo.rawValue) bitmapInfo=\(cgImage.bitmapInfo.rawValue) space=\(cgImage.colorSpace?.name.map(String.init) ?? "nil")")

        func mean(_ bytes: [UInt8]?) -> String {
            guard let bytes else { return "nil" }
            var sum = 0
            var stride = 0
            while stride < bytes.count { sum += Int(bytes[stride]); stride += 4 }
            return String(format: "%.1f (n=%d)", Double(sum) / Double(bytes.count / 4), bytes.count / 4)
        }

        // A: readback outside any renderer.
        report.append("A readback outside renderer, red mean: \(mean(RedactionRenderer.rgbaPixels(of: cgImage, in: rect)))")

        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        report.append("format range=\(format.preferredRange.rawValue)")

        var insideMean = "unset"
        let rendered = UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            image.draw(in: CGRect(origin: .zero, size: image.size))
            // B: readback inside the renderer closure.
            insideMean = mean(RedactionRenderer.rgbaPixels(of: cgImage, in: rect))
            // C: does a coloured fill come out coloured?
            UIColor(red: 0.7, green: 0.5, blue: 0.3, alpha: 1).setFill()
            context.fill(rect)
        }
        report.append("B readback inside renderer, red mean: \(insideMean)")
        if let out = rendered.cgImage {
            report.append("C fill probe red mean in rect: \(mean(RedactionRenderer.rgbaPixels(of: out, in: rect))) (expect ~178)")
            report.append("rendered: bpc=\(out.bitsPerComponent) bpp=\(out.bitsPerPixel) bitmapInfo=\(out.bitmapInfo.rawValue)")
        }

        // D: mosaic without noise.
        let box = NormalizedRect(x: 32 / image.size.width, y: 36 / image.size.height,
                                 width: 320 / image.size.width, height: 40 / image.size.height)
        let item = RedactionItem(box: box, style: .mosaic, strength: 1, category: .custom, isManual: true)
        let plan = RedactionPlan(items: [item], imageSize: PixelSize(width: Int(image.size.width), height: Int(image.size.height)))
        var options = RedactionRenderer.Options()
        options.addsMosaicNoise = false
        let mosaic = RedactionRenderer.apply(plan: plan, to: image, options: options)
        if let out = mosaic.cgImage {
            report.append("D mosaic (no noise) red mean in rect: \(mean(RedactionRenderer.rgbaPixels(of: out, in: rect)))")
        }
        let solidItem = RedactionItem(box: box, style: .solid, strength: 1, category: .custom, isManual: true)
        let solid = RedactionRenderer.apply(plan: RedactionPlan(items: [solidItem], imageSize: plan.imageSize), to: image)
        if let out = solid.cgImage {
            report.append("E solid red mean in rect: \(mean(RedactionRenderer.rgbaPixels(of: out, in: rect))) (expect ~33)")
        }

        XCTFail("DIAGNOSTIC\n" + report.joined(separator: "\n"))
    }
}
