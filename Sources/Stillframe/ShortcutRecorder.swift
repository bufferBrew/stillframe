import SwiftUI
import AppKit
import Carbon

/// A local key-down monitor only while the user explicitly records a shortcut.
/// Global capture shortcuts are suspended for the settings sheet by AppDelegate.
struct ShortcutRecorder: View {
    @Binding var binding: ShortcutBinding
    @Binding var recordingID: UInt32?
    @State private var monitor: Any?
    @State private var error: String?
    private var isRecording: Bool { recordingID == binding.id }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                error = nil; recordingID = isRecording ? nil : binding.id
            } label: {
                Text(isRecording ? "Press shortcut… (Esc cancels)" : binding.label + " · Record shortcut")
                    .frame(minWidth: 200, alignment: .leading)
            }
            .accessibilityLabel(isRecording ? "Recording shortcut for \(binding.title)" : "Record shortcut for \(binding.title), currently \(binding.label)")
            .onChange(of: recordingID) { _, value in
                removeMonitor()
                if value == binding.id { installMonitor() }
            }
            .onDisappear { removeMonitor() }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53 && flags.intersection([.command, .control, .option, .shift]).isEmpty {
                recordingID = nil; return nil
            }
            if event.keyCode == 48 && flags.intersection([.command, .control, .option]).isEmpty {
                recordingID = nil; return event
            }
            var modifiers: UInt32 = 0
            for (native, carbon) in [(NSEvent.ModifierFlags.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)] {
                if flags.contains(native) { modifiers |= UInt32(carbon) }
            }
            guard ShortcutBinding.keys.contains(where: { $0.1 == UInt32(event.keyCode) }) else {
                error = "This key is not supported. Use the key selector below."; return nil
            }
            let functionKey = ShortcutBinding.keys.contains { $0.1 == UInt32(event.keyCode) && $0.0.hasPrefix("F") && $0.0 != "Forward Delete" }
            guard functionKey || modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 else {
                error = "Add Command, Control or Option, or use an F-key."; return nil
            }
            binding.keyCode = UInt32(event.keyCode); binding.modifiers = modifiers; binding.enabled = true
            error = nil; recordingID = nil
            return nil
        }
    }
    private func removeMonitor() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
}
