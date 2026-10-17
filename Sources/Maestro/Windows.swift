import AppKit
import ApplicationServices

/// Private but stable for years; Rectangle and AltTab use it to get a window's CGWindowID.
@_silgen_name("_AXUIElementGetWindow") @discardableResult
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: inout CGWindowID) -> AXError

extension AXUIElement {
    func value<T>(_ attribute: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &v) == .success else { return nil }
        return v as? T
    }

    func set(_ attribute: String, _ v: CFTypeRef) {
        AXUIElementSetAttributeValue(self, attribute as CFString, v)
    }
}

struct AXWindow {
    let element: AXUIElement
    let pid: pid_t

    /// System-wide element with a short timeout: a hung app must not freeze Maestro.
    private static let systemWide: AXUIElement = {
        let e = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(e, 0.25)
        return e
    }()

    static func focused() -> AXWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window: AXUIElement = appElement.value(kAXFocusedWindowAttribute) else { return nil }
        return AXWindow(element: window, pid: app.processIdentifier)
    }

    /// The window under a point in AX coordinates.
    static func at(_ p: CGPoint) -> AXWindow? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &hit) == .success, let hit else { return nil }
        let role: String? = hit.value(kAXRoleAttribute)
        let window: AXUIElement? = role == kAXWindowRole ? hit : hit.value(kAXWindowAttribute)
        var pid: pid_t = 0
        guard let window, AXUIElementGetPid(window, &pid) == .success, pid != getpid() else { return nil }
        return AXWindow(element: window, pid: pid)
    }

    var app: AXUIElement { AXUIElementCreateApplication(pid) }
    var running: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }
    var appName: String { running?.localizedName ?? "" }
    var bundleID: String? { running?.bundleIdentifier }
    var icon: NSImage? { running?.icon }

    var id: CGWindowID? {
        var wid: CGWindowID = 0
        return _AXUIElementGetWindow(element, &wid) == .success ? wid : nil
    }

    var title: String? { element.value(kAXTitleAttribute) }

    var frame: CGRect? {
        guard let p: AXValue = element.value(kAXPositionAttribute),
              let s: AXValue = element.value(kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p, .cgPoint, &origin)
        AXValueGetValue(s, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    /// AX sets size and position separately. Size, position, size again: macOS clamps the size
    /// to the screen the window is on, so the second size wins after a display change.
    /// AXEnhancedUserInterface (set by some apps) makes resizing slow and wrong: off during the move.
    func setFrame(_ r: CGRect) {
        let app = self.app
        let enhanced: Bool? = app.value("AXEnhancedUserInterface")
        if enhanced == true { app.set("AXEnhancedUserInterface", kCFBooleanFalse) }
        defer { if enhanced == true { app.set("AXEnhancedUserInterface", kCFBooleanTrue) } }

        var size = r.size, origin = r.origin
        guard let s = AXValueCreate(.cgSize, &size), let p = AXValueCreate(.cgPoint, &origin) else { return }
        element.set(kAXSizeAttribute, s)
        element.set(kAXPositionAttribute, p)
        element.set(kAXSizeAttribute, s)
    }
}

enum Screens {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static var cursorAX: CGPoint {
        let m = NSEvent.mouseLocation
        return CGPoint(x: m.x, y: primaryHeight - m.y)
    }

    /// Usable area (no menu bar, no Dock, minus the user's margins) in AX coordinates.
    static func axVisibleFrame(_ s: NSScreen) -> CGRect {
        Store.shared.applyMargins(Layout.flip(s.visibleFrame, primaryHeight: primaryHeight))
    }

    static func screen(for axRect: CGRect) -> NSScreen? {
        func overlap(_ s: NSScreen) -> CGFloat {
            let i = Layout.flip(s.frame, primaryHeight: primaryHeight).intersection(axRect)
            return i.isNull ? 0 : i.width * i.height
        }
        return NSScreen.screens.max { overlap($0) < overlap($1) }
    }

    static func underMouse() -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
    }

    static func next(after s: NSScreen) -> NSScreen { neighbour(of: s, step: 1) }
    static func previous(_ s: NSScreen) -> NSScreen { neighbour(of: s, step: -1) }

    private static func neighbour(of s: NSScreen, step: Int) -> NSScreen {
        let all = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
        guard !all.isEmpty else { return s }
        let i = all.firstIndex(of: s) ?? 0
        return all[(i + step + all.count) % all.count]
    }
}

/// Runs actions and keeps Rectangle-style per-window history (repeat count, restore rect).
final class Mover {
    private struct Last { let action: Layout.Action; let frame: CGRect; let count: Int }
    private var last: [CGWindowID: Last] = [:]
    private var restore: [CGWindowID: CGRect] = [:]
    private var store: Store { .shared }

