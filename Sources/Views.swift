import SwiftUI
import ServiceManagement

// MARK: - Menu bar glyph (rendered to a template image)

struct MenuBarGlyph: View {
    var linked: Bool
    var connected: Bool
    var tx: TxInfo?

    var body: some View {
        HStack(spacing: 4) {
            MicMiniGlyph(style: linked ? .filled : (connected ? .outline : .slashed), size: 15)
            if let tx, let f = Battery.fraction(tx.batteryLevel) {
                BatteryGlyph(fraction: f, charging: tx.charging == true)
            }
        }
        .foregroundStyle(.black)
        .frame(height: 18)
        .padding(.horizontal, 1)
    }
}

/// Front view of the Mic Mini 2 transmitter: squircle body with a thin rim around the
/// face, two mic dimples in opposite corners, and the two side buttons on the right edge.
struct MicMiniGlyph: View {
    enum Style { case filled, outline, slashed }
    var style: Style
    var size: CGFloat = 15
    var showsMark = true      // "dji" set in the system font, italic
    var showsDimples = false
    var ledColor: Color? = nil

    var body: some View {
        Canvas { ctx, canvas in
            let s = size
            let r = CGRect(x: 0, y: (canvas.height - s) / 2, width: s, height: s)
            let corner = s * 0.30
            let body = Path(roundedRect: r, cornerRadius: corner, style: .continuous)
            let line = max(1, s * 0.085)
            func pt(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: r.minX + s * fx, y: r.minY + s * fy) }
            func circle(_ c: CGPoint, _ d: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)) }

            // side buttons, separated from the body by a hairline gap
            let bw = s * 0.2, bh = s * 0.21
            for cy in [0.43, 0.69] as [CGFloat] {
                let b = CGRect(x: r.maxX - bw * 0.42, y: r.minY + s * cy - bh / 2, width: bw, height: bh)
                ctx.fill(Path(roundedRect: b, cornerRadius: bw * 0.5, style: .continuous), with: .foreground)
            }
            ctx.blendMode = .destinationOut
            ctx.stroke(body, with: .foreground, lineWidth: s * 0.1)
            ctx.blendMode = .normal

            let inset = s * 0.085
            let face = Path(roundedRect: r.insetBy(dx: inset, dy: inset), cornerRadius: corner - inset * 0.7, style: .continuous)
            let dimples = [pt(0.74, 0.26), pt(0.26, 0.74)]
            let dimpleD = s * 0.17

            let mark = ctx.resolve(Text("dji")
                .font(.system(size: s * 0.42, weight: .heavy, design: .default))
                .italic()
                .kerning(-s * 0.025)
                .foregroundStyle(.black))
            let markAt = pt(0.48, 0.47)

            switch style {
            case .filled:
                ctx.fill(body, with: .foreground)
                ctx.blendMode = .destinationOut
                ctx.stroke(face, with: .foreground, lineWidth: s * 0.05)     // rim seam
                if showsDimples { for c in dimples { ctx.stroke(circle(c, dimpleD), with: .foreground, lineWidth: s * 0.04) } }
                if showsMark { ctx.draw(mark, at: markAt) }
                ctx.blendMode = .normal
            case .outline, .slashed:
                ctx.stroke(Path(roundedRect: r.insetBy(dx: line / 2, dy: line / 2), cornerRadius: corner - line / 2,
                                style: .continuous), with: .foreground, lineWidth: line)
                if showsDimples { for c in dimples { ctx.stroke(circle(c, dimpleD), with: .foreground, lineWidth: s * 0.04) } }
                if showsMark { ctx.draw(mark, at: markAt) }
            }

            if let ledColor {
                let led = CGRect(x: r.maxX - s * 0.27, y: r.minY + s * 0.012, width: s * 0.16, height: s * 0.065)
                ctx.fill(Path(roundedRect: led, cornerRadius: s * 0.025), with: .color(ledColor))
            }

            if style == .slashed {
                var slash = Path()
                slash.move(to: CGPoint(x: r.minX + s * 0.05, y: r.minY - s * 0.02))
                slash.addLine(to: CGPoint(x: r.maxX + s * 0.05, y: r.maxY + s * 0.02))
                ctx.blendMode = .destinationOut
                ctx.stroke(slash, with: .foreground, style: StrokeStyle(lineWidth: line * 2.6, lineCap: .round))
                ctx.blendMode = .normal
                ctx.stroke(slash, with: .foreground, style: StrokeStyle(lineWidth: line, lineCap: .round))
            }
        }
        .frame(width: size * 1.1, height: size * 1.06)
    }
}

