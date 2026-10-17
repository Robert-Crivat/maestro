import AppKit

/// Rectangle-style drag to snap: drag a window against a screen edge or corner and release.
final class SnapManager {
    typealias Zone = (action: Layout.Action, screen: NSScreen)

    private let mover: Mover
    private let preview = PreviewWindow()
    private var monitor: Any?
    private var window: AXWindow?
    private var initial: CGRect?
    private var original: CGRect?
    private var moving = false
    private var checks = 0
    private var zone: Zone?

    init(mover: Mover) { self.mover = mover }

    /// Starts or stops listening to follow the "Trascina ai bordi" switch.
    func update() {
        if Store.shared.snapEnabled, monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] in
                self?.handle($0)
            }
        } else if !Store.shared.snapEnabled, let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
            reset()
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            reset()
            guard AXIsProcessTrusted(), let w = AXWindow.at(Screens.cursorAX), !Store.shared.isExcluded(w.bundleID) else { return }
            window = w
            initial = w.frame
        case .leftMouseDragged:
            guard let window, let initial else { return }
            if moving { updateZone(); return }
            // A window drag moves the window without resizing it. Give up after a while
            // (text selection, resizing, scrolling…).
            checks += 1
            guard let now = window.frame, checks <= 30, now.size == initial.size else { reset(); return }
            if now.origin != initial.origin { startMoving(window, initial: initial, now: now) }
        case .leftMouseUp:
            if moving, let window, let zone,
               let rect = mover.target(zone.action, in: Screens.axVisibleFrame(zone.screen)) {
                mover.place(window, rect, as: zone.action, original: original)
            }
            reset()
        default:
            break
        }
    }

    private func startMoving(_ window: AXWindow, initial: CGRect, now: CGRect) {
        moving = true
        original = initial
        guard Store.shared.restoreOnUnsnap, let size = mover.unsnapSize(window, initial: initial) else { return }
        // Keep the cursor at the same relative spot of the title bar.
        let cursor = Screens.cursorAX
        let x = cursor.x - (cursor.x - now.minX) * (size.width / now.width)
        let restored = CGRect(x: x, y: now.minY, width: size.width, height: size.height)
        window.setFrame(restored)
        original = restored
    }

    private func updateZone() {
        let z = SnapManager.zone(at: NSEvent.mouseLocation)
        guard z?.action != zone?.action || z?.screen != zone?.screen else { return }
        zone = z
        if let z, let rect = mover.target(z.action, in: Screens.axVisibleFrame(z.screen)) {
            preview.show(rect)
        } else {
            preview.hide()
        }
    }

    private func reset() {
        window = nil
        initial = nil
        original = nil
        moving = false
        checks = 0
        zone = nil
        preview.hide()
    }

    /// Which action the cursor position (AppKit coordinates) asks for, if any.
    static func zone(at p: NSPoint) -> Zone? {
        let s = Store.shared
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) else { return nil }
        let f = screen.frame, d = CGFloat(s.snapDistance), corner: CGFloat = 20
        let left = p.x <= f.minX + d, right = p.x >= f.maxX - d - 1
        let top = p.y >= f.maxY - d - 1, bottom = p.y <= f.minY + d
        guard left || right || top || bottom else { return nil }
        let nearLeft = p.x <= f.minX + d + corner, nearRight = p.x >= f.maxX - d - corner - 1
        let nearTop = p.y >= f.maxY - d - corner - 1, nearBottom = p.y <= f.minY + d + corner
        func pick(_ a: Layout.Action?) -> Zone? { a.map { ($0, screen) } }

        if s.snapCorners == "quarters" {
            if (left && nearTop) || (top && nearLeft) { return pick(.topLeft) }
            if (right && nearTop) || (top && nearRight) { return pick(.topRight) }
            if (left && nearBottom) || (bottom && nearLeft) { return pick(.bottomLeft) }
            if (right && nearBottom) || (bottom && nearRight) { return pick(.bottomRight) }
        }
        if left || right { return s.snapSides == "halves" ? pick(left ? .leftHalf : .rightHalf) : nil }
        if top {
            switch s.snapTop {
            case "maximize": return pick(.maximize)
            case "topHalf": return pick(.topHalf)
            default: return nil
            }
        }
        switch s.snapBottom {
        case "thirds":
            let t = (p.x - f.minX) / f.width
            return pick(t < 1.0 / 3 ? .firstThird : t < 2.0 / 3 ? .centerThird : .lastThird)
        case "bottomHalf":
            return pick(.bottomHalf)
        default:
            return nil
        }
    }
}