    var gap: CGFloat { CGFloat(store.gap) }

    /// Keyboard and menu entry point.
    func perform(_ action: Layout.Action) {
        guard let window = usableFocusedWindow(), let frame = window.frame else { return }
        if action == .restore { restoreFrame(of: window); return }

        let prev = validLast(window, frame)
        guard var screen = store.useCursorScreen ? Screens.underMouse() : Screens.screen(for: frame) else {
            NSSound.beep(); return
        }
        var count = prev?.action == action ? prev!.count + 1 : 0
        var result = action
        switch (store.repeatMode, action) {
        case (.cycle, _):
            break
        case (.nextDisplay, .leftHalf), (.nextDisplay, .rightHalf):
            // Pressing again walks across displays: left half -> right half of the screen on the left.
            if count > 0 {
                let dest = action == .leftHalf ? Screens.previous(screen) : Screens.next(after: screen)
                if dest != screen { screen = dest; result = action == .leftHalf ? .rightHalf : .leftHalf }
            }
            count = 0
        default:
            count = 0
        }

        let visible = Screens.axVisibleFrame(screen)
        let rect: CGRect?
        switch action {
        case .center:
            rect = Layout.centered(frame.size, in: visible)
        case .nextDisplay, .previousDisplay:
            let src = Screens.screen(for: frame) ?? screen
            let dest = action == .nextDisplay ? Screens.next(after: src) : Screens.previous(src)
            let to = Screens.axVisibleFrame(dest)
            rect = Layout.constrain(Layout.transfer(frame, from: Screens.axVisibleFrame(src), to: to), to: to)
        default:
            rect = target(result, in: visible, count: count)
        }
        guard let rect else { NSSound.beep(); return }
        place(window, rect, as: result, count: count, frame: frame)

        if store.moveCursor, let f = window.frame { CGWarpMouseCursorPosition(CGPoint(x: f.midX, y: f.midY)) }
    }

    func apply(_ layout: SavedLayout) {
        guard let window = usableFocusedWindow(), let frame = window.frame,
              let screen = layout.cursorScreen ? Screens.underMouse() : Screens.screen(for: frame) else { return }
        let v = Screens.axVisibleFrame(screen)
        let cells = Layout.cellsRect(from: layout.from, to: layout.to, rows: layout.rows, cols: layout.cols, in: v)
        place(window, Layout.applyGaps(cells, in: v, gap: gap), as: .grid, frame: frame)
    }

    /// Frame for an edge action on a visible frame, gaps included.
    func target(_ action: Layout.Action, in visible: CGRect, count: Int = 0) -> CGRect? {
        Layout.rect(for: action, in: visible, repeatCount: count).map { Layout.applyGaps($0, in: visible, gap: gap) }
    }

    /// Moves the window and records history. `original` is the frame "Ripristina" goes back to.
    func place(_ window: AXWindow, _ rect: CGRect, as action: Layout.Action, count: Int = 0,
               frame current: CGRect? = nil, original: CGRect? = nil) {
        guard let frame = current ?? window.frame else { return }
        let id = window.id
        if let id, validLast(window, frame) == nil { restore[id] = original ?? frame }

        window.setFrame(rect)

        // The app may refuse the size: keep what it accepted on screen.
        var result = window.frame ?? rect
        if let screen = Screens.screen(for: rect) {
            let inside = Layout.constrain(result, to: Screens.axVisibleFrame(screen))
            if !Layout.nearlyEqual(inside, result, tolerance: 1) {
                window.setFrame(inside)
                result = window.frame ?? inside
            }
        }
        if let id { last[id] = Last(action: action, frame: result, count: count) }
    }

    /// Drag-to-snap: a window Maestro placed gets its earlier size back when dragged away.
    func unsnapSize(_ window: AXWindow, initial: CGRect) -> CGSize? {
        guard let id = window.id, let l = last[id], Layout.nearlyEqual(l.frame, initial), let r = restore[id] else { return nil }
        last[id] = nil
        return r.size
    }

    func usableFocusedWindow() -> AXWindow? {
        guard AXIsProcessTrusted(), let w = AXWindow.focused(), !store.isExcluded(w.bundleID) else {
            NSSound.beep(); return nil
        }
        return w
    }

    private func validLast(_ window: AXWindow, _ frame: CGRect) -> Last? {
        guard let id = window.id, let l = last[id], Layout.nearlyEqual(l.frame, frame) else { return nil }
        return l
    }

    private func restoreFrame(of window: AXWindow) {
        guard let id = window.id, let r = restore[id] else { NSSound.beep(); return }
        window.setFrame(r)
        last[id] = nil
    }
}
