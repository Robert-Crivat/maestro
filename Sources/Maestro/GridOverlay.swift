import AppKit
import Carbon.HIToolbox

/// Non-activating panel: takes keys and clicks without stealing focus from the app being moved.
final class OverlayPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

/// Translucent rectangle showing where a window will land (grid and drag-to-snap).
final class PreviewWindow {
    private let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)

    init() {
        window.level = .floating
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 12
        window.contentView = view
    }

    func show(_ axRect: CGRect) {
        window.setFrame(Layout.flip(axRect, primaryHeight: Screens.primaryHeight), display: true)
        window.orderFrontRegardless()
    }

    func hide() { window.orderOut(nil) }
}

/// Divvy-style panel: drag across the grid, the focused window takes that area.
final class GridOverlay: NSObject {
    var onOpenSettings: (() -> Void)?
    var onSaveLayout: ((SavedLayout) -> Void)?

    private let mover: Mover
    private let panel = OverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
    private let background = NSVisualEffectView()
    private let grid = GridView()
    private let icon = NSImageView()
    private let title = GridOverlay.label(13, .semibold, .white)
    private let subtitle = GridOverlay.label(11, .regular, NSColor.white.withAlphaComponent(0.6))
    private let sizeLabel = GridOverlay.label(11, .semibold, .white)
    private let hint = GridOverlay.label(11, .regular, NSColor.white.withAlphaComponent(0.6))
    private let gear = NSButton()
    private let preview = PreviewWindow()
    private var window: AXWindow?
    private var screen: NSScreen?
    private var escape: UInt32 = 0
    private var clickOutside: Any?
    private var flashToken = 0
    private var store: Store { .shared }

    init(mover: Mover) {
        self.mover = mover
        super.init()
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onKey = { [weak self] in self?.key($0) ?? false }

        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true
        panel.contentView = background

        icon.imageScaling = .scaleProportionallyUpOrDown
        gear.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Impostazioni")
        gear.isBordered = false
        gear.contentTintColor = NSColor.white.withAlphaComponent(0.7)
        gear.target = self
        gear.action = #selector(openSettings)
        hint.alignment = .right
        hint.stringValue = "⌘ al rilascio salva · + − colonne · esc chiude"
        [icon, title, subtitle, grid, sizeLabel, hint, gear].forEach(background.addSubview)

        grid.onChange = { [weak self] a, b in self?.selectionChanged(a, b) }
        grid.onCommit = { [weak self] a, b, save in self?.commit(a, b, save: save) }
    }

