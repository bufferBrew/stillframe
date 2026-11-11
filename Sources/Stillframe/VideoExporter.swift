import AVFoundation
import ImageIO
import UniformTypeIdentifiers

struct VideoClip: Equatable {
    var start: Double
    var end: Double
    var duration: Double { end - start }
    func validated(sourceDuration: Double) throws -> CMTimeRange {
        guard start.isFinite, end.isFinite, sourceDuration.isFinite, start >= 0, end <= sourceDuration + 0.001, duration >= 0.05 else {
            throw MediaExportError.invalidRange
        }
        return CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000), duration: CMTime(seconds: duration, preferredTimescale: 60000))
    }
}

enum MediaExportError: LocalizedError {
    case invalidRange, unsupported, gifTooLong, invalidGIFSettings, overwriteSource
    var errorDescription: String? {
        switch self {
        case .invalidRange: return "Choose a start and end within the video, at least 0.05 seconds apart."
        case .unsupported: return "This video cannot be exported. Try a different recording."
        case .gifTooLong: return "Choose a clip of 30 seconds or less for GIF export."
        case .invalidGIFSettings: return "Choose 5, 10, or 15 fps and a size between 240 and 1080 pixels."
        case .overwriteSource: return "Choose a different destination to preserve the original recording."
        }
    }
}

enum VideoExporter {
    static func export(source: URL, destination: URL, clip: VideoClip, gif: Bool, fps: Int = 10, maxSize: Int = 720, progress: @escaping @Sendable (Double) async -> Void = { _ in }) async throws {
        guard source.standardizedFileURL.resolvingSymlinksInPath() != destination.standardizedFileURL.resolvingSymlinksInPath() else { throw MediaExportError.overwriteSource }
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        let range = try clip.validated(sourceDuration: duration)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".stillframe-\(UUID().uuidString).\(gif ? "gif" : "mp4")")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        if gif {
            guard clip.duration <= 30 else { throw MediaExportError.gifTooLong }
            guard [5, 10, 15].contains(fps), (240...1080).contains(maxSize) else { throw MediaExportError.invalidGIFSettings }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxSize, height: maxSize)
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let count = Int(ceil(clip.duration * Double(fps)))
            guard let output = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.gif.identifier as CFString, count, nil) else { throw MediaExportError.unsupported }
            CGImageDestinationSetProperties(output, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            for index in 0..<count {
                try Task.checkCancellation()
                let result = try await generator.image(at: CMTime(seconds: clip.start + Double(index) / Double(fps), preferredTimescale: 60000))
                let delay = min(1 / Double(fps), clip.duration - Double(index) / Double(fps))
                CGImageDestinationAddImage(output, result.image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
                await progress(Double(index + 1) / Double(count))
            }
            guard CGImageDestinationFinalize(output) else { throw MediaExportError.unsupported }
        } else {
            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { throw MediaExportError.unsupported }
            exporter.timeRange = range
            exporter.shouldOptimizeForNetworkUse = true
            try await exporter.export(to: temporary, as: .mp4)
        }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: destination) }
        await progress(1)
    }
}
