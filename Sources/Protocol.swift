import Foundation

// Port of the DJI Mic receiver USB protocol parser from
// https://github.com/usokawa/dji-mic-mo (dji-mic-mo.py), including its "set" commands.

enum CRC {
    static let t8: [UInt8] = (0..<256).map { i in
        var c = UInt8(i)
        for _ in 0..<8 { c = (c >> 1) ^ ((c & 1) != 0 ? 0x8c : 0) }
        return c
    }
    static let t16: [UInt16] = (0..<256).map { i in
        var k = UInt16(i)
        for _ in 0..<8 { k = (k >> 1) ^ ((k & 1) != 0 ? 0x8408 : 0) }
        return k
    }
    static func crc8<C: Collection>(_ b: C) -> UInt8 where C.Element == UInt8 {
        var c: UInt8 = 0x77
        for x in b { c = t8[Int(c ^ x)] }
        return c
    }
    static func crc16<C: Collection>(_ b: C) -> UInt16 where C.Element == UInt8 {
        var c: UInt16 = 0x3692
        for x in b { c = (c >> 8) ^ t16[Int((c ^ UInt16(x)) & 0xff)] }
        return c
    }
}

struct RxInfo: Equatable, Codable {
    var name: String?
    var serial: String?
    var firmware: String?
    var batteryLevel: Int?      // not reported by Mic Mini 2 receivers
    var charging: Bool?
    var stereo: Bool?
    var safetyTrack: Bool?
    var gain: Int?
    var clippingControl: Bool?
}

struct TxInfo: Equatable, Codable {
    var slot: Int
    var name: String?
    var serial: String?
    var firmware: String?
    var batteryLevel: Int?      // 1 = full … 7 = empty (per dji-mic-mo); 0 = unknown
    var charging: Bool?
    var voiceToneRich: Bool?
    var voiceToneBright: Bool?
}

struct TxSettings: Equatable, Codable {
    var noiseCancellation: Bool?
    var noiseCancellationStrong: Bool?
    var lowCut: Bool?
    var clippingControl: Bool?
    var loudnessBalance: Bool?
    var autoOff: Bool?
    var micLedOff: Bool?
}

enum LinkStatus: String, Codable {
    case searching   // no receiver on USB
    case busy        // receiver present but another app holds it
    case connected
}

struct MicState: Equatable, Codable {
    var link: LinkStatus = .searching
    var rx: RxInfo? = nil
    var tx: [Int: TxInfo] = [:]          // slot 1…4
    var txSettings: TxSettings? = nil

    var transmitters: [TxInfo] { tx.keys.sorted().compactMap { tx[$0] } }
}

/// Parses DUML-style frames (0x55 …) from the receiver's vendor bulk endpoint.
struct PacketParser {
    private var buf: [UInt8] = []

    mutating func feed(_ bytes: ArraySlice<UInt8>) -> [[UInt8]] {
        buf.append(contentsOf: bytes)
        var out: [[UInt8]] = []
        var off = 0
        while off < buf.count {
            guard let idx = buf[off...].firstIndex(of: 0x55) else { off = buf.count; break }
            off = idx
            if buf.count - off < 4 { break }
            if CRC.crc8(buf[off..<off + 3]) != buf[off + 3] { off += 1; continue }
            let sz = Int(UInt16(buf[off + 1]) | UInt16(buf[off + 2]) << 8) & 0x3ff
            if sz < 13 { off += 1; continue }
            if sz > buf.count - off { break }
            let pkt = Array(buf[off..<off + sz])
            let want = UInt16(pkt[sz - 2]) | UInt16(pkt[sz - 1]) << 8
            if CRC.crc16(pkt[0..<sz - 2]) != want { off += 1; continue }
            off += sz
            out.append(pkt)
        }
        buf.removeFirst(min(off, buf.count))
        if buf.count > 8192 { buf.removeAll() }
        return out
    }
}

private func slotFor(_ mask: UInt8) -> Int? {
    switch mask { case 1: 1; case 2: 2; case 4: 3; case 8: 4; default: nil }
}

