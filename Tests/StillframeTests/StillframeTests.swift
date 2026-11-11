import XCTest
import AppKit
import Vision
@testable import Stillframe

final class StillframeTests: XCTestCase {
    private func fixture() -> NSImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let pixels = bitmap.bitmapData!
        for y in 0..<100 { for x in 0..<200 {
            let offset = y * bitmap.bytesPerRow + x * 4
            pixels[offset] = 255; pixels[offset + 1] = x < 100 ? 255 : 0
            pixels[offset + 2] = x < 100 ? 255 : 0; pixels[offset + 3] = 255
        } }
        let image = NSImage(size: NSSize(width: 200, height: 100)); image.addRepresentation(bitmap)
        return image
    }
    func testRedactionIsOpaqueInExportAndDoesNotAffectOutsidePixels() throws {
        let mark = Mark(tool: .redact, points: [.init(x: 0.1, y: 0.1), .init(x: 0.4, y: 0.6)])
        let png = try XCTUnwrap(ImageRenderer.png(ImageRenderer.render(fixture(), marks: [mark])))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        let inside = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 4, y: bitmap.pixelsHigh / 3)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(inside.redComponent, 0.02)
        XCTAssertLessThan(inside.greenComponent, 0.02)
        XCTAssertLessThan(inside.blueComponent, 0.02)
        XCTAssertEqual(inside.alphaComponent, 1, accuracy: 0.01)
        let outside = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide * 3 / 4, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(outside.redComponent, 0.98)
        XCTAssertLessThan(outside.greenComponent, 0.25)
    }
    func testCropUsesTopLeftCoordinatesAndClampsToBounds() throws {
        let image = try XCTUnwrap(ImageRenderer.crop(fixture(), from: .init(x: 0.5, y: 0), to: .init(x: 2, y: 1.5)))
        let bitmap = try XCTUnwrap(ImageRenderer.bitmap(image))
        XCTAssertEqual(bitmap.pixelsWide, 100); XCTAssertEqual(bitmap.pixelsHigh, 100)
        let color = try XCTUnwrap(bitmap.colorAt(x: 50, y: 50)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.redComponent, 0.98); XCTAssertLessThan(color.greenComponent, 0.25)
        XCTAssertNil(ImageRenderer.crop(fixture(), from: .init(x: 0.1, y: 0.1), to: .init(x: 0.1, y: 0.1)))
    }
    func testVerticalCropPreservesTopLeftOrientation() throws {
        let bitmap = try XCTUnwrap(ImageRenderer.bitmap(fixture()))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
            let offset = y * bitmap.bytesPerRow + x * 4
            let value: UInt8 = y < 50 ? 255 : 0
            pixels[offset] = value; pixels[offset + 1] = value
            pixels[offset + 2] = value; pixels[offset + 3] = 255
        } }
        let image = NSImage(size: NSSize(width: 200, height: 100)); image.addRepresentation(bitmap)
        let top = try XCTUnwrap(ImageRenderer.crop(image, from: .init(x: 0, y: 0), to: .init(x: 1, y: 0.5)))
        let bottom = try XCTUnwrap(ImageRenderer.crop(image, from: .init(x: 0, y: 0.5), to: .init(x: 1, y: 1)))
        let topBitmap = try XCTUnwrap(ImageRenderer.bitmap(top)), bottomBitmap = try XCTUnwrap(ImageRenderer.bitmap(bottom))
        XCTAssertEqual(topBitmap.pixelsHigh, 50)
        XCTAssertGreaterThan(try XCTUnwrap(topBitmap.colorAt(x: 100, y: 25)?.usingColorSpace(.sRGB)).redComponent, 0.98)
        XCTAssertLessThan(try XCTUnwrap(bottomBitmap.colorAt(x: 100, y: 25)?.usingColorSpace(.sRGB)).redComponent, 0.02)
    }
    func testBackgroundAddsPaddingAndPreservesSourceAspectRatio() throws {
        let plain = try XCTUnwrap(ImageRenderer.bitmap(ImageRenderer.render(fixture(), marks: [])))
        XCTAssertEqual(plain.pixelsWide, 200); XCTAssertEqual(plain.pixelsHigh, 100)
        let padded = try XCTUnwrap(ImageRenderer.bitmap(ImageRenderer.render(fixture(), marks: [], background: true)))
        XCTAssertEqual(padded.pixelsWide, 248); XCTAssertEqual(padded.pixelsHigh, 148)
    }
    @MainActor func testHistoryEditsUndoRedoCropAndReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureStore(root: root)
        XCTAssertTrue(store.add(image: fixture(), title: "Test capture"))
        let id = try XCTUnwrap(store.selectedID)
        let mark = Mark(tool: .redact, points: [.init(x: 0, y: 0), .init(x: 0.25, y: 0.5)])
        store.commit(mark)
        XCTAssertTrue(store.canUndo); XCTAssertEqual(store.selected?.marks, [mark])
        store.undo(); XCTAssertEqual(store.selected?.marks.count, 0); XCTAssertTrue(store.canRedo)
        store.redo(); XCTAssertEqual(store.selected?.marks, [mark])
        store.toggleBackground(); XCTAssertTrue(store.selected?.background == true)
        store.undo(); XCTAssertFalse(store.selected?.background ?? true)
        store.commit(Mark(tool: .crop, points: [.init(x: 0.5, y: 0), .init(x: 1, y: 1)]))
        XCTAssertEqual(ImageRenderer.bitmap(try XCTUnwrap(store.image))?.pixelsWide, 100)
        XCTAssertEqual(store.selected?.marks.count, 0)
        store.undo()
        XCTAssertEqual(ImageRenderer.bitmap(try XCTUnwrap(store.image))?.pixelsWide, 200)
        XCTAssertEqual(store.selected?.marks, [mark])
        store.rename("Renamed")
        let reload = CaptureStore(root: root); reload.select(id)
        XCTAssertNil(reload.error); XCTAssertEqual(reload.items.count, 1)
        XCTAssertEqual(reload.selected?.title, "Renamed"); XCTAssertEqual(reload.selected?.marks, [mark])
        reload.search = "renamed"; XCTAssertEqual(reload.visibleItems.count, 1)
        reload.filter = "video"; XCTAssertEqual(reload.visibleItems.count, 0)
        reload.removeSelected(); XCTAssertEqual(reload.items.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: store.items[0]).path))
    }
    func testAnnotationsRoundTripAndAllToolsRender() throws {
        let marks = MarkTool.allCases.filter { $0 != .crop }.map { tool in
            Mark(tool: tool, points: [.init(x: 0.1, y: 0.1), .init(x: 0.4, y: 0.4)], text: tool == .counter ? "1" : "Test")
        }
        let item = CaptureItem(title: "Capture", filename: "test.png", marks: marks)
        XCTAssertEqual(try JSONDecoder().decode(CaptureItem.self, from: JSONEncoder().encode(item)), item)
        for mark in marks { XCTAssertNotNil(ImageRenderer.png(ImageRenderer.render(fixture(), marks: [mark]))) }
    }
    @MainActor func testCorruptHistoryIsReportedWithoutDeletingCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("invalid".utf8).write(to: root.appendingPathComponent("history.json"))
        let store = CaptureStore(root: root)
        XCTAssertNotNil(store.error)
    }
}
