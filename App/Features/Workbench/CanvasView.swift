import SwiftUI
import UIKit
import PicSigCore

/// The image canvas: pinch to zoom, scroll to pan, and draw when a tool is armed.
///
/// Gestures are attached to the untransformed content view, so a touch location
/// divided by the content size is exactly the normalised coordinate the core
/// models use — no inverse transform maths, and therefore no drift between what
/// the user draws and what gets exported.
///
/// Zoom is expressed relative to "fits the width". A long screenshot opens fully
/// visible — that is the only way to judge whether the stitch is right — and can
/// be zoomed anywhere between that and several times the width.
struct CanvasView: View {
    let model: WorkbenchViewModel
    /// Sheets the canvas opens itself: the text editor for a new mark, and the
    /// editor for a mark that was tapped.
    @Binding var sheet: WorkbenchSheet?

    @Environment(\.displayScale) private var displayScale

    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var fittedImageSize: CGSize = .zero
    @State private var strokePoints: [NormalizedPoint] = []
    @State private var dragStart: NormalizedPoint?
    @State private var dragCurrent: NormalizedPoint?

    private let maximumZoom: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                content(containerSize: proxy.size)
                    .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
            }
            .scrollDisabled(model.activeTool.isDrawing)
            .overlay(alignment: .bottomTrailing) {
                if let image = model.composed ?? model.previewBase {
                    zoomControls(imageSize: image.size, container: proxy.size)
                        .padding(12)
                }
            }
            .overlay(alignment: .top) {
                if model.activeTool == .textPick {
                    Text("redact.pickText.hint")
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, 10)
                }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(containerSize: CGSize) -> some View {
        if let image = model.composed ?? model.previewBase {
            let contentSize = fittedSize(for: image.size, container: containerSize)
            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: contentSize.width, height: contentSize.height)

                if model.highlightsMatches {
                    matchOverlay(size: contentSize)
                }
                if model.activeTool == .textPick {
                    textBlockOverlay(size: contentSize)
                }
                pendingOverlay(size: contentSize)
                inProgressOverlay(size: contentSize)
                seamOverlay(size: contentSize)
            }
            .frame(width: contentSize.width, height: contentSize.height)
            .contentShape(Rectangle())
            .modifier(CanvasGestures(isDrawing: model.activeTool.isDrawing,
                                     drawing: canvasGesture(size: contentSize),
                                     onTap: { location in handleTap(location, size: contentSize) }))
            .simultaneousGesture(zoomGesture)
            .padding(8)
            .onAppear { fitWhole(imageSize: image.size, container: containerSize) }
            // A new stitch (or a crop) changes the aspect ratio; the old zoom would
            // leave it half off screen, so start over from "everything visible".
            .onChange(of: image.size) { _, newSize in
                guard newSize != fittedImageSize else { return }
                fitWhole(imageSize: newSize, container: containerSize)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "photo.stack")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("workbench.empty")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        }
    }

    // MARK: - Zoom

    private func fitWidthPoints(container: CGSize) -> CGFloat {
        max(80, container.width - 16)
    }

    private func fittedSize(for imageSize: CGSize, container: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0 else { return .zero }
        let width = fitWidthPoints(container: container) * zoom
        return CGSize(width: width, height: width * imageSize.height / imageSize.width)
    }

    /// Zoom at which the whole image is on screen. Below 1 for anything taller than
    /// the container — which is every long screenshot.
    private func fitWholeZoom(imageSize: CGSize, container: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0, container.height > 16 else { return 1 }
        let widthAtFit = fitWidthPoints(container: container)
        let heightAtFit = widthAtFit * imageSize.height / imageSize.width
        return min(1, (container.height - 16) / heightAtFit)
    }

    private func minimumZoom(imageSize: CGSize, container: CGSize) -> CGFloat {
        // Allow a little past "fits" so the image never feels stuck to the edges.
        fitWholeZoom(imageSize: imageSize, container: container) * 0.8
    }

    private func fitWhole(imageSize: CGSize, container: CGSize) {
        fittedImageSize = imageSize
        zoom = fitWholeZoom(imageSize: imageSize, container: container)
        committedZoom = zoom
    }

    /// Scale of the image on screen relative to its own pixels, which is what a
    /// percentage should mean: 100% is one image pixel per device pixel.
    private func pixelPercent(imageSize: CGSize, container: CGSize) -> Int {
        guard imageSize.width > 0 else { return 100 }
        let pointsWide = fitWidthPoints(container: container) * zoom
        let editingPixels = model.previewScale * imageSize.width
        return Int((pointsWide * displayScale / editingPixels * 100).rounded())
    }

    private func zoomControls(imageSize: CGSize, container: CGSize) -> some View {
        let minimum = minimumZoom(imageSize: imageSize, container: container)
        let wholeZoom = fitWholeZoom(imageSize: imageSize, container: container)
        let isWhole = abs(zoom - wholeZoom) < 0.01
        return HStack(spacing: 4) {
            Button {
                withAnimation(.snappy) { setZoom(zoom / 1.5, minimum: minimum) }
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(zoom <= minimum + 0.001)

            Text("\(pixelPercent(imageSize: imageSize, container: container))%")
                .font(.caption.monospacedDigit())
                .frame(width: 44)

            Button {
                withAnimation(.snappy) { setZoom(zoom * 1.5, minimum: minimum) }
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(zoom >= maximumZoom - 0.001)

            Divider().frame(height: 16)

            Button {
                withAnimation(.snappy) { setZoom(isWhole ? 1 : wholeZoom, minimum: minimum) }
            } label: {
                Image(systemName: isWhole ? "arrow.left.and.right" : "arrow.down.right.and.arrow.up.left")
            }
            .accessibilityLabel(isWhole ? "canvas.fitWidth" : "canvas.fitAll")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.thinMaterial, in: Capsule())
    }

    private func setZoom(_ value: CGFloat, minimum: CGFloat) {
        zoom = min(maximumZoom, max(minimum, value))
        committedZoom = zoom
    }

    /// Pinching multiplies the zoom that was in effect when the gesture started, so
    /// two successive pinches compound the way they do in Photos.
    ///
    /// Zooming is disabled while a tool is armed: a drawing drag and a pinch both
    /// begin as touches on the canvas, and letting them compete makes precise marks
    /// impossible.
    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard !model.activeTool.isDrawing else { return }
                let floor = fittedImageSize == .zero ? 0.1 : 0.05
                zoom = min(maximumZoom, max(floor, committedZoom * value.magnification))
            }
            .onEnded { _ in
                committedZoom = zoom
            }
    }

    // MARK: - Overlays

    private func matchOverlay(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.matches) { match in
                let rect = match.box.cgRect(in: size)
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(color(for: match), lineWidth: match.isEnabled ? 1.5 : 1)
                    .background {
                        if !match.isEnabled {
                            Color.clear
                        } else {
                            color(for: match).opacity(0.12)
                        }
                    }
                    .frame(width: max(rect.width, 3), height: max(rect.height, 3))
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
            }
        }
    }

    private func color(for match: SensitiveMatch) -> Color {
        guard match.isEnabled else { return .gray }
        switch match.category.severity {
        case .high: return .red
        case .medium: return .orange
        case .low: return .blue
        }
    }

    /// Shows where two screenshots were joined, so a wrong seam is easy to spot.
    ///
    /// A horizontal stitch measures its seams along X, so the marker is a vertical
    /// line in that case.
    @ViewBuilder
    private func seamOverlay(size: CGSize) -> some View {
        let isVertical = model.plan.axis.isVertical
        ZStack(alignment: .topLeading) {
            ForEach(Array(model.seamMarkers.enumerated()), id: \.offset) { _, marker in
                Rectangle()
                    .fill(marker.needsReview ? Color.orange : Color.green.opacity(0.7))
                    .frame(width: isVertical ? size.width : 1.5,
                           height: isVertical ? 1.5 : size.height)
                    .offset(x: isVertical ? 0 : CGFloat(marker.fraction) * size.width,
                            y: isVertical ? CGFloat(marker.fraction) * size.height : 0)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Marks committed to the document but not yet in the composed bitmap. Drawn
    /// with the same renderer the export uses, so the hand-off from "just drawn"
    /// to "baked in" is invisible — no flash while the compose catches up.
    @ViewBuilder
    private func pendingOverlay(size: CGSize) -> some View {
        let pending = model.pendingAnnotations
        if !pending.isEmpty, size.width > 0, size.height > 0 {
            PendingAnnotationsOverlay(annotations: pending, size: size, scale: displayScale)
                .allowsHitTesting(false)
        }
    }

    private func inProgressOverlay(size: CGSize) -> some View {
        Canvas { context, _ in
            let tool = model.activeTool
            let color = model.strokeColor.uiColor
            let lineWidth = max(1, model.strokeWidth * size.width)

            if let annotationTool = tool.annotationTool, !strokePoints.isEmpty {
                var path = Path()
                let points = strokePoints.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                if annotationTool.usesTwoPoints, points.count >= 2 {
                    let rect = CGRect(x: min(points[0].x, points[1].x),
                                      y: min(points[0].y, points[1].y),
                                      width: abs(points[1].x - points[0].x),
                                      height: abs(points[1].y - points[0].y))
                    switch annotationTool {
                    case .rectangle: path.addRoundedRect(in: rect, cornerSize: CGSize(width: 3, height: 3))
                    case .ellipse: path.addEllipse(in: rect)
                    default:
                        path.move(to: points[0])
                        path.addLine(to: points[1])
                    }
                } else {
                    path.move(to: points[0])
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
                context.stroke(path,
                               with: .color(Color(color).opacity(annotationTool == .highlighter ? 0.4 : 1)),
                               lineWidth: annotationTool == .highlighter ? lineWidth * 3 : lineWidth)
            }

            if tool == .redactionBox || tool == .cropBox,
               let start = dragStart, let current = dragCurrent {
                let rect = CGRect(x: min(start.x, current.x) * size.width,
                                  y: min(start.y, current.y) * size.height,
                                  width: abs(current.x - start.x) * size.width,
                                  height: abs(current.y - start.y) * size.height)
                let color: Color = tool == .redactionBox ? .black : .accentColor
                context.fill(Path(rect), with: .color(color.opacity(tool == .redactionBox ? 0.55 : 0.15)))
                context.stroke(Path(rect), with: .color(color), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
        .frame(width: size.width, height: size.height)
    }

    /// Every recognised line of text, so one tap can mask it. Lines that already
    /// carry a mask are shown filled, the rest as a thin outline.
    private func textBlockOverlay(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.textBlocks) { block in
                let rect = block.box.cgRect(in: size)
                let masked = model.isTextBlockMasked(block)
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(masked ? Color.black : Color.accentColor.opacity(0.8), lineWidth: 1)
                    .background {
                        (masked ? Color.black.opacity(0.35) : Color.accentColor.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                    .frame(width: max(rect.width, 3), height: max(rect.height, 3))
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Gestures

    /// Attaches the drawing drag only while a tool is armed. A drag recogniser with
    /// no minimum distance competes with the scroll view for every touch, so having
    /// it installed in view mode is what made the canvas feel stuck; a plain tap is
    /// all view mode needs.
    private struct CanvasGestures<Drawing: Gesture>: ViewModifier {
        let isDrawing: Bool
        let drawing: Drawing
        let onTap: (CGPoint) -> Void

        func body(content: Content) -> some View {
            if isDrawing {
                content.gesture(drawing)
            } else {
                content.onTapGesture(count: 1, coordinateSpace: .local) { location in onTap(location) }
            }
        }
    }

    private func handleTap(_ location: CGPoint, size: CGSize) {
        let point = normalized(location, in: size)
        switch model.activeTool {
        case .textPick:
            model.toggleTextBlock(at: point)
        case .none:
            if !toggleMatch(at: point), let hit = model.annotation(at: point) {
                sheet = .editAnnotation(hit.id)
            }
        default:
            break
        }
    }

    private func canvasGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let point = normalized(value.location, in: size)
                switch model.activeTool {
                case .none, .textPick:
                    break
                case .annotation(let tool):
                    if tool == .text || tool == .numberBadge { break }
                    if tool.usesTwoPoints {
                        if strokePoints.isEmpty {
                            strokePoints = [point, point]
                        } else {
                            strokePoints[1] = point
                        }
                    } else {
                        strokePoints.append(point)
                    }
                case .redactionBox, .cropBox:
                    if dragStart == nil { dragStart = point }
                    dragCurrent = point
                }
            }
            .onEnded { value in
                let point = normalized(value.location, in: size)
                defer {
                    strokePoints = []
                    dragStart = nil
                    dragCurrent = nil
                }

                switch model.activeTool {
                case .none, .textPick:
                    break
                case .annotation(let tool):
                    switch tool {
                    case .text:
                        sheet = .newText(point)
                    case .numberBadge:
                        model.commitAnnotation(Annotation(tool: .numberBadge,
                                                          points: [point],
                                                          color: model.strokeColor,
                                                          lineWidth: model.strokeWidth,
                                                          fontSize: model.fontSize,
                                                          number: model.document.state.nextBadgeNumber))
                    default:
                        let points = tool.usesTwoPoints
                            ? [strokePoints.first ?? point, point]
                            : strokePoints
                        guard points.count >= 2 else { break }
                        model.commitAnnotation(Annotation(tool: tool,
                                                          points: points,
                                                          color: model.strokeColor,
                                                          lineWidth: model.strokeWidth,
                                                          isFilled: model.isShapeFilled,
                                                          fontSize: model.fontSize))
                    }
                case .redactionBox:
                    guard let start = dragStart else { break }
                    model.addManualRedaction(box: rect(from: start, to: point))
                case .cropBox:
                    guard let start = dragStart else { break }
                    model.applyCrop(rect(from: start, to: point))
                    model.activeTool = .none
                }
            }
    }

    private func normalized(_ point: CGPoint, in size: CGSize) -> NormalizedPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        return NormalizedPoint(x: min(1, max(0, point.x / size.width)),
                               y: min(1, max(0, point.y / size.height)))
    }

    private func rect(from start: NormalizedPoint, to end: NormalizedPoint) -> NormalizedRect {
        NormalizedRect(x: min(start.x, end.x),
                       y: min(start.y, end.y),
                       width: abs(end.x - start.x),
                       height: abs(end.y - start.y))
            .clampedToUnitSpace()
    }

    /// Tapping a highlighted value in view mode turns its mask on or off, which is
    /// much faster than hunting for the row in the list.
    @discardableResult
    private func toggleMatch(at point: NormalizedPoint) -> Bool {
        guard model.highlightsMatches else { return false }
        let hit = model.matches.first { match in
            match.box.expanded(byX: 0.004, byY: 0.004)
                .intersects(NormalizedRect(x: point.x, y: point.y, width: 0.0005, height: 0.0005))
        }
        guard let hit else { return false }
        model.setMatch(hit.id, enabled: !hit.isEnabled)
        return true
    }
}

/// Rasterises a handful of annotations at screen size with `AnnotationRenderer`.
private struct PendingAnnotationsOverlay: View {
    let annotations: [Annotation]
    let size: CGSize
    let scale: CGFloat

    var body: some View {
        Image(uiImage: render())
            .frame(width: size.width, height: size.height)
    }

    private func render() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            AnnotationRenderer.draw(annotations: annotations, in: size, context: context)
        }
    }
}
