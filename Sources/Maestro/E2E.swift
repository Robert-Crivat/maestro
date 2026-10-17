import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// `Maestro --e2e-target`: a plain window in a second process, the only thing the test moves.
enum E2ETarget {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 700, height: 450),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Maestro · finestra di prova"
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { _ = window; exit(0) }  // never outlive a stuck test
        app.run()
        exit(0)
    }
}

/// `Maestro --e2e=<report>`: drives every feature with real keyboard and mouse events against
/// the test window, writes a report and quits. Nobody should touch the Mac while it runs (~1 min).
@MainActor
final class E2E {
    private let mover: Mover
    private let overlay: GridOverlay
    private let buildMenu: (NSMenu) -> Void
    private let statusItemVisible: () -> Bool
    private let reportPath: String
    private var lines: [String] = []
    private var failures = 0
    private var child: NSRunningApplication?
    private var screen: NSScreen!
    private var vis = CGRect.zero
    private var start = CGRect.zero
    private let source = CGEventSource(stateID: .hidSystemState)
    private let ctrlOpt: CGEventFlags = [.maskControl, .maskAlternate]
    private let ctrlOptCmd: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
    private var store: Store { .shared }

    init(mover: Mover, overlay: GridOverlay, buildMenu: @escaping (NSMenu) -> Void,
         statusItemVisible: @escaping () -> Bool, reportPath: String) {
        self.mover = mover
        self.overlay = overlay
        self.buildMenu = buildMenu
        self.statusItemVisible = statusItemVisible
        self.reportPath = reportPath
    }

