import SwiftUI
import AppKit

@MainActor
final class LevelStore: ObservableObject {
    /// 0…1 per transmitter slot.
    @Published var levels: [Int: Double] = [:]

    func update(_ raw: [Int: Int]) {
        var next = levels
        for (slot, v) in raw { next[slot] = min(1, Double(v) / 100) }
        levels = next
    }

    func retain(slots: Set<Int>) {
        let next = levels.filter { slots.contains($0.key) }
        if next != levels { levels = next }
    }
}

@MainActor
final class MicStore: ObservableObject {
    static let shared = MicStore()

    @Published private(set) var state = MicState()
    @Published private(set) var caseConnected = false
    @Published private(set) var receiverOnUSB = false
    @Published private(set) var menuBarImage = NSImage()

    let levels = LevelStore()
    private let reader = MicReader()
    private var timer: Timer?
    private var started = false

    init() { renderMenuBarImage() }

    func start() {
        guard !started else { return }
        started = true
        reader.onState = { [weak self] s in
            DispatchQueue.main.async { self?.set(state: s) }
        }
        reader.onLevels = { [weak self] l in
            DispatchQueue.main.async { self?.levels.update(l) }
        }
        reader.start()
        refreshUSB()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshUSB(); self?.prunePending() }
        }
    }

    func stop() {
        timer?.invalidate()
        reader.stop()
    }

    /// Sets a fixed state without touching USB (used to render README screenshots).
    func preview(state s: MicState, caseConnected box: Bool, levels l: [Int: Double]) {
        state = s
        caseConnected = box
        receiverOnUSB = s.link != .searching
        levels.levels = l
        renderMenuBarImage()
    }

    /// Sends a setting change to the receiver. The UI updates when the receiver reports the new
    /// value in its next status packet.
    func apply(_ change: SettingChange) {
        guard state.link == .connected, change.encoded != nil else { return }
        if change.isReflected(in: state) { return }
        pending[change.key] = (change, Date().addingTimeInterval(3))
        reader.send([change])
    }

    /// Changes sent but not yet confirmed by a status packet. Shown in the UI for up to 3 s so
    /// controls don't snap back while the receiver applies them; then device state wins.
    @Published private(set) var pending: [String: (change: SettingChange, until: Date)] = [:]

    func pendingChange(_ key: String) -> SettingChange? {
        guard let p = pending[key], p.until > Date() else { return nil }
        return p.change
    }

    private func prunePending() {
        let now = Date()
        let next = pending.filter { $0.value.until > now && !$0.value.change.isReflected(in: state) }
        if next.count != pending.count { pending = next }
    }

    private func set(state s: MicState) {
        guard s != state else { return }
        state = s
        prunePending()
        levels.retain(slots: Set(s.tx.keys))
        renderMenuBarImage()
    }

    private func refreshUSB() {
        let names = attachedDJIProducts()
        let box = names.contains { $0.localizedCaseInsensitiveContains("box") }
        let rx = names.contains { $0.localizedCaseInsensitiveContains("rx") || $0.localizedCaseInsensitiveContains("receiver") }
        if box != caseConnected { caseConnected = box }
        if rx != receiverOnUSB { receiverOnUSB = rx }
    }

    /// Battery shown in the menu bar: the lowest-charged linked transmitter.
    var primaryTransmitter: TxInfo? {
        state.transmitters.max { ($0.batteryLevel ?? 0) < ($1.batteryLevel ?? 0) }
    }

    private func renderMenuBarImage() {
        let glyph = MenuBarGlyph(linked: !state.transmitters.isEmpty,
                                 connected: state.link == .connected,
                                 tx: primaryTransmitter)
        let r = ImageRenderer(content: glyph)
        r.scale = 2
        if let cg = r.cgImage {
            let img = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
            img.isTemplate = true
            menuBarImage = img
        }
    }
}

// MARK: - Battery helpers

enum Battery {
    /// dji-mic-mo reports 1 = full … 7 = empty; 0 / nil = unknown.
    static func fraction(_ level: Int?) -> Double? {
        guard let level, (1...7).contains(level) else { return nil }
        return Double(8 - level) / 7
    }

    static func word(_ level: Int?) -> String {
        switch level {
        case 1: "Full"
        case 2: "High"
        case 3: "Good"
        case 4: "Half"
        case 5: "Fair"
        case 6: "Low"
        case 7: "Very Low"
        default: "—"
        }
    }

    static func color(_ level: Int?, charging: Bool) -> Color {
        if charging { return .green }
        switch level {
        case 7: return .red
        case 6: return .orange
        default: return .green
        }
    }
}
