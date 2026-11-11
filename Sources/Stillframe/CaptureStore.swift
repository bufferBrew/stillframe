import AppKit
import SwiftUI
import Vision
import UniformTypeIdentifiers

@MainActor
final class CaptureStore: ObservableObject {
    @Published private(set) var preferences = AppPreferences()
    @Published var items: [CaptureItem] = []
    @Published var selectedID: UUID?
    @Published var image: NSImage?
    @Published var tool: MarkTool = .arrow
    @Published var ink: Ink = .orange
    @Published var stroke: Double = 4
    @Published var text = "Note"
    @Published var isCapturing = false
    @Published var isRecognizing = false
    @Published var error: String?
    @Published var notice: String?
    @Published var revision = 0
    @Published var delay = 0
    @Published var systemAudio = false
    @Published var search = ""
    @Published var filter = "all"
    let root: URL
    let pasteboard: NSPasteboard
    private var regionPicker: RegionPicker?
    private var undoStack: [EditSnapshot] = []
    private var redoStack: [EditSnapshot] = []
    var onCapture: (() -> Void)?
    var onBeforeCapture: (() -> Void)?
    var onShow: (() -> Void)?

    init(root: URL? = nil, pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Stillframe", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            let settings = self.root.appendingPathComponent("preferences.json")
            if FileManager.default.fileExists(atPath: settings.path) {
                preferences = try JSONDecoder().decode(AppPreferences.self, from: Data(contentsOf: settings))
                preferences.migrateShortcuts()
                delay = preferences.captureDelay; systemAudio = preferences.recordSystemAudio
            }
        } catch { self.error = "Could not load settings; using defaults: \(error.localizedDescription)" }
        do {
            let manifest = self.root.appendingPathComponent("history.json")
            if FileManager.default.fileExists(atPath: manifest.path) {
                items = try JSONDecoder().decode([CaptureItem].self, from: Data(contentsOf: manifest))
            }
        } catch { self.error = "Could not load capture history: \(error.localizedDescription)" }
    }

    var selected: CaptureItem? { items.first { $0.id == selectedID } }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var visibleItems: [CaptureItem] {
        items.filter { (filter == "all" || $0.kind == filter) && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
    }
    var rendered: NSImage? {
        guard let image, let selected, selected.kind == "image" else { return nil }
        return ImageRenderer.render(image, marks: selected.marks, background: selected.background, settings: selected.backdropSettings)
    }
    var scrollingSeed: NSImage? {
        guard let image, let selected, selected.kind == "image",
              let data = ImageRenderer.png(ImageRenderer.render(image, marks: selected.marks)) else { return nil }
        // Existing annotations/redactions become pixels; a decorative backdrop is excluded.
        return NSImage(data: data)
    }
    func url(for item: CaptureItem) -> URL { root.appendingPathComponent(item.filename) }
    func makeURL(extension ext: String) -> URL { root.appendingPathComponent("\(UUID().uuidString).\(ext)") }

    func select(_ id: UUID?) {
        guard selectedID != id else { return }
        selectedID = id
        image = selected.flatMap { $0.kind == "image" ? NSImage(contentsOf: url(for: $0)) : nil }
        undoStack.removeAll(); redoStack.removeAll(); revision += 1
    }
    func persist() {
        do { try JSONEncoder().encode(items).write(to: root.appendingPathComponent("history.json"), options: .atomic) }
        catch { self.error = "Could not save capture history: \(error.localizedDescription)" }
    }
    @discardableResult
    func add(image: NSImage, title: String = "Screenshot", captureRect: CGRect? = nil) -> Bool {
        guard let data = ImageRenderer.png(image) else { error = "This image could not be decoded."; return false }
        let file = makeURL(extension: "png")
        do {
            try data.write(to: file, options: .atomic)
            let item = CaptureItem(title: title, filename: file.lastPathComponent, backdropSettings: preferences.backdrop, captureRect: captureRect)
            items.insert(item, at: 0); select(item.id); persist()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func addVideo(_ url: URL) {
        let item = CaptureItem(title: "Screen recording", filename: url.lastPathComponent, kind: "video")
        items.insert(item, at: 0); select(item.id); persist(); onShow?()
    }
    func importImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .bmp]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) {
            _ = add(image: image, title: url.deletingPathExtension().lastPathComponent)
        }
    }
    func pasteImage() {
        guard let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage], let image = images.first else {
            notice = "Copy an image, then choose Paste Image."; return
        }
        _ = add(image: image, title: "Pasted image")
    }
    func capture(_ mode: String) {
        guard !isCapturing else { return }
        isCapturing = true
        Task {
            guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
                error = "Allow Stillframe in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen Stillframe."
                isCapturing = false; return
            }
            onBeforeCapture?()
            NSApp.hide(nil)
            try? await Task.sleep(for: .milliseconds(350 + delay * 1000))
            var capturedRect: CGRect?
            if mode == "area" {
                capturedRect = await withCheckedContinuation { continuation in
                    let picker = RegionPicker(); regionPicker = picker
                    picker.choose { rect in continuation.resume(returning: rect) }
                }
                regionPicker = nil
                guard capturedRect != nil else { isCapturing = false; onShow?(); return }
                NSApp.hide(nil)
                try? await Task.sleep(for: .milliseconds(150))
            } else if mode == "screen" { capturedRect = CGDisplayBounds(CGMainDisplayID()) }
            let file = makeURL(extension: "png")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            var args = ["-x", "-t", "png"]
            if mode == "area", let rect = capturedRect { args.append("-R\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))") }
            else if mode == "window" { args += ["-i", "-w"] }
            else { args += ["-m"] }
            if mode == "screen", preferences.includeCursor { args.append("-C") }
            if mode == "window", !preferences.windowShadow { args.append("-o") }
            args.append(file.path)
            process.arguments = args
            let diagnostics = Pipe(); process.standardError = diagnostics
            do {
                let code: Int32 = try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                    do { try process.run() } catch { continuation.resume(throwing: error) }
                }
                if let result = NSImage(contentsOf: file) {
                    let item = CaptureItem(title: mode == "window" ? "Window capture" : mode == "area" ? "Area capture" : "Fullscreen capture", filename: file.lastPathComponent, backdropSettings: preferences.backdrop, captureRect: capturedRect)
                    items.insert(item, at: 0); select(item.id); image = result; persist()
                    NSApp.unhide(nil); didCapture()
                } else {
                    try? FileManager.default.removeItem(at: file)
                    if code != 0 && mode == "screen" { error = "Screen capture failed. Check Stillframe’s Screen Recording permission in System Settings." }
                    onShow?()
                }
            } catch { self.error = error.localizedDescription; onShow?() }
            isCapturing = false
        }
    }
    private func snapshot() -> EditSnapshot? {
        guard let image, let selected, let data = ImageRenderer.png(image) else { return nil }
        return EditSnapshot(imageData: data, marks: selected.marks, background: selected.background, backdropSettings: selected.backdropSettings, captureRect: selected.captureRect)
    }
    func commit(_ mark: Mark) {
        guard let index = items.firstIndex(where: { $0.id == selectedID }), let snapshot = snapshot() else { return }
        if mark.tool == .crop {
            guard let image, let first = mark.points.first, let last = mark.points.last,
                  let cropped = ImageRenderer.crop(ImageRenderer.render(image, marks: items[index].marks), from: first, to: last),
                  let data = ImageRenderer.png(cropped) else { return }
            do { try data.write(to: url(for: items[index]), options: .atomic) }
            catch { self.error = error.localizedDescription; return }
            self.image = cropped; items[index].marks = []; items[index].captureRect = nil
        } else { items[index].marks.append(mark) }
        undoStack.append(snapshot); redoStack.removeAll(); revision += 1; persist()
    }
    func toggleBackground() {
        guard let index = items.firstIndex(where: { $0.id == selectedID }), let snapshot = snapshot() else { return }
        undoStack.append(snapshot); redoStack.removeAll(); items[index].background.toggle(); revision += 1; persist()
    }
    private func restore(_ snapshot: EditSnapshot) {
        guard let index = items.firstIndex(where: { $0.id == selectedID }), let restored = NSImage(data: snapshot.imageData) else { return }
        do { try snapshot.imageData.write(to: url(for: items[index]), options: .atomic) }
        catch { self.error = error.localizedDescription; return }
        image = restored; items[index].marks = snapshot.marks; items[index].background = snapshot.background; items[index].backdropSettings = snapshot.backdropSettings; items[index].captureRect = snapshot.captureRect
        revision += 1; persist()
    }
    func undo() {
        guard let current = snapshot(), let previous = undoStack.popLast() else { return }
        redoStack.append(current); restore(previous)
    }
    func redo() {
        guard let current = snapshot(), let next = redoStack.popLast() else { return }
        undoStack.append(current); restore(next)
    }
    func copyImage() {
        guard let rendered else { return }
        guard let png = ImageRenderer.png(rendered) else { error = "Could not copy the captured image."; return }
        let tiff = rendered.tiffRepresentation
        pasteboard.declareTypes(tiff == nil ? [.png] : [.png, .tiff], owner: nil)
        guard pasteboard.setData(png, forType: .png) else {
            error = "The clipboard is currently unavailable."
            return
        }
        if let tiff { pasteboard.setData(tiff, forType: .tiff) }
        notice = "Screenshot copied to clipboard"
    }
    func export() {
        guard let selected else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = selected.kind == "video" ? [.mpeg4Movie] : (preferences.imageFormat == "jpg" ? [.jpeg, .png] : [.png, .jpeg])
        panel.nameFieldStringValue = selected.title + (selected.kind == "video" ? ".mp4" : "." + preferences.imageFormat)
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            if selected.kind == "video" {
                if target.standardizedFileURL == url(for: selected).standardizedFileURL { return }
                // Data.write(.atomic) supports replacing an existing file selected in NSSavePanel.
                try Data(contentsOf: url(for: selected), options: .mappedIfSafe).write(to: target, options: .atomic)
            } else {
                guard let rendered, let bitmap = ImageRenderer.bitmap(rendered),
                      let data = bitmap.representation(using: target.pathExtension.lowercased() == "jpg" || target.pathExtension.lowercased() == "jpeg" ? .jpeg : .png, properties: [.compressionFactor: 0.95]) else { return }
                try data.write(to: target, options: .atomic)
            }
            notice = "Saved \(target.lastPathComponent)"
        } catch { self.error = error.localizedDescription }
    }
    func copyText() {
        guard !isRecognizing, let rendered, let cg = ImageRenderer.bitmap(rendered)?.cgImage else { return }
        isRecognizing = true
        Task {
            do {
                let recognized = try await Task.detached(priority: .userInitiated) {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
                    try VNImageRequestHandler(cgImage: cg).perform([request])
                    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                }.value
                if recognized.isEmpty { notice = "No text found in this image" }
                else { pasteboard.clearContents(); pasteboard.setString(recognized, forType: .string); notice = "Recognized text copied" }
            } catch { self.error = "Text recognition failed: \(error.localizedDescription)" }
            isRecognizing = false
        }
    }
    func removeSelected() {
        guard let selected else { return }
        do { try FileManager.default.removeItem(at: url(for: selected)) }
        catch { self.error = error.localizedDescription; return }
        items.removeAll { $0.id == selected.id }; select(items.first?.id); persist()
    }
    func savePreferences(_ value: AppPreferences) throws {
        try JSONEncoder().encode(value).write(to: root.appendingPathComponent("preferences.json"), options: .atomic)
        preferences = value; delay = value.captureDelay; systemAudio = value.recordSystemAudio
    }
    func setBackdrop(_ settings: BackdropSettings) {
        guard let index = items.firstIndex(where: { $0.id == selectedID }), let snapshot = snapshot() else { return }
        undoStack.append(snapshot); redoStack.removeAll()
        items[index].backdropSettings = settings; items[index].background = true
        revision += 1; persist()
    }
    func didCapture() {
        copyImage()
        if preferences.openEditorAfterCapture { onShow?() } else { onCapture?() }
    }
    func rename(_ title: String) {
        guard let index = items.firstIndex(where: { $0.id == selectedID }), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        items[index].title = title; persist()
    }
}
