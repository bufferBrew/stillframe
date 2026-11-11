import Carbon
import AppKit

final class HotKeys {
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var bindings: [ShortcutBinding] = []
    var onTrigger: ((UInt32) -> Void)?

    func register(_ requested: [ShortcutBinding]) -> Bool {
        guard ShortcutBinding.validationError(requested) == nil else { return false }
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
                guard let event, let data else { return noErr }
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                let keys = Unmanaged<HotKeys>.fromOpaque(data).takeUnretainedValue()
                let key = id.id
                DispatchQueue.main.async { keys.onTrigger?(key) }
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { return false }
        }
        let previous = bindings
        unregisterKeys()
        if install(requested) { bindings = requested; return true }
        unregisterKeys()
        _ = install(previous)
        return false
    }
    private func install(_ requested: [ShortcutBinding]) -> Bool {
        for binding in requested where binding.enabled {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, EventHotKeyID(signature: 0x53744672, id: binding.id), GetApplicationEventTarget(), 0, &ref)
            guard status == noErr, let ref else { return false }
            refs.append(ref)
        }
        return true
    }
    func suspend() { unregisterKeys() }
    private func unregisterKeys() { refs.forEach { UnregisterEventHotKey($0) }; refs.removeAll() }
    deinit { unregisterKeys(); if let handler { RemoveEventHandler(handler) } }
}
