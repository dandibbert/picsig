import XCTest
import UIKit
@testable import PicSig

final class TextRedactionTests: XCTestCase {
    private var projects: [UUID] = []

    override func tearDown() {
        for id in projects { try? ProjectStore.delete(id) }
        super.tearDown()
    }

    private func image(width: Int = 1000, height: Int = 440, draw: (CGContext) -> Void) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image {
            draw($0.cgContext)
        }.cgImage)
    }

    private func project(_ image: CGImage) throws -> Project {
        var project = Project(title: "OCR tap test", kind: .scroll)
        projects.append(project.id)
        project.images = [try ProjectStore.addImage(image, project: project.id)]
        project.layout.breadth = Double(image.width)
        return project
    }

    func testRecognizedTextReturnsTransientGeometry() throws {
        let source = try image { context in
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 1000, height: 440))
            ("ORDER ALPHA 12345" as NSString).draw(
                at: CGPoint(x: 80, y: 90),
                withAttributes: [.font: UIFont.systemFont(ofSize: 54, weight: .semibold), .foregroundColor: UIColor.black]
            )
            ("PRIVATE NOTE" as NSString).draw(
                at: CGPoint(x: 80, y: 250),
                withAttributes: [.font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.black]
            )
        }
        let p = try project(source)
        let items = try PrivacyScanner.recognizedText(p)
        XCTAssertTrue(items.contains { $0.text.localizedCaseInsensitiveContains("ORDER") })
        XCTAssertTrue(items.contains { $0.text.localizedCaseInsensitiveContains("PRIVATE") })
        XCTAssertTrue(items.allSatisfy { $0.rect.isValid && $0.rect.intersection(.unit) == $0.rect })
        XCTAssertTrue(items.allSatisfy { (0...1).contains($0.confidence) })
    }

    @MainActor
    func testTapTextMaskNeverPersistsRecognizedPlaintext() throws {
        let source = try image { context in
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 1000, height: 440))
        }
        let p = try project(source)
        let session = StudioSession(project: p, stage: .edit)
        let item = RecognizedTextItem(text: "SECRET CUSTOMER NAME", rect: Box(0.1, 0.2, 0.6, 0.12), confidence: 0.98)

        session.toggleTextRedaction(item)
        let mask = try XCTUnwrap(session.textTapMask(for: item))
        XCTAssertTrue(mask.enabled)
        XCTAssertTrue(mask.reviewed)
        XCTAssertEqual(mask.kind, .manual)
        XCTAssertTrue(mask.groupID.hasPrefix("ocrTap:"))

        let json = String(decoding: try JSONEncoder().encode(session.project), as: UTF8.self)
        XCTAssertFalse(json.contains("SECRET CUSTOMER NAME"))
        XCTAssertFalse(json.contains("CUSTOMER NAME"))

        session.toggleTextRedaction(item)
        XCTAssertNil(session.textTapMask(for: item))
    }
}
