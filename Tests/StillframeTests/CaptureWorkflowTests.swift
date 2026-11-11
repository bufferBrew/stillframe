import AppKit
import Carbon
import XCTest
@testable import Stillframe

final class CaptureWorkflowTests: XCTestCase {
    private func image() -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 120, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let bytes = rep.bitmapData!
        for y in 0..<120 { for x in 0..<160 {
            let offset = y * rep.bytesPerRow + x * 4
            bytes[offset] = 255; bytes[offset + 1] = 255; bytes[offset + 2] = 255; bytes[offset + 3] = 255
        } }
        let image = NSImage(size: NSSize(width: 160, height: 120)); image.addRepresentation(rep)
        return image
    }
    @MainActor func testCompletedCapturesAlwaysPublishPNGAndImageToClipboardEvenWithLegacyOptOut() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let board = NSPasteboard(name: .init("Stillframe.Tests.\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: root); board.releaseGlobally() }
        let first = CaptureStore(root: root, pasteboard: board)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppPreferences())) as? [String: Any])
        legacy["copyAfterCapture"] = false
        legacy["shortcuts"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(ShortcutBinding.defaults.prefix(3))))
        try JSONSerialization.data(withJSONObject: legacy).write(to: root.appendingPathComponent("preferences.json"))
        let store = CaptureStore(root: root, pasteboard: board)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.preferences.shortcuts.count, 5)
        var overlaySawClipboard = false
        store.onCapture = { overlaySawClipboard = board.data(forType: .png) != nil }
        for title in ["Area capture", "Fullscreen capture", "Window capture", "Scrolling capture"] {
            board.clearContents(); board.setString("previous clipboard", forType: .string)
            XCTAssertTrue(store.add(image: image(), title: title))
            store.didCapture()
            let data = try XCTUnwrap(board.data(forType: .png))
            XCTAssertEqual(NSBitmapImageRep(data: data)?.pixelsWide, 160)
            XCTAssertEqual(NSBitmapImageRep(data: data)?.pixelsHigh, 120)
            XCTAssertTrue(overlaySawClipboard)
            XCTAssertTrue(NSImage.canInit(with: board))
            XCTAssertEqual(store.notice, "Screenshot copied to clipboard")
        }
        _ = first
    }
    @MainActor func testExtensionSeedPreservesRedactionAndOmitsBackdropAndRegionSurvivesUndo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureStore(root: root)
        let rect = CGRect(x: 10, y: 20, width: 80, height: 60)
        XCTAssertTrue(store.add(image: image(), captureRect: rect))
        store.commit(Mark(tool: .redact, points: [.init(x: 0.1, y: 0.1), .init(x: 0.5, y: 0.5)]))
        store.setBackdrop(.init(style: .sunset, padding: 20))
        let seed = try XCTUnwrap(store.scrollingSeed.flatMap(ImageRenderer.bitmap))
        XCTAssertEqual(seed.pixelsWide, 160); XCTAssertEqual(seed.pixelsHigh, 120)
        XCTAssertLessThan(try XCTUnwrap(seed.colorAt(x: 40, y: 30)?.usingColorSpace(.sRGB)).redComponent, 0.02)
        let id = try XCTUnwrap(store.selectedID)
        let reopened = CaptureStore(root: root); reopened.select(id)
        XCTAssertEqual(reopened.selected?.captureRect, rect)
        store.commit(Mark(tool: .crop, points: [.init(x: 0, y: 0), .init(x: 0.75, y: 1)]))
        XCTAssertNil(store.selected?.captureRect)
        store.undo(); XCTAssertEqual(store.selected?.captureRect, rect)
    }
    func testLegacyShortcutsMigrateWithoutOverwritingUserChoiceOrCreatingConflict() {
        var preferences = AppPreferences()
        preferences.shortcuts = Array(ShortcutBinding.defaults.prefix(3))
        preferences.shortcuts[0].keyCode = 22 // user already owns the recommended scroll combination
        preferences.migrateShortcuts()
        XCTAssertEqual(preferences.shortcuts.count, 5)
        XCTAssertEqual(preferences.shortcuts[0].keyCode, 22)
        XCTAssertFalse(preferences.shortcuts[3].enabled)
        XCTAssertTrue(preferences.shortcuts[4].enabled)
        XCTAssertNil(ShortcutBinding.validationError(preferences.shortcuts))
        let migrated = preferences
        preferences.migrateShortcuts(); XCTAssertEqual(migrated, preferences)
    }
    func testShortcutChoicesSupportOptionOnlyPunctuationAndStandaloneFunctionKeys() {
        var bindings = ShortcutBinding.defaults
        bindings[0].keyCode = 122; bindings[0].modifiers = 0 // F1
        bindings[1].keyCode = 44; bindings[1].modifiers = UInt32(optionKey) // Option-/
        bindings[2].keyCode = 125; bindings[2].modifiers = UInt32(cmdKey) // Command-Down
        XCTAssertNil(ShortcutBinding.validationError(bindings))
        XCTAssertEqual(bindings[0].menuKey.unicodeScalars.first?.value, 0xF704)
        XCTAssertEqual(bindings[1].menuKey, "/")
        XCTAssertEqual(bindings[2].menuKey.unicodeScalars.first?.value, 0xF701)
        XCTAssertEqual(bindings[4].menuKey, "\r")
        bindings[1].modifiers = UInt32(shiftKey)
        XCTAssertNotNil(ShortcutBinding.validationError(bindings))
    }
}
