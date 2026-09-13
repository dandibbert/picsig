import Foundation

/// Everything the editor can change about an image. Kept as one `Codable` value
/// so undo, redo and project files are all the same mechanism.
public struct EditState: Equatable, Codable, Sendable {
    public var annotations: [Annotation]
    /// Areas the user masked by hand, plus the automatic ones once accepted.
    public var redactions: [RedactionItem]
    public var adjustments: ImageAdjustments
    /// Crop in unit space of the stitched image.
    public var crop: NormalizedRect
    /// Rotation in 90° steps, applied after cropping.
    public var quarterTurns: Int
    public var isMirrored: Bool
    public var canvas: CanvasStyle
    public var watermark: Watermark?

    public init(annotations: [Annotation] = [],
                redactions: [RedactionItem] = [],
                adjustments: ImageAdjustments = .neutral,
                crop: NormalizedRect = .full,
                quarterTurns: Int = 0,
                isMirrored: Bool = false,
                canvas: CanvasStyle = .plain,
                watermark: Watermark? = nil) {
        self.annotations = annotations
        self.redactions = redactions
        self.adjustments = adjustments
        self.crop = crop
        self.quarterTurns = quarterTurns
        self.isMirrored = isMirrored
        self.canvas = canvas
        self.watermark = watermark
    }

    public static let empty = EditState()

    public var isUnmodified: Bool { self == .empty }

    public var nextBadgeNumber: Int {
        (annotations.compactMap(\.number).max() ?? 0) + 1
    }
}

/// Snapshot based undo stack.
///
/// Snapshots are cheap here (a few hundred small structs at worst) and they make
/// every operation undoable without writing a command object for each tool.
public struct EditDocument: Equatable, Sendable {
    public private(set) var state: EditState
    private var undoStack: [EditState] = []
    private var redoStack: [EditState] = []
    public let undoLimit: Int

    public init(state: EditState = .empty, undoLimit: Int = 60) {
        self.state = state
        self.undoLimit = max(1, undoLimit)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Applies a change and records it for undo. Returns false when the mutation
    /// left the state untouched, so a no-op tap does not fill the undo stack.
    @discardableResult
    public mutating func apply(_ mutate: (inout EditState) -> Void) -> Bool {
        let previous = state
        var draft = state
        mutate(&draft)
        guard draft != previous else { return false }
        undoStack.append(previous)
        if undoStack.count > undoLimit { undoStack.removeFirst(undoStack.count - undoLimit) }
        redoStack.removeAll()
        state = draft
        return true
    }

    /// Replaces the state without touching the undo stack — used while a gesture
    /// is in flight so a drag does not create dozens of undo steps.
    public mutating func previewChange(_ mutate: (inout EditState) -> Void) {
        mutate(&state)
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(state)
        state = previous
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(state)
        state = next
        return true
    }

    public mutating func resetHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    // MARK: - Convenience operations

    public mutating func add(_ annotation: Annotation) {
        apply { $0.annotations.append(annotation.simplified()) }
    }

    public mutating func removeAnnotation(id: UUID) {
        apply { $0.annotations.removeAll { $0.id == id } }
    }

    /// Edits one existing mark in place — its colour, width, text, font — as a
    /// single undo step. Returns false when the id is unknown or nothing changed.
    @discardableResult
    public mutating func updateAnnotation(id: UUID, _ mutate: (inout Annotation) -> Void) -> Bool {
        guard state.annotations.contains(where: { $0.id == id }) else { return false }
        return apply { state in
            guard let index = state.annotations.firstIndex(where: { $0.id == id }) else { return }
            mutate(&state.annotations[index])
        }
    }

    public mutating func clearAnnotations() {
        apply { $0.annotations.removeAll() }
    }

    public mutating func add(redaction: RedactionItem) {
        apply { $0.redactions.append(redaction) }
    }

    public mutating func removeRedaction(id: UUID) {
        apply { $0.redactions.removeAll { $0.id == id } }
    }

    /// Replaces the automatic redactions, keeping everything the user drew.
    public mutating func replaceAutomaticRedactions(with items: [RedactionItem]) {
        apply { state in
            state.redactions.removeAll { !$0.isManual }
            state.redactions.append(contentsOf: items)
        }
    }

    /// Applies a change to the crop, rotation or mirroring, moving every mark the
    /// user drew into the new canvas space as part of the same undo step.
    ///
    /// Both halves have to land together: if the geometry and the marks were two
    /// entries, the first Undo tap would move the marks back while leaving the
    /// image rotated, which is a state the user never created.
    @discardableResult
    public mutating func applyGeometryChange(_ mutate: (inout EditState) -> Void) -> Bool {
        apply { state in
            let previous = state
            mutate(&state)
            state = state.remappingMarks(fromCanvasSpaceOf: previous)
        }
    }

    public mutating func rotate(clockwise: Bool = true) {
        applyGeometryChange { $0.quarterTurns = (($0.quarterTurns + (clockwise ? 1 : 3)) % 4 + 4) % 4 }
    }

    public mutating func mirror() {
        applyGeometryChange { $0.isMirrored.toggle() }
    }

    public mutating func setCrop(_ crop: NormalizedRect) {
        applyGeometryChange { $0.crop = crop.clampedToUnitSpace() }
    }

    public mutating func resetCrop() {
        applyGeometryChange { $0.crop = .full }
    }

    /// Undoing the last freehand stroke is the single most used action, so it gets
    /// its own entry point rather than relying on the tool state.
    public mutating func undoLastStroke() {
        apply { state in
            if let index = state.annotations.lastIndex(where: { $0.tool == .pen || $0.tool == .highlighter }) {
                state.annotations.remove(at: index)
            }
        }
    }
}
