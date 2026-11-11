import SwiftUI
import AVKit

// Native semantic colors, system type, standard controls and an 8-point spacing scale.
private enum Layout {
    static let gap: CGFloat = 8
    static let inset: CGFloat = 16
}

struct MainView: View {
    @ObservedObject var store: CaptureStore
    @ObservedObject var recorder: Recorder
    var pin: () -> Void
    var startScrolling: () -> Void
    var applyPreferences: (AppPreferences) -> Bool
    var extendScrolling: () -> Void
    var settingsPresentation: (Bool) -> Void
    @State private var confirmDelete = false
    @State private var showRename = false
    @State private var newTitle = ""
    @State private var showHelp = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            captureBar
            Divider()
            HSplitView {
                sidebar.frame(minWidth: 210, idealWidth: 240, maxWidth: 310)
                workspace.frame(minWidth: 520)
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 800, minHeight: 560)
        .alert("Stillframe needs your attention", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK", role: .cancel) { store.error = nil }
            Button("Open Privacy Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
        } message: { Text(store.error ?? "") }
        .alert("Delete this capture?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { store.removeSelected() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("The local capture and its edits will be permanently removed.") }
        .alert("Rename capture", isPresented: $showRename) {
            TextField("Capture name", text: $newTitle)
            Button("Rename") { store.rename(newTitle) }
            Button("Cancel", role: .cancel) { }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("StillframeSettings"))) { _ in showSettings = true }
        .sheet(isPresented: $showSettings) {
            SettingsView(draft: store.preferences, apply: applyPreferences)
                .onAppear { settingsPresentation(true) }
                .onDisappear { settingsPresentation(false) }
        }
        .sheet(isPresented: $showHelp) {
            VStack(alignment: .leading, spacing: 16) {
                Label("Welcome to Stillframe", systemImage: "viewfinder").font(.title2.bold())
                Text("Capture. Make your point. Share.").foregroundStyle(.secondary)
                Text("Choose Area, Window, or Screen to take a screenshot. Use the tools above the image to drag annotations; Text and Step place a mark with a click. Crop flattens the current annotations and supports Undo.")
                Text(store.preferences.shortcuts.map { "\($0.label)  \($0.title)" }.joined(separator: "\n"))
                Text("All captures stay on this Mac. Screen capture and recording need Screen & System Audio Recording permission in System Settings. Recording captures the main display; Stillframe’s own windows are excluded.")
                Text("Import an image to try editing without screen permissions.").font(.callout)
                Button("Get started") { showHelp = false }.keyboardShortcut(.defaultAction)
            }.padding(32).frame(width: 470)
        }
    }

