import AppKit
import Carbon.HIToolbox
import SwiftUI

/// One recording at a time, app-wide: two fields listening at once would both take the same keys.
final class Recorder: ObservableObject {
    static let shared = Recorder()
    @Published private(set) var active: UUID?
    private var monitor: Any?

    func start(_ field: UUID, onKey: @escaping (NSEvent) -> Void) {
        stop()
        active = field
        HotkeyCenter.shared.suspend()  // global hotkeys would swallow the combination
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            onKey(event)
            return nil
        }
    }

    /// Stops the recording; with `field`, only if that field is the one recording.
    func stop(_ field: UUID? = nil) {
        guard let current = active, field == nil || field == current else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        active = nil
        HotkeyCenter.shared.resume()
    }
}

/// Click, press a key combination. Esc cancels, ⌫ clears.
struct ShortcutField: View {
    let key: String
    @Binding var shortcut: Shortcut?
    var conflict = false
    @EnvironmentObject var store: Store
    @ObservedObject private var recorder = Recorder.shared
    @State private var field = UUID()
    @State private var note: String?

    private var recording: Bool { recorder.active == field }

    var body: some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 12, weight: shortcut != nil && !recording ? .medium : .regular))
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity)
            if shortcut != nil && !recording {
                Button { shortcut = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
                    .padding(.trailing, 5)
                    .help("Rimuovi scorciatoia")
            }
        }
        .frame(width: 150, height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(borderColor, lineWidth: recording ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture { recording ? stop() : start() }
        .help("Clic per registrare · Esc annulla · ⌫ cancella")
        .onDisappear(perform: stop)
    }

    private var label: String {
        if recording { return note ?? "Premi i tasti…" }
        return shortcut?.display ?? "Registra scorciatoia"
    }

    private var textColor: Color {
        if recording { return note == nil ? .accentColor : .red }
        if conflict { return .red }
        return shortcut == nil ? .secondary : .primary
    }

    private var borderColor: Color {
        if recording { return .accentColor }
        return conflict ? .red : Color(nsColor: .separatorColor)
    }

    private func start() {
        note = nil
        recorder.start(field) { record($0) }
    }

    private func stop() { recorder.stop(field) }

    private func record(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let code = Int(event.keyCode)
        if mods.isEmpty && code == kVK_Escape { stop(); return }
        if mods.isEmpty && (code == kVK_Delete || code == kVK_ForwardDelete) { shortcut = nil; stop(); return }
        guard !mods.subtracting(.shift).isEmpty else { note = "Serve ⌃, ⌥ o ⌘"; NSSound.beep(); return }
        let s = Shortcut(keyCode: code, modifiers: mods.rawValue, chars: event.charactersIgnoringModifiers ?? "")
        if let owner = store.owner(of: s, except: key) { note = "Già usata da «\(owner)»"; NSSound.beep(); return }
        shortcut = s
        stop()
    }
}

struct ShortcutRow: View {
    let title: String
    let key: String
    @Binding var shortcut: Shortcut?
    @EnvironmentObject var hotkeys: HotkeyCenter

    var body: some View {
        LabeledContent {
            ShortcutField(key: key, shortcut: $shortcut, conflict: conflict)
        } label: {
            Text(title)
            if conflict {
                Text("\(shortcut?.display ?? "") è già usata da un'altra app\(otherWindowManager.map { " (\($0) è aperto)" } ?? ""). Chiudila o scegli un'altra combinazione.")
                    .foregroundStyle(.red)
            }
        }
    }

    private var conflict: Bool { shortcut != nil && hotkeys.conflicts.contains(key) }
}

/// A window manager that is running and probably owns the conflicting shortcut.
var otherWindowManager: String? {
    let known = ["com.knollsoft.Rectangle": "Rectangle", "com.knollsoft.Hookshot": "Hookshot",
                 "com.mizage.direct.Divvy": "Divvy", "com.mizage.Divvy": "Divvy", "com.crowdcafe.windowmagnet": "Magnet"]
    return NSWorkspace.shared.runningApplications.lazy.compactMap { $0.bundleIdentifier.flatMap { known[$0] } }.first
}

