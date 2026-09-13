import SwiftUI
import Observation
import PicSigCore

/// Everything the user can configure once and forget about, persisted as JSON in
/// `UserDefaults`.
@Observable
final class AppSettings {
    var scan: ScanSettings {
        didSet { save() }
    }
    var policy: MaskingPolicy {
        didSet { save() }
    }
    var export: ExportOptions {
        didSet { save() }
    }
    var stitch: StitchPreferences {
        didSet { save() }
    }
    var watermarkText: String {
        didSet { save() }
    }
    var isWatermarkEnabled: Bool {
        didSet { save() }
    }
    /// Scan for private information as soon as an image is imported.
    var scansOnImport: Bool {
        didSet { save() }
    }
    /// Run the verification pass (a second OCR of the masked result) on export.
    var verifiesBeforeExport: Bool {
        didSet { save() }
    }
    var detectsFaces: Bool {
        didSet { save() }
    }
    var detectsBarcodes: Bool {
        didSet { save() }
    }
    /// Salt for pseudonymised replacements. Random per install so two users do not
    /// produce the same fake values for the same input.
    var pseudonymSalt: String {
        didSet { save() }
    }
    var presetID: String {
        didSet { save() }
    }

    struct StitchPreferences: Codable, Equatable {
        var axis: StitchAxis = .vertical
        var trimsFixedRegions: Bool = true
        var keepsHeader: Bool = true
        var keepsFooter: Bool = true
        /// Extra tolerance for noisy sources; maps onto the detector's cost budget.
        var matchTolerance: Double = 14
        var layout: ManualLayoutOptions = .verticalStack
        var canvas: CanvasStyle = .plain
        var videoFramesPerSecond: Double = 4

        var detectorOptions: OverlapDetector.Options {
            var options = OverlapDetector.Options.default
            options.acceptableCost = max(4, matchTolerance)
            return options
        }

        var scrollOptions: ScrollStitchPlanner.Options {
            ScrollStitchPlanner.Options(axis: axis,
                                        detector: detectorOptions,
                                        trimFixedRegions: trimsFixedRegions,
                                        keepHeader: keepsHeader,
                                        keepFooter: keepsFooter)
        }

        var videoOptions: VideoScrollPlanner.Options {
            var detector = OverlapDetector.Options.video
            detector.acceptableCost = max(8, matchTolerance + 8)
            return VideoScrollPlanner.Options(axis: axis,
                                              detector: detector,
                                              trimFixedRegions: trimsFixedRegions,
                                              keepHeader: keepsHeader,
                                              keepFooter: keepsFooter)
        }
    }

    // MARK: - Derived

    var watermark: Watermark? {
        guard isWatermarkEnabled, !watermarkText.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return Watermark(text: watermarkText)
    }

    var coordinator: RedactionCoordinator {
        var visual = VisualDetectionService.Options()
        visual.detectsFaces = detectsFaces
        visual.detectsBarcodes = detectsBarcodes
        return RedactionCoordinator(scanSettings: scan,
                                    policy: policy,
                                    visualOptions: visual,
                                    pseudonymSalt: pseudonymSalt)
    }

    func apply(preset: RedactionPreset) {
        presetID = preset.id
        scan = preset.scanSettings
        policy = preset.policy
    }

    // MARK: - Persistence

    private struct Stored: Codable {
        var scan: ScanSettings
        var policy: MaskingPolicy
        var export: ExportOptions
        var stitch: StitchPreferences
        var watermarkText: String
        var isWatermarkEnabled: Bool
        var scansOnImport: Bool
        var verifiesBeforeExport: Bool
        var detectsFaces: Bool
        var detectsBarcodes: Bool
        var pseudonymSalt: String
        var presetID: String
    }

    private static let storageKey = "PicSig.settings.v1"

    init(scan: ScanSettings = .default,
         policy: MaskingPolicy = .default,
         export: ExportOptions = .default,
         stitch: StitchPreferences = StitchPreferences(),
         watermarkText: String = "",
         isWatermarkEnabled: Bool = false,
         scansOnImport: Bool = true,
         verifiesBeforeExport: Bool = true,
         detectsFaces: Bool = true,
         detectsBarcodes: Bool = true,
         pseudonymSalt: String = UUID().uuidString,
         presetID: String = "chat") {
        self.scan = scan
        self.policy = policy
        self.export = export
        self.stitch = stitch
        self.watermarkText = watermarkText
        self.isWatermarkEnabled = isWatermarkEnabled
        self.scansOnImport = scansOnImport
        self.verifiesBeforeExport = verifiesBeforeExport
        self.detectsFaces = detectsFaces
        self.detectsBarcodes = detectsBarcodes
        self.pseudonymSalt = pseudonymSalt
        self.presetID = presetID
    }

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return AppSettings()
        }
        // The memberwise init assigns before any observer runs, so loading does
        // not write the same blob straight back to disk.
        return AppSettings(scan: stored.scan,
                           policy: stored.policy,
                           export: stored.export,
                           stitch: stored.stitch,
                           watermarkText: stored.watermarkText,
                           isWatermarkEnabled: stored.isWatermarkEnabled,
                           scansOnImport: stored.scansOnImport,
                           verifiesBeforeExport: stored.verifiesBeforeExport,
                           detectsFaces: stored.detectsFaces,
                           detectsBarcodes: stored.detectsBarcodes,
                           pseudonymSalt: stored.pseudonymSalt,
                           presetID: stored.presetID)
    }

    private func save() {
        let stored = Stored(scan: scan,
                            policy: policy,
                            export: export,
                            stitch: stitch,
                            watermarkText: watermarkText,
                            isWatermarkEnabled: isWatermarkEnabled,
                            scansOnImport: scansOnImport,
                            verifiesBeforeExport: verifiesBeforeExport,
                            detectsFaces: detectsFaces,
                            detectsBarcodes: detectsBarcodes,
                            pseudonymSalt: pseudonymSalt,
                            presetID: presetID)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    func resetToDefaults() {
        scan = .default
        policy = .default
        export = .default
        stitch = StitchPreferences()
        isWatermarkEnabled = false
        watermarkText = ""
        scansOnImport = true
        verifiesBeforeExport = true
        detectsFaces = true
        detectsBarcodes = true
        presetID = "chat"
    }
}
