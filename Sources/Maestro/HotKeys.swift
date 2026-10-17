import Carbon.HIToolbox
import Foundation

/// Global shortcuts through Carbon RegisterEventHotKey (what both Divvy and Rectangle use).
/// Needs no permission; fails with eventHotKeyExistsErr if another app owns the combo.
final class HotKeys {
    static let shared = HotKeys()
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var key = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            HotKeys.shared.handlers[key.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Returns 0 when the combo is taken.
    @discardableResult
    func register(_ keyCode: Int, _ modifiers: Int, _ action: @escaping () -> Void) -> UInt32 {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers),
                                         EventHotKeyID(signature: OSType(0x4D41_4553), id: id),  // 'MAES'
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return 0 }
        refs[id] = ref
        handlers[id] = action
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
    }
}

/// Registers every shortcut in Store and reports the ones another app already owns.
final class HotkeyCenter: ObservableObject {
    static let shared = HotkeyCenter()
    @Published private(set) var conflicts: Set<String> = []
    var onTrigger: ((String) -> Void)?
    private var registered: [UInt32] = []
    private var suspended = false

    func reload() {
        unregisterAll()
        guard !suspended else { return }
        var failed = Set<String>()
        for (key, shortcut) in Store.shared.allShortcuts {
            let id = HotKeys.shared.register(shortcut.keyCode, shortcut.carbonModifiers) { [weak self] in
                self?.onTrigger?(key)
            }
            if id == 0 { failed.insert(key) } else { registered.append(id) }
        }
        if failed != conflicts { conflicts = failed }
    }

    /// While a shortcut is being recorded, global hotkeys must not fire.
    func suspend() { suspended = true; unregisterAll() }
    func resume() { suspended = false; reload() }

    private func unregisterAll() {
        registered.forEach { HotKeys.shared.unregister($0) }
        registered = []
    }
}
