import SwiftUI
import AppKit

@main
struct Main {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.contains("--dump") { Headless.dump(); return }
        if args.contains("--log") { Headless.log(); return }
        if let i = args.firstIndex(of: "--set"), i + 1 < args.count {
            let slot = args.firstIndex(of: "--slot").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 1
            exit(Headless.set(args[i + 1], slot: slot) ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--screenshots"), i + 1 < args.count {
            Headless.screenshots(dir: args[i + 1]); return
        }
        if let i = args.firstIndex(of: "--glyphs"), i + 1 < args.count {
            Headless.glyphs(path: args[i + 1]); return
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Headless.snapshot(prefix: args[i + 1]); return
        }
        DJIMicBarApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { MicStore.shared.start() }
    }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { MicStore.shared.stop() }
    }
}

struct DJIMicBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var store = MicStore.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store, levels: store.levels)
        } label: {
            Image(nsImage: store.menuBarImage)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Debug modes

@MainActor
enum Headless {
    struct Dump: Encodable {
        var link: LinkStatus
        var receiverOnUSB: Bool
        var caseConnected: Bool
        var rx: RxInfo?
        var transmitters: [TxInfo]
        var txSettings: TxSettings?
        var levels: [String: Double]
    }

    private static func collect(seconds: Double) -> MicStore {
        let store = MicStore.shared
        store.start()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        return store
    }

    static func dump() {
        let s = collect(seconds: 5)
        let out = Dump(link: s.state.link, receiverOnUSB: s.receiverOnUSB, caseConnected: s.caseConnected,
                       rx: s.state.rx, transmitters: s.state.transmitters, txSettings: s.state.txSettings,
                       levels: Dictionary(uniqueKeysWithValues: s.levels.levels.map { ("\($0.key)", $0.value) }))
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try! enc.encode(out), as: UTF8.self))
        s.stop()
    }

    /// Sends one setting change and waits for the receiver to report it.
    static func set(_ arg: String, slot: Int) -> Bool {
        guard let change = SettingChange(arg: arg, slot: slot) else {
            print("usage: --set lowCut|clippingControl|stereo|safetyTrack=on|off, voiceTone=regular|rich|bright, gain=-12|-6|0|6|12 [--slot N]")
            return false
        }
        let s = MicStore.shared
        s.start()
        defer { s.stop() }
        let ready = Date().addingTimeInterval(6)
        while Date() < ready && (s.state.rx?.name == nil || s.state.txSettings == nil && !change.isRxSetting) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        guard s.state.link == .connected, s.state.rx?.name != nil else {
            print("receiver not available (\(s.state.link.rawValue))"); return false
        }
        print("before: \(summary(s.state))")
        if change.isReflected(in: s.state) { print("already set"); return true }
        s.apply(change)
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline && !change.isReflected(in: s.state) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        print("after:  \(summary(s.state))")
        let ok = change.isReflected(in: s.state)
        print(ok ? "OK: receiver confirmed \(arg)" : "FAILED: receiver did not report \(arg) within 6 s")
        return ok
    }

    private static func summary(_ st: MicState) -> String {
        func b(_ v: Bool?) -> String { v.map { $0 ? "on" : "off" } ?? "?" }
        let tones = st.transmitters.map { "tone\($0.slot)=\(VoiceTone(tx: $0)?.rawValue ?? "?")" }.joined(separator: " ")
        return "lowCut=\(b(st.txSettings?.lowCut)) clipping=\(b(st.txSettings?.clippingControl)) \(tones) "
            + "stereo=\(b(st.rx?.stereo)) gain=\(st.rx?.gain.map(String.init) ?? "?") safetyTrack=\(b(st.rx?.safetyTrack))"
    }

    static func snapshot(prefix: String) {
        let s = collect(seconds: 5)
        for scheme in [ColorScheme.light, .dark] {
            let view = PopoverView(store: s, levels: s.levels)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
            write(ImageRenderer(content: view), to: "\(prefix)-\(scheme == .dark ? "dark" : "light").png")
        }
        write(ImageRenderer(content: MenuBarGlyph(linked: !s.state.transmitters.isEmpty,
                                                  connected: s.state.link == .connected,
                                                  tx: s.primaryTransmitter)
                                .padding(4).background(Color.white)),
              to: "\(prefix)-menubar.png")
        let sample = TxInfo(slot: 1, batteryLevel: 4, charging: true)
        write(ImageRenderer(content: HStack(spacing: 12) {
                    MenuBarGlyph(linked: true, connected: true, tx: s.primaryTransmitter)
                    MenuBarGlyph(linked: true, connected: true, tx: sample)
                    MenuBarGlyph(linked: false, connected: true, tx: nil)
                    MenuBarGlyph(linked: false, connected: false, tx: nil)
                }
                .padding(4).background(Color.white)),
              to: "\(prefix)-menubar-states.png")
        s.stop()
    }

    /// Prints a timestamped line whenever the observed state changes. Runs until killed.
    static func log() {
        let s = MicStore.shared
        s.start()
        var last = ""
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                let tx = s.state.transmitters.map { t in
                    "mic\(t.slot) battery=\(t.batteryLevel.map(String.init) ?? "?") charging=\(t.charging.map { $0 ? "yes" : "no" } ?? "?")"
                }.joined(separator: " ")
                let line = "receiver=\(s.state.link.rawValue) case=\(s.caseConnected ? "on-usb" : "absent") "
                    + (tx.isEmpty ? "mic=not-linked" : tx)
                if line != last {
                    print("\(fmt.string(from: Date())) \(line)")
                    fflush(stdout)
                    last = line
                }
            }
        }
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.run()
    }

    /// Renders README screenshots from demo states (no device or serial numbers involved).
    static func screenshots(dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let rx = RxInfo(name: "DJI Mic Mini 2", firmware: "02.03.17.00", stereo: false, safetyTrack: false,
                        gain: 0, clippingControl: true)
        let settings = TxSettings(noiseCancellation: true, noiseCancellationStrong: false, lowCut: true,
                                  clippingControl: true, loudnessBalance: false, autoOff: false, micLedOff: false)
        func tx(_ slot: Int, _ level: Int) -> TxInfo {
            TxInfo(slot: slot, name: "DJI Mic Mini 2", firmware: "02.03.17.00", batteryLevel: level,
                   charging: false, voiceToneRich: true, voiceToneBright: false)
        }
        let scenes: [(String, MicState, Bool, [Int: Double])] = [
            ("linked", MicState(link: .connected, rx: rx, tx: [1: tx(1, 1)], txSettings: settings), true, [1: 0.42]),
            ("two-mics", MicState(link: .connected, rx: rx, tx: [1: tx(1, 2), 2: tx(2, 6)], txSettings: settings),
             false, [1: 0.3, 2: 0.55]),
            ("not-linked", MicState(link: .connected, rx: rx), true, [:]),
        ]
        for (name, state, box, levels) in scenes {
            let store = MicStore()
            store.preview(state: state, caseConnected: box, levels: levels)
            for scheme in [ColorScheme.light, .dark] {
                let view = PopoverView(store: store, levels: store.levels, showsFooterControls: false,
                                       drawsStaticSwitches: true)
                writeWindow(view, dark: scheme == .dark, to: "\(dir)/panel-\(name)-\(scheme == .dark ? "dark" : "light").png")
            }
        }
        // Menu bar states, drawn on a light and a dark bar.
        let states: [(String, MenuBarGlyph)] = [
            ("Mic linked", MenuBarGlyph(linked: true, connected: true, tx: tx(1, 1))),
            ("Low battery", MenuBarGlyph(linked: true, connected: true, tx: tx(1, 6))),
            ("Charging", MenuBarGlyph(linked: true, connected: true,
                                      tx: TxInfo(slot: 1, batteryLevel: 4, charging: true))),
            ("Mic not linked", MenuBarGlyph(linked: false, connected: true, tx: nil)),
            ("No receiver", MenuBarGlyph(linked: false, connected: false, tx: nil)),
        ]
        let strip = VStack(spacing: 0) {
            ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                HStack(spacing: 28) {
                    ForEach(states, id: \.0) { label, glyph in
                        VStack(spacing: 6) {
                            if scheme == .dark { glyph.colorInvert() } else { glyph }
                            Text(label).font(.system(size: 10))
                                .foregroundStyle(scheme == .dark ? Color.white.opacity(0.7) : Color.black.opacity(0.6))
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.93))
            }
        }
        .fixedSize()
        write(ImageRenderer(content: strip), to: "\(dir)/menubar-states.png")
    }

    static func glyphs(path: String) {
        let row = { (size: CGFloat, dimples: Bool) in
            HStack(spacing: size * 0.6) {
                MicMiniGlyph(style: .filled, size: size, showsDimples: dimples)
                MicMiniGlyph(style: .outline, size: size, showsDimples: dimples)
                MicMiniGlyph(style: .slashed, size: size, showsDimples: dimples)
            }
        }
        let v = VStack(alignment: .leading, spacing: 16) {
            row(120, true); row(120, false)
            HStack(spacing: 24) {
                MenuBarGlyph(linked: true, connected: true, tx: TxInfo(slot: 1, batteryLevel: 1, charging: false))
                MenuBarGlyph(linked: true, connected: true, tx: TxInfo(slot: 1, batteryLevel: 4, charging: true))
                MenuBarGlyph(linked: false, connected: true, tx: nil)
                MenuBarGlyph(linked: false, connected: false, tx: nil)
            }
            HStack(spacing: 24) { row(15, true); row(15, false) }
        }
        .padding(16).foregroundStyle(.black).background(Color.white)
        write(ImageRenderer(content: v), to: path)
    }

    /// Renders through an off-screen AppKit window so switches and menus (which ImageRenderer
    /// can't draw) show up.
    private static func writeWindow<V: View>(_ view: V, dark: Bool, to path: String) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.appearance = host.appearance
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("render failed: \(path)"); return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }

    private static func write<V: View>(_ r: ImageRenderer<V>, to path: String) {
        r.scale = 2
        guard let cg = r.cgImage else { print("render failed: \(path)"); return }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}
