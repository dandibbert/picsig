import SwiftUI
import UIKit

enum CanvasTool: String, CaseIterable {
    case navigate, textMask, mask, adjust, pen, arrow, rectangle, text, crop, erase
    static let toolbar: [CanvasTool] = [.navigate, .textMask, .mask, .text, .arrow, .pen, .rectangle, .crop]
    var title: String {
        switch self {
        case .navigate: return "选择"; case .textMask: return "点字打码"; case .mask: return "框选打码"
        case .adjust: return "调整"; case .pen: return "画笔"; case .arrow: return "箭头"
        case .rectangle: return "方框"; case .text: return "加字"; case .crop: return "裁剪"; case .erase: return "擦除"
        }
    }
    var symbol: String {
        switch self {
        case .navigate: return "cursorarrow"; case .textMask: return "text.viewfinder"; case .mask: return "rectangle.dashed"
        case .adjust: return "arrow.up.left.and.arrow.down.right"; case .pen: return "pencil.tip"; case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"; case .text: return "textformat"; case .crop: return "crop"; case .erase: return "eraser"
        }
    }
    var draws: Bool { [.mask, .pen, .arrow, .rectangle, .crop].contains(self) }
}
enum CanvasAction {
    case mask(Box), adjust(UUID, Box), annotation(Annotation), crop(Box), select(UUID?), text(Point2D), erase(Point2D)
    case selectAnnotation(UUID?), updateAnnotation(Annotation), editText(UUID), redactText(RecognizedTextItem)
}

