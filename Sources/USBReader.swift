import Foundation
import IOKit
import IOKit.usb

/// Background thread that owns the receiver's vendor bulk interface: streams status and sends
/// queued setting changes. Never touches the USB configuration (the same device is the live
/// audio input).
final class MicReader {
    var onState: ((MicState) -> Void)?
    var onLevels: (([Int: Int]) -> Void)?

    private let lock = NSLock()
    private var _stopped = false
    private var stopped: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _stopped }
        set { lock.lock(); _stopped = newValue; lock.unlock() }
    }
    private var thread: Thread?
    private var finished = DispatchSemaphore(value: 0)
    private var _outbox: [SettingChange] = []

    /// Queues setting changes; they are written on the reader thread before the next read.
    func send(_ changes: [SettingChange]) {
        lock.lock(); _outbox += changes; lock.unlock()
    }

    private func takeOutbox() -> [SettingChange] {
        lock.lock(); defer { lock.unlock() }
        let o = _outbox; _outbox.removeAll(); return o
    }

    private var hasOutbox: Bool { lock.lock(); defer { lock.unlock() }; return !_outbox.isEmpty }

    func start() {
        let t = Thread { [weak self] in self?.run(); self?.finished.signal() }
        t.name = "DJIMicReader"
        t.qualityOfService = .utility
        thread = t
        t.start()
    }

    /// Stops the reader and waits briefly so the interface is released cleanly.
    func stop() {
        stopped = true
        _ = finished.wait(timeout: .now() + 1)
    }

    private func sleepUnlessStopped(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while !stopped && Date() < end { usleep(100_000) }
    }

    private func run() {
        var ctx: OpaquePointer?
        guard libusb_init(&ctx) == 0 else { return }
        defer { libusb_exit(ctx) }

        var lastLink: LinkStatus? = nil
        func publishIdle(_ link: LinkStatus) {
            if lastLink != link { onState?(MicState(link: link)); lastLink = link }
        }

        while !stopped {
            guard let (dev, ifc, alt) = findReceiver(ctx) else {
                publishIdle(.searching)
                sleepUnlessStopped(2)
                continue
            }
            var h: OpaquePointer?
            if libusb_open(dev, &h) != 0 || h == nil {
                libusb_unref_device(dev)
                publishIdle(.busy)
                sleepUnlessStopped(2)
                continue
            }
            if libusb_claim_interface(h, ifc) != 0 {
                libusb_close(h)
                libusb_unref_device(dev)
                publishIdle(.busy)
                sleepUnlessStopped(2)
                continue
            }
            if alt { _ = libusb_set_interface_alt_setting(h, ifc, 1) }

            lastLink = .connected
            _ = takeOutbox()   // drop changes queued while disconnected
            stream(handle: h!, endpoint: UInt8(0x80 | ifc), out: outEndpoint(dev, interface: ifc) ?? UInt8(ifc))

            _ = libusb_release_interface(h, ifc)
            libusb_close(h)
            libusb_unref_device(dev)
            lastLink = nil
            if !stopped { sleepUnlessStopped(1) }
        }
    }

    private func stream(handle h: OpaquePointer, endpoint inEP: UInt8, out outEP: UInt8) {
        var state = MicState(link: .connected)
        var published = state
        onState?(state)
        var parser = PacketParser()
        var chunk = [UInt8](repeating: 0, count: 1024)
        var pendingLevels: [Int: Int] = [:]
        var lastFlush = Date.distantPast
        let timeoutErr = Int32(LIBUSB_ERROR_TIMEOUT.rawValue)
        var seq: UInt16 = 0

        func write(_ frame: [UInt8]) {
            var f = frame
            var sent: Int32 = 0
            let r = libusb_bulk_transfer(h, outEP, &f, Int32(f.count), &sent, 1000)
            if r != 0 { NSLog("DJIMicBar: write failed (\(r))") }
            seq &+= 1
        }

        while !stopped {
            // Like dji-mic-mo, only send once the receiver has identified itself.
            let changes = state.rx?.name != nil ? takeOutbox() : []
            if !changes.isEmpty {
                write(Frame.time(seq: seq))
                for c in changes {
                    guard let e = c.encoded else { continue }
                    write(Frame.set(seq: seq, addr: e.addr, cmd: e.cmd, val: e.val))
                }
            }

            var got: Int32 = 0
            let r = libusb_bulk_transfer(h, inEP, &chunk, Int32(chunk.count), &got, hasOutbox ? 20 : 250)
            if got > 0 {
                for pkt in parser.feed(chunk[0..<Int(got)]) {
                    pendingLevels.merge(apply(packet: pkt, to: &state)) { _, new in new }
                }
            }
            if r != 0 && r != timeoutErr { break }   // unplugged / IO error

            if state != published {        // structural changes: publish immediately
                published = state
                onState?(state)
            }
            if !pendingLevels.isEmpty, Date().timeIntervalSince(lastFlush) > 0.1 {
                onLevels?(pendingLevels)
                pendingLevels.removeAll()
                lastFlush = Date()
            }
        }
    }

    /// Finds a DJI receiver: VID 2ca3, PID 4011 (Mic Mini / Mini 2) with vendor bulk EP 0x86,
    /// or PID 4015/4115 (Mobile receiver, Mini 2S) on interface 4. The charging case shares
    /// PID 4011 but lacks the endpoint, so it is skipped. Returned device is referenced.
    private func findReceiver(_ ctx: OpaquePointer?) -> (OpaquePointer, Int32, Bool)? {
        var list: UnsafeMutablePointer<OpaquePointer?>?
        let n = libusb_get_device_list(ctx, &list)
        guard n > 0, let list else { return nil }
        defer { libusb_free_device_list(list, 1) }

        for i in 0..<n {
            guard let dev = list[i] else { continue }
            var desc = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &desc) == 0, desc.idVendor == 0x2ca3 else { continue }
            let ifc: Int32
            switch desc.idProduct {
            case 0x4011: ifc = 6
            case 0x4015, 0x4115: ifc = 4
            default: continue
            }
            if hasEndpoint(dev, interface: ifc, address: UInt8(0x80 | ifc)) {
                libusb_ref_device(dev)
                return (dev, ifc, desc.idProduct != 0x4011)
            }
        }
        return nil
    }

    /// The bulk OUT endpoint of `interface` (0x06 on the Mic Mini receiver).
    private func outEndpoint(_ dev: OpaquePointer, interface: Int32) -> UInt8? {
        var cfg: UnsafeMutablePointer<libusb_config_descriptor>?
        if libusb_get_active_config_descriptor(dev, &cfg) != 0 {
            guard libusb_get_config_descriptor(dev, 0, &cfg) == 0 else { return nil }
        }
        guard let c = cfg else { return nil }
        defer { libusb_free_config_descriptor(c) }
        for ii in 0..<Int(c.pointee.bNumInterfaces) {
            let itf = c.pointee.interface[ii]
            for a in 0..<Int(itf.num_altsetting) {
                let alt = itf.altsetting[a]
                guard Int32(alt.bInterfaceNumber) == interface else { continue }
                for e in 0..<Int(alt.bNumEndpoints) {
                    let ep = alt.endpoint[e]
                    if ep.bEndpointAddress & 0x80 == 0, ep.bmAttributes & 0x03 == 2 { return ep.bEndpointAddress }
                }
            }
        }
        return nil
    }

    private func hasEndpoint(_ dev: OpaquePointer, interface: Int32, address: UInt8) -> Bool {
        var cfg: UnsafeMutablePointer<libusb_config_descriptor>?
        if libusb_get_active_config_descriptor(dev, &cfg) != 0 {
            guard libusb_get_config_descriptor(dev, 0, &cfg) == 0 else { return false }
        }
        guard let c = cfg else { return false }
        defer { libusb_free_config_descriptor(c) }
        for ii in 0..<Int(c.pointee.bNumInterfaces) {
            let itf = c.pointee.interface[ii]
            for a in 0..<Int(itf.num_altsetting) {
                let alt = itf.altsetting[a]
                guard Int32(alt.bInterfaceNumber) == interface else { continue }
                for e in 0..<Int(alt.bNumEndpoints) where alt.endpoint[e].bEndpointAddress == address {
                    return true
                }
            }
        }
        return false
    }
}

/// Names of DJI USB devices currently attached (no device access needed).
func attachedDJIProducts() -> [String] {
    var names: [String] = []
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iter) == KERN_SUCCESS else {
        return names
    }
    defer { IOObjectRelease(iter) }
    while true {
        let s = IOIteratorNext(iter)
        if s == 0 { break }
        defer { IOObjectRelease(s) }
        let vid = IORegistryEntryCreateCFProperty(s, "idVendor" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int
        guard vid == 0x2ca3 else { continue }
        if let name = IORegistryEntryCreateCFProperty(s, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String {
            names.append(name)
        }
    }
    return names
}
