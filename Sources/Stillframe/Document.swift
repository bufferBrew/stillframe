import AppKit

struct UnitPoint2: Codable, Equatable {
    var x: Double
    var y: Double
    func point(in size: NSSize) -> NSPoint { NSPoint(x: x * size.width, y: y * size.height) }
}

enum MarkTool: String, Codable, CaseIterable, Identifiable {
    case arrow, rectangle, ellipse, pen, text, counter, highlight, redact, crop
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .pen: return "pencil.tip"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .highlight: return "highlighter"
        case .redact: return "rectangle.fill"
        case .crop: return "crop"
        }
    }
}

struct Mark: Codable, Equatable, Identifiable {
    var id = UUID()
    var tool: MarkTool
    var points: [UnitPoint2]
    var color: String = "orange"
    var width: Double = 4
    var text: String = ""
}

enum Ink: String, CaseIterable, Identifiable {
    case orange, blue, red, green, white, black
    var id: String { rawValue }
    var nsColor: NSColor {
        switch self {
        case .orange: return .systemOrange
        case .blue: return .systemBlue
        case .red: return .systemRed
        case .green: return .systemGreen
        case .white: return .white
        case .black: return .black
        }
    }
}

struct CaptureItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var filename: String
    var created = Date()
    var kind: String = "image"
    var marks: [Mark] = []
    var background: Bool = false
    var backdropSettings: BackdropSettings?
    var captureRect: CGRect?
}

/// All annotation coordinates use top-left normalized image coordinates.
/// Preview, PNG/JPEG export, clipboard, OCR and pinning use this same renderer.
enum ImageRenderer {
    static func bitmap(_ image: NSImage) -> NSBitmapImageRep? {
        guard let data = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: data)
    }

    static func render(_ original: NSImage, marks: [Mark], background: Bool = false, settings: BackdropSettings? = nil) -> NSImage {
        guard let source = bitmap(original) else { return original }
        let base = NSSize(width: source.pixelsWide, height: source.pixelsHigh)
        let padding: CGFloat = background ? padding(for: base, settings: settings) : 0
        let size = NSSize(width: base.width + padding * 2, height: base.height + padding * 2)
        let output = NSImage(size: size, flipped: true) { _ in
            if background {
                let bounds = NSRect(origin: .zero, size: size)
                if settings?.style == .custom, let data = settings?.customImage, let custom = NSImage(data: data) {
                    custom.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
                } else {
                    let colors = (settings?.style ?? .ocean).colors
                    NSGradient(starting: colors.0, ending: colors.1)?.draw(in: bounds, angle: 35)
                }
            }
            NSGraphicsContext.saveGraphicsState()
            let transform = AffineTransform(translationByX: padding, byY: padding)
            (transform as NSAffineTransform).concat()
            original.draw(in: NSRect(origin: .zero, size: base), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            for mark in marks { draw(mark, size: base) }
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        return output
    }

    static func padding(for size: NSSize, settings: BackdropSettings?) -> CGFloat {
        guard let settings else { return max(24, min(size.width, size.height) * 0.07) }
        return (min(size.width, size.height) * min(25, max(0, settings.padding)) / 100).rounded()
    }

    static func draw(_ mark: Mark, size: NSSize) {
        guard let first = mark.points.first, let last = mark.points.last else { return }
        let start = first.point(in: size), end = last.point(in: size)
        let rect = NSRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y))
        let color = Ink(rawValue: mark.color)?.nsColor ?? .systemOrange
        let width = CGFloat(mark.width) * max(1, size.width / 1200)
        color.setStroke()
        color.setFill()
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch mark.tool {
        case .rectangle, .crop:
            path.appendRect(rect); path.stroke()
        case .ellipse:
            path.appendOval(in: rect); path.stroke()
        case .highlight:
            color.withAlphaComponent(0.3).setFill(); rect.fill(using: .sourceOver)
        case .redact:
            // Solid, opaque redaction. Export contains no underlying source pixels.
            NSColor.black.setFill(); rect.fill(using: .copy)
        case .pen:
            path.move(to: start)
            for point in mark.points.dropFirst() { path.line(to: point.point(in: size)) }
            path.stroke()
        case .arrow:
            path.move(to: start); path.line(to: end); path.stroke()
            let angle = atan2(end.y - start.y, end.x - start.x)
            let length = max(width * 4, 18)
            let head = NSBezierPath()
            head.move(to: NSPoint(x: end.x - length * cos(angle - .pi / 6), y: end.y - length * sin(angle - .pi / 6)))
            head.line(to: end)
            head.line(to: NSPoint(x: end.x - length * cos(angle + .pi / 6), y: end.y - length * sin(angle + .pi / 6)))
            head.lineWidth = width; head.lineCapStyle = .round; head.lineJoinStyle = .round; head.stroke()
        case .text:
            let font = NSFont.systemFont(ofSize: max(18, width * 5), weight: .semibold)
            (mark.text as NSString).draw(at: start, withAttributes: [.font: font, .foregroundColor: color, .backgroundColor: NSColor.textBackgroundColor.withAlphaComponent(0.85)])
        case .counter:
            let diameter = max(30, width * 9)
            let badge = NSRect(x: start.x - diameter / 2, y: start.y - diameter / 2, width: diameter, height: diameter)
            NSBezierPath(ovalIn: badge).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: diameter * 0.55, weight: .bold), .foregroundColor: NSColor.white]
            let textSize = (mark.text as NSString).size(withAttributes: attributes)
            (mark.text as NSString).draw(at: NSPoint(x: start.x - textSize.width / 2, y: start.y - textSize.height / 2), withAttributes: attributes)
        }
    }

    static func png(_ image: NSImage) -> Data? { bitmap(image)?.representation(using: .png, properties: [:]) }

    static func crop(_ image: NSImage, from a: UnitPoint2, to b: UnitPoint2) -> NSImage? {
        guard let bitmap = bitmap(image), let cg = bitmap.cgImage else { return nil }
        let x = max(0, min(1, min(a.x, b.x))), y = max(0, min(1, min(a.y, b.y)))
        let right = max(0, min(1, max(a.x, b.x))), bottom = max(0, min(1, max(a.y, b.y)))
        let rect = CGRect(x: x * Double(cg.width), y: y * Double(cg.height), width: (right - x) * Double(cg.width), height: (bottom - y) * Double(cg.height)).integral
        guard rect.width >= 2, rect.height >= 2, let cropped = cg.cropping(to: rect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }
}

struct EditSnapshot {
    var imageData: Data
    var marks: [Mark]
    var background: Bool
    var backdropSettings: BackdropSettings?
    var captureRect: CGRect?
}