    func run() async {
        let domain = Bundle.main.bundleIdentifier ?? "com.maestro.local"
        let savedDefaults = UserDefaults.standard.persistentDomain(forName: domain)
        let savedMouse = Screens.cursorAX
        lines.append("Maestro · test end-to-end · \(Date().formatted())")
        lines.append("Schermi: \(NSScreen.screens.count) · altro window manager aperto: \(otherWindowManager ?? "nessuno")")
        let wm = UserDefaults(suiteName: "com.apple.WindowManager")
        lines.append("Aggancio nativo di macOS ai bordi: \(wm?.object(forKey: "EnableTilingByEdgeDrag").map { "\($0)" } ?? "predefinito")\n")

        if check("Accessibilità concessa a Maestro", AXIsProcessTrusted()) {
            resetSettings()
            if let w = await launchTarget() {
                await actions(w)
                await settingsEffects(w)
                await hotkeys(w)
                await grid(w)
                await snapping(w)
                model()
                menu()
                await settingsWindow()
            }
        }

        child?.forceTerminate()
        store.editing = nil
        SettingsWindow.shared.close()
        if let savedDefaults {
            UserDefaults.standard.setPersistentDomain(savedDefaults, forName: domain)
        } else {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        UserDefaults.standard.synchronize()
        CGWarpMouseCursorPosition(savedMouse)
        lines.append(failures == 0 ? "\nTUTTO OK" : "\n\(failures) controlli falliti")
        try? lines.joined(separator: "\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Groups

    private func actions(_ w: AXWindow) async {
        section("Azioni")
        await place(w, start)
        check("Posizione iniziale impostata", near(w.frame, start), fmt(w.frame))
        await act(.leftHalf); expect("Metà sinistra", w, target(.leftHalf))
        check("Metà sinistra: bordo a 8 pt dallo schermo", abs((w.frame?.minX ?? -99) - (vis.minX + 8)) < 1.5, fmt(w.frame))
        await act(.leftHalf); expect("Ripetuta: ⅔", w, target(.leftHalf, count: 1))
        await act(.leftHalf); expect("Ripetuta di nuovo: ⅓", w, target(.leftHalf, count: 2))
        await act(.leftHalf); expect("Quarta volta: torna a ½", w, target(.leftHalf))
        await act(.restore); expect("Ripristina la posizione di prima", w, start)
        let edge: [Layout.Action] = [.rightHalf, .topHalf, .bottomHalf, .firstThird, .centerThird, .lastThird,
                                     .topLeft, .topRight, .bottomLeft, .bottomRight, .maximize]
        for a in edge { await act(a); expect(a.title, w, target(a)) }
        await place(w, start); await act(.center)
        expect("Centra", w, Layout.centered(start.size, in: vis))
        let layout = SavedLayout(name: "E2E", rows: 6, cols: 6, from: .init(row: 0, col: 1), to: .init(row: 5, col: 4))
        mover.apply(layout); await wait(0.35)
        expect("Layout salvato applicato", w, cells(layout.from, layout.to))
        guard NSScreen.screens.count > 1 else { skip("Schermo successivo / precedente: c'è un solo schermo"); return }
        await place(w, start)
        await act(.nextDisplay)
        check("Schermo successivo", w.frame.flatMap(Screens.screen(for:)) == Screens.next(after: screen), fmt(w.frame))
        await act(.previousDisplay)
        check("Schermo precedente", w.frame.flatMap(Screens.screen(for:)) == screen, fmt(w.frame))
    }

    private func settingsEffects(_ w: AXWindow) async {
        section("Effetto delle impostazioni")
        store.gap = 0
        await place(w, start); await act(.leftHalf)
        expect("Spazio 0: metà sinistra fino ai bordi", w, Layout.rect(for: .leftHalf, in: vis, repeatCount: 0)!)
        store.gap = 8
        store.marginTop = 30
        await act(.maximize)
        check("Margine sopra 30 pt", abs((w.frame?.minY ?? -99) - (vis.minY + 38)) < 1.5, fmt(w.frame))
        store.marginTop = 0
        store.excluded = [Bundle.main.bundleIdentifier ?? ""]
        await place(w, start); await act(.leftHalf)
        expect("App esclusa: la finestra non si muove", w, start)
        store.excluded = []
        store.moveCursor = true
        await place(w, start); await act(.rightHalf)
        let center = w.frame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? .zero
        check("Il cursore segue la finestra", hypot(Screens.cursorAX.x - center.x, Screens.cursorAX.y - center.y) < 3)
        store.moveCursor = false
        guard NSScreen.screens.count > 1 else { skip("Ripetizione verso lo schermo accanto: un solo schermo"); return }
        let next = Screens.next(after: screen)
        store.repeatMode = .nextDisplay
        await place(w, start); await act(.rightHalf); await act(.rightHalf)
        expect("Ripetendo → metà sinistra dello schermo accanto", w, mover.target(.leftHalf, in: Screens.axVisibleFrame(next))!)
        store.repeatMode = .cycle
        store.useCursorScreen = true
        let nv = Screens.axVisibleFrame(next)
        CGWarpMouseCursorPosition(CGPoint(x: nv.midX, y: nv.midY))
        await place(w, start); await act(.leftHalf)
        expect("«Schermo del cursore»: agisce sullo schermo col mouse", w, mover.target(.leftHalf, in: nv)!)
        store.useCursorScreen = false
    }

    private func hotkeys(_ w: AXWindow) async {
        section("Scorciatoie da tastiera (eventi veri)")
        check("Nessun conflitto interno", HotkeyCenter.shared.conflicts.isEmpty, "\(HotkeyCenter.shared.conflicts)")
        await place(w, start)
        key(kVK_DownArrow, ctrlOpt); await wait(0.5)
        expect("⌃⌥↓ → metà inferiore", w, target(.bottomHalf))
        let custom = Shortcut(keyCode: kVK_ANSI_L, modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue, chars: "l")
        store.shortcuts[Layout.Action.leftHalf.rawValue] = custom
        await place(w, start)
        key(kVK_ANSI_L, ctrlOptCmd); await wait(0.5)
        expect("Scorciatoia cambiata in ⌃⌥⌘L", w, target(.leftHalf))
        if otherWindowManager == nil {
            await place(w, start)
            key(kVK_LeftArrow, ctrlOpt); await wait(0.5)
            expect("La vecchia ⌃⌥← non fa più niente", w, start)
        } else {
            skip("Vecchia ⌃⌥← inattiva: \(otherWindowManager!) è aperto e la userebbe lui")
        }
        store.shortcuts[Layout.Action.leftHalf.rawValue] = nil
        await place(w, start)
        key(kVK_ANSI_L, ctrlOptCmd); await wait(0.5)
        expect("Scorciatoia rimossa: nessun effetto", w, start)
        store.shortcuts = Store.defaultShortcuts

        var layout = SavedLayout(name: "E2E", rows: 6, cols: 6, from: .init(row: 0, col: 0), to: .init(row: 2, col: 5))
        layout.shortcut = Shortcut(keyCode: kVK_ANSI_1, modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue, chars: "1")
        store.layouts = [layout]
        await place(w, start)
        key(kVK_ANSI_1, ctrlOptCmd); await wait(0.5)
        expect("Scorciatoia di un layout salvato", w, cells(layout.from, layout.to))
        store.layouts = []

        let dup = HotKeys.shared.register(kVK_ANSI_G, controlKey | optionKey) {}
        check("Una combinazione già usata da Maestro viene rifiutata", dup == 0)
        if dup != 0 { HotKeys.shared.unregister(dup) }
    }

    private func grid(_ w: AXWindow) async {
        section("Griglia")
        await place(w, start)
        CGWarpMouseCursorPosition(CGPoint(x: vis.midX, y: vis.midY)); await wait(0.2)
        key(kVK_ANSI_G, ctrlOpt); await wait(0.5)
        check("⌃⌥G apre la griglia", overlay.isShowingGrid)
        if !overlay.isShowingGrid { overlay.show(); await wait(0.4) }
        key(kVK_ANSI_KeypadMinus); await wait(0.3)
        check("Il tasto − toglie una colonna", store.gridCols == 5, "colonne: \(store.gridCols)")
        key(kVK_ANSI_KeypadPlus); await wait(0.3)
        check("Il tasto + aggiunge una colonna", store.gridCols == 6, "colonne: \(store.gridCols)")
        if let g = overlay.gridScreenRect {
            await drag(from: cellPoint(g, 0, 0), to: cellPoint(g, 5, 2))
            expect("Trascinando sulle celle 3 × 6 a sinistra", w, cells(.init(row: 0, col: 0), .init(row: 5, col: 2)))
            check("La griglia si chiude dopo la scelta", !overlay.isVisible)
        } else {
            check("Griglia visibile per il trascinamento", false)
        }

        overlay.show(); await wait(0.4)
        key(kVK_Escape); await wait(0.3)
        check("Esc chiude la griglia", !overlay.isVisible)

        await place(w, start)
        overlay.show(); await wait(0.4)
        let title = CGPoint(x: start.midX, y: start.minY + 12)
        mouse(.leftMouseDown, title); mouse(.leftMouseUp, title); await wait(0.3)
        check("Un clic fuori chiude la griglia", !overlay.isVisible)

        overlay.show(); await wait(0.4)
        if let g = overlay.gridScreenRect {
            await drag(from: cellPoint(g, 0, 3), to: cellPoint(g, 5, 5), endFlags: .maskCommand)
            await wait(0.6)
            check("⌘ al rilascio apre «Nuovo layout»", store.editing != nil && SettingsWindow.shared.visibleTitle != nil,
                  "editing: \(store.editing != nil), finestra: \(SettingsWindow.shared.visibleTitle ?? "chiusa")")
            check("Il nuovo layout ha l'area scelta",
                  store.editing?.from == .init(row: 0, col: 3) && store.editing?.to == .init(row: 5, col: 5))
        }
        store.editing = nil
        SettingsWindow.shared.close()
        await focusChild()

        store.excluded = [Bundle.main.bundleIdentifier ?? ""]
        overlay.show(); await wait(0.3)
        check("App esclusa: un messaggio invece della griglia", overlay.isVisible && !overlay.isShowingGrid)
        await wait(1.9)
        check("Il messaggio sparisce da solo", !overlay.isVisible)
        store.excluded = []
    }

    private func snapping(_ w: AXWindow) async {
        section("Trascina ai bordi (trascinamenti veri)")
        let sf = Layout.flip(screen.frame, primaryHeight: Screens.primaryHeight)
        func bar(_ f: CGRect?) -> CGPoint { let f = f ?? start; return CGPoint(x: f.midX, y: f.minY + 12) }

        await place(w, start)
        await drag(from: bar(start), to: CGPoint(x: sf.minX + 2, y: sf.midY))
        expect("Bordo sinistro → metà sinistra", w, target(.leftHalf))
        await drag(from: bar(w.frame), to: CGPoint(x: vis.midX, y: vis.midY))
        check("Staccandola torna 700 × 450", w.frame.map { abs($0.width - 700) < 3 && abs($0.height - 450) < 3 } ?? false, fmt(w.frame))
        await drag(from: bar(w.frame), to: CGPoint(x: sf.midX, y: sf.minY + 1))
        expect("Bordo superiore → massimizza", w, target(.maximize))
        await place(w, start)
        await drag(from: bar(start), to: CGPoint(x: sf.midX, y: sf.maxY - 2))
        expect("Bordo inferiore, al centro → terzo centrale", w, target(.centerThird))
        await place(w, start)
        await drag(from: bar(start), to: CGPoint(x: sf.maxX - 2, y: sf.minY + 2))
        expect("Angolo in alto a destra → quarto", w, target(.topRight))

        store.snapEnabled = false; await wait(0.3)
        await place(w, start)
        await drag(from: bar(start), to: CGPoint(x: sf.minX + 2, y: sf.midY))
        check("Con l'aggancio spento non si aggancia", !near(w.frame, target(.leftHalf)), fmt(w.frame))
        store.snapEnabled = true; await wait(0.3)
    }

    private func model() {
        section("Modello e impostazioni")
        store.gap = 13
        check("Le impostazioni vengono salvate", UserDefaults.standard.double(forKey: "gap") == 13)
        store.gap = 8
        store.showMenuIcon = false
        check("Icona nella barra: si nasconde", !statusItemVisible())
        store.showMenuIcon = true
        check("Icona nella barra: riappare", statusItemVisible())
        if SMAppService.mainApp.status == .enabled {
            skip("Avvio al login: è già attivo, non lo tocco")
        } else {
            do {
                try SMAppService.mainApp.register()
                let on = SMAppService.mainApp.status
                check("Avvio al login: si attiva", on == .enabled, "stato: \(on.rawValue) (2 = da approvare in Impostazioni di Sistema)")
                try SMAppService.mainApp.unregister()
                check("Avvio al login: si disattiva", SMAppService.mainApp.status != .enabled)
            } catch {
                check("Avvio al login", false, error.localizedDescription)
            }
        }
        let left = Store.defaultShortcuts[Layout.Action.leftHalf.rawValue]!
        check("Doppione riconosciuto nel registratore", store.owner(of: left, except: "rightHalf") == "Metà sinistra")
        check("Nessun falso doppione", store.owner(of: left, except: Layout.Action.leftHalf.rawValue) == nil)
    }

    private func menu() {
        section("Menu della barra")
        let menu = NSMenu()
        buildMenu(menu)
        let titles = menu.items.map(\.title)
        let wanted = ["Griglia…", "Metà sinistra", "Massimizza", "Centra", "Ripristina", "Schermo successivo", "Impostazioni…", "Esci da Maestro"]
        let missing = wanted.filter { !titles.contains($0) }
        check("Voci principali presenti", missing.isEmpty, "mancano: \(missing)")
        let left = menu.items.first { $0.title == "Metà sinistra" }
        check("⌃⌥← mostrata accanto a «Metà sinistra»",
              left?.keyEquivalent == functionKey(NSLeftArrowFunctionKey) && left?.keyEquivalentModifierMask == [.control, .option])
        let subs = ["Terzi", "Angoli", "Layout salvati"].filter { t in menu.items.first { $0.title == t }?.submenu == nil }
        check("Sottomenu Terzi, Angoli, Layout salvati", subs.isEmpty, "mancano: \(subs)")
    }

    private func settingsWindow() async {
        section("Finestra Impostazioni")
        for pane in Pane.allCases {
            SettingsWindow.shared.show(pane)
            await wait(0.5)
            check("Si apre «\(pane.title)»", SettingsWindow.shared.visibleTitle == pane.title, SettingsWindow.shared.visibleTitle ?? "chiusa")
        }
        SettingsWindow.shared.close()
    }

    // MARK: Setup

    private func resetSettings() {
        store.gap = 8; store.marginTop = 0; store.marginBottom = 0; store.marginSides = 0
        store.useCursorScreen = false; store.repeatMode = .cycle; store.moveCursor = false
        store.gridRows = 6; store.gridCols = 6; store.panelNearCursor = false; store.showPreview = true
        store.snapEnabled = true; store.snapSides = "halves"; store.snapTop = "maximize"; store.snapBottom = "thirds"
        store.snapCorners = "quarters"; store.snapDistance = 5; store.restoreOnUnsnap = true
        store.excluded = []; store.layouts = []; store.shortcuts = Store.defaultShortcuts
    }

    private func launchTarget() async -> AXWindow? {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = ["--e2e-target"]
        config.activates = true
        child = try? await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
        guard child != nil, await focusChild(), let w = AXWindow.focused(), let frame = w.frame,
              let s = Screens.screen(for: frame) else {
            check("Finestra di prova in primo piano", false)
            return nil
        }
        screen = s
        vis = Screens.axVisibleFrame(s)
        start = CGRect(x: vis.minX + 120, y: vis.minY + 90, width: 700, height: 450)
        check("Finestra di prova in primo piano", true)
        return w
    }

    @discardableResult
    private func focusChild() async -> Bool {
        guard let child else { return false }
        child.activate()
        return await waitFor(8) {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == child.processIdentifier && AXWindow.focused() != nil
        }
    }

    // MARK: Helpers

    @discardableResult
    private func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") -> Bool {
        let d = ok ? "" : detail()
        lines.append("\(ok ? "OK  " : "FAIL") \(name)\(d.isEmpty ? "" : " — \(d)")")
        if !ok { failures += 1 }
        return ok
    }

    private func expect(_ name: String, _ w: AXWindow, _ rect: CGRect) {
        check(name, near(w.frame, rect), "atteso \(fmt(rect)), ottenuto \(fmt(w.frame))")
    }

    private func skip(_ what: String) { lines.append("—    \(what): saltato") }
    private func section(_ title: String) { lines.append("\n## \(title)") }

    private func target(_ a: Layout.Action, count: Int = 0) -> CGRect { mover.target(a, in: vis, count: count) ?? .null }

    private func cells(_ a: Layout.Cell, _ b: Layout.Cell) -> CGRect {
        Layout.applyGaps(Layout.cellsRect(from: a, to: b, rows: 6, cols: 6, in: vis), in: vis, gap: 8)
    }

    private func near(_ a: CGRect?, _ b: CGRect) -> Bool { a.map { Layout.nearlyEqual($0, b, tolerance: 3) } ?? false }

    private func fmt(_ r: CGRect?) -> String {
        guard let r else { return "nessuna" }
        return "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))"
    }

    private func act(_ a: Layout.Action) async { mover.perform(a); await wait(0.35) }
    private func place(_ w: AXWindow, _ r: CGRect) async { w.setFrame(r); await wait(0.35) }
    private func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    private func waitFor(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            await wait(0.1)
        }
        return condition()
    }

    private func key(_ code: Int, _ flags: CGEventFlags = []) {
        // A real arrow key press also carries the numeric-pad and Fn flags, and Carbon hotkeys
        // on arrows only fire with them: without these the synthetic press is silently ignored.
        var flags = flags
        if [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow].contains(code) {
            flags.formUnion([.maskNumericPad, .maskSecondaryFn])
        }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    private func mouse(_ type: CGEventType, _ p: CGPoint, _ flags: CGEventFlags = []) {
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
    }

    private func drag(from a: CGPoint, to b: CGPoint, endFlags: CGEventFlags = []) async {
        mouse(.leftMouseDown, a); await wait(0.15)
        let steps = 30
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            await wait(0.02)
        }
        await wait(0.2)
        mouse(.leftMouseUp, b, endFlags)
        await wait(0.5)
    }

    /// Centre of a grid cell, from the grid's AppKit screen rect to AX coordinates.
    private func cellPoint(_ g: NSRect, _ row: Int, _ col: Int) -> CGPoint {
        let x = g.minX + (CGFloat(col) + 0.5) * g.width / CGFloat(store.gridCols)
        let y = g.maxY - (CGFloat(row) + 0.5) * g.height / CGFloat(store.gridRows)
        return CGPoint(x: x, y: Screens.primaryHeight - y)
    }
}
