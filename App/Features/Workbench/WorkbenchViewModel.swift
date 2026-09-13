import SwiftUI
import Observation
import PicSigCore

/// Tool currently armed in the canvas.
enum EditorTool: Equatable {
    case none
    case annotation(AnnotationTool)
    case redactionBox
    case cropBox

    var annotationTool: AnnotationTool? {
        if case .annotation(let tool) = self { return tool }
        return nil
    }

    var isDrawing: Bool { self != .none }
}

enum StitchMode: String, CaseIterable, Identifiable {
    /// Detect the overlap between screenshots.
    case auto
    /// Just place them next to each other, grid included.
    case manual
    /// Assemble a screen recording.
    case video

    var id: String { rawValue }
    var localizationKey: String { "stitch.mode.\(rawValue)" }
}

@MainActor
@Observable
final class WorkbenchViewModel {
    // MARK: Inputs

    private(set) var sources: [CGImage] = []
    private(set) var videoURL: URL?
    private(set) var mode: StitchMode = .auto

    // MARK: Stitching

    var preferences: AppSettings.StitchPreferences
    private(set) var plan: StitchPlan = .empty
    private(set) var stitched: UIImage?
    /// Downscaled copy the editor draws on; annotations are normalised so the
    /// export still uses the full resolution image.
    private(set) var previewBase: UIImage?
    private(set) var composed: UIImage?
    private var manualOverlaps: [Int: Int] = [:]

    // MARK: Editing

    var document = EditDocument()
    var activeTool: EditorTool = .none
    var strokeColor: RGBAColor = .red
    var strokeWidth: Double = 0.006
    var fontSize: Double = 0.035
    var isShapeFilled = false
    var pendingText = ""

    // MARK: Redaction

    private(set) var layout: TextLayout = .empty
    private(set) var matches: [SensitiveMatch] = []
    private(set) var audit: RedactionAudit?
    var isScanning = false
    var highlightsMatches = true
    /// Draws a line on the canvas at every seam, so a bad alignment is visible
    /// without hunting for it.
    var showsSeams = false
    /// Set when the canvas was rebuilt after a scan, so the panel can offer a
    /// rescan instead of showing results that no longer line up.
    private(set) var needsRescan = false
    private(set) var hasScannedOnce = false

    // MARK: Status

    var statusKey: LocalizedStringKey?
    var progress: Double?
    var errorMessage: String?
    var exportedFiles: [URL] = []
    /// Number of images the last "save to Photos" wrote, so the panel can confirm it
    /// happened — otherwise saving looks like nothing at all.
    var savedPageCount: Int?
    var isBusy: Bool { statusKey != nil }

    private var settings: AppSettings
    private var recomposeTask: Task<Void, Never>?
    private var adjustmentBaseline: ImageAdjustments?
    /// Bumped on every rebuild so results of a superseded stitch or scan can be
    /// dropped instead of being applied to a canvas they no longer describe.
    private var canvasGeneration = 0

    init(settings: AppSettings) {
        self.settings = settings
        self.preferences = settings.stitch
    }

    // MARK: - Loading

    func load(_ request: WorkbenchRequest) async {
        switch request.source {
        case .images(let boxes):
            sources = boxes.map(\.image)
            mode = boxes.count > 1 ? .auto : .manual
            await restitch()
        case .video(let url):
            videoURL = url
            mode = .video
            await loadVideoFrames(url)
        }
    }

