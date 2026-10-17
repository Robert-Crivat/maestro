import AppKit
import Combine

if CommandLine.arguments.contains("--selftest") {
    Layout.selfTest()
    exit(0)
}
if CommandLine.arguments.contains("--e2e-target") { E2ETarget.run() }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let mover = Mover()
    private lazy var overlay = GridOverlay(mover: mover)
    private lazy var snap = SnapManager(mover: mover)
    private var observers: Set<AnyCancellable> = []
    private var store: Store { .shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = mainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.split.3x3", accessibilityDescription: "Maestro")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        overlay.onOpenSettings = { SettingsWindow.shared.show(.grid) }
        overlay.onSaveLayout = { layout in
            Store.shared.pane = .grid
            Store.shared.editing = layout
            SettingsWindow.shared.show()
        }
        HotkeyCenter.shared.onTrigger = { [weak self] key in self?.trigger(key) }
        HotkeyCenter.shared.reload()

        // @Published fires before the value is stored: read the new value from the sink, or hop a turn.
        store.$showMenuIcon.sink { [weak self] in self?.statusItem.isVisible = $0 }.store(in: &observers)
        store.$snapEnabled.sink { [weak self] _ in DispatchQueue.main.async { self?.snap.update() } }.store(in: &observers)

        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--e2e=") }) {
            let report = String(arg.dropFirst(6))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await E2E(mover: mover, overlay: overlay, buildMenu: { [unowned self] in self.menuWillOpen($0) },
                          statusItemVisible: { [unowned self] in self.statusItem.isVisible }, reportPath: report).run()
            }
            return
        }

        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        if !trusted || CommandLine.arguments.contains("--settings") {
            let pane = CommandLine.arguments.lazy.compactMap { $0.hasPrefix("--pane=") ? Pane(rawValue: String($0.dropFirst(7))) : nil }.first
            SettingsWindow.shared.show(pane ?? .general)
        }
    }

    /// Opening Maestro again from the Finder shows the settings (the only way back if the icon is hidden).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.shared.show()
        return false
    }

    private func trigger(_ key: String) {
        if key.hasPrefix("layout:") {
            overlay.hide()
            if let layout = store.layouts.first(where: { $0.hotkeyID == key }) { mover.apply(layout) }
        } else if let action = Layout.Action(rawValue: key) {
            run(action)
        }
    }

    private func run(_ action: Layout.Action) {
        if action == .grid { overlay.toggle() } else { overlay.hide(); mover.perform(action) }
    }

    // MARK: Status menu, rebuilt on every open so it always shows current state.

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        if #available(macOS 14, *) { menu.addItem(.sectionHeader(title: "Maestro")) }
        if !AXIsProcessTrusted() {
            menu.addItem(item("⚠︎ Accessibilità non concessa — Apri Impostazioni…", #selector(openGeneral)))
            menu.addItem(.separator())
        }
        if let other = otherWindowManager {
            menu.addItem(item("⚠︎ \(other) è aperto e può rubare le scorciatoie — Apri Impostazioni…", #selector(openShortcuts)))
            menu.addItem(.separator())
        } else if !HotkeyCenter.shared.conflicts.isEmpty {
            menu.addItem(item("⚠︎ Alcune scorciatoie sono già usate — Apri Impostazioni…", #selector(openShortcuts)))
            menu.addItem(.separator())
        }
        menu.addItem(actionItem(.grid, title: "Griglia…"))
        menu.addItem(.separator())
        ActionGroup.halves.actions.forEach { menu.addItem(actionItem($0)) }
        menu.addItem(submenu("Terzi", ActionGroup.thirds.actions.map { actionItem($0) }))
        menu.addItem(submenu("Angoli", ActionGroup.corners.actions.map { actionItem($0) }))
        ActionGroup.other.actions.forEach { menu.addItem(actionItem($0)) }
        menu.addItem(.separator())

        var layoutItems = store.layouts.map(layoutItem)
        if layoutItems.isEmpty { layoutItems = [NSMenuItem(title: "Nessun layout", action: nil, keyEquivalent: "")] }
        layoutItems += [.separator(), item("Gestisci layout…", #selector(openGrid))]
        menu.addItem(submenu("Layout salvati", layoutItems))
        menu.addItem(.separator())

        if let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier {
            let ignore = item("Ignora «\(app.localizedName ?? id)»", #selector(toggleIgnore(_:)))
            ignore.representedObject = id
            ignore.state = store.isExcluded(id) ? .on : .off
            menu.addItem(ignore)
        }
        menu.addItem(item("Impostazioni…", #selector(openGeneral), key: ","))
        menu.addItem(item("Esci da Maestro", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = target ?? self
        return mi
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        items.forEach(menu.addItem)
        parent.submenu = menu
        return parent
    }

    private func actionItem(_ action: Layout.Action, title: String? = nil) -> NSMenuItem {
        let mi = item(title ?? action.title, #selector(menuAction(_:)))
        mi.representedObject = action.rawValue
        if let s = store.shortcuts[action.rawValue] {
            mi.keyEquivalent = s.menuKey
            mi.keyEquivalentModifierMask = s.flags
        }
        return mi
    }

    private func layoutItem(_ layout: SavedLayout) -> NSMenuItem {
        let mi = item(layout.name, #selector(menuAction(_:)))
        mi.representedObject = layout.hotkeyID
        if let s = layout.shortcut {
            mi.keyEquivalent = s.menuKey
            mi.keyEquivalentModifierMask = s.flags
        }
        return mi
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        // Let the menu close first so the target app is frontmost again.
        guard let key = sender.representedObject as? String else { return }
        DispatchQueue.main.async { self.trigger(key) }
    }

    @objc private func toggleIgnore(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { store.toggleExcluded(id) }
    }

    @objc private func openGeneral() { SettingsWindow.shared.show(.general) }
    @objc private func openShortcuts() { SettingsWindow.shared.show(.shortcuts) }
    @objc private func openGrid() { SettingsWindow.shared.show(.grid) }

    /// Accessory apps have no visible menu bar, but ⌘W and copy/paste in text fields need these items.
    private func mainMenu() -> NSMenu {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let top = NSMenuItem()
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            top.submenu = menu
            main.addItem(top)
        }
        add("Maestro", [NSMenuItem(title: "Esci da Maestro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")])
        add("File", [NSMenuItem(title: "Chiudi", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")])
        add("Modifica", [
            NSMenuItem(title: "Annulla", action: Selector(("undo:")), keyEquivalent: "z"),
            NSMenuItem(title: "Taglia", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copia", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Incolla", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Seleziona tutto", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ])
        return main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
