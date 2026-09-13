import XCTest
import UIKit
import ImageIO
@testable import PicSig

final class ImagingTests: XCTestCase {
    private var projects: [UUID] = []
    override func tearDown() {
        for id in projects { try? ProjectStore.delete(id) }
        super.tearDown()
    }
    private func image(width: Int = 256, height: Int = 256, draw: (CGContext) -> Void) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { draw($0.cgContext) }.cgImage)
    }
    private func project(_ cgImage: CGImage) throws -> Project {
        var project = Project(title: "Synthetic image test", kind: .scroll)
        projects.append(project.id)
        project.images = [try ProjectStore.addImage(cgImage, project: project.id)]
        project.layout.breadth = Double(cgImage.width)
        return project
    }
    private func rgba(_ cgImage: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let result = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: cgImage.width, height: cgImage.height,
                                          bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            return true
        }
        XCTAssertTrue(result); return pixels
    }
    func testGrayRasterMaintainsTopToBottomOrientation() throws {
        let source = try image { context in
            context.setFillColor(UIColor.black.cgColor); context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            context.setFillColor(UIColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 256, height: 100))
        }
        let raster = try MediaWorker.raster(source)
        XCTAssertGreaterThan(raster.pixels[20 * raster.width + 20], 240)
        XCTAssertLessThan(raster.pixels[220 * raster.width + 20], 10)
    }
    func testMasksAreOpaqueAndIndependentOfUnderlyingPixels() throws {
        let red = try image { $0.setFillColor(UIColor.red.cgColor); $0.fill(CGRect(x: 0, y: 0, width: 256, height: 256)) }
        let blue = try image { $0.setFillColor(UIColor.blue.cgColor); $0.fill(CGRect(x: 0, y: 0, width: 256, height: 256)) }
        for style in MaskStyle.allCases {
            var first = try project(red), second = try project(blue)
            var mask = PrivacyMask(rect: .unit, kind: .manual); mask.style = style
            first.edit.masks = [mask]; second.edit.masks = [mask]
            let a = try rgba(XCTUnwrap(Renderer.render(first).cgImage))
            let b = try rgba(XCTUnwrap(Renderer.render(second).cgImage))
            XCTAssertEqual(a, b, "Redaction output must not encode source pixels: \(style)")
            XCTAssertTrue(stride(from: 3, to: a.count, by: 4).allSatisfy { a[$0] == 255 })
        }
    }
    func testAnnotationCannotPaintOverMask() throws {
        let source = try image { $0.setFillColor(UIColor.white.cgColor); $0.fill(CGRect(x: 0, y: 0, width: 256, height: 256)) }
        var p = try project(source); p.edit.masks = [PrivacyMask(rect: .unit, kind: .manual)]
        let before = try rgba(XCTUnwrap(Renderer.render(p).cgImage))
        p.edit.annotations = [Annotation(kind: .text, points: [Point2D(0.1, 0.1)], text: "secret", width: 8),
                              Annotation(kind: .arrow, points: [Point2D(0, 0), Point2D(1, 1)], width: 20)]
        XCTAssertEqual(before, try rgba(XCTUnwrap(Renderer.render(p).cgImage)))
    }
    func testCropRotationAndRegionRenderMatchFullOutput() throws {
        let source = try image(width: 256, height: 512) { context in
            for row in 0..<512 {
                context.setFillColor(UIColor(red: CGFloat(row % 100) / 100, green: CGFloat(row % 73) / 73, blue: 0.4, alpha: 1).cgColor)
                context.fill(CGRect(x: 0, y: row, width: 256, height: 1))
            }
        }
        var p = try project(source); p.edit.crop = Box(0.125, 0.125, 0.75, 0.75)
        p.edit.masks = [PrivacyMask(rect: Box(0.2, 0.2, 0.25, 0.25), kind: .manual)]
        for turn in 0..<4 {
            p.edit.quarterTurns = turn
            let full = try XCTUnwrap(Renderer.render(p).cgImage)
            XCTAssertEqual(full.width, turn % 2 == 0 ? 192 : 384)
            XCTAssertEqual(full.height, turn % 2 == 0 ? 384 : 192)
            let region = Box(16, 22, 96, 120)
            let part = try XCTUnwrap(Renderer.render(p, region: region).cgImage)
            let expected = try XCTUnwrap(full.cropping(to: region.cgRect))
            XCTAssertEqual(try rgba(part), try rgba(expected), "Tile transform mismatch at rotation \(turn)")
        }
    }
    func testWrittenExportsDoNotContainSourceMetadata() throws {
        let source = try image { $0.setFillColor(UIColor.white.cgColor); $0.fill(CGRect(x: 0, y: 0, width: 256, height: 256)) }
        let p = try project(source)
        for jpeg in [false, true] {
            let url = ProjectStore.directory(p.id).appendingPathComponent(jpeg ? "export.jpg" : "export.png")
            try ProjectStore.writeImage(source, to: url, jpeg: jpeg)
            let decoded = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [CFString: Any])
            XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
            XCTAssertNil(properties[kCGImagePropertyIPTCDictionary])
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal])
            XCTAssertNil(exif?[kCGImagePropertyExifDateTimeDigitized])
            XCTAssertNil(exif?[kCGImagePropertyExifUserComment])
            XCTAssertNil(exif?[kCGImagePropertyExifLensModel])
            XCTAssertNil(exif?[kCGImagePropertyExifBodySerialNumber])
            XCTAssertNil(exif?[kCGImagePropertyExifMakerNote])
            XCTAssertEqual(CGImageSourceGetCount(decoded), 1)
        }
    }
    func testStaleSaveCannotOverwriteNewerEdit() throws {
        let source = try image { $0.setFillColor(UIColor.white.cgColor); $0.fill(CGRect(x: 0, y: 0, width: 256, height: 256)) }
        var older = try project(source); older.updatedAt = Date(timeIntervalSince1970: 100)
        var newer = older; newer.updatedAt = Date(timeIntervalSince1970: 200); newer.title = "Newer"
        try ProjectStore.save(newer); try ProjectStore.save(older)
        let read = try JSONDecoder().decode(Project.self, from: Data(contentsOf: ProjectStore.directory(older.id).appendingPathComponent("project.json")))
        XCTAssertEqual(read.title, "Newer")
    }
    func testTraversalRejected() throws {
        let source = SourceImage(file: "../../outside.png", size: Size2D(256, 256))
        XCTAssertThrowsError(try ProjectStore.sourceURL(source, in: UUID()))
    }
    func testImageCancellationRollsBackNewSources() async throws {
        let source = try image { $0.setFillColor(UIColor.white.cgColor); $0.fill(CGRect(x: 0, y: 0, width: 256, height: 256)) }
        let original = try project(source); try ProjectStore.save(original)
        let url = try ProjectStore.sourceURL(original.images[0], in: original.id)
        let task = Task { try await MediaWorker.shared.importImages([url], into: original, progress: { _, _ in }) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must throw") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(names, [original.images[0].file])
    }
    func testVisionFindsEmailKeywordAndSplitAddressOnDevice() throws {
        let source = try image(width: 1000, height: 760) { context in
            context.setFillColor(UIColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 760))
            ("Email: alice@example.test" as NSString).draw(at: CGPoint(x: 70, y: 90), withAttributes: [.font: UIFont.systemFont(ofSize: 42), .foregroundColor: UIColor.black])
            ("PRIVATE_MARKER" as NSString).draw(at: CGPoint(x: 70, y: 270), withAttributes: [.font: UIFont.systemFont(ofSize: 42), .foregroundColor: UIColor.black])
            ("Home Address" as NSString).draw(at: CGPoint(x: 70, y: 450), withAttributes: [.font: UIFont.systemFont(ofSize: 38, weight: .semibold), .foregroundColor: UIColor.black])
            ("1234 Market Street Apt 5B" as NSString).draw(at: CGPoint(x: 70, y: 550), withAttributes: [.font: UIFont.systemFont(ofSize: 38), .foregroundColor: UIColor.black])
        }
        var p = try project(source); p.privacy.enabledKinds = [.email, .keyword, .address]; p.privacy.keywords = ["PRIVATE_MARKER"]
        let report = try PrivacyScanner.scan(p, progress: { _, _ in })
        XCTAssertTrue(report.warnings.isEmpty)
        XCTAssertTrue(report.masks.contains { $0.kind == .email })
        XCTAssertTrue(report.masks.contains { $0.kind == .keyword })
        XCTAssertTrue(report.masks.contains { $0.kind == .address })
        XCTAssertTrue(report.masks.allSatisfy { $0.rect.isValid && $0.rect.intersection(.unit) == $0.rect })
        p.edit.masks = report.masks
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(p.edit), as: UTF8.self).contains("alice"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(p.edit), as: UTF8.self).contains("Market"))
    }
    @MainActor func testQuickTwoScreenshotFlowRemovesFixedBrowserBarsWithoutChangingOverlap() async throws {
        let width = 320
        let bodyHeight = 600
        let topBar = 50
        let bottomBar = 60
        let documentHeight = 950
        let secondOffset = 350

        let document = try image(width: width, height: documentHeight) { context in
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: documentHeight))
            for y in stride(from: 0, to: documentHeight, by: 4) {
                for x in stride(from: 0, to: width, by: 8) {
                    let r = CGFloat((y * 17 + x * 31 + (y * x) % 97) % 255) / 255
                    let g = CGFloat((y * 47 + x * 11 + 53) % 255) / 255
                    let b = CGFloat((y * 7 + x * 61 + 101) % 255) / 255
                    context.setFillColor(UIColor(red: r, green: g, blue: b, alpha: 1).cgColor)
                    context.fill(CGRect(x: x, y: y, width: 8, height: 4))
                }
            }
        }

        func screenshot(offset: Int, changingClock: Bool) throws -> CGImage {
            try image(width: width, height: topBar + bodyHeight + bottomBar) { context in
                context.setFillColor(UIColor(white: 0.10, alpha: 1).cgColor)
                context.fill(CGRect(x: 0, y: 0, width: width, height: topBar))
                context.setFillColor(UIColor(white: 0.92, alpha: 1).cgColor)
                context.fill(CGRect(x: 100, y: 13, width: 120, height: 22))
                if changingClock {
                    context.setFillColor(UIColor.systemRed.cgColor)
                    context.fill(CGRect(x: 12, y: 14, width: 28, height: 18))
                }

                context.saveGState()
                context.clip(to: CGRect(x: 0, y: topBar, width: width, height: bodyHeight))
                UIImage(cgImage: document).draw(at: CGPoint(x: 0, y: topBar - offset))
                context.restoreGState()

                context.setFillColor(UIColor(white: 0.88, alpha: 1).cgColor)
                context.fill(CGRect(x: 0, y: topBar + bodyHeight, width: width, height: bottomBar))
                context.setFillColor(UIColor(white: 0.35, alpha: 1).cgColor)
                context.fill(CGRect(x: 42, y: topBar + bodyHeight + 20, width: 236, height: 18))
            }
        }

        let firstURL = FileManager.default.temporaryDirectory.appendingPathComponent("picsig-quick-\(UUID().uuidString)-1.png")
        let secondURL = FileManager.default.temporaryDirectory.appendingPathComponent("picsig-quick-\(UUID().uuidString)-2.png")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        try ProjectStore.writeImage(try screenshot(offset: 0, changingClock: false), to: firstURL)
        try ProjectStore.writeImage(try screenshot(offset: secondOffset, changingClock: true), to: secondURL)

        let draft = Project(title: "Quick regression", kind: .scroll)
        projects.append(draft.id)
        let session = StudioSession(project: draft)
        session.quickImport([firstURL, secondURL], finishInEditor: false)

        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if !session.busy, session.note?.contains("已自动拼接") == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertNil(session.notice, session.notice?.message ?? "")
        XCTAssertTrue(session.note?.contains("清理检测到的固定状态栏") == true, session.note ?? "quick flow never finished")
        XCTAssertEqual(session.project.images.count, 2)
        let first = try XCTUnwrap(session.project.images.first)
        let last = try XCTUnwrap(session.project.images.last)
        let firstCrop = first.automaticCrop ?? first.crop
        let lastCrop = last.automaticCrop ?? last.crop
        XCTAssertGreaterThan(firstCrop.y * first.size.height, 40)
        XCTAssertGreaterThan((1 - lastCrop.maxY) * last.size.height, 50)
        XCTAssertGreaterThan(last.leadingCut * lastCrop.height * last.size.height, 235)
        XCTAssertLessThan(last.leadingCut * lastCrop.height * last.size.height, 265)

        let composition = try Composition.build(session.project)
        XCTAssertEqual(composition.size.width, Double(width), accuracy: 0.5)
        XCTAssertEqual(composition.size.height, Double(documentHeight), accuracy: 8,
                       "Quick flow must remove outer browser bars without reintroducing overlap pixels")
    }
    func testResidentialAddressHeuristics() {
        for value in [
            "上海市浦东新区张江镇祖冲之路1234弄5号楼2单元201室",
            "1234 Market Street Apt 5B, San Francisco, CA 94103",
            "東京都新宿区西新宿2丁目8番1号",
            "家庭住址：杭州市西湖区文三路88号"
        ] {
            XCTAssertTrue(PrivacyScanner.looksLikeResidentialAddress(value), value)
        }
        XCTAssertFalse(PrivacyScanner.looksLikeResidentialAddress("今天走这条道路很开心"))
        XCTAssertFalse(PrivacyScanner.looksLikeResidentialAddress("产品型号 A1234，版本 2.0"))
    }
}
