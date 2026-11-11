import SwiftUI
import AppKit

struct EditorCanvas: NSViewRepresentable {
    @ObservedObject var store: CaptureStore
    func makeNSView(context: Context) -> AnnotationView { AnnotationView() }
    func updateNSView(_ view: AnnotationView, context: Context) {
        view.store = store
        view.preview = store.rendered
        view.needsDisplay = true
    }
}

final class AnnotationView: NSView {
    weak var store: CaptureStore?
    var preview: NSImage?
    private var draft: Mark?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var imageRect: NSRect {
        guard let preview else { return .zero }
        let available = bounds.insetBy(dx: 32, dy: 32)
        guard available.width > 0, available.height > 0 else { return .zero }
        let scale = min(available.width / preview.size.width, available.height / preview.size.height)
        let size = NSSize(width: preview.size.width * scale, height: preview.size.height * scale)
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    private var contentRect: NSRect {
        guard let store, store.selected?.background == true, let original = store.image, let bitmap = ImageRenderer.bitmap(original) else { return imageRect }
        let size = NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        let pad = ImageRenderer.padding(for: size, settings: store.selected?.backdropSettings)
        let rect = imageRect
        return rect.insetBy(dx: rect.width * pad / (size.width + pad * 2), dy: rect.height * pad / (size.height + pad * 2))
    }
    override func resetCursorRects() { addCursorRect(contentRect, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        guard let preview else { return }
        preview.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        if let draft, let image = store?.image, let bitmap = ImageRenderer.bitmap(image) {
            let rect = contentRect
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            let transform = NSAffineTransform()
            transform.translateX(by: rect.minX, yBy: rect.minY)
            transform.scaleX(by: rect.width / CGFloat(bitmap.pixelsWide), yBy: rect.height / CGFloat(bitmap.pixelsHigh))
            transform.concat()
            ImageRenderer.draw(draft, size: NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    private func point(_ event: NSEvent) -> UnitPoint2 {
        let point = convert(event.locationInWindow, from: nil), rect = contentRect
        return UnitPoint2(x: max(0, min(1, (point.x - rect.minX) / max(1, rect.width))), y: max(0, min(1, (point.y - rect.minY) / max(1, rect.height))))
    }
    override func mouseDown(with event: NSEvent) {
        guard let store, contentRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        window?.makeFirstResponder(self)
        let start = point(event)
        let count = (store.selected?.marks.filter { $0.tool == .counter }.count ?? 0) + 1
        draft = Mark(tool: store.tool, points: [start, start], color: store.ink.rawValue, width: store.stroke, text: store.tool == .counter ? String(count) : store.text)
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard draft != nil else { return }
        if draft?.tool == .pen { draft?.points.append(point(event)) }
        else { draft?.points[1] = point(event) }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard var mark = draft else { return }
        if mark.tool != .pen { mark.points[1] = point(event) }
        draft = nil
        let a = mark.points[0], b = mark.points.last!
        if mark.tool == .text || mark.tool == .counter || abs(a.x - b.x) + abs(a.y - b.y) > 0.002 { store?.commit(mark) }
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { draft = nil; needsDisplay = true }
        else { super.keyDown(with: event) }
    }
}
