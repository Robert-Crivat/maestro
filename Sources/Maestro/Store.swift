import AppKit
import Carbon.HIToolbox

/// A recorded key combination. `chars` is what NSEvent reported, kept for display and menus.
struct Shortcut: Codable, Equatable {
    var keyCode: Int
    var modifiers: UInt  // NSEvent.ModifierFlags raw value: command / option / control / shift only
    var chars: String

    static func ctrlOpt(_ keyCode: Int, _ chars: String, command: Bool = false) -> Shortcut {
        var flags: NSEvent.ModifierFlags = [.control, .option]
        if command { flags.insert(.command) }
        return Shortcut(keyCode: keyCode, modifiers: flags.rawValue, chars: chars)
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    func same(as other: Shortcut) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }

    var carbonModifiers: Int {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.shift) { m |= shiftKey }
        return m
    }

    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + (Shortcut.keyNames[keyCode] ?? chars.uppercased())
    }

    /// NSMenuItem key equivalent: only shown in menus, the global hotkey does the work.
    var menuKey: String { keyCode == kVK_Delete ? "\u{8}" : chars.lowercased() }

    private static let keyNames: [Int: String] = [
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_Tab: "⇥", kVK_Space: "Spazio", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]
}

/// The character NSEvent delivers for arrows and other function keys.
func functionKey(_ code: Int) -> String { String(Character(UnicodeScalar(code)!)) }

extension Layout.Action {
    var title: String {
        switch self {
        case .grid: "Apri la griglia"
        case .leftHalf: "Metà sinistra"
        case .rightHalf: "Metà destra"
        case .topHalf: "Metà superiore"
        case .bottomHalf: "Metà inferiore"
        case .firstThird: "Primo terzo"
        case .centerThird: "Terzo centrale"
        case .lastThird: "Ultimo terzo"
        case .topLeft: "In alto a sinistra"
        case .topRight: "In alto a destra"
        case .bottomLeft: "In basso a sinistra"
        case .bottomRight: "In basso a destra"
        case .maximize: "Massimizza"
        case .center: "Centra"
        case .restore: "Ripristina"
        case .nextDisplay: "Schermo successivo"
        case .previousDisplay: "Schermo precedente"
        }
    }
}

enum ActionGroup: CaseIterable, Identifiable {
    case grid, halves, thirds, corners, other
    var id: Self { self }

    var title: String {
        switch self {
        case .grid: "Griglia"
        case .halves: "Metà"
        case .thirds: "Terzi"
        case .corners: "Angoli"
        case .other: "Altro"
        }
    }

    var actions: [Layout.Action] {
        switch self {
        case .grid: [.grid]
        case .halves: [.leftHalf, .rightHalf, .topHalf, .bottomHalf]
        case .thirds: [.firstThird, .centerThird, .lastThird]
        case .corners: [.topLeft, .topRight, .bottomLeft, .bottomRight]
        case .other: [.maximize, .center, .restore, .nextDisplay, .previousDisplay]
        }
    }
}

enum RepeatMode: String, CaseIterable, Identifiable {
    case cycle, nextDisplay, none
    var id: Self { self }

    var title: String {
        switch self {
        case .cycle: "Ciclo ½ → ⅔ → ⅓"
        case .nextDisplay: "Passa allo schermo accanto"
        case .none: "Nessun effetto"
        }
    }
}

struct SavedLayout: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var rows: Int
    var cols: Int
    var from: Layout.Cell
    var to: Layout.Cell
    var cursorScreen = false
    var shortcut: Shortcut?

    var hotkeyID: String { "layout:\(id.uuidString)" }

    var summary: String {
        let w = abs(to.col - from.col) + 1, h = abs(to.row - from.row) + 1
        return "\(w) × \(h) su \(cols) × \(rows) · " + (cursorScreen ? "schermo del cursore" : "schermo della finestra")
    }
}

/// Every setting, persisted in UserDefaults; SwiftUI observes it, the rest of the app reads it.
final class Store: ObservableObject {
    static let shared = Store()

    // Navigation state, not persisted.
    @Published var pane: Pane? = .general
    @Published var editing: SavedLayout?

    @Published var showMenuIcon: Bool { didSet { put(showMenuIcon, "showMenuIcon") } }
    @Published var gap: Double { didSet { put(gap, "gap") } }
    @Published var marginTop: Double { didSet { put(marginTop, "marginTop") } }
    @Published var marginBottom: Double { didSet { put(marginBottom, "marginBottom") } }
    @Published var marginSides: Double { didSet { put(marginSides, "marginSides") } }
    @Published var useCursorScreen: Bool { didSet { put(useCursorScreen, "useCursorScreen") } }
    @Published var repeatMode: RepeatMode { didSet { put(repeatMode.rawValue, "repeatMode") } }
    @Published var moveCursor: Bool { didSet { put(moveCursor, "moveCursor") } }
    @Published var gridRows: Int { didSet { put(gridRows, "gridRows") } }
    @Published var gridCols: Int { didSet { put(gridCols, "gridCols") } }
    @Published var panelNearCursor: Bool { didSet { put(panelNearCursor, "panelNearCursor") } }
    @Published var showPreview: Bool { didSet { put(showPreview, "showPreview") } }
    @Published var snapEnabled: Bool { didSet { put(snapEnabled, "snapEnabled") } }
    @Published var snapSides: String { didSet { put(snapSides, "snapSides") } }
    @Published var snapTop: String { didSet { put(snapTop, "snapTop") } }
    @Published var snapBottom: String { didSet { put(snapBottom, "snapBottom") } }
    @Published var snapCorners: String { didSet { put(snapCorners, "snapCorners") } }
    @Published var snapDistance: Double { didSet { put(snapDistance, "snapDistance") } }
    @Published var restoreOnUnsnap: Bool { didSet { put(restoreOnUnsnap, "restoreOnUnsnap") } }
    @Published var excluded: [String] { didSet { put(excluded, "excluded") } }
    @Published var shortcuts: [String: Shortcut] { didSet { persist(shortcuts, "shortcuts"); HotkeyCenter.shared.reload() } }
    @Published var layouts: [SavedLayout] { didSet { persist(layouts, "layouts"); HotkeyCenter.shared.reload() } }