    private static func label(_ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    func toggle() { panel.isVisible ? hide() : show() }

    var isVisible: Bool { panel.isVisible }
    var isShowingGrid: Bool { panel.isVisible && !grid.isHidden }
    /// The grid in AppKit screen coordinates (used by the end-to-end test).
    var gridScreenRect: NSRect? { isShowingGrid ? panel.convertToScreen(grid.convert(grid.bounds, to: nil)) : nil }

    func show() {
        guard AXIsProcessTrusted() else {
            flash("Serve l'accesso Accessibilità", "Impostazioni di Sistema → Privacy e sicurezza → Accessibilità"); return
        }
        // Capture the target before the panel appears (Divvy does the same).
        guard let target = AXWindow.focused(), let screen = Screens.underMouse() ?? NSScreen.main else {
            flash("Nessuna finestra da spostare", "Clicca su una finestra e riprova"); return
        }
        if store.isExcluded(target.bundleID) {
            flash("«\(target.appName)» è un'app esclusa", "Puoi cambiarlo in Impostazioni → App escluse"); return
        }
        window = target
        self.screen = screen
        flashToken += 1
        setGridMode(true)
        icon.image = target.icon
        title.stringValue = target.appName
        subtitle.stringValue = target.title ?? ""
        grid.rows = store.gridRows
        grid.cols = store.gridCols
        grid.selection = nil
        layoutPanel(on: screen)
        updateSizeLabel()
        panel.makeKeyAndOrderFront(nil)

        // Esc as a hotkey too, in case the panel does not get key events.
        escape = HotKeys.shared.register(kVK_Escape, 0) { [weak self] in self?.hide() }
        clickOutside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        panel.orderOut(nil)
        preview.hide()
        if escape != 0 { HotKeys.shared.unregister(escape) }
        escape = 0
        if let m = clickOutside { NSEvent.removeMonitor(m) }
        clickOutside = nil
        window = nil
    }

    private func layoutPanel(on screen: NSScreen) {
        let v = screen.visibleFrame
        let pad: CGFloat = 16, width: CGFloat = 368, header: CGFloat = 34, footer: CGFloat = 14
        let gridHeight = (width * v.height / v.width).rounded()  // cells shaped like the screen
        let size = NSSize(width: width + pad * 2, height: 12 + footer + 10 + gridHeight + 12 + header + 14)
        var origin = NSPoint(x: v.midX - size.width / 2, y: v.midY - size.height / 2)
        if store.panelNearCursor {
            let m = NSEvent.mouseLocation
            origin = NSPoint(x: min(max(m.x - size.width / 2, v.minX + 8), v.maxX - size.width - 8),
                             y: min(max(m.y - size.height / 2, v.minY + 8), v.maxY - size.height - 8))
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: false)

        var y: CGFloat = 12
        sizeLabel.frame = NSRect(x: pad, y: y, width: 110, height: footer)
        hint.frame = NSRect(x: pad + 110, y: y, width: width - 110, height: footer)
        y += footer + 10
        grid.frame = NSRect(x: pad, y: y, width: width, height: gridHeight)
        y += gridHeight + 12
        icon.frame = NSRect(x: pad, y: y + 1, width: 32, height: 32)
        title.frame = NSRect(x: pad + 42, y: y + 17, width: width - 76, height: 17)
        subtitle.frame = NSRect(x: pad + 42, y: y + 2, width: width - 76, height: 15)
        gear.frame = NSRect(x: pad + width - 20, y: y + 8, width: 20, height: 18)
    }

    /// Short message in the same panel, e.g. when there is no window to move.
    private func flash(_ message: String, _ detail: String) {
        guard let screen = Screens.underMouse() ?? NSScreen.main else { return }
        NSSound.beep()
        hide()
        setGridMode(false)
        let v = screen.visibleFrame, size = NSSize(width: 360, height: 72)
        panel.setFrame(NSRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2,
                              width: size.width, height: size.height), display: false)
        title.stringValue = message
        subtitle.stringValue = detail
        title.frame = NSRect(x: 16, y: 38, width: size.width - 32, height: 18)
        subtitle.frame = NSRect(x: 16, y: 18, width: size.width - 32, height: 16)
        panel.orderFrontRegardless()
        flashToken += 1
        let token = flashToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.flashToken == token { self?.panel.orderOut(nil) }
        }
    }

    private func setGridMode(_ on: Bool) {
        [icon, grid, sizeLabel, hint, gear].forEach { $0.isHidden = !on }
        title.alignment = on ? .left : .center
        subtitle.alignment = on ? .left : .center
    }

    private func key(_ event: NSEvent) -> Bool {
        if Int(event.keyCode) == kVK_Escape { hide(); return true }
        switch event.charactersIgnoringModifiers {
        case "+", "=": changeColumns(by: 1); return true
        case "-": changeColumns(by: -1); return true
        default: return false
        }
    }

    private func changeColumns(by delta: Int) {
        let n = min(max(store.gridCols + delta, 1), 12)
        store.gridCols = n
        grid.cols = n
        grid.selection = nil
        preview.hide()
        updateSizeLabel()
    }

    private func updateSizeLabel() {
        if let (a, b) = grid.selection {
            let w = abs(b.col - a.col) + 1, h = abs(b.row - a.row) + 1
            sizeLabel.stringValue = "\(w) × \(h) di \(grid.cols) × \(grid.rows)"
        } else {
            sizeLabel.stringValue = "\(grid.cols) × \(grid.rows)"
        }
    }

    private func targetRect(_ a: Layout.Cell, _ b: Layout.Cell) -> CGRect? {
        guard let screen else { return nil }
        let visible = Screens.axVisibleFrame(screen)
        return Layout.applyGaps(Layout.cellsRect(from: a, to: b, rows: grid.rows, cols: grid.cols, in: visible),
                                in: visible, gap: mover.gap)
    }

    private func selectionChanged(_ a: Layout.Cell, _ b: Layout.Cell) {
        updateSizeLabel()
        if store.showPreview, let r = targetRect(a, b) { preview.show(r) }
    }

    private func commit(_ a: Layout.Cell, _ b: Layout.Cell, save: Bool) {
        if save {
            let layout = SavedLayout(name: "Layout \(store.layouts.count + 1)", rows: grid.rows, cols: grid.cols, from: a, to: b)
            hide()
            onSaveLayout?(layout)
            return
        }
        if let window, let r = targetRect(a, b) { mover.place(window, r, as: .grid) }
        hide()
    }

    @objc private func openSettings() {
        hide()
        onOpenSettings?()
    }
}

final class GridView: NSView {
    var rows = 6 { didSet { needsDisplay = true } }
    var cols = 6 { didSet { needsDisplay = true } }
    var selection: (Layout.Cell, Layout.Cell)? { didSet { needsDisplay = true } }
    var onChange: ((Layout.Cell, Layout.Cell) -> Void)?
    var onCommit: ((Layout.Cell, Layout.Cell, Bool) -> Void)?
    private var anchor: Layout.Cell?
    private var hover: Layout.Cell? { didSet { if hover != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }  // row 0 at the top, like the screen
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    private func cell(_ event: NSEvent) -> Layout.Cell {
        let p = convert(event.locationInWindow, from: nil)
        let col = Int(p.x / (bounds.width / CGFloat(cols))), row = Int(p.y / (bounds.height / CGFloat(rows)))
        return Layout.Cell(row: min(max(row, 0), rows - 1), col: min(max(col, 0), cols - 1))
    }

    override func mouseMoved(with event: NSEvent) { hover = cell(event) }
    override func mouseExited(with event: NSEvent) { hover = nil }

    override func mouseDown(with event: NSEvent) {
        let c = cell(event)
        anchor = c
        selection = (c, c)
        onChange?(c, c)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let c = cell(event)
        hover = c
        if selection?.1 != c {
            selection = (anchor, c)
            onChange?(anchor, c)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard anchor != nil, let (a, b) = selection else { return }
        anchor = nil
        onCommit?(a, b, event.modifierFlags.contains(.command))
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width / CGFloat(cols), h = bounds.height / CGFloat(rows)
        for r in 0..<rows {
            for c in 0..<cols {
                var on = false
                if let (a, b) = selection {
                    on = (min(a.row, b.row)...max(a.row, b.row)).contains(r)
                        && (min(a.col, b.col)...max(a.col, b.col)).contains(c)
                }
                let hovered = hover == Layout.Cell(row: r, col: c)
                let color: NSColor = on ? .controlAccentColor : NSColor.white.withAlphaComponent(hovered ? 0.26 : 0.12)
                color.setFill()
                let rect = NSRect(x: CGFloat(c) * w, y: CGFloat(r) * h, width: w, height: h).insetBy(dx: 2, dy: 2)
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            }
        }
    }
}
