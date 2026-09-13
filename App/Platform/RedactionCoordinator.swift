import UIKit
import PicSigCore

/// Runs the whole masking pipeline: recognise → detect → plan → (render) → verify.
struct RedactionCoordinator {
    var scanSettings: ScanSettings = .default
    var policy: MaskingPolicy = .default
    var textOptions: TextRecognitionService.Options = .default
    var visualOptions: VisualDetectionService.Options = .default
    var pseudonymSalt: String = "picsig"

    struct ScanResult {
        var layout: TextLayout
        var matches: [SensitiveMatch]
        var plan: RedactionPlan
    }

    func scan(image: CGImage) throws -> ScanResult {
        var service = TextRecognitionService()
        service.options = textOptions
        let layout = try service.recognize(cgImage: image)

        let scanner = SensitiveScanner(settings: scanSettings)
        var matches = scanner.scan(layout)

        if visualOptions.detectsFaces || visualOptions.detectsBarcodes {
            var visual = VisualDetectionService()
            visual.options = visualOptions
            matches.append(contentsOf: visual.detect(cgImage: image,
                                                     enabledCategories: scanSettings.enabledCategories))
        }

        matches.sort { lhs, rhs in
            lhs.box.minY == rhs.box.minY ? lhs.box.minX < rhs.box.minX : lhs.box.minY < rhs.box.minY
        }

        return ScanResult(layout: layout,
                          matches: matches,
                          plan: plan(matches: matches, layout: layout, imageSize: image.pixelSize))
    }

    func plan(matches: [SensitiveMatch],
              layout: TextLayout,
              imageSize: PixelSize,
              manualItems: [RedactionItem] = []) -> RedactionPlan {
        RedactionPlanner.plan(matches: matches,
                              layout: layout,
                              policy: policy,
                              imageSize: imageSize,
                              manualItems: manualItems,
                              options: .init(pseudonyms: PseudonymGenerator(salt: pseudonymSalt)))
    }

    /// Re-reads the masked result and reports anything still legible.
    ///
    /// This is the check that turns "I hope the mosaic was strong enough" into a
    /// yes or no answer.
    func verify(rendered: CGImage,
                matches: [SensitiveMatch],
                layout: TextLayout,
                plan: RedactionPlan) throws -> RedactionAudit {
        var service = TextRecognitionService()
        var options = textOptions
        options.computesCharacterBoxes = false
        service.options = options

        let rescanLayout = try service.recognize(cgImage: rendered)
        let rescanned = SensitiveScanner(settings: aggressiveVerificationSettings()).scan(rescanLayout)

        return RedactionVerifier.audit(plan: plan,
                                       matches: matches,
                                       layout: layout,
                                       policy: policy,
                                       rescanned: rescanned)
    }

    /// Verification deliberately looks harder than the original scan: a value that
    /// only *almost* qualified before must still be reported if it survived.
    private func aggressiveVerificationSettings() -> ScanSettings {
        var settings = scanSettings
        settings.minConfidence = max(0.3, scanSettings.minConfidence - 0.2)
        settings.propagateRepeatedValues = false
        return settings
    }
}