struct BatteryGlyph: View {
    var fraction: Double
    var charging: Bool

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(lineWidth: 1.1)
                    .frame(width: 22, height: 11)
                    .opacity(0.55)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .frame(width: max(2, 18 * fraction), height: 7)
                    .padding(.leading, 2)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .black))
                        .frame(width: 22, height: 11)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
            RoundedRectangle(cornerRadius: 1).frame(width: 1.5, height: 4).opacity(0.55)
        }
    }
}

// MARK: - Popover

struct PopoverView: View {
    @ObservedObject var store: MicStore
    @ObservedObject var levels: LevelStore
    var showsFooterControls = true

    private var state: MicState { store.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            tiles
            if !state.transmitters.isEmpty {
                ForEach(state.transmitters, id: \.slot) { tx in
                    InputMeter(title: state.transmitters.count > 1 ? "Mic \(tx.slot) input" : "Input level",
                               level: levels.levels[tx.slot] ?? 0)
                }
            }
            if let s = state.txSettings {
                SectionCard(title: "Microphone") {
                    SettingRow(icon: "waveform.badge.minus", title: "Noise Cancellation",
                               value: noiseValue(s), on: s.noiseCancellation == true)
                    SettingRow(icon: "dial.low", title: "Low Cut", value: onOff(s.lowCut), on: s.lowCut == true)
                    if let tx = state.transmitters.first, tx.voiceToneRich != nil {
                        SettingRow(icon: "person.wave.2", title: "Voice Tone", value: tone(tx),
                                   on: tx.voiceToneRich == true || tx.voiceToneBright == true)
                    }
                    SettingRow(icon: "waveform.path.ecg", title: "Clipping Control",
                               value: onOff(s.clippingControl), on: s.clippingControl == true)
                }
            }
            if let rx = state.rx, state.link == .connected {
                SectionCard(title: "Receiver") {
                    SettingRow(icon: "speaker.wave.2", title: "Channel",
                               value: rx.stereo == true ? "Stereo" : "Mono", on: true)
                    if let g = rx.gain {
                        SettingRow(icon: "slider.horizontal.3", title: "Output Gain",
                                   value: g == 0 ? "0 dB" : String(format: "%+d dB", g), on: g != 0)
                    }
                    SettingRow(icon: "square.on.square", title: "Safety Track",
                               value: onOff(rx.safetyTrack), on: rx.safetyTrack == true)
                }
            }
            if showsFooterControls { footer }
        }
        .padding(14)
        .frame(width: 320)
    }

    // Header like the AirPods menu: device name + connection line.
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle().fill(state.link == .connected ? Color.accentColor : Color.secondary.opacity(0.35))
                MicMiniGlyph(style: .filled, size: 14).foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.rx?.name ?? "DJI Mic").font(.system(size: 13, weight: .semibold))
                Text(statusLine).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var statusLine: String {
        switch state.link {
        case .searching:
            return store.caseConnected ? "Only the charging case is on USB" : "Receiver not connected"
        case .busy:
            return "Receiver busy — close other DJI Mic tools (e.g. the web app in Chrome)"
        case .connected:
            let n = state.transmitters.count
            if n == 0 { return "Connected · mic not linked (off or in case)" }
            return n == 1 ? "Connected · 1 mic linked" : "Connected · \(n) mics linked"
        }
    }

    private var tiles: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(state.transmitters, id: \.slot) { tx in
                BatteryTile(icon: "djimic",
                            title: state.transmitters.count > 1 ? "Mic \(tx.slot)" : "Mic",
                            fraction: Battery.fraction(tx.batteryLevel),
                            value: tx.charging == true ? "Charging" : Battery.word(tx.batteryLevel),
                            color: Battery.color(tx.batteryLevel, charging: tx.charging == true),
                            charging: tx.charging == true,
                            help: tx.batteryLevel.map { "Battery step \(8 - $0) of 7" })
                    .frame(maxWidth: .infinity)
            }
            if state.transmitters.isEmpty {
                BatteryTile(icon: "djimic", title: "Mic", fraction: nil, value: "Not linked",
                            color: .secondary, charging: false, dimmed: true)
                    .frame(maxWidth: .infinity)
            }
            BatteryTile(icon: "antenna.radiowaves.left.and.right", title: "Receiver",
                        fraction: Battery.fraction(state.rx?.batteryLevel),
                        value: state.link == .searching ? "Unplugged" : (state.link == .busy ? "Busy" : "USB"),
                        color: .green, charging: false, ring: state.link == .connected,
                        dimmed: state.link == .searching)
                .frame(maxWidth: .infinity)
            BatteryTile(icon: "shippingbox.fill", title: "Case", fraction: nil,
                        value: store.caseConnected ? "USB" : "Unplugged",
                        color: .green, charging: false, ring: store.caseConnected,
                        dimmed: !store.caseConnected)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.6)))
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Divider()
            if let fw = state.transmitters.first?.firmware ?? state.rx?.firmware {
                HStack {
                    Text("Firmware \(fw)").foregroundStyle(.tertiary)
                    Spacer()
                    if let sn = state.transmitters.first?.serial { Text(sn).foregroundStyle(.tertiary) }
                }
                .font(.system(size: 10))
                .textSelection(.enabled)
            }
            HStack {
                LoginToggle()
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
                    .buttonStyle(.borderless)
            }
            .font(.system(size: 12))
        }
    }

    private func onOff(_ b: Bool?) -> String { b == nil ? "—" : (b! ? "On" : "Off") }
    private func noiseValue(_ s: TxSettings) -> String {
        guard let nc = s.noiseCancellation else { return "—" }
        if !nc { return "Off" }
        return s.noiseCancellationStrong == true ? "Strong" : "On"
    }
    private func tone(_ tx: TxInfo) -> String {
        if tx.voiceToneRich == true { return "Rich" }
        if tx.voiceToneBright == true { return "Bright" }
        return "Regular"
    }
}

