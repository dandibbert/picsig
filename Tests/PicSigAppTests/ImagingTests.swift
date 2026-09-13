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
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return try XCTUnwrap(
            UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
                .image { draw($0.cgContext) }
                .cgImage
        )
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
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: cgImage.width,
                height: cgImage.height,
                bitsPerComponent: 8,
                bytesPerRow: cgImage.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            return true
        }
        XCTAssertTrue(result)
        return pixels
    }

    private func textureByte(_ seed: UInt64) -> UInt8 {
        var value = seed &+ 0x9E3779B97F4A7C15
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return UInt8(truncatingIfNeeded: value >> 24)
    }

    /// Generates deterministic, non-periodic 2D texture so there is only one valid viewport overlap.
    private func makeScrollDocument(width: Int, height: Int) throws -> CGImage {
        let half = max(1, width / 2)
        return try image(width: width, height: height) { context in
            for row in 0..<height {
                let y = CGFloat(row)
                let left = CGFloat(textureByte(UInt64(row) &* 2)) / 255.0
                let right = CGFloat(textureByte(UInt64(row) &* 2 &+ 1)) / 255.0
                context.setFillColor(UIColor(white: left, alpha: 1).cgColor)
                context.fill(CGRect(x: 0, y: y, width: CGFloat(half), height: 1))
                context.setFillColor(UIColor(white: right, alpha: 1).cgColor)
                context.fill(CGRect(x: CGFloat(half), y: y, width: CGFloat(width - half), height: 1))
            }
        }
    }

    private func makeBrowserScreenshot(
        document: CGImage,
        width: Int,
        bodyHeight: Int,
        topBar: Int,
        bottomBar: Int,
        offset: Int,
        changingClock: Bool
    ) throws -> CGImage {
        let totalHeight = topBar + bodyHeight + bottomBar
        let w = CGFloat(width)
        let top = CGFloat(topBar)
        let body = CGFloat(bodyHeight)
        let bottom = CGFloat(bottomBar)
        let documentImage = UIImage(cgImage: document)

        return try image(width: width, height: totalHeight) { context in
            context.setFillColor(UIColor(white: 0.10, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: w, height: top))

            context.setFillColor(UIColor(white: 0.92, alpha: 1).cgColor)
            context.fill(CGRect(x: 100, y: 13, width: 120, height: 22))

            if changingClock {
                context.setFillColor(UIColor.systemRed.cgColor)
                context.fill(CGRect(x: 12, y: 14, width: 28, height: 18))
            }

            context.saveGState()
            context.clip(to: CGRect(x: 0, y: top, width: w, height: body))
            documentImage.draw(at: CGPoint(x: 0, y: top - CGFloat(offset)))
            context.restoreGState()

            let footerY = top + body
            context.setFillColor(UIColor(white: 0.88, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: footerY, width: w, height: bottom))
            context.setFillColor(UIColor(white: 0.35, alpha: 1).cgColor)
            context.fill(CGRect(x: 42, y: footerY + 20, width: 236, height: 18))
        }
    }

    func testGrayRasterMaintainsTopToBottomOrientation() throws {
        let source = try image { context in
            context.setFillColor(UIColor.black.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 100))
        }
        let raster = try MediaWorker.raster(source)
        XCTAssertGreaterThan(raster.pixels[20 * raster.width + 20], 240)
        XCTAssertLessThan(raster.pixels[220 * raster.width + 20], 10)
    }

    func testMasksAreOpaqueAndIndependentOfUnderlyingPixels() throws {
        let red = try image {
            $0.setFillColor(UIColor.red.cgColor)
            $0.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        }
        let blue = try image {
            $0.setFillColor(UIColor.blue.cgColor)
            $0.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        }
        for style in MaskStyle.allCases {
            var first = try project(red)
            var second = try project(blue)
            var mask = PrivacyMask(rect: .unit, kind: .manual)
            mask.style = style
            first.edit.masks = [mask]
            second.edit.masks = [mask]
            let a = try rgba(XCTUnwrap(Renderer.render(first).cgImage))
            let b = try rgba(XCTUnwrap(Renderer.render(second).cgImage))
            XCTAssertEqual(a, b, "Redaction output must not encode source pixels: \(style)")
            XCTAssertTrue(stride(from: 3, to: a.count, by: 4).allSatisfy { a[$0] == 255 })
        }
    }

    func testAnnotationCannotPaintOverMask() throws {
        let source = try image {
            $0.setFillColor(UIColor.white.cgColor)
            $0.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        }
        var p = try project(source)
        p.edit.masks = [PrivacyMask(rect: .unit, kind: .manual)]
        let before = try rgba(XCTUnwrap(Renderer.render(p).cgImage))
        p.edit.annotations = [
            Annotation(kind: .text, points: [Point2D(0.1, 0.1)], text: "secret", width: 8),
            Annotation(kind: .arrow, points: [Point2D(0, 0), Point2D(1, 1)], width: 20)
        ]
        XCTAssertEqual(before, try rgba(XCTUnwrap(Renderer.render(p).cgImage)))
    }

    func testCropRotationAndRegionRenderMatchFullOutput() throws {
        let source = try image(width: 256, height: 512) { context in
            for row in 0..<512 {
                let color = UIColor(
                    red: CGFloat(row % 100) / 100,
                    green: CGFloat(row % 73) / 73,
                    blue: 0.4,
                    alpha: 1
                )
                context.setFillColor(color.cgColor)
                context.fill(CGRect(x: 0, y: row, width: 256, height: 1))
            }
        }
        var p = try project(source)
        p.edit.crop = Box(0.125, 0.125, 0.75, 0.75)
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
        let source = try image {
            $0.setFillColor(UIColor.white.cgColor)
            $0.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        }
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
        let source = try image {
            $0.setFillColor(UIColor.white.cgColor)
            $0.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        }
        var older = try project(source)
        older.updatedAt = Date(timeIntervalSince1970: 100)
        var newer = older
        newer.updatedAt = Date(timeIntervalSince1970: 200)
        newer.title = "Newer"
        try ProjectStore.save(newer)
        try ProjectStore.save(older)
        let manifest = ProjectStore.directory(older.id).appendingPathComponent("project.json")
        let read = try JSONDecoder().decode(Project.self, from: Data(contentsOf: manifest))
        XCTAssertEqual(read.title, "Newer")
    }

    func testTraversalRejected() throws {
        let source = SourceImage(file: "../../outside.png", size: Size2D(256, 256))
        XCTAssertThrowsError(try ProjectStore.sourceURL(source, in: UUID()))
    }

    func testImageCancellationRollsBackNewSources() async throws {
        let source = try image {
            $0.setFillColor(UIColor.white.cgColor)
            $0.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        }
        let original = try project(source)
        try ProjectStore.save(original)
        let url = try ProjectStore.sourceURL(original.images[0], in: original.id)
        let task = Task {
            try await MediaWorker.shared.importImages([url], into: original, progress: { _, _ in })
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must throw")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(names, [original.images[0].file])
    }

    func testVisionFindsEmailKeywordAndSplitAddressOnDevice() throws {
        let source = try image(width: 1000, height: 760) { context in
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 1000, height: 760))
            ("Email: alice@example.test" as NSString).draw(
                at: CGPoint(x: 70, y: 90),
                withAttributes: [.font: UIFont.systemFont(ofSize: 42), .foregroundColor: UIColor.black]
            )
            ("PRIVATE_MARKER" as NSString).draw(
                at: CGPoint(x: 70, y: 270),
                withAttributes: [.font: UIFont.systemFont(ofSize: 42), .foregroundColor: UIColor.black]
            )
            ("Home Address" as NSString).draw(
                at: CGPoint(x: 70, y: 450),
                withAttributes: [.font: UIFont.systemFont(ofSize: 38, weight: .semibold), .foregroundColor: UIColor.black]
            )
            ("1234 Market Street Apt 5B" as NSString).draw(
                at: CGPoint(x: 70, y: 550),
                withAttributes: [.font: UIFont.systemFont(ofSize: 38), .foregroundColor: UIColor.black]
            )
        }
        var p = try project(source)
        p.privacy.enabledKinds = [.email, .keyword, .address]
        p.privacy.keywords = ["PRIVATE_MARKER"]
        let report = try PrivacyScanner.scan(p, progress: { _, _ in })
        XCTAssertTrue(report.warnings.isEmpty)
        XCTAssertTrue(report.masks.contains { $0.kind == .email })
        XCTAssertTrue(report.masks.contains { $0.kind == .keyword })
        XCTAssertTrue(report.masks.contains { $0.kind == .address })
        XCTAssertTrue(report.masks.allSatisfy { $0.rect.isValid && $0.rect.intersection(.unit) == $0.rect })
        p.edit.masks = report.masks
        let persisted = String(decoding: try JSONEncoder().encode(p.edit), as: UTF8.self)
        XCTAssertFalse(persisted.contains("alice"))
        XCTAssertFalse(persisted.contains("Market"))
    }

    @MainActor
    func testQuickTwoScreenshotFlowRemovesFixedBrowserBarsWithoutChangingOverlap() async throws {
        let width = 320
        let bodyHeight = 600
        let topBar = 50
        let bottomBar = 60
        let documentHeight = 950
        let secondOffset = 350

        let document = try makeScrollDocument(width: width, height: documentHeight)
        let firstShot = try makeBrowserScreenshot(
            document: document,
            width: width,
            bodyHeight: bodyHeight,
            topBar: topBar,
            bottomBar: bottomBar,
            offset: 0,
            changingClock: false
        )
        let secondShot = try makeBrowserScreenshot(
            document: document,
            width: width,
            bodyHeight: bodyHeight,
            topBar: topBar,
            bottomBar: bottomBar,
            offset: secondOffset,
            changingClock: true
        )

        let token = UUID().uuidString
        let firstURL = FileManager.default.temporaryDirectory.appendingPathComponent("picsig-quick-\(token)-1.png")
        let secondURL = FileManager.default.temporaryDirectory.appendingPathComponent("picsig-quick-\(token)-2.png")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        try ProjectStore.writeImage(firstShot, to: firstURL)
        try ProjectStore.writeImage(secondShot, to: secondURL)

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
        XCTAssertTrue(
            session.note?.contains("清理检测到的固定状态栏") == true,
            session.note ?? "quick flow never finished"
        )
        XCTAssertEqual(session.project.images.count, 2)

        let first = try XCTUnwrap(session.project.images.first)
        let last = try XCTUnwrap(session.project.images.last)
        let firstCrop = first.automaticCrop ?? first.crop
        let lastCrop = last.automaticCrop ?? last.crop
        let firstTopRemoved = firstCrop.y * first.size.height
        let lastBottomRemoved = (1 - lastCrop.maxY) * last.size.height
        let overlapPixels = last.leadingCut * lastCrop.height * last.size.height

        XCTAssertGreaterThan(firstTopRemoved, 40)
        XCTAssertGreaterThan(lastBottomRemoved, 50)
        XCTAssertGreaterThan(overlapPixels, 235)
        XCTAssertLessThan(overlapPixels, 265)

        let composition = try Composition.build(session.project)
        XCTAssertEqual(composition.size.width, Double(width), accuracy: 0.5)
        XCTAssertEqual(
            composition.size.height,
            Double(documentHeight),
            accuracy: 8,
            "Quick flow must remove outer browser bars without reintroducing overlap pixels"
        )
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

    @MainActor
    func testRenderedTextScreenshotsStitchWithoutRepeatingParagraphs() async throws {
        let width = 600, body = 1100, top = 120, bottom = 100, docHeight = 1760, advance = 660
        let document = try image(width: width, height: docHeight) { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: docHeight))
            for line in 0..<43 {
                let y = CGFloat(18 + line * 40)
                let text = String(format: "%02d  %@", line, ["A screenshot is mostly white space.", "Keep each paragraph exactly once.", "Shipping address and private notes.", "Tap the image text to redact it."][line % 4])
                (text as NSString).draw(at: CGPoint(x: 24, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: 22), .foregroundColor: UIColor.black])
            }
        }
        let first = try makeBrowserScreenshot(document: document, width: width, bodyHeight: body, topBar: top, bottomBar: bottom, offset: 0, changingClock: false)
        let second = try makeBrowserScreenshot(document: document, width: width, bodyHeight: body, topBar: top, bottomBar: bottom, offset: advance, changingClock: true)
        var p = Project(title: "Rendered text regression", kind: .scroll)
        projects.append(p.id); p.layout.breadth = Double(width)
        p.images = [try ProjectStore.addImage(first, project: p.id), try ProjectStore.addImage(second, project: p.id)]
        let report = try await MediaWorker.shared.stitch(p, trimBars: true, progress: { _, _ in })
        XCTAssertEqual(report.uncertain, 0, "A real text layout must not fall back to simple stacking")
        let a = try XCTUnwrap(report.project.images.first), b = try XCTUnwrap(report.project.images.last)
        let cropA = try XCTUnwrap(a.automaticCrop).scaled(to: a.size)
        let cropB = try XCTUnwrap(b.automaticCrop).scaled(to: b.size)
        XCTAssertGreaterThanOrEqual(cropA.y, Double(top - 2))
        XCTAssertLessThan(cropA.y, Double(top + 30), "Must not delete the first paragraph")
        XCTAssertGreaterThanOrEqual(b.size.height - cropB.maxY, Double(bottom - 2))
        let rendered = try Renderer.render(report.project)
        let expectedStart = cropA.y - Double(top)
        let expectedEnd = Double(advance) + cropB.maxY - Double(top)
        XCTAssertEqual(Double(rendered.size.height), expectedEnd - expectedStart, accuracy: 2, "Every content row must occur once")
        for (name, source) in [("TextInput-A", UIImage(cgImage: first)), ("TextInput-B", UIImage(cgImage: second)), ("TextStitched-Result", rendered)] {
            let item = XCTAttachment(image: source); item.name = name; item.lifetime = .keepAlways; add(item)
        }
    }

    func testVisionProtectsAnEntireWrappedAddressBlock() throws {
        let source = try image(width: 1000, height: 600) { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 600))
            let values = ["Shipping Address", "1234 Market Street", "Building 6 Apartment 802", "San Francisco, CA 94103", "Order: TEST-ONLY"]
            for (index, text) in values.enumerated() {
                (text as NSString).draw(at: CGPoint(x: 70, y: 65 + index * 85), withAttributes: [.font: UIFont.systemFont(ofSize: 36), .foregroundColor: UIColor.black])
            }
        }
        var p = try project(source); p.privacy.enabledKinds = [.address]
        let report = try PrivacyScanner.scan(p, progress: { _, _ in })
        let addresses = report.masks.filter { $0.kind == .address }
        for y in [160.0, 245.0, 330.0] {
            XCTAssertTrue(addresses.contains { $0.rect.contains(Point2D(0.1, y / 600)) }, "Address continuation at y=\(y) was missed")
        }
        XCTAssertFalse(addresses.contains { $0.rect.contains(Point2D(0.1, 415.0 / 600)) }, "Must stop at the next form field")
    }
}
