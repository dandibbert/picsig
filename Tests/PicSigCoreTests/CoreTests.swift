import XCTest
@testable import PicSigCore

final class CoreTests: XCTestCase {
    func project(_ kind: ProjectKind = .scroll) -> Project {
        var p = Project(title: "Test", kind: kind)
        p.layout = LayoutOptions(); p.layout.breadth = 1000
        p.images = [SourceImage(file: "a.png", size: Size2D(1000, 2000)), SourceImage(file: "b.png", size: Size2D(1000, 2000))]
        return p
    }
    func testVerticalOverlap() throws {
        var p = project(); p.images[1].leadingCut = 0.25
        let layout = try Composition.build(p)
        XCTAssertEqual(layout.size, Size2D(1000, 3500))
        XCTAssertEqual(layout.placements[1].source, Box(0, 500, 1000, 1500))
        XCTAssertEqual(layout.placements[1].destination.y, 2000)
    }
    func testHorizontalUsesHeight() throws {
        let p = project(.horizontal)
        let layout = try Composition.build(p)
        XCTAssertEqual(layout.size, Size2D(1000, 1000))
        XCTAssertEqual(layout.placements[1].destination.x, 500)
    }
    func testFirstImageNeverCut() throws {
        var p = project(); p.images[0].leadingCut = 0.9
        XCTAssertEqual(try Composition.build(p).placements[0].source.height, 2000)
    }
    func testCropBeforeOverlap() throws {
        var p = project(); p.images[1].crop = Box(0, 0.1, 1, 0.8); p.images[1].leadingCut = 0.5
        XCTAssertEqual(try Composition.build(p).placements[1].source, Box(0, 1000, 1000, 800))
    }
    func testAutomaticCropDoesNotMutateManualCrop() throws {
        var p = project(); p.images[0].automaticCrop = Box(0, 0, 1, 0.9)
        XCTAssertEqual(try Composition.build(p).placements[0].source.height, 1800)
        XCTAssertEqual(p.images[0].crop, .unit)
    }
    func testMarginsGaps() throws {
        var p = project(); p.layout.margin = 10; p.layout.gap = 20
        XCTAssertEqual(try Composition.build(p).size, Size2D(1020, 4040))
    }
    func testInvalidGeometry() {
        var p = project(); p.images[1].size = Size2D(.nan, 0)
        XCTAssertThrowsError(try Composition.build(p))
        p = project(); p.images[0].crop = Box(2, 2, 1, 1)
        XCTAssertThrowsError(try Composition.build(p))
        p = project(); p.layout.breadth = .infinity
        XCTAssertThrowsError(try Composition.build(p))
        p = project(); p.images = []
        XCTAssertThrowsError(try Composition.build(p))
    }
    func testBudgetGuard() {
        var p = project(); p.images = [SourceImage(file: "x", size: Size2D(1000, 300000))]
        XCTAssertThrowsError(try Composition.build(p))
    }
    func testRotationMapping() throws {
        let canvas = Size2D(100, 200), crop = Box(0.1, 0.1, 0.8, 0.8)
        let r = try ExportGeometry(canvas: canvas, crop: crop, turns: 1)
        XCTAssertEqual(r.size, Size2D(160, 80))
        XCTAssertEqual(r.sourceRegion(for: Box(0, 0, 20, 10)), Box(10, 160, 10, 20))
        for turns in -4...8 {
            let g = try ExportGeometry(canvas: canvas, crop: crop, turns: turns)
            XCTAssertEqual(g.sourceRegion(for: Box(0, 0, g.size.width, g.size.height)), Box(10, 20, 80, 160))
        }
    }
    func testSlicesCoverCanvasWithoutGaps() throws {
        for size in [Size2D(1200, 22000), Size2D(22000, 1200)] {
            let g = try ExportGeometry(canvas: size)
            let slices = g.slices(maxPixels: 2_000_000)
            XCTAssertEqual(slices.reduce(0) { $0 + $1.area }, size.area)
            XCTAssertTrue(slices.allSatisfy { $0.area <= 2_000_000 })
            for index in 1..<slices.count {
                if size.height > size.width { XCTAssertEqual(slices[index - 1].maxY, slices[index].y) }
                else { XCTAssertEqual(slices[index - 1].maxX, slices[index].x) }
            }
        }
    }
    func testJSONRoundtripWithoutOCRText() throws {
        var p = project()
        p.edit.masks = [PrivacyMask(rect: Box(0.1, 0.2, 0.3, 0.4), kind: .phone)]
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: data), p)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("recognizedText"))
    }
    private func kinds(_ text: String, options: PrivacyOptions = PrivacyOptions()) -> Set<SensitiveKind> {
        Set(PrivacyRules.findings(in: text, options: options).map(\.kind))
    }
    func testChinesePhone() { XCTAssertTrue(kinds("手机：138 0013 8000").contains(.phone)) }
    func testInternationalPhone() { XCTAssertTrue(kinds("Call +1 (415) 555-0132").contains(.phone)) }
    func testEmail() { XCTAssertTrue(kinds("Contact person+demo@example.test").contains(.email)) }
    func testIdentity() { XCTAssertTrue(kinds("11010519491231002X").contains(.identity)) }
    func testUSIdentity() { XCTAssertTrue(kinds("SSN: 000-12-3456").contains(.identity)) }
    func testValidCard() { XCTAssertTrue(kinds("4111 1111 1111 1111").contains(.bankCard)) }
    func testInvalidCardDoesNotTriggerUnlabelled() { XCTAssertFalse(kinds("4111 1111 1111 1112").contains(.bankCard)) }
    func testLabelledCardStillProtectedIfOCRError() { XCTAssertTrue(kinds("卡号：4111 1111 1111 1112").contains(.bankCard)) }
    func testLuhn() {
        XCTAssertTrue(PrivacyRules.isLuhnValid("4111111111111111"))
        XCTAssertFalse(PrivacyRules.isLuhnValid("0000000000000000"))
        XCTAssertFalse(PrivacyRules.isLuhnValid("１２３４"))
    }
    func testAddressAndName() {
        XCTAssertTrue(kinds("收件人：张小明").contains(.name))
        XCTAssertTrue(kinds("地址：上海市示例路100号").contains(.address))
    }
    func testSecrets() {
        for value in ["sk-demo01234567890123456789", "Bearer abcdefghijk0123456789", "验证码：123456", "https://example.test/?token=abcdef123456"] {
            XCTAssertTrue(kinds(value).contains(.secret), value)
        }
    }
    func testIPv4Validation() {
        XCTAssertTrue(kinds("host 192.0.2.42").contains(.ipAddress))
        XCTAssertFalse(kinds("version 999.999.999.999").contains(.ipAddress))
    }
    func testIPv6() { XCTAssertTrue(kinds("2001:db8::1").contains(.ipAddress)) }
    func testCategoryToggle() {
        var options = PrivacyOptions(); options.enabledKinds = [.secret]
        XCTAssertFalse(kinds("13800138000", options: options).contains(.phone))
    }
    func testUnicodeKeywordRangeAndLiteralEscaping() {
        var options = PrivacyOptions(); options.keywords = ["张小明", "a.b+", "🦊"]
        let text = "👨‍👩‍👧‍👦 张小明 a.b+ 🦊"
        let results = PrivacyRules.findings(in: text, options: options).filter { $0.kind == .keyword }
        XCTAssertEqual(Set(results.compactMap { Range($0.range, in: text).map { String(text[$0]) } }), Set(options.keywords))
    }
    func testRepeatedKeywordsAllFound() {
        var options = PrivacyOptions(); options.keywords = ["secretName"]
        XCTAssertEqual(PrivacyRules.findings(in: "secretName and SECRETNAME", options: options).filter { $0.kind == .keyword }.count, 2)
    }
    private func raster(y: Int, height: Int, shift: Int = 0) throws -> GrayRaster {
        var pixels: [UInt8] = []
        for row in y..<(y + height) {
            for x in 0..<48 {
                var seed = UInt64((row + shift) * 104729 + x * 7907 + row * x * 13)
                seed = (seed ^ (seed >> 30)) &* 0xbf58476d1ce4e5b9
                seed = (seed ^ (seed >> 27)) &* 0x94d049bb133111eb
                pixels.append(UInt8(truncatingIfNeeded: seed ^ (seed >> 31)))
            }
        }
        return try GrayRaster(width: 48, height: height, pixels: pixels)
    }
    func testExactOverlap() throws {
        let a = try raster(y: 0, height: 400), b = try raster(y: 173, height: 400)
        let match = OverlapDetector.match(a, b)
        XCTAssertEqual(match?.rows, 227)
        XCTAssertFalse(match?.duplicate ?? true)
    }
    func testDuplicate() throws {
        let a = try raster(y: 0, height: 200)
        XCTAssertTrue(OverlapDetector.match(a, a)?.duplicate == true)
    }
    func testUnrelatedRefuses() throws {
        XCTAssertNil(OverlapDetector.match(try raster(y: 0, height: 200), try raster(y: 5000, height: 200)))
    }
    func testFlatAreasRefuseFalseOverlap() throws {
        let a = try GrayRaster(width: 48, height: 200, pixels: [UInt8](repeating: 255, count: 9600))
        let b = try GrayRaster(width: 48, height: 200, pixels: [UInt8](repeating: 249, count: 9600))
        XCTAssertNil(OverlapDetector.match(a, b))
    }
    func testFixedBars() throws {
        let bodyA = try raster(y: 0, height: 200), bodyB = try raster(y: 120, height: 200)
        let top = [UInt8](repeating: 245, count: 48 * 20), bottom = [UInt8](repeating: 200, count: 48 * 15)
        let a = try GrayRaster(width: 48, height: 235, pixels: top + bodyA.pixels + bottom)
        let b = try GrayRaster(width: 48, height: 235, pixels: top + bodyB.pixels + bottom)
        let insets = OverlapDetector.fixedInsets(a, b)
        XCTAssertEqual(insets.top, 20); XCTAssertEqual(insets.bottom, 15)
    }
    func testFixedBarsIgnoreSmallDynamicStatusText() throws {
        let bodyA = try raster(y: 0, height: 200), bodyB = try raster(y: 120, height: 200)
        let topA = [UInt8](repeating: 245, count: 48 * 20)
        var topB = topA
        for row in 0..<20 {
            for x in 3..<8 { topB[row * 48 + x] = UInt8((row * 17 + x * 31) % 220) }
        }
        let bottom = [UInt8](repeating: 200, count: 48 * 15)
        let a = try GrayRaster(width: 48, height: 235, pixels: topA + bodyA.pixels + bottom)
        let b = try GrayRaster(width: 48, height: 235, pixels: topB + bodyB.pixels + bottom)
        let insets = OverlapDetector.fixedInsets(a, b)
        XCTAssertEqual(insets.top, 20)
        XCTAssertEqual(insets.bottom, 15)
    }

    private func textPage(offset: Int, height: Int, salt: Int = 0) throws -> GrayRaster {
        let width = 96
        var pixels = [UInt8](repeating: 250, count: width * height)
        for y in 0..<height {
            let row = y + offset, line = row / 47, glyphY = row % 47
            guard glyphY >= 9, glyphY < 23 else { continue }
            for x in 9..<87 {
                let char = x / 5, gx = x % 5
                let seed = (line + 1) &* 73856093 ^ (char + salt) &* 19349663
                if gx < 3, ((seed >> ((glyphY + gx) % 17)) & 1) == 1 {
                    pixels[y * width + x] = 50
                }
            }
        }
        return try GrayRaster(width: width, height: height, pixels: pixels)
    }
    func testSparseWhiteTextScreenshotsWithShortAndLongOverlap() throws {
        let a = try textPage(offset: 0, height: 1600)
        for offset in [83, 499, 1217, 1490] {
            let b = try textPage(offset: offset, height: 1600)
            XCTAssertEqual(OverlapDetector.match(a, b)?.rows, 1600 - offset, "Scroll offset \(offset)")
        }
    }
    func testDifferentWhiteTextPagesNeverDiscardContent() throws {
        XCTAssertNil(OverlapDetector.match(try textPage(offset: 0, height: 1300), try textPage(offset: 2000, height: 1300, salt: 791)))
    }
    func testViewportMatchSurvivesDifferentBrowserHeaderHeights() throws {
        let aBody = try textPage(offset: 0, height: 1400)
        let bBody = try textPage(offset: 620, height: 1460)
        let a = try GrayRaster(width: 96, height: 1600, pixels: [UInt8](repeating: 210, count: 96 * 100) + aBody.pixels + [UInt8](repeating: 230, count: 96 * 100))
        let b = try GrayRaster(width: 96, height: 1600, pixels: [UInt8](repeating: 216, count: 96 * 40) + bBody.pixels + [UInt8](repeating: 235, count: 96 * 100))
        XCTAssertEqual(OverlapDetector.viewportMatch(a, b)?.rows, 920)
    }

    func testAddressesWithoutArabicDigitsAndWrappedBlocks() {
        for text in ["上海市浦东新区", "幸福花园三期六幢二单元八零二室", "北京市朝阳区望京街道", "臺北市信義區松仁路一百號", "東京都新宿区西新宿2-8-1", "123 Market St."] {
            XCTAssertTrue(AddressDetector.isAddress(text), text)
        }
        let lines = [
            AddressDetector.Line("收货地址", Box(10, 10, 100, 20)),
            AddressDetector.Line("上海市浦东新区", Box(160, 10, 180, 20)),
            AddressDetector.Line("张江镇祖冲之路", Box(160, 40, 180, 20)),
            AddressDetector.Line("幸福花园六幢二单元", Box(160, 70, 180, 20)),
            AddressDetector.Line("802室", Box(160, 100, 70, 20)),
            AddressDetector.Line("备注：放在门口", Box(160, 130, 180, 20)),
            AddressDetector.Line("商品：儿童画册", Box(160, 200, 180, 20))
        ]
        XCTAssertEqual(AddressDetector.protectedLines(lines), Set([0, 1, 2, 3, 4]))
    }
    func testLastAddressLabelAndSeparateCardsDoNotCrashOrSwallowOtherFields() {
        let lines = [AddressDetector.Line("电话：13800138000", Box(10, 10, 200, 20)), AddressDetector.Line("地址", Box(10, 200, 60, 20))]
        XCTAssertEqual(AddressDetector.protectedLines(lines), [1])
        XCTAssertFalse(AddressDetector.isAddress("产品型号 A1234，版本 2.0"))
        XCTAssertFalse(AddressDetector.isAddress("今天走这条道路很开心"))
    }

    func testLayoutChangesKeepMasksAndAnnotationsAttachedToSource() throws {
        var p = project()
        p.edit.masks = [PrivacyMask(rect: Box(0.1, 0.6, 0.3, 0.05), kind: .manual)]
        p.edit.annotations = [Annotation(kind: .text, points: [Point2D(0.2, 0.7)], text: "Editable")]
        let old = try Composition.build(p)
        p.images.reverse()
        let new = try Composition.build(p)
        let result = EditRemapper.remap(p.edit, from: old, to: new)
        XCTAssertEqual(result.masks.count, 1)
        XCTAssertEqual(result.masks[0].rect.y, 0.1, accuracy: 0.000001)
        XCTAssertEqual(result.annotations[0].points[0].y, 0.2, accuracy: 0.000001)
        XCTAssertEqual(result.annotations[0].id, p.edit.annotations[0].id)
        XCTAssertEqual(result.annotations[0].text, "Editable")
    }
    func testSeamCrossingMaskSplitsRatherThanExposingSourcePixels() throws {
        var p = project(); let old = try Composition.build(p)
        p.edit.masks = [PrivacyMask(rect: Box(0.2, 0.45, 0.5, 0.1), kind: .manual)]
        p.layout.gap = 100
        let result = EditRemapper.remap(p.edit, from: old, to: try Composition.build(p))
        XCTAssertEqual(result.masks.count, 2)
        XCTAssertNotEqual(result.masks[0].id, result.masks[1].id)
        XCTAssertEqual(result.masks[0].groupID, result.masks[1].groupID)
    }
    func testRenderedFontParagraphsLargeAndShortOverlap() throws {
        let folder = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Fixtures")
        let data = [UInt8](try Data(contentsOf: folder.appendingPathComponent("paragraph-page.gray")))
        XCTAssertEqual(data.count, 96 * 2800)
        func viewport(_ offset: Int) throws -> GrayRaster {
            try GrayRaster(width: 96, height: 1100, pixels: Array(data[offset * 96..<(offset + 1100) * 96]))
        }
        for advance in [73, 420, 660, 841, 946, 1011] {
            let match = try XCTUnwrap(OverlapDetector.match(viewport(0), viewport(advance)), "Advance \(advance)")
            XCTAssertEqual(match.rows, 1100 - advance, "Rendered text has an exact pixel translation")
            XCTAssertFalse(match.duplicate)
        }
    }
}