    private func loadVideoFrames(_ url: URL) async {
        statusKey = "workbench.status.extracting"
        progress = 0
        var sampler = VideoFrameSampler()
        sampler.options = VideoFrameSampler.Options(framesPerSecond: preferences.videoFramesPerSecond)

        do {
            let frames = try await sampler.frames(from: url) { [weak self] value in
                Task { @MainActor in self?.progress = value }
            }
            sources = frames
            progress = nil
            guard !frames.isEmpty else {
                statusKey = nil
                errorMessage = NSLocalizedString("workbench.error.noFrames", comment: "")
                return
            }
            await restitch()
        } catch {
            statusKey = nil
            progress = nil
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Stitching

    func restitch() async {
        guard !sources.isEmpty else { return }
        canvasGeneration += 1
        let generation = canvasGeneration
        statusKey = "workbench.status.stitching"
        let boxes = sources.map(CGImageBox.init)
        let mode = self.mode
        let preferences = self.preferences
        let overlaps = manualOverlaps

        let result = await Task.detached(priority: .userInitiated) { () -> (StitchPlan, ImageBox?) in
            StitchPipeline.build(sources: boxes,
                                 mode: mode,
                                 preferences: preferences,
                                 manualOverlaps: overlaps)
        }.value

        // Toggling two settings quickly starts two rebuilds; only the newest one
        // may touch the canvas, or the older result would win the race.
        guard generation == canvasGeneration else { return }

        plan = result.0
        stitched = result.1?.image
        previewBase = stitched?.resized(longestEdge: 2600)
        statusKey = nil

        if plan.isEmpty {
            errorMessage = NSLocalizedString("workbench.error.stitchFailed", comment: "")
        }

        // The canvas changed, so every box that referred to the old one is stale.
        matches = []
        layout = .empty
        audit = nil
        document.replaceAutomaticRedactions(with: [])
        await recompose()

        if settings.scansOnImport && !hasScannedOnce {
            await scanForSensitiveInformation()
        } else if hasScannedOnce {
            needsRescan = true
        }
    }

    func setMode(_ newMode: StitchMode) {
        guard newMode != mode else { return }
        mode = newMode
        Task { await restitch() }
    }

    func updatePreferences(_ mutate: (inout AppSettings.StitchPreferences) -> Void) {
        var copy = preferences
        mutate(&copy)
        guard copy != preferences else { return }
        // A different sample rate means different frames, so the recording has to
        // be read again; everything else only changes how the frames are joined.
        let needsResampling = copy.videoFramesPerSecond != preferences.videoFramesPerSecond
        preferences = copy
        settings.stitch = copy
        Task {
            if needsResampling, mode == .video, let videoURL {
                await loadVideoFrames(videoURL)
            } else {
                await restitch()
            }
        }
    }

    func moveSource(from source: IndexSet, to destination: Int) {
        sources.move(fromOffsets: source, toOffset: destination)
        manualOverlaps.removeAll()
        Task { await restitch() }
    }

    func removeSource(at index: Int) {
        guard sources.indices.contains(index) else { return }
        sources.remove(at: index)
        manualOverlaps.removeAll()
        Task { await restitch() }
    }

    func reverseSources() {
        sources.reverse()
        manualOverlaps.removeAll()
        Task { await restitch() }
    }

    /// Nudges a seam by hand when the automatic alignment is not convincing.
    func adjustOverlap(forJoinAt index: Int, by delta: Int) {
        guard plan.joins.indices.contains(index) else { return }
        let join = plan.joins[index]
        let current = manualOverlaps[join.nextIndex] ?? join.overlap
        manualOverlaps[join.nextIndex] = max(0, current + delta)
        Task { await restitch() }
    }

    func resetOverlaps() {
        guard !manualOverlaps.isEmpty else { return }
        manualOverlaps.removeAll()
        Task { await restitch() }
    }

    var hasManualOverlaps: Bool { !manualOverlaps.isEmpty }

    /// Seam nudging works by re-running the pairwise overlap search with a fixed
    /// overlap, which only the screenshot planner does. A recording is assembled
    /// from absolute scroll positions, so there is no per-pair overlap to override
    /// and the buttons would silently do nothing.
    var canAdjustSeams: Bool { mode == .auto }

    /// Where to draw the seam markers, as a fraction along the stitch axis.
    ///
    /// The plan describes the *stitched* image, while the canvas shows the cropped,
    /// rotated and mirrored one, so the markers only line up while the geometry is
    /// untouched. Rather than draw them in the wrong place, they are withheld.
    var seamMarkers: [(fraction: Double, needsReview: Bool)] {
        guard showsSeams, !plan.joins.isEmpty else { return [] }
        guard document.state.crop == .full,
              document.state.normalizedQuarterTurns == 0,
              !document.state.isMirrored else { return [] }
        let length = plan.axis.isVertical ? plan.canvasSize.height : plan.canvasSize.width
        guard length > 0 else { return [] }
        return plan.joins.map { (Double($0.canvasPosition) / Double(length), $0.needsReview) }
    }

    /// True when seams exist but the current crop or rotation means they cannot be
    /// drawn, so the panel can say why the toggle appears to do nothing.
    var seamMarkersHiddenByGeometry: Bool {
        showsSeams && !plan.joins.isEmpty && seamMarkers.isEmpty
    }

    // MARK: - Composition

    func scheduleRecompose() {
        recomposeTask?.cancel()
        recomposeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self?.recompose()
        }
    }

    func recompose() async {
        guard let base = previewBase else {
            composed = nil
            return
        }
        let box = ImageBox(base)
        let state = document.state
        let result = await Task.detached(priority: .userInitiated) { () -> ImageBox in
            ImageBox(ImageComposer.compose(base: box.image, state: state))
        }.value
        composed = result.image
    }

    // MARK: - Redaction

    /// Size of the canvas space image, worked out arithmetically because the
    /// masking plan is rebuilt on every checkbox tap and rasterising a cropped
    /// 20000 pixel image that often would be felt.
    var canvasSpaceSize: PixelSize {
        guard let stitched else { return .zero }
        return document.state.canvasSize(for: PixelSize(width: Int(stitched.size.width),
                                                        height: Int(stitched.size.height)))
    }

    /// The image in *canvas space*: cropped, rotated and mirrored, but not yet
    /// masked or annotated.
    ///
    /// Everything the user draws is expressed in this space, and so is everything
    /// the scanner reports — otherwise a mask planned on the uncropped image would
    /// be drawn at the wrong place, because `ImageComposer` crops before it masks.
    private func canvasSpaceImage() -> UIImage? {
        guard let stitched else { return nil }
        var image = stitched
        let state = document.state
        if state.crop != .full {
            image = ImageComposer.cropped(image, to: state.crop)
        }
        if state.quarterTurns != 0 || state.isMirrored {
            image = ImageComposer.oriented(image, quarterTurns: state.quarterTurns, mirrored: state.isMirrored)
        }
        return image
    }

    func scanForSensitiveInformation() async {
        guard let base = canvasSpaceImage(), let cgImage = base.cgImage else { return }
        isScanning = true
        statusKey = "workbench.status.scanning"
        audit = nil
        let generation = canvasGeneration

        let box = CGImageBox(cgImage)
        let coordinator = settings.coordinator
        let result = await Task.detached(priority: .userInitiated) { () -> Result<RedactionCoordinator.ScanResult, Error> in
            do {
                return .success(try coordinator.scan(image: box.image))
            } catch {
                return .failure(error)
            }
        }.value

        // Boxes are relative to the image that was scanned; if it has been
        // restitched meanwhile they would land in the wrong place.
        guard generation == canvasGeneration else {
            isScanning = false
            statusKey = nil
            needsRescan = true
            return
        }

        isScanning = false
        statusKey = nil
        hasScannedOnce = true
        needsRescan = false

        switch result {
        case .success(let scan):
            layout = scan.layout
            matches = scan.matches
            rebuildAutomaticRedactions()
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    func rebuildAutomaticRedactions() {
        let size = canvasSpaceSize
        guard !size.isEmpty else { return }
        let plan = settings.coordinator.plan(matches: matches, layout: layout, imageSize: size)
        document.replaceAutomaticRedactions(with: plan.items)
        audit = nil
        scheduleRecompose()
    }

    func setMatch(_ id: UUID, enabled: Bool) {
        guard let index = matches.firstIndex(where: { $0.id == id }) else { return }
        matches[index].isEnabled = enabled
        rebuildAutomaticRedactions()
    }

    func setCategory(_ category: SensitiveCategory, enabled: Bool) {
        if enabled {
            settings.scan.enabledCategories.insert(category)
        } else {
            settings.scan.enabledCategories.remove(category)
        }
        for index in matches.indices where matches[index].category == category {
            matches[index].isEnabled = enabled
        }
        // The scanner never looked for a category that was off, so switching one on
        // cannot reveal anything until the image is read again. Without this the
        // checkbox looks broken for exactly the categories the user cared enough
        // about to enable.
        if enabled, hasScannedOnce, !matches.contains(where: { $0.category == category }) {
            needsRescan = true
        }
        rebuildAutomaticRedactions()
    }

    /// Panels read the policy through the model so they never have to reach into
    /// the settings object themselves.
    func rule(for category: SensitiveCategory) -> MaskingRule {
        settings.policy.rule(for: category)
    }

    func isEnabled(_ category: SensitiveCategory) -> Bool {
        settings.scan.enabledCategories.contains(category)
    }

    var activePresetID: String { settings.presetID }

    var defaultMaskingStyle: RedactionStyle { settings.policy.defaultRule.style }

    func setDefaultMaskingStyle(_ style: RedactionStyle) {
        var rule = settings.policy.defaultRule
        rule.style = style
        settings.policy.defaultRule = rule
        rebuildAutomaticRedactions()
    }

    func setStyle(_ style: RedactionStyle, for category: SensitiveCategory) {
        var rule = settings.policy.rule(for: category)
        rule.style = style
        settings.policy.setRule(rule, for: category)
        rebuildAutomaticRedactions()
    }

    func setStrength(_ strength: Double, for category: SensitiveCategory) {
        var rule = settings.policy.rule(for: category)
        rule.strength = strength
        settings.policy.setRule(rule, for: category)
        rebuildAutomaticRedactions()
    }

    /// Character level masking: how much of the value stays readable so the row
    /// is still recognisable.
    func setPreserved(leading: Int? = nil, trailing: Int? = nil, for category: SensitiveCategory) {
        let existing = settings.policy.rule(for: category)
        let rule = MaskingRule(style: existing.style,
                               preserveLeading: leading ?? existing.preserveLeading,
                               preserveTrailing: trailing ?? existing.preserveTrailing,
                               strength: existing.strength,
                               stickerSymbol: existing.stickerSymbol)
        settings.policy.setRule(rule, for: category)
        rebuildAutomaticRedactions()
    }

    func apply(preset: RedactionPreset) {
        settings.apply(preset: preset)
        Task { await scanForSensitiveInformation() }
    }

    func enableAllMatches(_ enabled: Bool) {
        for index in matches.indices { matches[index].isEnabled = enabled }
        rebuildAutomaticRedactions()
    }

    func addManualRedaction(box: NormalizedRect) {
        guard box.width > 0.002, box.height > 0.002 else { return }
        var rule = settings.policy.defaultRule
        if rule.style == .replacement { rule.style = .mosaic } // nothing to replace by hand
        document.add(redaction: RedactionItem(box: box,
                                              style: rule.style,
                                              strength: rule.strength,
                                              stickerSymbol: rule.stickerSymbol,
                                              category: .custom,
                                              isManual: true,
                                              valuePreview: NSLocalizedString("redaction.manual", comment: "")))
        audit = nil
        scheduleRecompose()
    }

    func removeRedaction(_ id: UUID) {
        let matchID = document.state.redactions.first(where: { $0.id == id })?.matchID
        document.removeRedaction(id: id)
        if let matchID, let index = matches.firstIndex(where: { $0.id == matchID }) {
            // Keep the match list in sync, otherwise the next rebuild puts the mask
            // straight back.
            matches[index].isEnabled = false
        }
        audit = nil
        scheduleRecompose()
    }

    var matchesByCategory: [(category: SensitiveCategory, matches: [SensitiveMatch])] {
        Dictionary(grouping: matches, by: \.category)
            .map { (category: $0.key, matches: $0.value) }
            .sorted { lhs, rhs in
                lhs.category.severity == rhs.category.severity
                    ? lhs.matches.count > rhs.matches.count
                    : lhs.category.severity > rhs.category.severity
            }
    }

    var enabledMatchCount: Int { matches.filter(\.isEnabled).count }

    /// Renders the final image and reads it back to prove nothing sensitive
    /// survived.
    func verifyRedaction() async {
        guard let stitched else { return }
        statusKey = "workbench.status.verifying"
        let generation = canvasGeneration
        let base = ImageBox(stitched)
        let state = document.state
        let coordinator = settings.coordinator
        let currentMatches = matches
        let currentLayout = layout

        let result = await Task.detached(priority: .userInitiated) { () -> Result<RedactionAudit, Error> in
            let rendered = ImageComposer.compose(base: base.image, state: state)
            guard let cgImage = rendered.cgImage else {
                return .failure(ExportError.noImage)
            }
            let plan = RedactionPlan(items: state.redactions,
                                     imageSize: PixelSize(width: cgImage.width, height: cgImage.height))
            do {
                return .success(try coordinator.verify(rendered: cgImage,
                                                       matches: currentMatches,
                                                       layout: currentLayout,
                                                       plan: plan))
            } catch {
                return .failure(error)
            }
        }.value

        statusKey = nil
        guard generation == canvasGeneration else { return }
        switch result {
        case .success(let audit): self.audit = audit
        case .failure(let error): errorMessage = error.localizedDescription
        }
    }

    // MARK: - Annotations

    func commitAnnotation(_ annotation: Annotation) {
        document.add(annotation)
        scheduleRecompose()
    }

    func undoLastStroke() {
        document.undoLastStroke()
        scheduleRecompose()
    }

    func clearAnnotations() {
        document.clearAnnotations()
        scheduleRecompose()
    }

    func removeAnnotation(_ id: UUID) {
        document.removeAnnotation(id: id)
        scheduleRecompose()
    }

    func undo() {
        guard document.undo() else { return }
        scheduleRecompose()
    }

    func redo() {
        guard document.redo() else { return }
        scheduleRecompose()
    }

    /// Slider drags update the preview without touching the undo stack; the whole
    /// gesture becomes a single undo step when it ends.
    func beginAdjusting() {
        guard adjustmentBaseline == nil else { return }
        adjustmentBaseline = document.state.adjustments
    }

    func setAdjustments(_ mutate: (inout ImageAdjustments) -> Void) {
        beginAdjusting()
        document.previewChange { mutate(&$0.adjustments) }
        scheduleRecompose()
    }

    func commitAdjustments() {
        guard let baseline = adjustmentBaseline else { return }
        adjustmentBaseline = nil
        let current = document.state.adjustments
        guard current != baseline else { return }
        document.previewChange { $0.adjustments = baseline }
        document.apply { $0.adjustments = current }
    }

    func resetAdjustments() {
        document.apply { $0.adjustments = .neutral }
        scheduleRecompose()
    }

    /// The crop is stored in base space while the user draws in canvas space, so
    /// the drawn rectangle has to travel back through the rotation, the mirroring
    /// and any earlier crop first.
    func applyCrop(_ rect: NormalizedRect) {
        let crop = document.state.baseSpaceRect(rect)
        applyGeometryChange { $0.crop = crop.clampedToUnitSpace() }
    }

    func resetCrop() {
        applyGeometryChange { $0.crop = .full }
    }

    var isCropped: Bool { document.state.crop != .full }

    func rotate() {
        applyGeometryChange { $0.quarterTurns = (($0.quarterTurns + 1) % 4 + 4) % 4 }
    }

    func mirror() {
        applyGeometryChange { $0.isMirrored.toggle() }
    }

    /// Cropping, rotating or mirroring redefines canvas space.
    ///
    /// Marks the user drew are moved with the content by `applyGeometryChange`, but
    /// the scan results cannot be: their boxes came from OCR on the old canvas and
    /// the character offsets no longer describe anything, so they are dropped and a
    /// rescan is offered. Clearing them has to happen inside the same mutation, or
    /// undoing once would restore the masks under the new geometry.
    private func applyGeometryChange(_ mutate: (inout EditState) -> Void) {
        let hadFindings = !matches.isEmpty
        let changed = document.applyGeometryChange { state in
            mutate(&state)
            if hadFindings { state.redactions.removeAll { !$0.isManual } }
        }
        guard changed else { return }

        if hadFindings {
            matches = []
            layout = .empty
            needsRescan = true
        }
        audit = nil
        scheduleRecompose()
    }

    func setWatermark(_ watermark: Watermark?) {
        document.apply { $0.watermark = watermark }
        scheduleRecompose()
    }

    func setCanvasStyle(_ style: CanvasStyle) {
        document.apply { $0.canvas = style }
        scheduleRecompose()
    }

    // MARK: - Export

    /// Export options live in the settings so they are remembered between
    /// sessions; the panel edits them through here.
    var exportOptions: ExportOptions {
        get { settings.export }
        set { settings.export = newValue }
    }

    /// Size of the image that will actually be written, after crop and scaling.
    var exportSize: PixelSize {
        settings.export.scale.targetSize(for: canvasSpaceSize)
    }

    func export(saveToPhotos: Bool) async {
        guard let stitched else { return }
        statusKey = saveToPhotos ? "workbench.status.saving" : "workbench.status.exporting"
        savedPageCount = nil

        var state = document.state
        if state.watermark == nil, let watermark = settings.watermark {
            state.watermark = watermark
        }
        let base = ImageBox(stitched)
        let options = settings.export
        let shouldVerify = settings.verifiesBeforeExport && !matches.isEmpty
        let coordinator = settings.coordinator
        let currentMatches = matches
        let currentLayout = layout

        let outcome = await Task.detached(priority: .userInitiated) { () async -> Result<ExportOutcome, Error> in
            let rendered = ImageComposer.compose(base: base.image, state: state)
            var verification: RedactionAudit?
            if shouldVerify, let cgImage = rendered.cgImage {
                let plan = RedactionPlan(items: state.redactions,
                                         imageSize: PixelSize(width: cgImage.width, height: cgImage.height))
                verification = try? coordinator.verify(rendered: cgImage,
                                                       matches: currentMatches,
                                                       layout: currentLayout,
                                                       plan: plan)
            }
            do {
                let output = try ImageExporter.write(rendered,
                                                     options: options,
                                                     baseName: "PicSig-\(Int(Date().timeIntervalSince1970))")
                if saveToPhotos {
                    try await ImageExporter.saveToPhotoLibrary(output.pages, options: options)
                }
                return .success(ExportOutcome(files: output.files + (output.pdf.map { [$0] } ?? []),
                                              pageCount: output.pages.count,
                                              audit: verification))
            } catch {
                return .failure(error)
            }
        }.value

        statusKey = nil
        switch outcome {
        case .success(let result):
            if let verification = result.audit { audit = verification }
            // Saving to the library is the whole action; handing the files to the
            // share sheet as well would put a second screen in front of the user who
            // just wanted the image in Photos.
            if saveToPhotos {
                savedPageCount = result.pageCount
            } else {
                exportedFiles = result.files
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
}

/// Result of an export, containing only values that are safe to hand back to the
/// main actor.
private struct ExportOutcome: Sendable {
    let files: [URL]
    let pageCount: Int
    let audit: RedactionAudit?
}

/// The heavy lifting, kept off the main actor.
private enum StitchPipeline {
    static func build(sources: [CGImageBox],
                      mode: StitchMode,
                      preferences: AppSettings.StitchPreferences,
                      manualOverlaps: [Int: Int]) -> (StitchPlan, ImageBox?) {
        let images = sources.map(\.image)
        guard !images.isEmpty else { return (.empty, nil) }

        let plan: StitchPlan
        switch mode {
        case .manual:
            plan = ManualLayoutPlanner.plan(sizes: images.map(\.pixelSize), options: preferences.layout)
        case .auto, .video:
            // Alignment runs on grayscale copies. 1600 pixels is wider than any
            // current phone screenshot, so this is normally lossless.
            let maxWidth = 1600
            let grays = images.compactMap { $0.grayImage(maxWidth: maxWidth) }
            guard grays.count == images.count, let firstGray = grays.first, let firstImage = images.first else {
                return (.empty, nil)
            }
            let scale = Double(firstImage.width) / Double(max(1, firstGray.width))
            let detectionPlan: StitchPlan
            if mode == .video {
                detectionPlan = VideoScrollPlanner.plan(frames: grays, options: preferences.videoOptions)
            } else {
                // Seam nudges are stored in full resolution pixels, because that is
                // what the seam inspector shows; the planner works on the downscaled
                // copies, so they have to come back down first.
                let detectionOverlaps = manualOverlaps.mapValues {
                    max(0, Int((Double($0) / scale).rounded()))
                }
                detectionPlan = ScrollStitchPlanner.plan(images: grays,
                                                         manualOverlaps: detectionOverlaps,
                                                         options: preferences.scrollOptions)
            }
            plan = detectionPlan.scaled(byX: scale, byY: scale)
        }

        let rendered: UIImage?
        if mode == .manual, !preferences.canvas.isPlain {
            rendered = StitchRenderer.renderStyled(plan: plan, sources: images, style: preferences.canvas)
        } else {
            rendered = StitchRenderer.render(plan: plan,
                                             sources: images,
                                             background: preferences.canvas.backgroundColor)
        }
        return (plan, rendered.map(ImageBox.init))
    }
}