struct ZoomCanvas: UIViewRepresentable {
    var image: UIImage
    var canvas: Size2D
    var edit: EditState = EditState()
    var tool: CanvasTool = .navigate
    var selected: UUID?
    var selectedAnnotation: UUID?
    var textRegions: [RecognizedTextItem] = []
    var reveal = false
    var color = "coral"
    var lineWidth: Double = 5
    var detail: DetailPatch?
    var action: (CanvasAction) -> Void = { _ in }
    var requestDetail: (Box) -> Void = { _ in }
    func makeUIView(context: Context) -> CanvasScrollView {
        let scroll = CanvasScrollView(); scroll.delegate = context.coordinator
        context.coordinator.scroll = scroll
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1; pan.delegate = context.coordinator
        scroll.surface.addGestureRecognizer(pan); context.coordinator.editPan = pan
        scroll.panGestureRecognizer.require(toFail: pan)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: pan); scroll.surface.addGestureRecognizer(tap)
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2; scroll.surface.addGestureRecognizer(doubleTap)
        // Single taps are immediate in text-redaction mode; double tap is only for text editing.
        doubleTap.delegate = context.coordinator
        context.coordinator.doubleTapRecognizer = doubleTap
        return scroll
    }
    func updateUIView(_ scroll: CanvasScrollView, context: Context) {
        context.coordinator.parent = self
        let overlay = scroll.surface.overlay
        overlay.canvas = canvas; overlay.edit = edit; overlay.selected = selected
        overlay.selectedAnnotation = selectedAnnotation; overlay.reveal = reveal
        overlay.textRegions = tool == .textMask ? textRegions : []
        overlay.showCropHandles = tool == .crop
        if scroll.surface.base.image !== image {
            let oldSize = scroll.surface.bounds.size
            // A mask edit, undo or scan must never reset the user's viewport.
            if oldSize != image.size {
                scroll.setZoomScale(1, animated: false)
                scroll.surface.frame = CGRect(origin: .zero, size: image.size)
                scroll.contentSize = image.size; scroll.needsInitialScale = true
            }
            scroll.surface.base.image = image
            scroll.surface.setNeedsLayout(); scroll.setNeedsLayout()
        }
        if let detail {
            scroll.surface.detail.image = detail.image
            scroll.surface.detail.frame = detail.region.scaled(to: Size2D(image.size.width, image.size.height)).cgRect
            scroll.surface.detail.isHidden = false
        } else { scroll.surface.detail.isHidden = true }
        scroll.panGestureRecognizer.minimumNumberOfTouches = tool.draws ? 2 : 1
        context.coordinator.editPan?.isEnabled = tool != .textMask && tool != .text
        context.coordinator.doubleTapRecognizer?.isEnabled = tool == .navigate || tool == .text
        overlay.displayScale = max(0.1, scroll.zoomScale * image.size.width / canvas.width)
        overlay.setNeedsDisplay()
        scroll.accessibilityValue = "遮挡 \(edit.masks.filter(\.enabled).count)，标注 \(edit.annotations.count)"
        scroll.surface.setAccessibility(textRegions: tool == .textMask ? textRegions : [], edit: edit, canvas: canvas, textMode: tool == .textMask, action: action)
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: ZoomCanvas
        weak var scroll: CanvasScrollView?
        weak var editPan: UIPanGestureRecognizer?
        weak var doubleTapRecognizer: UITapGestureRecognizer?
        private var start = Point2D(0, 0), points: [Point2D] = [], initialBox: Box?, initialMark: Annotation?, corner: Int?
        init(_ parent: ZoomCanvas) { self.parent = parent }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { scroll?.surface }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            scroll?.centerContent()
            scroll?.surface.overlay.displayScale = max(0.1, scrollView.zoomScale * parent.image.size.width / parent.canvas.width)
            scroll?.surface.overlay.setNeedsDisplay()
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { detail() }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) { if !willDecelerate { detail() } }
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { detail() }
        private func detail() {
            guard let scroll else { return }
            let r = scroll.convert(scroll.bounds, to: scroll.surface)
            parent.requestDetail(Box(r).normalized(to: Size2D(scroll.surface.bounds.width, scroll.surface.bounds.height)).intersection(.unit))
        }
        private func point(_ gesture: UIGestureRecognizer) -> Point2D {
            guard let view = scroll?.surface else { return Point2D(0, 0) }
            let p = gesture.location(in: view)
            return Point2D(min(1, max(0, p.x / max(1, view.bounds.width))), min(1, max(0, p.y / max(1, view.bounds.height))))
        }
        private var hitPadding: Size2D {
            let size = scroll?.surface.bounds.size ?? .zero, scale = max(0.1, scroll?.zoomScale ?? 1)
            return Size2D(16.0 / max(1.0, Double(size.width * scale)), 16.0 / max(1.0, Double(size.height * scale)))
        }
        private func rectangle(_ a: Point2D, _ b: Point2D) -> Box { Box(min(a.x, b.x), min(a.y, b.y), abs(a.x - b.x), abs(a.y - b.y)) }
        private func selectedBox() -> Box? {
            if let id = parent.selected, let mask = parent.edit.masks.first(where: { $0.id == id }) { return mask.rect }
            if let id = parent.selectedAnnotation, let mark = parent.edit.annotations.first(where: { $0.id == id }) { return Renderer.annotationBounds(mark, canvas: parent.canvas) }
            return nil
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === doubleTapRecognizer { return parent.tool != .textMask }
            guard gestureRecognizer === editPan else { return true }
            if parent.tool.draws { return true }
            guard let box = selectedBox() else { return false }
            return box.expanded(dx: hitPadding.width, dy: hitPadding.height).contains(point(gestureRecognizer))
        }
        private func mark(at p: Point2D) -> Annotation? {
            parent.edit.annotations.reversed().first { Renderer.hitAnnotation($0, at: p, canvas: parent.canvas, tolerance: hitPadding) }
        }
        @objc func tap(_ gesture: UITapGestureRecognizer) {
            let location = point(gesture)
            if parent.tool == .textMask {
                // Prefer the smallest containing text box, then the nearest box within a finger's margin.
                let hits = parent.textRegions.filter { $0.rect.expanded(dx: hitPadding.width * 0.5, dy: hitPadding.height * 0.5).contains(location) }
                let hit = hits.min { lhs, rhs in
                    let l = lhs.rect.contains(location), r = rhs.rect.contains(location)
                    return l == r ? lhs.rect.area < rhs.rect.area : l
                }
                if let hit { parent.action(.redactText(hit)) }
                return
            }
            if parent.tool == .erase { parent.action(.erase(location)); return }
            if let mask = parent.edit.masks.last(where: { $0.enabled && $0.rect.contains(location) }) {
                parent.action(.select(mask.id)); return
            }
            if let mark = mark(at: location) {
                parent.action(.selectAnnotation(mark.id))
                if parent.tool == .text && mark.kind == .text { parent.action(.editText(mark.id)) }
                return
            }
            if parent.tool == .text { parent.action(.text(location)); return }
            parent.action(.select(nil)); parent.action(.selectAnnotation(nil))
        }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            if let mark = mark(at: point(gesture)), mark.kind == .text { parent.action(.editText(mark.id)) }
        }
        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard let overlay = scroll?.surface.overlay else { return }
            let current = point(gesture)
            if gesture.state == .began {
                start = current; points = [current]; initialBox = nil; initialMark = nil; corner = nil
                if parent.tool == .navigate || parent.tool == .adjust { initialBox = selectedBox() }
                if parent.tool == .crop && parent.edit.crop != .unit,
                   parent.edit.crop.expanded(dx: hitPadding.width, dy: hitPadding.height).contains(current) { initialBox = parent.edit.crop }
                if let id = parent.selectedAnnotation, initialBox != nil {
                    initialMark = parent.edit.annotations.first { $0.id == id }
                }
                if let box = initialBox {
                    let corners = [Point2D(box.x, box.y), Point2D(box.maxX, box.y), Point2D(box.x, box.maxY), Point2D(box.maxX, box.maxY)]
                    corner = corners.indices.min { distance(corners[$0], current) < distance(corners[$1], current) }
                    if let c = corner, distance(corners[c], current) > 24 { corner = nil }
                }
            }
            if points.count < 4000 { points.append(current) }
            if let box = initialBox {
                var target = Box(min(max(0, box.x + current.x - start.x), max(0, 1 - box.width)),
                                 min(max(0, box.y + current.y - start.y), max(0, 1 - box.height)), box.width, box.height)
                if let corner {
                    let opposite = [Point2D(box.maxX, box.maxY), Point2D(box.x, box.maxY), Point2D(box.maxX, box.y), Point2D(box.x, box.y)][corner]
                    target = rectangle(opposite, current)
                }
                if var mark = initialMark {
                    let sx = target.width / max(0.000001, box.width), sy = target.height / max(0.000001, box.height)
                    mark.points = mark.points.map { Point2D(target.x + ($0.x - box.x) * sx, target.y + ($0.y - box.y) * sy) }
                    if corner != nil { mark.width = min(40, max(mark.kind == .text ? 3.6 : 1, mark.width * (mark.kind == .text ? sx : sqrt(sx * sy)))) }
                    overlay.ghostMark = mark
                } else { overlay.ghostBox = target; overlay.movingMask = parent.tool == .crop ? nil : parent.selected }
            } else {
                switch parent.tool {
                case .mask, .crop: overlay.ghostBox = rectangle(start, current)
                case .pen, .arrow, .rectangle:
                    let kind: MarkKind = parent.tool == .pen ? .pen : (parent.tool == .arrow ? .arrow : .rectangle)
                    overlay.ghostMark = Annotation(kind: kind, points: kind == .pen ? points : [start, current], width: parent.lineWidth, color: parent.color)
                default: break
                }
            }
            overlay.setNeedsDisplay()
            if gesture.state == .ended {
                if let box = overlay.ghostBox, box.width * parent.canvas.width >= 4, box.height * parent.canvas.height >= 4 {
                    if parent.tool == .mask { parent.action(.mask(box)) }
                    else if parent.tool == .crop { parent.action(.crop(box)) }
                    else if let id = parent.selected { parent.action(.adjust(id, box)) }
                }
                if let mark = overlay.ghostMark {
                    parent.action(initialMark == nil ? .annotation(mark) : .updateAnnotation(mark))
                }
            }
            if [.ended, .cancelled, .failed].contains(gesture.state) {
                overlay.ghostBox = nil; overlay.ghostMark = nil; overlay.movingMask = nil; overlay.setNeedsDisplay()
            }
        }
        private func distance(_ a: Point2D, _ b: Point2D) -> CGFloat {
            guard let size = scroll?.surface.bounds.size else { return .infinity }
            return hypot((a.x - b.x) * size.width, (a.y - b.y) * size.height) * (scroll?.zoomScale ?? 1)
        }
    }
}

