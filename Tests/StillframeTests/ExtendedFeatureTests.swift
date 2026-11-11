import XCTest
import AppKit
import AVFoundation
import ImageIO
import Carbon
@testable import Stillframe

final class ExtendedFeatureTests: XCTestCase {
    private func pattern(width: Int = 160, height: Int = 800, seed: Int = 0) -> NSImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let pixels = bitmap.bitmapData!
        for y in 0..<height { for x in 0..<width {
            let offset = y * bitmap.bytesPerRow + x * 4
            pixels[offset] = UInt8((y * 37 + x * 31 + y * x * 7 + seed * 59) % 251)
            pixels[offset + 1] = UInt8((y * 13 + x * 19 + seed * 23) % 253)
            pixels[offset + 2] = UInt8((y * 29 + x * 11 + seed * 11) % 255)
            pixels[offset + 3] = 255
        } }
        let image = NSImage(size: NSSize(width: width, height: height)); image.addRepresentation(bitmap)
        return image
    }
    private func region(_ image: NSImage, y: Int, height: Int) throws -> NSImage {
        let bitmap = try XCTUnwrap(ImageRenderer.bitmap(image)?.cgImage)
        let cg = try XCTUnwrap(bitmap.cropping(to: CGRect(x: 0, y: y, width: bitmap.width, height: height)))
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
    func testScrollingStitchesThreeOverlappingFramesWithoutDuplicatingContent() throws {
        let source = pattern()
        let a = try region(source, y: 0, height: 320), b = try region(source, y: 200, height: 320), c = try region(source, y: 400, height: 320)
        XCTAssertEqual(try ScrollStitcher.verticalShift(previous: XCTUnwrap(ImageRenderer.bitmap(a)?.cgImage), next: XCTUnwrap(ImageRenderer.bitmap(b)?.cgImage)), 200)
        let joined = try ScrollStitcher.join(ScrollStitcher.join(a, b), c)
        let result = try XCTUnwrap(ImageRenderer.bitmap(joined))
        XCTAssertEqual(result.pixelsWide, 160); XCTAssertEqual(result.pixelsHigh, 720)
        let original = try XCTUnwrap(ImageRenderer.bitmap(source))
        for y in [10, 210, 319, 320, 519, 520, 700] {
            let expected = try XCTUnwrap(original.colorAt(x: 50, y: y)?.usingColorSpace(.sRGB))
            let actual = try XCTUnwrap(result.colorAt(x: 50, y: y)?.usingColorSpace(.sRGB))
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.03)
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.03)
        }
    }
    func testScrollingRejectsDuplicateAndIncompatibleFramesAndSupportsExplicitOverlap() throws {
        let a = try region(pattern(), y: 0, height: 320)
        XCTAssertThrowsError(try ScrollStitcher.join(a, a))
        XCTAssertThrowsError(try ScrollStitcher.join(a, pattern(width: 80, height: 320)))
        let b = try region(pattern(), y: 200, height: 320)
        let manual = try ScrollStitcher.join(a, b, manualOverlap: 120)
        XCTAssertEqual(ImageRenderer.bitmap(manual)?.pixelsHigh, 520)
        XCTAssertThrowsError(try ScrollStitcher.join(a, b, manualOverlap: 320))
    }
    func testShortcutsValidateDuplicatesModifiersAndUnsupportedKeys() {
        var bindings = ShortcutBinding.defaults
        XCTAssertNil(ShortcutBinding.validationError(bindings))
        XCTAssertEqual(bindings[0].label, "⌃⇧⌘4")
        bindings[1].keyCode = bindings[0].keyCode
        XCTAssertNotNil(ShortcutBinding.validationError(bindings))
        bindings[1].enabled = false
        XCTAssertNil(ShortcutBinding.validationError(bindings))
        bindings[0].modifiers = UInt32(shiftKey)
        XCTAssertNotNil(ShortcutBinding.validationError(bindings))
        bindings = ShortcutBinding.defaults; bindings[0].keyCode = 999
        XCTAssertNotNil(ShortcutBinding.validationError(bindings))
    }
    @MainActor func testPreferencesAndPerCaptureBackgroundSurviveRelaunchAndUndo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureStore(root: root)
        var preferences = AppPreferences()
        preferences.captureDelay = 5; preferences.includeCursor = true; preferences.imageFormat = "jpg"
        preferences.recordingFPS = 60; preferences.backdrop = BackdropSettings(style: .paper, padding: 12)
        try store.savePreferences(preferences)
        XCTAssertTrue(store.add(image: pattern(height: 100)))
        let id = try XCTUnwrap(store.selectedID)
        store.setBackdrop(BackdropSettings(style: .sunset, padding: 20))
        XCTAssertEqual(store.selected?.backdropSettings?.style, .sunset)
        store.undo(); XCTAssertEqual(store.selected?.backdropSettings?.style, .paper)
        store.redo(); XCTAssertEqual(store.selected?.backdropSettings?.style, .sunset)
        let reopened = CaptureStore(root: root); reopened.select(id)
        XCTAssertEqual(reopened.preferences, preferences); XCTAssertEqual(reopened.delay, 5)
        XCTAssertEqual(reopened.selected?.backdropSettings?.style, .sunset)
        XCTAssertTrue(reopened.selected?.background == true)
        let rendered = try XCTUnwrap(reopened.rendered.flatMap(ImageRenderer.bitmap))
        XCTAssertEqual(rendered.pixelsWide, 200); XCTAssertEqual(rendered.pixelsHigh, 140)
    }
    func testOldCaptureMetadataStillDecodesAndCustomBackgroundIsEmbedded() throws {
        let old = CaptureItem(title: "Legacy", filename: "old.png")
        let data = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(CaptureItem.self, from: data)
        XCTAssertNil(decoded.backdropSettings)
        let background = try XCTUnwrap(ImageRenderer.png(pattern(width: 80, height: 80)))
        let item = CaptureItem(title: "Custom", filename: "custom.png", background: true, backdropSettings: BackdropSettings(style: .custom, padding: 10, customImage: background))
        let reload = try JSONDecoder().decode(CaptureItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(reload, item)
        XCTAssertNotNil(ImageRenderer.png(ImageRenderer.render(pattern(height: 100), marks: [], background: true, settings: reload.backdropSettings)))
    }
    @MainActor func testCorruptSettingsDoNotHideExistingCaptureHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureStore(root: root)
        XCTAssertTrue(store.add(image: pattern(height: 100)))
        try Data("invalid settings".utf8).write(to: root.appendingPathComponent("preferences.json"))
        let reopened = CaptureStore(root: root)
        XCTAssertEqual(reopened.items.count, 1)
        XCTAssertEqual(reopened.preferences, AppPreferences())
        XCTAssertNotNil(reopened.error)
    }
    func testClipRangeRejectsInvalidAndNonFiniteValues() {
        for clip in [VideoClip(start: -1, end: 1), .init(start: 1, end: 0), .init(start: 0, end: 4), .init(start: .nan, end: 1), .init(start: 0, end: .infinity)] {
            XCTAssertThrowsError(try clip.validated(sourceDuration: 3))
        }
        XCTAssertNoThrow(try VideoClip(start: 0.5, end: 2).validated(sourceDuration: 3))
    }
    private func makeVideo(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 120])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 120])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? MediaExportError.unsupported }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, Date() < deadline else { throw writer.error ?? MediaExportError.unsupported }
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 160, 120, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
            let pixelBuffer = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let pixels = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            for y in 0..<120 { for x in 0..<160 {
                let offset = y * stride + x * 4
                pixels[offset] = UInt8(frame * 7); pixels[offset + 1] = UInt8(x); pixels[offset + 2] = UInt8(y); pixels[offset + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)) else { throw writer.error ?? MediaExportError.unsupported }
        }
        writer.endSession(atSourceTime: CMTime(seconds: 3, preferredTimescale: 600))
        input.markAsFinished(); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
    func testRealMP4TrimAndGIFExportPreserveOriginalAndReplaceDestination() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mp4"), trimmed = folder.appendingPathComponent("clip.mp4"), gif = folder.appendingPathComponent("clip.gif")
        try await makeVideo(at: source)
        let original = try Data(contentsOf: source)
        let clip = VideoClip(start: 1, end: 2)
        try await VideoExporter.export(source: source, destination: trimmed, clip: clip, gif: false)
        let duration = try await AVURLAsset(url: trimmed).load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.12)
        try Data("existing file".utf8).write(to: gif)
        try await VideoExporter.export(source: source, destination: gif, clip: clip, gif: true, fps: 10, maxSize: 480)
        let images = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(images), 10)
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(images, 0, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(images, 9, nil))
        XCTAssertEqual(try Data(contentsOf: source), original)
        let validGIF = try Data(contentsOf: gif)
        let cancelled = Task { try await VideoExporter.export(source: source, destination: gif, clip: clip, gif: true) }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Cancelled export succeeded") } catch { }
        XCTAssertEqual(try Data(contentsOf: gif), validGIF)
        do {
            try await VideoExporter.export(source: source, destination: gif, clip: .init(start: 0, end: 10), gif: true)
            XCTFail("Invalid range was accepted")
        } catch { XCTAssertEqual(CGImageSourceGetCount(try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))), 10) }
        do {
            try await VideoExporter.export(source: source, destination: source, clip: clip, gif: false)
            XCTFail("Source overwrite was accepted")
        } catch { XCTAssertEqual(try Data(contentsOf: source), original) }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".stillframe-") })
    }
}
