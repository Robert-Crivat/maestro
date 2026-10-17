import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum Pane: String, CaseIterable, Identifiable {
    case general, shortcuts, grid, snap, excluded
    var id: Self { self }

    var title: String {
        switch self {
        case .general: "Generale"
        case .shortcuts: "Scorciatoie"
        case .grid: "Griglia e layout"
        case .snap: "Trascina ai bordi"
        case .excluded: "App escluse"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .shortcuts: "keyboard.fill"
        case .grid: "square.grid.3x3.fill"
        case .snap: "rectangle.lefthalf.filled"
        case .excluded: "nosign"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .shortcuts: .blue
        case .grid: .purple
        case .snap: .orange
        case .excluded: .red
        }
    }
}

func openAccessibilitySettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
}

final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private var titleObserver: AnyCancellable?

    func show(_ pane: Pane? = nil) {
        if let pane { Store.shared.pane = pane }
        if window == nil {
            let root = SettingsView().environmentObject(Store.shared).environmentObject(HotkeyCenter.shared)
            let controller = NSHostingController(rootView: root)
            if #available(macOS 14, *) { controller.sceneBridgingOptions = [.toolbars, .title] }
            let w = NSWindow(contentViewController: controller)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.toolbarStyle = .unified
            w.setContentSize(NSSize(width: 800, height: 600))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            // navigationTitle does not reach an NSWindow built by hand: set it from the selected pane.
            titleObserver = Store.shared.$pane.sink { [weak w] in w?.title = ($0 ?? .general).title }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    var visibleTitle: String? { window?.isVisible == true ? window?.title : nil }
    func close() { window?.close() }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var hotkeys: HotkeyCenter

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $store.pane) { pane in
                Label { Text(pane.title) } icon: { PaneIcon(pane: pane) }
            }
            .navigationSplitViewColumnWidth(210)
        } detail: {
            detail.navigationTitle((store.pane ?? .general).title)
        }
        .frame(minWidth: 760, minHeight: 540)
        .sheet(item: $store.editing) { layout in
            LayoutEditor(layout: layout).environmentObject(store).environmentObject(hotkeys)
        }
    }

    @ViewBuilder private var detail: some View {
        switch store.pane ?? .general {
        case .general: GeneralPane()
        case .shortcuts: ShortcutsPane()
        case .grid: GridPane()
        case .snap: SnapPane()
        case .excluded: ExcludedPane()
        }
    }
}

