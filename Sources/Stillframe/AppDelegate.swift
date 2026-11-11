import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var store: CaptureStore!
    let recorder = Recorder()
    let scrolling = ScrollingCapture()
    private var window: NSWindow!
    private var overlay: NSPanel?
    private var pins: [NSPanel] = []
    private var status: NSStatusItem!
    private var hotKeys = HotKeys()
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let demo = CommandLine.arguments.contains("--demo")
        store = CaptureStore(root: demo ? FileManager.default.temporaryDirectory.appendingPathComponent("Stillframe-Demo", isDirectory: true) : nil)
        recorder.onFinish = { [weak self] url in self?.store.addVideo(url) }
        recorder.onError = { [weak self] message in self?.store.error = message; self?.showWindow() }
        store.onShow = { [weak self] in self?.showWindow() }
        store.onCapture = { [weak self] in self?.showQuickAccess() }
        store.onBeforeCapture = { [weak self] in self?.window?.orderOut(nil); self?.overlay?.orderOut(nil) }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Stillframe"
        window.setFrameAutosaveName("StillframeEditor")
        window.minSize = NSSize(width: 820, height: 600)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.contentView = NSHostingView(rootView: MainView(store: store, recorder: recorder, pin: { [weak self] in self?.pinImage() }, startScrolling: { [weak self] in self?.startScrolling() }, applyPreferences: { [weak self] value in self?.applyPreferences(value) ?? false }, extendScrolling: { [weak self] in self?.extendScrolling() }, settingsPresentation: { [weak self] editing in self?.setShortcutEditing(editing) }))
        scrolling.onError = { [weak self] message in self?.store.error = message; self?.showWindow() }
        scrolling.onCancel = { [weak self] in self?.store.isCapturing = false; self?.showWindow() }
        scrolling.onFinish = { [weak self] image, rect in
            guard let self else { return }
            self.store.isCapturing = false
            if self.store.add(image: image, title: "Scrolling capture", captureRect: rect) { self.store.didCapture() }
        }
        createMenus()
        hotKeys.onTrigger = { [weak self] id in
            Task { @MainActor in
                guard let self, !self.recorder.isBusy else { return }
                if id == 4 {
                    self.scrollOrAdd()
                    return
                }
                if id == 5 { self.scrolling.finish(); return }
                guard !self.store.isCapturing else { return }
                if id == 3 { self.toggleRecording() }
                else if !self.recorder.isRecording { self.store.capture(id == 1 ? "area" : "screen") }
            }
        }
        if !hotKeys.register(store.preferences.shortcuts) { store.notice = "A global shortcut is in use. Capture buttons and the menu bar are available." }
        recorder.$isRecording.combineLatest(recorder.$isBusy).sink { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshStatus() }
        }.store(in: &subscriptions)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshStatus() } }
        if demo && store.items.isEmpty { _ = store.add(image: Self.demoImage(), title: "Welcome to your clearer workflow") }
        else { store.select(store.items.first?.id) }
        showWindow()
    }
    @objc func showWindow() {
        overlay?.orderOut(nil)
        NSApp.unhide(nil); NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    @objc func area() { if !recorder.isRecording && !recorder.isBusy { store.capture("area") } }
    @objc func screen() { if !recorder.isRecording && !recorder.isBusy { store.capture("screen") } }
    @objc func captureWindow() { if !recorder.isRecording && !recorder.isBusy { store.capture("window") } }
    @objc func toggleRecording() {
        Task {
            guard !recorder.isBusy, !store.isCapturing else { return }
            if recorder.isRecording { await recorder.stop() }
            else { await recorder.start(to: store.makeURL(extension: "mp4"), systemAudio: store.systemAudio, fps: store.preferences.recordingFPS, maxWidth: store.preferences.recordingMaxWidth) }
        }
    }
    @objc func showSettings() { showWindow(); NotificationCenter.default.post(name: Notification.Name("StillframeSettings"), object: nil) }
    @objc func startScrolling() {
        guard !recorder.isRecording, !recorder.isBusy, !store.isCapturing else { return }
        store.isCapturing = true; window.orderOut(nil); overlay?.orderOut(nil)
        configureScrollingKeys()
        scrolling.begin()
    }
    @objc func extendScrolling() {
        guard !recorder.isRecording, !recorder.isBusy, !store.isCapturing,
              let selected = store.selected, selected.kind == "image", let frozen = store.scrollingSeed else { return }
        store.isCapturing = true; window.orderOut(nil); overlay?.orderOut(nil)
        configureScrollingKeys()
        scrolling.begin(seed: frozen, region: selected.captureRect)
    }
    private func configureScrollingKeys() {
        scrolling.addShortcut = store.preferences.shortcuts.first { $0.id == 4 }?.label ?? "Scroll & Capture"
        scrolling.finishShortcut = store.preferences.shortcuts.first { $0.id == 5 }?.label ?? "Finish"
    }
    private func setShortcutEditing(_ editing: Bool) {
        if editing { hotKeys.suspend() }
        else if !hotKeys.register(store.preferences.shortcuts) { store.notice = "A shortcut is unavailable. Capture buttons remain available; choose another combination in Settings." }
    }
    private func applyPreferences(_ value: AppPreferences) -> Bool {
        let previous = store.preferences
        guard hotKeys.register(value.shortcuts) else { return false }
        do { try store.savePreferences(value); updateShortcutMenus(); return true }
        catch { _ = hotKeys.register(previous.shortcuts); return false }
    }
    private func updateShortcutMenus() {
        for shortcut in store.preferences.shortcuts {
            if let item = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTag: Int(shortcut.id)) {
                item.keyEquivalent = shortcut.enabled ? shortcut.menuKey : ""
                item.keyEquivalentModifierMask = shortcut.eventModifiers
            }
        }
    }
    @objc func scrollOrAdd() { if scrolling.isActive { scrolling.scrollAndCapture() } else { startScrolling() } }
    @objc func finishScrolling() { scrolling.finish() }
    @objc func importImage() { showWindow(); store.importImage() }
    @objc func pasteImage() { showWindow(); store.pasteImage() }
    @objc func copyImage() { store.copyImage() }
    @objc func exportImage() { store.export() }
    @objc func undoEdit() { store.undo() }
    @objc func redoEdit() { store.redo() }
    @objc func openPrivacy() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
    @objc func quit() {
        if recorder.isRecording {
            Task { await recorder.stop() }
            store.notice = "Finishing recording. Quit again once it is saved."
        } else if !recorder.isBusy { NSApp.terminate(nil) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if scrolling.isActive {
            store.notice = "Finish or cancel the scrolling capture before quitting."; return .terminateCancel
        }
        if recorder.isRecording || recorder.isBusy {
            store.notice = "Stop the recording and wait for it to save before quitting."
            showWindow(); return .terminateCancel
        }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for file in filenames {
            if let image = NSImage(contentsOfFile: file) { _ = store.add(image: image, title: URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent) }
        }
        showWindow(); sender.reply(toOpenOrPrint: .success)
    }
    private func menuItem(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; item.keyEquivalentModifierMask = modifiers
        return item
    }
    private func createMenus() {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(NSMenuItem(title: "About Stillframe", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        app.addItem(menuItem("Settings…", #selector(showSettings), key: ","))
        app.addItem(menuItem("Screen Recording Permission…", #selector(openPrivacy)))
        app.addItem(.separator())
        let hide = NSMenuItem(title: "Hide Stillframe", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"); app.addItem(hide)
        app.addItem(menuItem("Quit Stillframe", #selector(quit), key: "q"))
        let appRoot = NSMenuItem(); appRoot.submenu = app; main.addItem(appRoot)
        let file = NSMenu(title: "File")
        let areaItem = menuItem("Capture Area", #selector(area)); areaItem.tag = 1; file.addItem(areaItem)
        file.addItem(menuItem("Capture Window", #selector(captureWindow)))
        let screenItem = menuItem("Capture Screen", #selector(screen)); screenItem.tag = 2; file.addItem(screenItem)
        let scrollItem = menuItem("Scroll & Capture", #selector(scrollOrAdd)); scrollItem.tag = 4; file.addItem(scrollItem)
        let finishItem = menuItem("Finish Scrolling Capture", #selector(finishScrolling)); finishItem.tag = 5; file.addItem(finishItem)
        file.addItem(menuItem("Extend Screenshot with Scrolling…", #selector(extendScrolling)))
        file.addItem(.separator())
        file.addItem(menuItem("Import Image…", #selector(importImage), key: "o"))
        file.addItem(menuItem("Export…", #selector(exportImage), key: "s"))
        let fileRoot = NSMenuItem(title: "File", action: nil, keyEquivalent: ""); fileRoot.submenu = file; main.addItem(fileRoot)
        let edit = NSMenu(title: "Edit")
        edit.addItem(menuItem("Undo Annotation", #selector(undoEdit), key: "z"))
        edit.addItem(menuItem("Redo Annotation", #selector(redoEdit), key: "z", modifiers: [.command, .shift]))
        edit.addItem(.separator())
        // Standard responder actions preserve text-field editing shortcuts.
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        edit.addItem(menuItem("Copy Edited Image", #selector(copyImage), key: "c", modifiers: [.command, .shift]))
        edit.addItem(menuItem("Paste Image", #selector(pasteImage), key: "v", modifiers: [.command, .shift]))
        let editRoot = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); editRoot.submenu = edit; main.addItem(editRoot)
        let windows = NSMenu(title: "Window")
        windows.addItem(menuItem("Show Library", #selector(showWindow), key: "0"))
        windows.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        let windowRoot = NSMenuItem(title: "Window", action: nil, keyEquivalent: ""); windowRoot.submenu = windows; main.addItem(windowRoot)
        NSApp.mainMenu = main; NSApp.windowsMenu = windows
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Stillframe capture")
        status.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.addItem(menuItem("Open Stillframe", #selector(showWindow)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Capture Area", #selector(area)))
        menu.addItem(menuItem("Capture Window", #selector(captureWindow)))
        menu.addItem(menuItem("Capture Screen", #selector(screen)))
        menu.addItem(menuItem("Scrolling Capture…", #selector(startScrolling)))
        menu.addItem(.separator())
        let record = menuItem("Start Recording", #selector(toggleRecording)); record.tag = 99; menu.addItem(record)
        menu.addItem(menuItem("Import Image…", #selector(importImage)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Stillframe", #selector(quit)))
        menu.addItem(menuItem("Settings…", #selector(showSettings)))
        status.menu = menu
        updateShortcutMenus()
    }
    private func refreshStatus() {
        guard status != nil else { return }
        if let start = recorder.startedAt, recorder.isRecording {
            let seconds = max(0, Int(Date().timeIntervalSince(start)))
            status.button?.title = String(format: " ● %02d:%02d", seconds / 60, seconds % 60)
        } else { status.button?.title = recorder.isBusy ? " …" : "" }
        status.menu?.item(withTag: 99)?.title = recorder.isBusy ? "Finishing / Starting…" : recorder.isRecording ? "Stop Recording" : "Start Recording"
        status.menu?.item(withTag: 99)?.isEnabled = !recorder.isBusy
    }
    private func showQuickAccess() {
        overlay?.close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 280), styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Captured"
        panel.level = .floating; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: QuickAccessView(store: store, edit: { [weak self] in self?.showWindow() }, pin: { [weak self] in self?.pinImage() }, extend: { [weak self] in self?.extendScrolling() }))
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        if let frame = screen?.visibleFrame { panel.setFrameOrigin(NSPoint(x: frame.maxX - 340, y: frame.minY + 24)) }
        overlay = panel; panel.orderFrontRegardless()
    }
    private func pinImage() {
        guard let image = store.rendered else { return }
        pins.removeAll { !$0.isVisible }
        let scale = min(1, 600 / image.size.width, 500 / image.size.height)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: max(160, image.size.width * scale), height: max(100, image.size.height * scale)), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = store.selected?.title ?? "Pinned screenshot"
        panel.level = .floating; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(8))
        panel.center(); panel.orderFrontRegardless(); pins.append(panel)
    }
    static func demoImage() -> NSImage {
        NSImage(size: NSSize(width: 1200, height: 750), flipped: true) { _ in
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1200, height: 750).fill()
            NSColor(calibratedWhite: 0.96, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 1200, height: 64).fill()
            for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.setFill(); NSBezierPath(ovalIn: NSRect(x: 24 + index * 26, y: 24, width: 12, height: 12)).fill()
            }
            ("YOUR NEXT GREAT IDEA" as NSString).draw(at: NSPoint(x: 80, y: 160), withAttributes: [.font: NSFont.systemFont(ofSize: 18, weight: .medium), .foregroundColor: NSColor.systemIndigo])
            ("Less explaining.\nMore showing." as NSString).draw(at: NSPoint(x: 80, y: 220), withAttributes: [.font: NSFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: NSColor.black])
            ("Select a tool above. Drag to annotate, highlight, or redact.\nTry Copy Text to extract this text with on-device OCR." as NSString).draw(at: NSPoint(x: 84, y: 440), withAttributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.darkGray])
            NSColor.systemIndigo.setFill(); NSBezierPath(roundedRect: NSRect(x: 84, y: 560, width: 240, height: 56), xRadius: 12, yRadius: 12).fill()
            ("Make your point →" as NSString).draw(at: NSPoint(x: 108, y: 576), withAttributes: [.font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor.white])
            return true
        }
    }
}

private struct QuickAccessView: View {
    @ObservedObject var store: CaptureStore
    var edit: () -> Void
    var pin: () -> Void
    var extend: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            if let rendered = store.rendered { Image(nsImage: rendered).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 140).onDrag { NSItemProvider(object: rendered) } }
            HStack {
                Button("Edit", action: edit).buttonStyle(.borderedProminent)
                Button("Copy", action: store.copyImage)
                Button("Save", action: store.export)
                Button(action: pin) { Image(systemName: "pin") }.help("Pin screenshot")
            }
            Button("Extend with Scrolling…", action: extend).help("Continue this screenshot down the page")
            Text("Copied to clipboard · Drag to share").font(.caption).foregroundStyle(.secondary)
        }.padding(16)
    }
}