/// Applies one packet to `state`. Returns per-slot input levels from 0x05 packets.
@discardableResult
func apply(packet pkt: [UInt8], to state: inout MicState) -> [Int: Int] {
    guard pkt.count >= 13, pkt[9] == 0x5b, pkt[10] == 0x03 else { return [:] }
    let d = Array(pkt[11..<pkt.count - 2])
    let sz = d.count
    guard sz >= 4 else { return [:] }
    let typ = d[3]

    func u8(_ base: Int, _ off: Int) -> UInt8? { base + off < sz ? d[base + off] : nil }
    func bit(_ base: Int, _ off: Int, _ m: UInt8) -> Bool? { u8(base, off).map { $0 & m != 0 } }
    func bits(_ base: Int, _ off: Int, _ shift: UInt8, _ m: UInt8) -> Int? { u8(base, off).map { Int(($0 >> shift) & m) } }
    func i8(_ base: Int, _ off: Int) -> Int? { u8(base, off).map { Int(Int8(bitPattern: $0)) } }
    func fstr(_ base: Int, _ off: Int, _ n: Int) -> String? {
        let s = base + off
        guard s + n <= sz else { return nil }
        return String(decoding: d[s..<s + n], as: UTF8.self)
    }
    func vstr(_ base: Int, _ off: Int) -> String? {
        let s = base + off
        guard s >= 1, s < sz else { return nil }
        return String(decoding: d[s..<min(sz, s + Int(d[s - 1]))], as: UTF8.self)
    }
    func ver(_ base: Int, _ off: Int) -> String? {
        let s = base + off
        guard s + 4 <= sz else { return nil }
        return d[s..<s + 4].reversed().map { String(format: "%02d", $0) }.joined(separator: ".")
    }

    var bases: [Int: Int] = [:]
    var hasRx = false
    switch typ {
    case 0x01 where sz >= 45:
        hasRx = true
        var i = 45 + Int(d[44])
        while i + 42 <= sz {
            if d[i] == 0x01, let s = slotFor(d[i + 1]) { bases[s] = i }
            i += 42 + Int(d[i + 41])
        }
    case 0x03 where sz >= 41:
        hasRx = true
        var i = 41
        while i < sz - 31 {
            if d[i] == 0x02, let s = slotFor(d[i + 1]) { bases[s] = i }
            i += 32
        }
    case 0x05 where sz >= 10:
        var i = 3
        while i < sz - 6 {
            if d[i] == 0x05, let s = slotFor(d[i + 1]) { bases[s] = i }
            i += 7
        }
    default:
        return [:]
    }

    if hasRx {
        var rx = state.rx ?? RxInfo()
        if typ == 0x01 {
            rx.name = vstr(0, 45) ?? rx.name
            rx.serial = fstr(0, 13, 14) ?? rx.serial
            rx.firmware = ver(0, 9) ?? rx.firmware
        } else {
            if rx.name != nil && rx.name != "DJI Mic Mini 2" {
                rx.batteryLevel = bits(0, 10, 5, 0x07) ?? rx.batteryLevel
                rx.charging = bit(0, 10, 0x10) ?? rx.charging
            }
            rx.stereo = bit(0, 10, 0x04) ?? rx.stereo
            rx.safetyTrack = bit(0, 37, 0x40) ?? rx.safetyTrack
            rx.gain = i8(0, 11) ?? rx.gain
            rx.clippingControl = bit(0, 37, 0x10) ?? rx.clippingControl
        }
        state.rx = rx
    }

    var levels: [Int: Int] = [:]
    for slot in 1...4 {
        guard let b = bases[slot] else {
            if typ == 0x01 || typ == 0x03 { state.tx[slot] = nil }
            continue
        }
        var t = state.tx[slot] ?? TxInfo(slot: slot)
        switch typ {
        case 0x01:
            t.name = vstr(b, 42) ?? t.name
            t.serial = fstr(b, 10, 14) ?? t.serial
            t.firmware = ver(b, 6) ?? t.firmware
        case 0x03:
            t.batteryLevel = bits(b, 7, 2, 0x07) ?? t.batteryLevel
            t.charging = bit(b, 7, 0x02) ?? t.charging
            if t.name != "DJI Mic Mini" {
                t.voiceToneRich = bit(b, 9, 0x40) ?? t.voiceToneRich
                t.voiceToneBright = bit(b, 9, 0x80) ?? t.voiceToneBright
            }
        default:
            if let v = u8(b, 6) { levels[slot] = Int(v) }
        }
        state.tx[slot] = t
    }

    if bases.isEmpty {
        if typ == 0x01 || typ == 0x03 { state.txSettings = nil }
        return levels
    }
    if typ == 0x03, let b = bases.keys.sorted().first.flatMap({ bases[$0] }) {
        var s = state.txSettings ?? TxSettings()
        s.noiseCancellation = bit(b, 7, 0x01) ?? s.noiseCancellation
        s.noiseCancellationStrong = bit(b, 6, 0x20) ?? s.noiseCancellationStrong
        s.lowCut = bit(b, 9, 0x20) ?? s.lowCut
        s.clippingControl = bit(b, 8, 0x04) ?? s.clippingControl
        s.loudnessBalance = bit(b, 11, 0x80) ?? s.loudnessBalance
        s.autoOff = bit(b, 6, 0x10) ?? s.autoOff
        s.micLedOff = bit(b, 6, 0x02) ?? s.micLedOff
        state.txSettings = s
    }
    return levels
}

// MARK: - Writing settings

enum VoiceTone: String, CaseIterable, Codable {
    case regular = "Regular", rich = "Rich", bright = "Bright"

    init?(tx: TxInfo) {
        guard tx.voiceToneRich != nil || tx.voiceToneBright != nil else { return nil }
        self = tx.voiceToneRich == true ? .rich : (tx.voiceToneBright == true ? .bright : .regular)
    }
}