struct PaneIcon: View {
    let pane: Pane
    var body: some View {
        Image(systemName: pane.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(pane.color.gradient, in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Generale

struct GeneralPane: View {
    @EnvironmentObject var store: Store
    @State private var trusted = AXIsProcessTrusted()
    @State private var atLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            if !trusted {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Maestro non può spostare le finestre").bold()
                            Text("Serve l'accesso in Impostazioni di Sistema → Privacy e sicurezza → Accessibilità.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Apri…", action: openAccessibilitySettings).buttonStyle(.borderedProminent)
                    }
                }
            }
            Section {
                Toggle("Apri Maestro al login", isOn: Binding(get: { atLogin }, set: setLogin))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle(isOn: $store.showMenuIcon) {
                    Text("Mostra l'icona nella barra dei menu")
                    Text("Se la nascondi, riapri Maestro dal Finder per tornare qui.")
                }
                LabeledContent("Accesso Accessibilità") {
                    HStack(spacing: 6) {
                        Circle().fill(trusted ? Color.green : Color.orange).frame(width: 8, height: 8)
                        Text(trusted ? "Concesso" : "Non concesso")
                    }
                }
            }
            Section("Finestre") {
                LabeledContent("Spazio tra le finestre") { SliderValue(value: $store.gap, range: 0...30) }
                LabeledContent("Margini dello schermo") {
                    HStack(spacing: 10) {
                        number("Sopra", $store.marginTop)
                        number("Sotto", $store.marginBottom)
                        number("Lati", $store.marginSides)
                    }
                }
                Picker("Schermo su cui agire", selection: $store.useCursorScreen) {
                    Text("Della finestra").tag(false)
                    Text("Del cursore").tag(true)
                }
                .pickerStyle(.segmented).fixedSize()
                Picker("Ripetendo una scorciatoia delle metà", selection: $store.repeatMode) {
                    ForEach(RepeatMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Sposta il cursore con la finestra", isOn: $store.moveCursor)
            }
        }
        .formStyle(.grouped)
        .onReceive(tick) { _ in trusted = AXIsProcessTrusted() }
    }

    private func number(_ label: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            TextField(label, value: value, format: .number)
                .labelsHidden().frame(width: 46).multilineTextAlignment(.trailing)
        }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Non riesco a cambiare l'avvio al login: \(error.localizedDescription)"
        }
        atLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Scorciatoie

struct ShortcutsPane: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Form {
            // macOS does not report hotkeys owned by other apps: warn about the usual suspects.
            if let other = otherWindowManager {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(other) è aperto").bold()
                            Text("Usa combinazioni simili alle predefinite di Maestro: quando coincidono, solo una delle due app riceve i tasti. Chiudi \(other) o cambia le scorciatoie qui sotto.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            ForEach(ActionGroup.allCases) { group in
                Section(group.title) {
                    ForEach(group.actions, id: \.self) { action in
                        ShortcutRow(title: action.title, key: action.rawValue, shortcut: binding(action))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .toolbar { Button("Ripristina predefinite") { store.shortcuts = Store.defaultShortcuts } }
    }

    private func binding(_ action: Layout.Action) -> Binding<Shortcut?> {
        Binding(get: { store.shortcuts[action.rawValue] }, set: { store.shortcuts[action.rawValue] = $0 })
    }
}

// MARK: - Griglia e layout

struct GridPane: View {
    @EnvironmentObject var store: Store
    @State private var selected: UUID?

    var body: some View {
        Form {
            Section {
                LabeledContent("Dimensione della griglia") {
                    HStack(spacing: 16) {
                        Stepper("Righe \(store.gridRows)", value: $store.gridRows, in: 1...12)
                        Stepper("Colonne \(store.gridCols)", value: $store.gridCols, in: 1...12)
                    }
                }
                Picker("Posizione del pannello", selection: $store.panelNearCursor) {
                    Text("Al centro").tag(false)
                    Text("Vicino al cursore").tag(true)
                }
                .pickerStyle(.segmented).fixedSize()
                Toggle("Anteprima mentre trascini", isOn: $store.showPreview)
            }
            Section("Layout salvati") {
                if store.layouts.isEmpty {
                    EmptyState(title: "Nessun layout",
                               text: "Apri la griglia con \(store.shortcuts[Layout.Action.grid.rawValue]?.display ?? "la sua scorciatoia"), seleziona un'area e rilascia tenendo premuto ⌘.") {
                        Button("Nuovo layout…", action: newLayout)
                    }
                }
                ForEach(store.layouts) { layout in
                    LayoutRow(layout: layout, shortcut: shortcutBinding(layout.id))
                        .padding(.vertical, 2)
                        .background(selected == layout.id ? Color.accentColor.opacity(0.15) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { store.editing = layout }
                        .onTapGesture { selected = layout.id }
                }
                HStack {
                    PlusMinus(add: newLayout, remove: removeSelected, canRemove: selected != nil)
                    Spacer()
                    Text("Doppio clic su un layout per modificarlo").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func newLayout() {
        let rows = store.gridRows, cols = store.gridCols
        store.editing = SavedLayout(name: "Layout \(store.layouts.count + 1)", rows: rows, cols: cols,
                                    from: .init(row: 0, col: 0), to: .init(row: rows - 1, col: max(cols / 2 - 1, 0)))
    }

    private func removeSelected() {
        store.layouts.removeAll { $0.id == selected }
        selected = nil
    }

    private func shortcutBinding(_ id: UUID) -> Binding<Shortcut?> {
        Binding(get: { store.layouts.first { $0.id == id }?.shortcut },
                set: { s in if let i = store.layouts.firstIndex(where: { $0.id == id }) { store.layouts[i].shortcut = s } })
    }
}

struct LayoutRow: View {
    let layout: SavedLayout
    @Binding var shortcut: Shortcut?
    @EnvironmentObject var hotkeys: HotkeyCenter

    var body: some View {
        HStack(spacing: 12) {
            CellsView(rows: layout.rows, cols: layout.cols, from: layout.from, to: layout.to, spacing: 1, radius: 1.5)
                .frame(width: 54, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(layout.name)
                Text(layout.summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ShortcutField(key: layout.hotkeyID, shortcut: $shortcut,
                          conflict: shortcut != nil && hotkeys.conflicts.contains(layout.hotkeyID))
        }
    }
}

struct LayoutEditor: View {
    @EnvironmentObject var store: Store
    @State var layout: SavedLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "Nuovo layout" : "Modifica layout").font(.headline)
            CellPicker(rows: layout.rows, cols: layout.cols, from: $layout.from, to: $layout.to)
                .aspectRatio(16 / 10, contentMode: .fit)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Nome").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    TextField("Nome", text: $layout.name).labelsHidden()
                }
                GridRow {
                    Text("Scorciatoia").foregroundStyle(.secondary)
                    ShortcutField(key: layout.hotkeyID, shortcut: $layout.shortcut)
                }
                GridRow {
                    Text("Schermo").foregroundStyle(.secondary)
                    Picker("Schermo", selection: $layout.cursorScreen) {
                        Text("Della finestra").tag(false)
                        Text("Del cursore").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            HStack {
                Spacer()
                Button("Annulla") { store.editing = nil }.keyboardShortcut(.cancelAction)
                Button("Salva") { store.save(layout); store.editing = nil }
                    .keyboardShortcut(.defaultAction)
                    .disabled(layout.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var isNew: Bool { !store.layouts.contains { $0.id == layout.id } }
}

// MARK: - Trascina ai bordi

struct SnapPane: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Form {
            Section {
                Toggle("Aggancia le finestre trascinandole ai bordi", isOn: $store.snapEnabled)
            }
            Section {
                ZonesDiagram().frame(height: 170)
                Picker("Bordo sinistro / destro", selection: $store.snapSides) {
                    Text("Metà").tag("halves")
                    Text("Nessuna azione").tag("off")
                }
                Picker("Bordo superiore", selection: $store.snapTop) {
                    Text("Massimizza").tag("maximize")
                    Text("Metà superiore").tag("topHalf")
                    Text("Nessuna azione").tag("off")
                }
                Picker("Bordo inferiore", selection: $store.snapBottom) {
                    Text("Terzi (sinistro · centro · destro)").tag("thirds")
                    Text("Metà inferiore").tag("bottomHalf")
                    Text("Nessuna azione").tag("off")
                }
                Picker("Angoli", selection: $store.snapCorners) {
                    Text("Quarti").tag("quarters")
                    Text("Nessuna azione").tag("off")
                }
            }
            .disabled(!store.snapEnabled)
            Section {
                LabeledContent("Distanza dal bordo per agganciare") { SliderValue(value: $store.snapDistance, range: 1...30) }
                Toggle("Ridà la dimensione di prima quando stacchi la finestra", isOn: $store.restoreOnUnsnap)
            } footer: {
                Text("Se macOS aggancia anche lui le finestre, spegni «Trascina le finestre ai bordi dello schermo per affiancarle» in Impostazioni di Sistema → Scrivania e Dock.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!store.snapEnabled)
        }
        .formStyle(.grouped)
    }
}

// MARK: - App escluse

struct ExcludedPane: View {
    @EnvironmentObject var store: Store
    @State private var selected: String?

    var body: some View {
        Form {
            Section {
                Text("Su queste app Maestro ignora scorciatoie, griglia e trascinamento ai bordi.").foregroundStyle(.secondary)
            }
            Section {
                if store.excluded.isEmpty {
                    EmptyState(title: "Nessuna app esclusa", text: "Maestro agisce su tutte le app.") { EmptyView() }
                }
                ForEach(store.excluded, id: \.self) { id in
                    AppRow(bundleID: id)
                        .padding(.vertical, 2)
                        .background(selected == id ? Color.accentColor.opacity(0.15) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { selected = id }
                }
                HStack {
                    PlusMinus(add: pickApp, remove: { store.excluded.removeAll { $0 == selected }; selected = nil },
                              canRemove: selected != nil)
                    Spacer()
                    Menu("Aggiungi un'app aperta") {
                        ForEach(runningApps, id: \.processIdentifier) { app in
                            Button(app.localizedName ?? "") { store.excluded.append(app.bundleIdentifier ?? "") }
                        }
                    }
                    .fixedSize()
                }
            }
        }
        .formStyle(.grouped)
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { app in
                guard app.activationPolicy == .regular, let id = app.bundleIdentifier else { return false }
                return id != Bundle.main.bundleIdentifier && !store.excluded.contains(id)
            }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !store.excluded.contains(id) { store.excluded.append(id) }
        }
    }
}

struct AppRow: View {
    let bundleID: String

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack(spacing: 10) {
            Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage())
                .resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.map { $0.deletingPathExtension().lastPathComponent } ?? bundleID)
                Text(bundleID).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