    private var captureBar: some View {
        ViewThatFits(in: .horizontal) {
            captureControls.fixedSize(horizontal: true, vertical: false).frame(maxWidth: .infinity)
            captureControls.labelStyle(.iconOnly)
        }
        .buttonStyle(.bordered)
        .padding(Layout.inset)
        .disabled(store.isCapturing)
    }
    private var captureControls: some View {
        HStack(spacing: Layout.gap * 2) {
            Label("Stillframe", systemImage: "viewfinder").font(.title3.bold())
            Divider().frame(height: 24)
            Button { store.capture("area") } label: { Label("Area", systemImage: "selection.pin.in.out") }.help("Capture an area · " + shortcut(1))
            Button { store.capture("window") } label: { Label("Window", systemImage: "macwindow") }
            Button { store.capture("screen") } label: { Label("Screen", systemImage: "display") }.help("Capture main display · " + shortcut(2))
            Button(action: startScrolling) { Label("Scroll", systemImage: "scroll") }.help("Join a scrolling region into one image")
            Menu {
                Picker("Capture delay", selection: $store.delay) {
                    Text("No delay").tag(0); Text("3 seconds").tag(3); Text("5 seconds").tag(5); Text("10 seconds").tag(10)
                }
            } label: { Label(store.delay == 0 ? "Timer" : "\(store.delay)s", systemImage: "timer") }.fixedSize()
            Spacer(minLength: 8)
            if recorder.isRecording || recorder.isBusy {
                if let start = recorder.startedAt { Text(start, style: .timer).monospacedDigit().foregroundStyle(.red) }
                Button { Task { await recorder.stop() } } label: { Label("Stop", systemImage: "stop.circle.fill") }
                    .tint(.red).disabled(recorder.isBusy)
            } else {
                Toggle("Audio", isOn: $store.systemAudio).toggleStyle(.checkbox).help("Include system audio in recordings")
                Button { record() } label: { Label("Record", systemImage: "record.circle") }.help("Record main display · " + shortcut(3))
            }
            Button { showSettings = true } label: { Image(systemName: "gearshape") }.help("Settings · ⌘,").accessibilityLabel("Settings")
        }
    }
    private func record() {
        Task { await recorder.start(to: store.makeURL(extension: "mp4"), systemAudio: store.systemAudio, fps: store.preferences.recordingFPS, maxWidth: store.preferences.recordingMaxWidth) }
    }
    private func shortcut(_ id: UInt32) -> String { store.preferences.shortcuts.first { $0.id == id }?.label ?? "Off" }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("LIBRARY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Import Image…", action: store.importImage)
                    Button("Paste Image", action: store.pasteImage)
                } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).fixedSize().help("Add an image")
            }.padding(.horizontal, Layout.inset).padding(.top, Layout.inset)
            TextField("Search captures", text: $store.search).textFieldStyle(.roundedBorder).padding(.horizontal, Layout.inset)
            Picker("Capture type", selection: $store.filter) {
                Text("All").tag("all"); Text("Images").tag("image"); Text("Videos").tag("video")
            }.pickerStyle(.segmented).padding(.horizontal, Layout.inset)
            List(selection: Binding(get: { store.selectedID }, set: { store.select($0) })) {
                ForEach(store.visibleItems) { item in
                    CaptureRow(item: item, url: store.url(for: item), revision: store.revision).tag(item.id)
                        .contextMenu {
                            Button("Rename…") { store.select(item.id); newTitle = item.title; showRename = true }
                            if item.kind == "image" {
                                Button("Extend with Scrolling…") { store.select(item.id); extendScrolling() }
                            }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.url(for: item)]) }
                            Divider()
                            Button("Delete…", role: .destructive) { store.select(item.id); confirmDelete = true }
                        }
                }
            }.listStyle(.sidebar)
            if store.visibleItems.isEmpty {
                Text(store.search.isEmpty ? "Your captures will appear here." : "No matching captures.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, Layout.inset).padding(.bottom, Layout.inset)
            }
        }.background(.background)
    }
    @ViewBuilder private var workspace: some View {
        if let selected = store.selected {
            if selected.kind == "video" {
                VideoWorkspace(url: store.url(for: selected), exportOriginal: store.export, reportError: { store.error = $0 }, reportSuccess: { store.notice = $0 }).id(selected.id)
            } else if store.image != nil {
                VStack(spacing: 0) {
                    editorTools
                    Divider()
                    EditorCanvas(store: store)
                    Divider()
                    VStack(spacing: Layout.gap) {
                      HStack(spacing: 12) {
                        Text(selected.title).font(.callout.weight(.medium)).lineLimit(1)
                        if let bitmap = store.image.flatMap(ImageRenderer.bitmap) {
                            Text("\(bitmap.pixelsWide) × \(bitmap.pixelsHigh)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Spacer()
                      }
                      HStack(spacing: 12) {
                        Button(action: extendScrolling) { Label("Extend…", systemImage: "scroll") }.help("Extend this screenshot while scrolling")
                        Button(action: store.copyText) { Label(store.isRecognizing ? "Reading…" : "Copy Text", systemImage: "text.viewfinder") }.disabled(store.isRecognizing)
                        Button(action: pin) { Image(systemName: "pin") }.help("Pin above other windows")
                        Button(action: store.copyImage) { Label("Copy", systemImage: "doc.on.doc") }
                        Spacer(minLength: 0)
                        Button(action: store.export) { Label("Export…", systemImage: "square.and.arrow.up") }.buttonStyle(.borderedProminent)
                      }
                    }.padding(Layout.inset)
                }
            } else {
                ContentUnavailableView("Image unavailable", systemImage: "exclamationmark.triangle", description: Text("The capture file may have been moved. Import it again to continue."))
            }
        } else {
            VStack(spacing: 24) {
                Image(systemName: "viewfinder").font(.system(size: 64, weight: .ultraLight)).foregroundStyle(.tint)
                VStack(spacing: 8) {
                    Text("A little clarity goes a long way.").font(.title2.weight(.semibold))
                    Text("Capture a moment. Make your point. Send it on.").foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button("Capture an area") { store.capture("area") }.buttonStyle(.borderedProminent)
                    Button("Import an image…", action: store.importImage).buttonStyle(.bordered)
                }
                Text(shortcut(1) + " to capture from anywhere").font(.caption).foregroundStyle(.secondary)
                Button("How Stillframe works") { showHelp = true }.buttonStyle(.link)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(32)
        }
    }
    private var editorTools: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(MarkTool.allCases) { tool in
                    Button { store.tool = tool } label: {
                        Image(systemName: tool.symbol).frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .tint(store.tool == tool ? .accentColor : nil)
                    .help(tool == .redact ? "Redact: cover sensitive content with opaque black" : tool == .counter ? "Step: click to place a numbered marker" : tool.title)
                    .accessibilityLabel(tool == .counter ? "Step" : tool.title)
                    .accessibilityAddTraits(store.tool == tool ? .isSelected : [])
                }
                Spacer(minLength: 4)
                Button(action: store.undo) { Image(systemName: "arrow.uturn.backward") }.disabled(!store.canUndo).help("Undo · ⌘Z")
                Button(action: store.redo) { Image(systemName: "arrow.uturn.forward") }.disabled(!store.canRedo).help("Redo · ⇧⌘Z")
            }
            HStack(spacing: 12) {
                Label(store.tool == .counter ? "Step" : store.tool.title, systemImage: store.tool.symbol).font(.caption).frame(width: 90, alignment: .leading)
                Picker("Ink", selection: $store.ink) { ForEach(Ink.allCases) { ink in Text(ink.rawValue.capitalized).tag(ink) } }.frame(width: 140)
                Picker("Stroke", selection: $store.stroke) { Text("Thin").tag(2.0); Text("Medium").tag(4.0); Text("Thick").tag(8.0) }.frame(width: 150)
                if store.tool == .text { TextField("Annotation text", text: $store.text).textFieldStyle(.roundedBorder) }
                Spacer(minLength: 0)
                Menu {
                    ForEach(BackdropStyle.allCases.filter { $0 != .custom }) { style in
                        Button(style.title) {
                            var value = store.selected?.backdropSettings ?? store.preferences.backdrop
                            value.style = style; store.setBackdrop(value)
                        }
                    }
                    Button("Custom Image…") {
                        if let data = chooseBackgroundImage() {
                            var value = store.selected?.backdropSettings ?? store.preferences.backdrop
                            value.style = .custom; value.customImage = data; store.setBackdrop(value)
                        }
                    }
                    Divider()
                    ForEach([0, 4, 8, 12, 20], id: \.self) { padding in
                        Button("\(padding)% padding") {
                            var value = store.selected?.backdropSettings ?? store.preferences.backdrop
                            value.padding = Double(padding); store.setBackdrop(value)
                        }
                    }
                } label: { Image(systemName: "paintpalette") }.fixedSize().help("Background style and padding").accessibilityLabel("Background options")
                Toggle(isOn: Binding(get: { store.selected?.background ?? false }, set: { _ in store.toggleBackground() })) {
                    Label("Backdrop", systemImage: "square.on.square")
                }.toggleStyle(.button).help("Add a gradient background and padding")
            }
        }.padding(12)
    }
    private var statusBar: some View {
        HStack {
            if store.isCapturing { ProgressView().controlSize(.small); Text("Select your capture. Press Escape to cancel.") }
            else if let notice = store.notice {
                Label(notice, systemImage: "checkmark.circle")
                Button { store.notice = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("Dismiss message")
            } else { Label("Stored on this Mac", systemImage: "internaldrive") }
            Spacer()
            Text("\(store.items.count) captures")
            Button { showHelp = true } label: { Image(systemName: "questionmark.circle") }.buttonStyle(.plain).help("Help")
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
    }
}

private struct CaptureRow: View {
    let item: CaptureItem
    let url: URL
    let revision: Int
    var body: some View {
        HStack(spacing: 10) {
            Group {
                if item.kind == "image", let image = NSImage(contentsOf: url) {
                    Image(nsImage: ImageRenderer.render(image, marks: item.marks, background: item.background, settings: item.backdropSettings)).resizable().aspectRatio(contentMode: .fit)
                } else { Image(systemName: "video.fill").font(.title2).foregroundStyle(.secondary) }
            }.frame(width: 48, height: 40).background(.quaternary, in: RoundedRectangle(cornerRadius: 4)).clipped()
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(item.created, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
}
