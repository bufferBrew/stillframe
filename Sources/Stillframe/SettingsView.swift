import SwiftUI
import Carbon
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: AppPreferences
    var apply: (AppPreferences) -> Bool
    @State private var message: String?
    @State private var recordingID: UInt32?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Stillframe Settings").font(.title2.bold())
            TabView {
                ScrollView {
                  VStack(alignment: .leading, spacing: 12) {
                    ForEach($draft.shortcuts) { $shortcut in
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(shortcut.title, isOn: $shortcut.enabled)
                            ShortcutRecorder(binding: $shortcut, recordingID: $recordingID)
                            HStack {
                                ForEach([(controlKey, "Control"), (optionKey, "Option"), (shiftKey, "Shift"), (cmdKey, "Command")], id: \.0) { flag, label in
                                    Toggle(label, isOn: Binding(get: { shortcut.modifiers & UInt32(flag) != 0 }, set: { value in
                                        if value { shortcut.modifiers |= UInt32(flag) } else { shortcut.modifiers &= ~UInt32(flag) }
                                    })).toggleStyle(.checkbox)
                                }
                                Picker("Key", selection: $shortcut.keyCode) { ForEach(ShortcutBinding.keys, id: \.1) { key in Text(key.0).tag(key.1) } }.labelsHidden().frame(width: 100).accessibilityLabel("\(shortcut.title) key")
                            }.disabled(!shortcut.enabled)
                        }.padding(.vertical, 8)
                    }
                    Text("Record a combination or use the selectors. Command, Control, or Option combinations and standalone F-keys are supported. System-reserved keys may be unavailable; conflicts keep your previous shortcuts.").font(.caption).foregroundStyle(.secondary)
                    Button("Use Recommended Shortcuts") { recordingID = nil; draft.shortcuts = ShortcutBinding.defaults }
                  }.padding(12)
                }.tabItem { Label("Shortcuts", systemImage: "keyboard") }
                Form {
                    Picker("Default delay", selection: $draft.captureDelay) {
                        Text("None").tag(0); Text("3 seconds").tag(3); Text("5 seconds").tag(5); Text("10 seconds").tag(10)
                    }
                    Toggle("Include cursor in fullscreen screenshots", isOn: $draft.includeCursor)
                    Toggle("Include window shadows", isOn: $draft.windowShadow)
                    Label("Every screenshot is automatically copied to the clipboard", systemImage: "doc.on.clipboard").font(.callout)
                    Toggle("Open editor after capture", isOn: $draft.openEditorAfterCapture)
                    Picker("Default export format", selection: $draft.imageFormat) { Text("PNG").tag("png"); Text("JPEG").tag("jpg") }
                    Divider()
                    Toggle("Record system audio by default", isOn: $draft.recordSystemAudio)
                    Picker("Recording frame rate", selection: $draft.recordingFPS) { Text("15 fps").tag(15); Text("30 fps").tag(30); Text("60 fps").tag(60) }
                    Picker("Recording resolution", selection: $draft.recordingMaxWidth) { Text("Up to 1080p").tag(1920); Text("Up to 4K").tag(3840) }
                }.tabItem { Label("Capture", systemImage: "viewfinder") }
                Form {
                    Picker("Default style", selection: $draft.backdrop.style) { ForEach(BackdropStyle.allCases) { Text($0.title).tag($0) } }
                    HStack { Text("Padding"); Slider(value: $draft.backdrop.padding, in: 0...25, step: 1); Text("\(Int(draft.backdrop.padding))%").monospacedDigit().frame(width: 48) }
                    Button(draft.backdrop.customImage == nil ? "Choose custom background…" : "Replace custom background…") {
                        if let data = chooseBackgroundImage() { draft.backdrop.customImage = data; draft.backdrop.style = .custom }
                    }
                    Text("Defaults apply to new captures. Existing captures keep their own background settings.").font(.caption).foregroundStyle(.secondary)
                }.tabItem { Label("Background", systemImage: "photo") }
            }.padding(.top, 8)
            if let message { Text(message).foregroundStyle(.red).font(.callout).accessibilityLabel("Settings error: \(message)") }
            HStack {
                Button("Restore Defaults") { draft = AppPreferences(); message = nil }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    recordingID = nil
                    if let validation = ShortcutBinding.validationError(draft.shortcuts) { message = validation }
                    else if draft.backdrop.style == .custom && draft.backdrop.customImage == nil { message = "Choose a custom background image first." }
                    else if apply(draft) { dismiss() }
                    else { message = "A shortcut is unavailable, or settings could not be saved. Your previous settings remain active." }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 680, height: 570)
    }
}

@MainActor
func chooseBackgroundImage() -> Data? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
    guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return nil }
    // Bound the embedded asset to a 2048px edge; every capture persists its own backdrop.
    let scale = min(1, 2048 / max(image.size.width, image.size.height))
    let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    let resized = NSImage(size: size, flipped: true) { _ in
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil); return true
    }
    return ImageRenderer.png(resized)
}
