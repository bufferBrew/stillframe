import AppKit
import SwiftUI

@MainActor
final class ScrollingCapture: ObservableObject {
    @Published var count = 0
    @Published var isBusy = false
    @Published var message = "Scroll down about half a screen, then Add Frame."
    @Published var manual = false
    @Published var overlapPercent = 50.0
    @Published var result: NSImage?
    private var region = CGRect.zero
    private var panel: NSPanel?
    private var picker: RegionPicker?
    var addShortcut = "⌃⇧⌘6"
    var finishShortcut = "⌃⇧⌘Return"
    var onFinish: ((NSImage, CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onError: ((String) -> Void)?
    var isActive: Bool { panel != nil || picker != nil }

    func begin(seed: NSImage? = nil, region seedRegion: CGRect? = nil) {
        guard !isActive else { panel?.orderFrontRegardless(); return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            onCancel?()
            onError?("Allow Stillframe in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen it. Rebuilt local apps may need access enabled again.")
            return
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { onCancel?(); return }
        result = seed; count = seed == nil ? 0 : 1; manual = false
        if let seedRegion, seedRegion.width > 0, seedRegion.height > 0, seed != nil {
            region = seedRegion
            message = "Scroll down with overlapping content, then Add Frame. Your screenshot is frame 1."
            showControls(screen: screen)
        } else {
            let picker = RegionPicker(); self.picker = picker
            picker.choose { [weak self] rect in
                guard let self else { return }
                self.picker = nil
                guard let rect else { self.result = nil; self.count = 0; self.onCancel?(); return }
                self.region = rect
                self.showControls(screen: screen)
                if self.result == nil { self.addFrame() }
                else { self.message = "Use the same region as the original screenshot. Scroll down, then Add Frame." }
            }
        }
    }
    private func showControls(screen: NSScreen) {
        let control = NSPanel(contentRect: NSRect(x: screen.visibleFrame.maxX - 430, y: screen.visibleFrame.minY + 24, width: 400, height: 380), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        control.title = "Scrolling Capture"; control.level = .floating; control.isReleasedWhenClosed = false
        control.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        control.contentView = NSHostingView(rootView: ScrollControls(session: self))
        panel = control; NSApp.unhide(nil); control.orderFrontRegardless()
    }
    func addFrame() {
        guard !isBusy, panel != nil else { return }
        isBusy = true; panel?.orderOut(nil)
        Task {
            defer { isBusy = false; panel?.orderFrontRegardless() }
            // Hide all Stillframe surfaces while sampling the fixed region.
            NSApp.hide(nil)
            try? await Task.sleep(for: .milliseconds(250))
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("stillframe-scroll-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: file); NSApp.unhide(nil) }
            do {
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-R\(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))", file.path]
                let status: Int32 = try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                    do { try process.run() } catch { continuation.resume(throwing: error) }
                }
                guard status == 0, let image = NSImage(data: try Data(contentsOf: file)) else { throw StitchError.invalidImage }
                if let previous = result {
                    let pixels = ImageRenderer.bitmap(image)?.pixelsHigh ?? 0
                    // Matching/rendering work runs off the UI executor.
                    let overlap = manual ? Int(Double(pixels) * overlapPercent / 100) : nil
                    guard let dataA = ImageRenderer.png(previous), let dataB = ImageRenderer.png(image) else { throw StitchError.invalidImage }
                    let data = try await Task.detached(priority: .userInitiated) {
                        guard let a = NSImage(data: dataA), let b = NSImage(data: dataB), let output = ImageRenderer.png(try ScrollStitcher.join(a, b, manualOverlap: overlap)) else { throw StitchError.invalidImage }
                        return output
                    }.value
                    result = NSImage(data: data)
                } else { result = image }
                count += 1; message = "Frame \(count) added. Scroll down, then add the next frame."
            } catch { message = error.localizedDescription }
        }
    }
    func finish() {
        guard !isBusy, panel != nil, let result else { return }
        panel?.close(); panel = nil; self.result = nil; count = 0
        onFinish?(result, region)
    }
    func cancel() {
        guard !isBusy else { return }
        if let picker { picker.cancel(); return }
        panel?.close(); panel = nil; result = nil; count = 0; onCancel?()
    }
}

private struct ScrollControls: View {
    @ObservedObject var session: ScrollingCapture
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label("\(session.count) frames", systemImage: "rectangle.stack").font(.headline); Spacer(); if session.isBusy { ProgressView().controlSize(.small) } }
            if let image = session.result {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 72).accessibilityLabel("Combined screenshot preview")
            }
            Text(session.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Toggle("Set overlap manually", isOn: $session.manual)
            if session.manual {
                HStack { Slider(value: $session.overlapPercent, in: 10...90, step: 1).accessibilityLabel("Frame overlap"); Text("\(Int(session.overlapPercent))%") }
            }
            Text("Scroll down in the target app, then press \(session.addShortcut) to extend. Press \(session.finishShortcut) to finish and copy.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { session.cancel() }
                Spacer()
                Button("Add Frame") { session.addFrame() }.buttonStyle(.borderedProminent)
                Button("Finish") { session.finish() }.disabled(session.result == nil)
            }
        }.padding(16).disabled(session.isBusy)
    }
}

@MainActor
final class RegionPicker {
    private var panel: NSPanel?
    private var completion: ((CGRect?) -> Void)?
    func choose(completion: @escaping (CGRect?) -> Void) {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { completion(nil); return }
        self.completion = completion
        let chooser = RegionSelectionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        chooser.title = "Select Capture Region"
        chooser.level = .screenSaver; chooser.isOpaque = false; chooser.backgroundColor = .clear
        chooser.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        chooser.isReleasedWhenClosed = false
        let view = RegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onSelect = { [weak self] rect in
            guard let self else { return }
            let global = rect?.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
            let result = global.map { CGRect(x: $0.minX, y: (NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY) - $0.maxY, width: $0.width, height: $0.height).integral }
            self.complete(result)
        }
        chooser.contentView = view; panel = chooser
        NSApp.unhide(nil); chooser.makeKeyAndOrderFront(nil); chooser.makeFirstResponder(view)
    }
    func cancel() { complete(nil) }
    private func complete(_ rect: CGRect?) {
        let action = completion; completion = nil
        panel?.orderOut(nil); panel = nil
        action?(rect)
    }
}

private final class RegionSelectionView: NSView {
    var onSelect: ((NSRect?) -> Void)?
    private var start: NSPoint?
    private var selection = NSRect.zero
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.3).setFill(); bounds.fill()
        NSColor.clear.setFill(); selection.fill(using: .copy)
        NSColor.white.setStroke(); let path = NSBezierPath(rect: selection); path.lineWidth = 2; path.stroke()
        ("Drag a region · Return for full display · Escape to cancel" as NSString).draw(at: NSPoint(x: 32, y: bounds.height - 60), withAttributes: [.font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor.white, .backgroundColor: NSColor.black.withAlphaComponent(0.7)])
    }
    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let end = convert(event.locationInWindow, from: nil)
        selection = NSRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        if selection.width >= 64, selection.height >= 64 { onSelect?(selection); onSelect = nil }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onSelect?(nil); onSelect = nil }
        else if event.keyCode == 36 { onSelect?(bounds); onSelect = nil }
        else { super.keyDown(with: event) }
    }
}

private final class RegionSelectionPanel: NSPanel { override var canBecomeKey: Bool { true } }