/// Grid thumbnail with a selection.
struct CellsView: View {
    let rows: Int
    let cols: Int
    let from: Layout.Cell
    let to: Layout.Cell
    var spacing: CGFloat = 3
    var radius: CGFloat = 4

    var body: some View {
        Canvas { context, size in
            let w = size.width / CGFloat(cols), h = size.height / CGFloat(rows)
            let rowRange = min(from.row, to.row)...max(from.row, to.row)
            let colRange = min(from.col, to.col)...max(from.col, to.col)
            for r in 0..<rows {
                for c in 0..<cols {
                    let rect = CGRect(x: CGFloat(c) * w, y: CGFloat(r) * h, width: w, height: h)
                        .insetBy(dx: spacing / 2, dy: spacing / 2)
                    let on = rowRange.contains(r) && colRange.contains(c)
                    context.fill(Path(roundedRect: rect, cornerRadius: radius),
                                 with: .color(on ? Color.accentColor : Color.secondary.opacity(0.18)))
                }
            }
        }
    }
}

/// Drag across the cells to choose an area.
struct CellPicker: View {
    let rows: Int
    let cols: Int
    @Binding var from: Layout.Cell
    @Binding var to: Layout.Cell
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            CellsView(rows: rows, cols: cols, from: from, to: to)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let cell = Layout.Cell(
                            row: clamp(Int(value.location.y / (geo.size.height / CGFloat(rows))), rows),
                            col: clamp(Int(value.location.x / (geo.size.width / CGFloat(cols))), cols))
                        if !dragging { dragging = true; from = cell }
                        to = cell
                    }
                    .onEnded { _ in dragging = false })
        }
    }

    private func clamp(_ v: Int, _ n: Int) -> Int { min(max(v, 0), n - 1) }
}

/// Screen sketch with the snap zones, labelled from the current settings.
struct ZonesDiagram: View {
    @EnvironmentObject var store: Store

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height, edge: CGFloat = 16, corner: CGFloat = 22
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.37, blue: 0.78), Color(red: 0.64, green: 0.39, blue: 0.73)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white, lineWidth: 2))
                    .frame(width: w / 2 - 12, height: h - 16)
                    .offset(x: 8, y: 8)
                if store.snapSides == "halves" {
                    zone(x: 0, y: corner, w: edge, h: h - 2 * corner, "◀")
                    zone(x: w - edge, y: corner, w: edge, h: h - 2 * corner, "▶")
                }
                if store.snapTop != "off" {
                    zone(x: corner, y: 0, w: w - 2 * corner, h: edge, store.snapTop == "maximize" ? "massimizza" : "metà superiore")
                }
                if store.snapBottom != "off" {
                    zone(x: corner, y: h - edge, w: w - 2 * corner, h: edge, store.snapBottom == "thirds" ? "terzi" : "metà inferiore")
                }
                if store.snapCorners == "quarters" {
                    zone(x: 0, y: 0, w: corner, h: corner, "")
                    zone(x: w - corner, y: 0, w: corner, h: corner, "")
                    zone(x: 0, y: h - corner, w: corner, h: corner, "")
                    zone(x: w - corner, y: h - corner, w: corner, h: corner, "")
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.vertical, 4)
    }

    private func zone(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, _ text: String) -> some View {
        Rectangle()
            .fill(.white.opacity(0.3))
            .overlay(Rectangle().strokeBorder(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [3])))
            .overlay(Text(text).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white))
            .frame(width: w, height: h)
            .offset(x: x, y: y)
    }
}

struct SliderValue: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack {
            Slider(value: $value, in: range, step: 1).labelsHidden().frame(width: 170)
            Text("\(Int(value)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
        }
    }
}

struct PlusMinus: View {
    let add: () -> Void
    let remove: () -> Void
    let canRemove: Bool

    var body: some View {
        HStack(spacing: 0) {
            Button(action: add) { Image(systemName: "plus").frame(width: 22, height: 18) }
            Divider().frame(height: 16)
            Button(action: remove) { Image(systemName: "minus").frame(width: 22, height: 18) }.disabled(!canRemove)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 2)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

struct EmptyState<Action: View>: View {
    let title: String
    let text: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 6) {
            Text(title).bold()
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
            action.padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
}
