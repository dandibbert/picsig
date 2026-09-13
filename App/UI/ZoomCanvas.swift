import SwiftUI
import UIKit

enum CanvasTool: String, CaseIterable {
    case navigate, mask, adjust, pen, arrow, rectangle, text, crop, erase
    var title: String {
        switch self { case .navigate: return "浏览"; case .mask: return "遮挡"; case .adjust: return "调框"; case .pen: return "画笔"; case .arrow: return "箭头"; case .rectangle: return "方框"; case .text: return "文字"; case .crop: return "裁剪"; case .erase: return "擦除" }
    }
    var symbol: String {
        switch self { case .navigate: return "hand.draw"; case .mask: return "rectangle.fill"; case .adjust: return "arrow.up.left.and.arrow.down.right"; case .pen: return "pencil.tip"; case .arrow: return "arrow.up.right"; case .rectangle: return "rectangle"; case .text: return "textformat"; case .crop: return "crop"; case .erase: return "eraser" }
    }
}
enum CanvasAction {
    case mask(Box), adjust(UUID, Box), annotation(Annotation), crop(Box), select(UUID?), text(Point2D), erase(Point2D)
}

struct ZoomCanvas: UIViewRepresentable {
    var image: UIImage
    var canvas: Size2D
    var edit: EditState = EditState()
    var tool: CanvasTool = .navigate
    var selected: UUID?
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
        pan.maximumNumberOfTouches = 1; scroll.surface.addGestureRecognizer(pan); context.coordinator.editPan = pan
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: pan); scroll.surface.addGestureRecognizer(tap)
        return scroll
    }
    func updateUIView(_ scroll: CanvasScrollView, context: Context) {
        context.coordinator.parent = self
        scroll.surface.overlay.canvas = canvas
        scroll.surface.overlay.edit = edit; scroll.surface.overlay.selected = selected; scroll.surface.overlay.reveal = reveal
        if scroll.surface.base.image !== image {
            scroll.setZoomScale(1, animated: false)
            scroll.surface.base.image = image
            scroll.surface.frame = CGRect(origin: .zero, size: image.size)
            scroll.contentSize = image.size; scroll.needsInitialScale = true
            scroll.surface.setNeedsLayout(); scroll.setNeedsLayout()
        }
        if let detail = detail {
            scroll.surface.detail.image = detail.image
            scroll.surface.detail.frame = detail.region.scaled(to: Size2D(image.size.width, image.size.height)).cgRect
            scroll.surface.detail.isHidden = false
        } else { scroll.surface.detail.isHidden = true }
        scroll.panGestureRecognizer.minimumNumberOfTouches = tool == .navigate ? 1 : 2
        context.coordinator.editPan?.isEnabled = tool != .navigate
        scroll.surface.overlay.setNeedsDisplay()
        if context.coordinator.lastSelected != selected {
            context.coordinator.lastSelected = selected
            if let selected = selected, let mask = edit.masks.first(where: { $0.id == selected }) {
                let box = mask.rect.expanded(dx: 0.08, dy: max(0.015, mask.rect.height)).intersection(.unit)
                DispatchQueue.main.async {
                    scroll.zoom(to: box.scaled(to: Size2D(image.size.width, image.size.height)).cgRect, animated: true)
                }
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomCanvas
        weak var scroll: CanvasScrollView?
        weak var editPan: UIPanGestureRecognizer?
        var lastSelected: UUID?
        private var start = Point2D(0, 0), points: [Point2D] = [], initialBox: Box?, corner: Int?
        init(_ parent: ZoomCanvas) { self.parent = parent }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { scroll?.surface }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { scroll?.centerContent() }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { detail() }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) { if !willDecelerate { detail() } }
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { detail() }
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { detail() }
        private func detail() {
            guard let scroll = scroll else { return }
            let rect = scroll.convert(scroll.bounds, to: scroll.surface)
            let size = Size2D(scroll.surface.bounds.width, scroll.surface.bounds.height)
            parent.requestDetail(Box(rect).normalized(to: size).intersection(.unit))
        }
        private func point(_ gesture: UIGestureRecognizer) -> Point2D {
            guard let view = scroll?.surface else { return Point2D(0, 0) }
            let p = gesture.location(in: view)
            return Point2D(min(1, max(0, p.x / max(1, view.bounds.width))), min(1, max(0, p.y / max(1, view.bounds.height))))
        }
        private func rectangle(_ a: Point2D, _ b: Point2D) -> Box { Box(min(a.x, b.x), min(a.y, b.y), abs(a.x - b.x), abs(a.y - b.y)) }
        @objc func tap(_ gesture: UITapGestureRecognizer) {
            let location = point(gesture)
            if parent.tool == .text { parent.action(.text(location)); return }
            if parent.tool == .erase { parent.action(.erase(location)); return }
            parent.action(.select(parent.edit.masks.last(where: { $0.rect.contains(location) })?.id))
        }
        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard let overlay = scroll?.surface.overlay else { return }
            let current = point(gesture)
            if gesture.state == .began {
                start = current; points = [current]; initialBox = nil; corner = nil
                if parent.tool == .adjust, let selected = parent.selected,
                   let mask = parent.edit.masks.first(where: { $0.id == selected }) {
                    initialBox = mask.rect
                    let corners = [Point2D(mask.rect.x, mask.rect.y), Point2D(mask.rect.maxX, mask.rect.y), Point2D(mask.rect.x, mask.rect.maxY), Point2D(mask.rect.maxX, mask.rect.maxY)]
                    let zoom = scroll?.zoomScale ?? 1
                    if let index = corners.indices.min(by: { distance(corners[$0], current) < distance(corners[$1], current) }), distance(corners[index], current) < 32 / max(0.1, zoom) { corner = index }
                }
            }
            if points.count < 4000 { points.append(current) }
            let rect = rectangle(start, current)
            switch parent.tool {
            case .mask, .crop: overlay.ghostBox = rect
            case .adjust:
                if let initial = initialBox {
                    let dx = current.x - start.x, dy = current.y - start.y
                    var result = Box(min(max(0, initial.x + dx), 1 - initial.width), min(max(0, initial.y + dy), 1 - initial.height), initial.width, initial.height)
                    if let corner = corner {
                        let opposite = [Point2D(initial.maxX, initial.maxY), Point2D(initial.x, initial.maxY), Point2D(initial.maxX, initial.y), Point2D(initial.x, initial.y)][corner]
                        result = rectangle(opposite, current)
                    }
                    overlay.ghostBox = result
                }
            case .pen, .arrow, .rectangle:
                let kind: MarkKind = parent.tool == .pen ? .pen : (parent.tool == .arrow ? .arrow : .rectangle)
                overlay.ghostMark = Annotation(kind: kind, points: kind == .pen ? points : [start, current], width: parent.lineWidth, color: parent.color)
            default: break
            }
            overlay.setNeedsDisplay()
            if gesture.state == .ended {
                if let box = overlay.ghostBox, box.width * parent.canvas.width >= 4, box.height * parent.canvas.height >= 4 {
                    if parent.tool == .mask { parent.action(.mask(box)) }
                    if parent.tool == .crop { parent.action(.crop(box)) }
                    if parent.tool == .adjust, let id = parent.selected { parent.action(.adjust(id, box)) }
                }
                if let mark = overlay.ghostMark { parent.action(.annotation(mark)) }
            }
            if [.ended, .cancelled, .failed].contains(gesture.state) {
                overlay.ghostBox = nil; overlay.ghostMark = nil; overlay.setNeedsDisplay()
            }
        }
        private func distance(_ a: Point2D, _ b: Point2D) -> CGFloat {
            guard let size = scroll?.surface.bounds.size else { return .infinity }
            return hypot((a.x - b.x) * size.width, (a.y - b.y) * size.height)
        }
    }
}