/// A setting change, as sent by dji-mic-mo's "apply config" path. Only settings that dji-mic-mo
/// allows writing on a DJI Mic Mini 2 receiver are listed (noise cancellation is not).
enum SettingChange: Equatable {
    case lowCut(Bool)                       // all transmitters
    case txClippingControl(Bool)            // all transmitters
    case voiceTone(slot: Int, VoiceTone)    // one transmitter
    case stereo(Bool)                       // receiver
    case safetyTrack(Bool)                  // receiver
    case gain(Int)                          // receiver, -12 / -6 / 0 / 6 / 12 dB

    static let gainSteps = [-12, -6, 0, 6, 12]

    var isRxSetting: Bool {
        switch self { case .stereo, .safetyTrack, .gain: true; default: false }
    }

    /// Identifies which setting this changes (one pending value per key).
    var key: String {
        switch self {
        case .lowCut: "lowCut"
        case .txClippingControl: "txClippingControl"
        case .voiceTone(let slot, _): "voiceTone\(slot)"
        case .stereo: "stereo"
        case .safetyTrack: "safetyTrack"
        case .gain: "gain"
        }
    }

    func isReflected(in s: MicState) -> Bool {
        switch self {
        case .lowCut(let v): s.txSettings?.lowCut == v
        case .txClippingControl(let v): s.txSettings?.clippingControl == v
        case .voiceTone(let slot, let t): s.tx[slot].map { VoiceTone(tx: $0) == t } ?? false
        case .stereo(let v): s.rx?.stereo == v
        case .safetyTrack(let v): s.rx?.safetyTrack == v
        case .gain(let v): s.rx?.gain == v
        }
    }

    /// (node address, command, value). Node 0x0000 = receiver, 0xffff = all transmitters,
    /// 1/2/4/8 = transmitter slot 1…4.
    var encoded: (addr: UInt16, cmd: UInt8, val: UInt8)? {
        switch self {
        case .lowCut(let on): return (0xffff, 0x03, on ? 1 : 0)
        case .txClippingControl(let on): return (0xffff, 0x24, on ? 1 : 0)
        case .voiceTone(let slot, let tone):
            guard (1...4).contains(slot) else { return nil }
            let v: UInt8 = switch tone { case .regular: 0; case .rich: 1; case .bright: 2 }
            return (UInt16(1) << (slot - 1), 0x29, v)
        case .stereo(let on): return (0x0000, 0x08, on ? 2 : 0)
        case .safetyTrack(let on): return (0x0000, 0x21, on ? 1 : 0)
        case .gain(let db):
            guard Self.gainSteps.contains(db) else { return nil }
            return (0x0000, 0x39, UInt8(bitPattern: Int8(db)))
        }
    }

    /// Parses "key=value" (for --set), e.g. lowCut=off, voiceTone=rich, gain=-6.
    init?(arg: String, slot: Int = 1) {
        let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let v = parts[1].lowercased()
        let b: Bool? = ["on", "true", "1", "yes", "stereo"].contains(v) ? true
            : (["off", "false", "0", "no", "mono"].contains(v) ? false : nil)
        switch parts[0] {
        case "lowCut": guard let b else { return nil }; self = .lowCut(b)
        case "clippingControl": guard let b else { return nil }; self = .txClippingControl(b)
        case "voiceTone": guard let t = VoiceTone.allCases.first(where: { $0.rawValue.lowercased() == v }) else { return nil }
            self = .voiceTone(slot: slot, t)
        case "stereo", "channel": guard let b else { return nil }; self = .stereo(b)
        case "safetyTrack": guard let b else { return nil }; self = .safetyTrack(b)
        case "gain": guard let g = Int(v) else { return nil }; self = .gain(g)
        default: return nil
        }
    }
}

enum Frame {
    private static func build(seq: UInt16, body: [UInt8]) -> [UInt8] {
        let len = 8 + body.count + 2
        var p: [UInt8] = [0x55, UInt8(len & 0xff), UInt8((len >> 8) & 0x03) | 0x04]
        p.append(CRC.crc8(p))
        p += [0x02, 0x5a, UInt8(seq & 0xff), UInt8(seq >> 8)]
        p += body
        let c = CRC.crc16(p)
        p += [UInt8(c & 0xff), UInt8(c >> 8)]
        return p
    }

    /// Set-parameter frame (dji-mic-mo `send`).
    static func set(seq: UInt16, addr: UInt16, cmd: UInt8, val: UInt8) -> [UInt8] {
        build(seq: seq, body: [0x40, 0x5b, 0x01, 0x02, UInt8(addr & 0xff), UInt8(addr >> 8), 0x00, 0x00,
                               cmd, 0x00, 0x01, val])
    }

    /// Clock sync frame that dji-mic-mo sends before each batch of settings (`send_time`).
    static func time(seq: UInt16, date: Date = Date()) -> [UInt8] {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return build(seq: seq, body: [0x40, 0x5b, 0x01, 0x02, 0x00, 0x00, 0x00, 0x00, 0x33, 0x00, 0x08, 0x09,
                                      UInt8(c.year! % 100), UInt8(c.month!), UInt8(c.day!),
                                      UInt8(c.hour!), UInt8(c.minute!), UInt8(c.second!), 0x00])
    }
}