    static let defaultShortcuts: [String: Shortcut] = [
        Layout.Action.grid.rawValue: .ctrlOpt(kVK_ANSI_G, "g"),
        Layout.Action.leftHalf.rawValue: .ctrlOpt(kVK_LeftArrow, functionKey(NSLeftArrowFunctionKey)),
        Layout.Action.rightHalf.rawValue: .ctrlOpt(kVK_RightArrow, functionKey(NSRightArrowFunctionKey)),
        Layout.Action.topHalf.rawValue: .ctrlOpt(kVK_UpArrow, functionKey(NSUpArrowFunctionKey)),
        Layout.Action.bottomHalf.rawValue: .ctrlOpt(kVK_DownArrow, functionKey(NSDownArrowFunctionKey)),
        Layout.Action.topLeft.rawValue: .ctrlOpt(kVK_ANSI_U, "u"),
        Layout.Action.topRight.rawValue: .ctrlOpt(kVK_ANSI_I, "i"),
        Layout.Action.bottomLeft.rawValue: .ctrlOpt(kVK_ANSI_J, "j"),
        Layout.Action.bottomRight.rawValue: .ctrlOpt(kVK_ANSI_K, "k"),
        Layout.Action.maximize.rawValue: .ctrlOpt(kVK_Return, "\r"),
        Layout.Action.center.rawValue: .ctrlOpt(kVK_ANSI_C, "c"),
        Layout.Action.restore.rawValue: .ctrlOpt(kVK_Delete, "\u{7f}"),
        Layout.Action.nextDisplay.rawValue: .ctrlOpt(kVK_RightArrow, functionKey(NSRightArrowFunctionKey), command: true),
        Layout.Action.previousDisplay.rawValue: .ctrlOpt(kVK_LeftArrow, functionKey(NSLeftArrowFunctionKey), command: true),
    ]

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            "showMenuIcon": true, "gap": 8.0, "repeatMode": RepeatMode.cycle.rawValue,
            "gridRows": 6, "gridCols": 6, "showPreview": true,
            "snapEnabled": true, "snapSides": "halves", "snapTop": "maximize", "snapBottom": "thirds",
            "snapCorners": "quarters", "snapDistance": 5.0, "restoreOnUnsnap": true,
        ])
        showMenuIcon = d.bool(forKey: "showMenuIcon")
        gap = d.double(forKey: "gap")
        marginTop = d.double(forKey: "marginTop")
        marginBottom = d.double(forKey: "marginBottom")
        marginSides = d.double(forKey: "marginSides")
        useCursorScreen = d.bool(forKey: "useCursorScreen")
        repeatMode = RepeatMode(rawValue: d.string(forKey: "repeatMode") ?? "") ?? .cycle
        moveCursor = d.bool(forKey: "moveCursor")
        gridRows = d.integer(forKey: "gridRows")
        gridCols = d.integer(forKey: "gridCols")
        panelNearCursor = d.bool(forKey: "panelNearCursor")
        showPreview = d.bool(forKey: "showPreview")
        snapEnabled = d.bool(forKey: "snapEnabled")
        snapSides = d.string(forKey: "snapSides") ?? "halves"
        snapTop = d.string(forKey: "snapTop") ?? "maximize"
        snapBottom = d.string(forKey: "snapBottom") ?? "thirds"
        snapCorners = d.string(forKey: "snapCorners") ?? "quarters"
        snapDistance = d.double(forKey: "snapDistance")
        restoreOnUnsnap = d.bool(forKey: "restoreOnUnsnap")
        excluded = d.stringArray(forKey: "excluded") ?? []
        shortcuts = Store.load("shortcuts") ?? Store.defaultShortcuts
        layouts = Store.load("layouts") ?? []
    }

    /// Action shortcuts and layout shortcuts, keyed by hotkey ID.
    var allShortcuts: [(String, Shortcut)] {
        shortcuts.map { ($0.key, $0.value) } + layouts.compactMap { l in l.shortcut.map { (l.hotkeyID, $0) } }
    }

    /// What else in Maestro already uses `shortcut`, if anything.
    func owner(of shortcut: Shortcut, except key: String) -> String? {
        if let hit = shortcuts.first(where: { $0.key != key && $0.value.same(as: shortcut) }) {
            return Layout.Action(rawValue: hit.key)?.title ?? hit.key
        }
        return layouts.first { $0.hotkeyID != key && $0.shortcut?.same(as: shortcut) == true }?.name
    }

    func isExcluded(_ bundleID: String?) -> Bool { bundleID.map(excluded.contains) ?? false }

    func toggleExcluded(_ bundleID: String) {
        if let i = excluded.firstIndex(of: bundleID) { excluded.remove(at: i) } else { excluded.append(bundleID) }
    }

    func save(_ layout: SavedLayout) {
        if let i = layouts.firstIndex(where: { $0.id == layout.id }) { layouts[i] = layout } else { layouts.append(layout) }
    }

    /// Usable screen area (AX coordinates) minus the user's margins.
    func applyMargins(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX + marginSides, y: r.minY + marginTop,
               width: max(r.width - 2 * marginSides, 100), height: max(r.height - marginTop - marginBottom, 100))
    }

    private func put(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: key) }

    private func persist<T: Encodable>(_ value: T, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
