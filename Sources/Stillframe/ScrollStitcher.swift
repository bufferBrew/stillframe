import AppKit

enum StitchError: LocalizedError {
    case dimensions, noMovement, noOverlap, ambiguous, tooLarge, invalidImage
    var errorDescription: String? {
        switch self {
        case .dimensions: return "Keep the capture region and display scale unchanged. Frames must have the same width."
        case .noMovement: return "The region has not moved. Scroll down, then add another frame."
        case .noOverlap: return "No reliable overlap found. Scroll less, avoid sticky headers, or set the overlap manually."
        case .ambiguous: return "The overlap is ambiguous. Use a region with distinct content, or set it manually."
        case .tooLarge: return "This capture reached the 80-megapixel limit. Finish it and start another."
        case .invalidImage: return "The captured image could not be read."
        }
    }
}

enum ScrollStitcher {
    /// Positive shift is newly revealed content after scrolling DOWN.
    static func verticalShift(previous: CGImage, next: CGImage) throws -> Int {
        guard previous.width == next.width, previous.height == next.height else { throw StitchError.dimensions }
        let height = next.height, width = 64
        guard height >= 32 else { throw StitchError.noOverlap }
        func gray(_ image: CGImage) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: width * height)
            let success = bytes.withUnsafeMutableBytes { storage -> Bool in
                guard let context = CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                context.interpolationQuality = .low
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard success else { throw StitchError.invalidImage }; return bytes
        }
        let a = try gray(previous), b = try gray(next)
        func score(_ shift: Int) -> Double {
            let overlap = height - shift, rows = min(40, overlap)
            var sum = 0, count = 0
            // Ignore outer columns containing scrollbar edges and window borders.
            for sample in 0..<rows {
                let y = sample * (overlap - 1) / max(1, rows - 1)
                for x in 5..<(width - 5) {
                    sum += abs(Int(a[(y + shift) * width + x]) - Int(b[y * width + x])); count += 1
                }
            }
            return Double(sum) / Double(max(1, count))
        }
        if score(0) < 0.5 { throw StitchError.noMovement }
        let minOverlap = max(16, height / 8)
        var bestShift = 0, best = Double.infinity
        var candidates: [(Int, Double)] = []
        for shift in 1...(height - minOverlap) {
            let value = score(shift)
            candidates.append((shift, value))
            if value < best { best = value; bestShift = shift }
        }
        guard best < 7 else { throw StitchError.noOverlap }
        if candidates.contains(where: { abs($0.0 - bestShift) > 4 && $0.1 <= best + 0.15 }) { throw StitchError.ambiguous }
        return bestShift
    }

    static func join(_ previous: NSImage, _ next: NSImage, manualOverlap: Int? = nil) throws -> NSImage {
        guard let a = ImageRenderer.bitmap(previous)?.cgImage, let b = ImageRenderer.bitmap(next)?.cgImage else { throw StitchError.invalidImage }
        guard a.width == b.width, a.height >= b.height else { throw StitchError.dimensions }
        let overlap: Int
        if let manualOverlap {
            guard (1..<b.height).contains(manualOverlap) else { throw StitchError.noOverlap }
            overlap = manualOverlap
        } else {
            guard let tail = a.cropping(to: CGRect(x: 0, y: a.height - b.height, width: a.width, height: b.height)) else { throw StitchError.invalidImage }
            overlap = b.height - (try verticalShift(previous: tail, next: b))
        }
        let added = b.height - overlap, height = a.height + added
        guard height <= 80000000 / a.width else { throw StitchError.tooLarge }
        guard let tail = b.cropping(to: CGRect(x: 0, y: overlap, width: b.width, height: added)) else { throw StitchError.invalidImage }
        let image = NSImage(size: NSSize(width: a.width, height: height), flipped: true) { _ in
            NSImage(cgImage: a, size: NSSize(width: a.width, height: a.height)).draw(in: NSRect(x: 0, y: 0, width: a.width, height: a.height), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            NSImage(cgImage: tail, size: NSSize(width: b.width, height: added)).draw(in: NSRect(x: 0, y: a.height, width: b.width, height: added), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            return true
        }
        guard let png = ImageRenderer.png(image), let flattened = NSImage(data: png) else { throw StitchError.invalidImage }
        return flattened
    }
}