// MARK: - Components

struct BatteryTile: View {
    var icon: String
    var title: String
    var fraction: Double?
    var value: String
    var color: Color
    var charging: Bool
    var ring = true
    var dimmed = false
    var help: String? = nil

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 4)
                if let fraction {
                    Circle().trim(from: 0, to: fraction)
                        .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else if ring && !dimmed {
                    Circle().stroke(Color.primary.opacity(0.3), lineWidth: 4)
                }
                Group {
                    if icon == "djimic" {
                        MicMiniGlyph(style: dimmed ? .outline : .filled, size: 24, ledColor: dimmed ? nil : .green)
                    } else {
                        Image(systemName: icon).font(.system(size: 18, weight: .medium))
                    }
                }
                .foregroundStyle(dimmed ? Color.secondary : Color.primary)
            }
            .frame(width: 50, height: 50)
            .overlay(alignment: .topTrailing) {
                if charging {
                    Image(systemName: "bolt.circle.fill")
                        .font(.system(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                        .offset(x: 3, y: -3)
                }
            }
            VStack(spacing: 1) {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(dimmed ? .secondary : .primary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .opacity(dimmed ? 0.6 : 1)
        .help(help ?? "")
    }
}

struct InputMeter: View {
    var title: String
    var level: Double

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(LinearGradient(colors: [.green, .green, .yellow, .red],
                                                  startPoint: .leading, endPoint: .trailing))
                        .mask(alignment: .leading) {
                            Capsule().frame(width: max(0, g.size.width * level))
                        }
                }
            }
            .frame(height: 5)
            .animation(.easeOut(duration: 0.12), value: level)
        }
        .padding(.horizontal, 2)
    }
}

struct SectionCard<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.leading, 2)
            VStack(spacing: 0) { content }
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.6)))
        }
    }
}

struct SettingRow: View {
    var icon: String
    var title: String
    var value: String
    var on: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(on ? Color.accentColor : Color.primary.opacity(0.1))
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(on ? Color.white : Color.primary.opacity(0.7))
            }
            .frame(width: 24, height: 24)
            Text(title).font(.system(size: 12))
            Spacer()
            Text(value).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

struct LoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Open at Login", isOn: Binding(get: { enabled }, set: { new in
            do {
                if new { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("DJIMicBar login item: \(error)")
            }
            enabled = SMAppService.mainApp.status == .enabled
        }))
        .toggleStyle(.checkbox)
    }
}