final class CanvasScrollView: UIScrollView {
    let surface = CanvasSurface()
    var needsInitialScale = true
    private var oldSize = CGSize.zero
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .secondarySystemBackground
        addSubview(surface); bouncesZoom = true; showsHorizontalScrollIndicator = true; showsVerticalScrollIndicator = true
        accessibilityLabel = "图片编辑画布"; accessibilityHint = "双指缩放。编辑工具下用双指平移。"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard surface.bounds.width > 0, surface.bounds.height > 0, bounds.width > 0 else { return }
        if needsInitialScale || bounds.size != oldSize {
            let widthScale = bounds.width / surface.bounds.width, heightScale = bounds.height / surface.bounds.height
            minimumZoomScale = min(widthScale, heightScale)
            maximumZoomScale = max(8, max(widthScale, heightScale) * 8)
            zoomScale = surface.bounds.height >= surface.bounds.width ? widthScale : heightScale
            oldSize = bounds.size; needsInitialScale = false
        }
        centerContent()
    }
    func centerContent() {
        let inset = UIEdgeInsets(top: max(0, (bounds.height - contentSize.height) / 2), left: max(0, (bounds.width - contentSize.width) / 2), bottom: 0, right: 0)
        if contentInset != inset { contentInset = inset }
    }
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
}
final class CanvasOverlay: UIView {
    var canvas = Size2D(1, 1), edit = EditState()
    var selected: UUID?, reveal = false
    var ghostBox: Box?, ghostMark: Annotation?
    override init(frame: CGRect) { super.init(frame: frame); isOpaque = false; contentMode = .redraw; backgroundColor = .clear }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard !reveal, let context = UIGraphicsGetCurrentContext(), canvas.width > 0 else { return }
        context.scaleBy(x: bounds.width / canvas.width, y: bounds.height / canvas.height)
        Renderer.drawAnnotations(edit.annotations + (ghostMark.map { [$0] } ?? []), canvas: canvas, context: context)
        Renderer.drawMasks(edit.masks, canvas: canvas, context: context)
        if edit.crop != .unit {
            let path = UIBezierPath(rect: CGRect(origin: .zero, size: canvas.cgSize))
            path.append(UIBezierPath(rect: edit.crop.scaled(to: canvas).cgRect)); path.usesEvenOddFillRule = true
            UIColor.black.withAlphaComponent(0.28).setFill(); path.fill()
        }
        for mask in edit.masks where mask.id == selected || !mask.enabled {
            let box = mask.rect.scaled(to: canvas).cgRect
            context.setStrokeColor((mask.enabled ? UIColor.systemMint : UIColor.systemOrange).cgColor)
            context.setLineWidth(max(3, canvas.width / max(1, bounds.width) * 2))
            context.setLineDash(phase: 0, lengths: mask.enabled ? [] : [8, 5]); context.stroke(box)
            if mask.id == selected {
                context.setFillColor(UIColor.systemMint.cgColor)
                for p in [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)] {
                    let side = max(10, canvas.width / max(1, bounds.width) * 6)
                    context.fillEllipse(in: CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side))
                }
            }
        }
        if let box = ghostBox {
            context.setFillColor(UIColor.systemIndigo.withAlphaComponent(0.25).cgColor); context.fill(box.scaled(to: canvas).cgRect)
            context.setStrokeColor(UIColor.systemIndigo.cgColor); context.setLineWidth(3); context.stroke(box.scaled(to: canvas).cgRect)
        }
    }
}