final class CanvasScrollView: UIScrollView {
    let surface = CanvasSurface()
    var needsInitialScale = true
    private var oldSize = CGSize.zero
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .secondarySystemBackground
        addSubview(surface); bouncesZoom = true
        accessibilityLabel = "图片编辑画布"; accessibilityIdentifier = "editor-canvas"
        accessibilityHint = "双指缩放，点击文字打码或选中标注后拖动。"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard surface.bounds.width > 0, surface.bounds.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        let widthScale = bounds.width / surface.bounds.width, heightScale = bounds.height / surface.bounds.height
        minimumZoomScale = min(widthScale, heightScale)
        maximumZoomScale = max(8, max(widthScale, heightScale) * 8)
        if needsInitialScale {
            zoomScale = surface.bounds.height >= surface.bounds.width ? widthScale : heightScale
            needsInitialScale = false
        }
        // Inspector/keyboard height changes leave scale and scroll position untouched.
        oldSize = bounds.size; centerContent()
    }
    func centerContent() {
        let inset = UIEdgeInsets(top: max(0, (bounds.height - contentSize.height) / 2), left: max(0, (bounds.width - contentSize.width) / 2), bottom: 0, right: 0)
        if contentInset != inset { contentInset = inset }
    }
}
private final class TextHitElement: UIAccessibilityElement {
    var activate: () -> Void = {}
    override func accessibilityActivate() -> Bool { activate(); return true }
}
final class CanvasSurface: UIView {
    let base = UIImageView(), detail = UIImageView(), overlay = CanvasOverlay()
    override init(frame: CGRect) {
        super.init(frame: frame); isUserInteractionEnabled = true
        base.contentMode = .scaleToFill; detail.contentMode = .scaleToFill
        addSubview(base); addSubview(detail); addSubview(overlay)
        base.isUserInteractionEnabled = false; detail.isUserInteractionEnabled = false; overlay.isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); base.frame = bounds; overlay.frame = bounds }
    func setAccessibility(textRegions: [RecognizedTextItem], edit: EditState, canvas: Size2D, textMode: Bool, action: @escaping (CanvasAction) -> Void) {
        func element(_ rect: Box, _ label: String, _ identifier: String, _ callback: @escaping () -> Void) -> UIAccessibilityElement {
            let result = TextHitElement(accessibilityContainer: self)
            result.accessibilityLabel = label; result.accessibilityIdentifier = identifier; result.accessibilityTraits = .button
            result.accessibilityFrameInContainerSpace = rect.scaled(to: Size2D(bounds.width, bounds.height)).cgRect
            result.activate = callback; return result
        }
        if textMode {
            accessibilityElements = textRegions.enumerated().map { index, region in
                element(region.rect, "文字区域 \(index + 1)", "canvas-text-target-\(index)") { action(.redactText(region)) }
            }
        } else {
            var elements: [UIAccessibilityElement] = edit.annotations.enumerated().map { index, mark in
                element(Renderer.annotationBounds(mark, canvas: canvas), "标注 \(index + 1)", "canvas-annotation-\(index)") { action(.selectAnnotation(mark.id)) }
            }
            elements += edit.masks.filter(\.enabled).enumerated().map { index, mask in
                element(mask.rect, "遮挡 \(index + 1)", "canvas-mask-\(index)") { action(.select(mask.id)) }
            }
            accessibilityElements = elements
        }
    }
}
final class CanvasOverlay: UIView {
    var canvas = Size2D(1, 1), edit = EditState()
    var selected: UUID?, selectedAnnotation: UUID?, movingMask: UUID?, reveal = false
    var textRegions: [RecognizedTextItem] = []
    var ghostBox: Box?, ghostMark: Annotation?
    var showCropHandles = false
    var displayScale: Double = 1
    override init(frame: CGRect) { super.init(frame: frame); isOpaque = false; contentMode = .redraw; backgroundColor = .clear }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard !reveal, let context = UIGraphicsGetCurrentContext(), canvas.width > 0 else { return }
        context.scaleBy(x: bounds.width / canvas.width, y: bounds.height / canvas.height)
        let marks = edit.annotations.filter { $0.id != ghostMark?.id } + (ghostMark.map { [$0] } ?? [])
        Renderer.drawAnnotations(marks, canvas: canvas, context: context)
        var masks = edit.masks
        if let movingMask, let box = ghostBox, let i = masks.firstIndex(where: { $0.id == movingMask }) { masks[i].rect = box }
        Renderer.drawMasks(masks, canvas: canvas, context: context)
        context.setLineWidth(1 / displayScale)
        for region in textRegions {
            let box = region.rect.scaled(to: canvas).cgRect
            context.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.7).cgColor)
            context.setFillColor(UIColor.systemBlue.withAlphaComponent(0.06).cgColor)
            context.fill(box); context.stroke(box)
        }
        let crop = showCropHandles ? (ghostBox ?? edit.crop) : edit.crop
        if crop != .unit {
            let path = UIBezierPath(rect: CGRect(origin: .zero, size: canvas.cgSize))
            path.append(UIBezierPath(rect: crop.scaled(to: canvas).cgRect)); path.usesEvenOddFillRule = true
            UIColor.black.withAlphaComponent(0.28).setFill(); path.fill()
            if showCropHandles { selection(crop, context) }
        }
        if let mask = masks.first(where: { $0.id == selected }) { selection(mask.rect, context) }
        if let mark = marks.first(where: { $0.id == selectedAnnotation }) { selection(Renderer.annotationBounds(mark, canvas: canvas), context) }
        if let box = ghostBox, movingMask == nil, !showCropHandles {
            context.setFillColor(UIColor.systemBlue.withAlphaComponent(0.25).cgColor); context.fill(box.scaled(to: canvas).cgRect)
            selection(box, context)
        }
    }
    private func selection(_ rect: Box, _ context: CGContext) {
        let r = rect.scaled(to: canvas).cgRect, side = 9 / displayScale
        context.setStrokeColor(UIColor.systemBlue.cgColor); context.setLineWidth(1.5 / displayScale); context.stroke(r)
        for p in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)] {
            let handle = CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side)
            context.setFillColor(UIColor.white.cgColor); context.fillEllipse(in: handle); context.strokeEllipse(in: handle)
        }
    }
}
