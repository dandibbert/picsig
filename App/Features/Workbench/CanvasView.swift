import SwiftUI
import UIKit
import PicSigCore

/// The image canvas: pinch to zoom, scroll to pan, and draw when a tool is armed.
///
/// Gestures are attached to the untransformed content view, so a touch location
/// divided by the content size is exactly the normalised coordinate the core
/// models use — no inverse transform maths, and therefore no drift between what
/// the user draws and what gets exported.
struct CanvasView: View {
    let model: WorkbenchViewModel

    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var strokePoints: [NormalizedPoint] = []
    @State private var dragStart: NormalizedPoint?
    @State private var dragCurrent: NormalizedPoint?
    @State private var textPoint: NormalizedPoint?
    @State private var textInput = ""
    @State private var isTextPromptPresented = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                content(containerSize: proxy.size)
            }
            .scrollDisabled(model.activeTool.isDrawing)
            .overlay(alignment: .bottomTrailing) {
                zoomControls
                    .padding(12)
            }
        }
        .alert("annotate.text.prompt", isPresented: $isTextPromptPresented) {
            TextField("annotate.text.placeholder", text: $textInput)
            Button("common.cancel", role: .cancel) { textInput = "" }
            Button("common.done") { commitText() }
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
                inProgressOverlay(size: contentSize)
                seamOverlay(size: contentSize)
            }
            .frame(width: contentSize.width, height: contentSize.height)
            .contentShape(Rectangle())
            .gesture(canvasGesture(size: contentSize))
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
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

    private func fittedSize(for imageSize: CGSize, container: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0 else { return .zero }
        let width = max(80, container.width - 24) * zoom
        return CGSize(width: width, height: width * imageSize.height / imageSize.width)
    }

    private var zoomControls: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.snappy) { setZoom(zoom - 0.5) }
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            Text(String(format: "%.1f×", zoom))
                .font(.caption.monospacedDigit())
                .frame(width: 38)
            Button {
                withAnimation(.snappy) { setZoom(zoom + 0.5) }
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.thinMaterial, in: Capsule())
    }

    private func setZoom(_ value: CGFloat) {
        zoom = min(6, max(1, value))
        committedZoom = zoom
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
    @ViewBuilder
    private func seamOverlay(size: CGSize) -> some View {
        if model.showsSeams, model.plan.canvasSize.height > 0 {
            ZStack(alignment: .topLeading) {
                ForEach(Array(model.plan.joins.enumerated()), id: \.offset) { _, join in
                    let y = CGFloat(Double(join.canvasPosition) / Double(model.plan.canvasSize.height)) * size.height
                    Rectangle()
                        .fill(join.needsReview ? Color.orange : Color.green.opacity(0.7))
                        .frame(width: size.width, height: 1.5)
                        .offset(y: y)
                        .allowsHitTesting(false)
                }
            }
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

    // MARK: - Gestures

    private func canvasGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let point = normalized(value.location, in: size)
                switch model.activeTool {
                case .none:
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
                case .none:
                    toggleMatch(at: point)
                case .annotation(let tool):
                    switch tool {
                    case .text:
                        textPoint = point
                        textInput = ""
                        isTextPromptPresented = true
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
    private func toggleMatch(at point: NormalizedPoint) {
        let hit = model.matches.first { match in
            match.box.expanded(byX: 0.004, byY: 0.004)
                .intersects(NormalizedRect(x: point.x, y: point.y, width: 0.0005, height: 0.0005))
        }
        guard let hit else { return }
        model.setMatch(hit.id, enabled: !hit.isEnabled)
    }

    private func commitText() {
        defer { textInput = "" }
        guard let point = textPoint, !textInput.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.commitAnnotation(Annotation(tool: .text,
                                          points: [point],
                                          color: model.strokeColor,
                                          lineWidth: model.strokeWidth,
                                          text: textInput,
                                          fontSize: model.fontSize))
    }
}
