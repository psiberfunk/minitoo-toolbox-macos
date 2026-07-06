import Foundation
import IOBluetooth
import Network

struct JobResponse: Codable {
    let ok: Bool
    let message: String
    let packets: Int?
    let bytes: Int?
    let sawRequest: Bool?
    let sawAck: Bool?
    let reply: String?
}

struct JobRequest: Codable {
    let packets: String?
    let delay: Double?
    let dryRun: Bool?
    let waitForReply: Double?
}

final class RFCOMMDelegate: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private let lock = NSLock()
    private var rx = Data()
    var onClosed: (() -> Void)?

    func resetRx() {
        lock.lock(); defer { lock.unlock() }
        rx.removeAll(keepingCapacity: true)
    }

    func rxSnapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return rx
    }

    func contains(_ needle: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return rx.range(of: needle) != nil
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let d = Data(bytes: dataPointer, count: dataLength)
        lock.lock()
        rx.append(d)
        lock.unlock()
        let hex = d.prefix(2048).map { String(format: "%02x", $0) }.joined(separator: " ")
        print("rx \(dataLength): \(hex)\(d.count > 2048 ? " ..." : "")")
        fflush(stdout)
    }

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        print("rfcomm openComplete status=0x\(String(error, radix: 16))")
        fflush(stdout)
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        print("rfcomm closed")
        fflush(stdout)
        onClosed?()
    }

    func rfcommChannelWriteComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn, bytesWritten length: Int) {
        if error != kIOReturnSuccess {
            print("rfcomm writeComplete status=0x\(String(error, radix: 16)) bytes=\(length)")
            fflush(stdout)
        }
    }
}

final class DivoomDaemon {
    let address: String
    let channelID: BluetoothRFCOMMChannelID
    let port: UInt16
    let delegate = RFCOMMDelegate()
    var device: IOBluetoothDevice?
    var rfcomm: IOBluetoothRFCOMMChannel?
    var listener: NWListener?
    let queue = DispatchQueue(label: "divoom.daemon")
    let sendQueue = DispatchQueue(label: "divoom.send")

    let requestFrame = Data([0x01, 0x07, 0x00, 0x04, 0x8b, 0x55, 0x00, 0x01, 0xec, 0x00, 0x02])
    let ackFrame = Data([0x01, 0x09, 0x00, 0x04, 0xbd, 0x55, 0x13, 0x01, 0x05, 0x00, 0x38, 0x01, 0x02])

    init(address: String, channelID: UInt8, port: UInt16) {
        self.address = address
        self.channelID = BluetoothRFCOMMChannelID(channelID)
        self.port = port
        // If IOBluetooth does deliver a close notification, react immediately
        // instead of leaving a stale rfcomm reference around for isOpen() to
        // (possibly incorrectly) report as still open.
        delegate.onClosed = { [weak self] in self?.rfcomm = nil }
    }

    func openRFCOMM() throws {
        if let ch = rfcomm, ch.isOpen() { return }
        guard let dev = IOBluetoothDevice(addressString: address) else {
            throw NSError(domain: "DivoomDaemon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bluetooth device not found: \(address)"])
        }
        device = dev
        var ch: IOBluetoothRFCOMMChannel?
        print("opening \(dev.name ?? "?") \(dev.addressString ?? "?") rfcomm channel \(channelID)")
        let ret = dev.openRFCOMMChannelSync(&ch, withChannelID: channelID, delegate: delegate)
        print("open ret=0x\(String(ret, radix: 16)) obj=\(ch != nil)")
        guard ret == kIOReturnSuccess, let channel = ch else {
            throw NSError(domain: "DivoomDaemon", code: Int(ret), userInfo: [NSLocalizedDescriptionKey: "RFCOMM open failed ret=0x\(String(ret, radix: 16)). If audio profile is connected, disconnect it once, then start daemon."])
        }
        rfcomm = channel
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }

    func parsePackets(_ data: Data) throws -> [Data] {
        var packets: [Data] = []
        var off = 0
        while off + 2 <= data.count {
            let len = Int(data[off]) | (Int(data[off + 1]) << 8)
            off += 2
            guard len > 0, off + len <= data.count else {
                throw NSError(domain: "DivoomDaemon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bad length-prefixed packet file"])
            }
            packets.append(Data(data[off ..< off + len]))
            off += len
        }
        guard off == data.count else {
            throw NSError(domain: "DivoomDaemon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Trailing packet bytes"])
        }
        return packets
    }

    func waitFor(_ needle: Data, timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if delegate.contains(needle) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        return delegate.contains(needle)
    }

    func sendPacket(_ pkt: Data) throws {
        guard let ch = rfcomm, ch.isOpen() else {
            try openRFCOMM()
            return try sendPacket(pkt)
        }
        var d = pkt
        let len = UInt16(d.count)
        // IOBluetoothRFCOMMChannel calls appear to require the same thread
        // that opened the channel (has its run loop registered) — dispatching
        // writeSync to a different thread was tried and confirmed BROKEN via
        // real hardware testing: it reported kIOReturnSuccess without the
        // device ever receiving the bytes. Back to a plain same-thread call;
        // the stale-channel-hang problem this was meant to solve is still
        // open (see PROTOCOL.md daemon robustness notes) — needs a fix that
        // doesn't change threads.
        let ret = d.withUnsafeMutableBytes { ptr in
            ch.writeSync(ptr.baseAddress, length: len)
        }
        guard ret == kIOReturnSuccess else {
            throw NSError(domain: "DivoomDaemon", code: Int(ret), userInfo: [NSLocalizedDescriptionKey: "RFCOMM write failed ret=0x\(String(ret, radix: 16))"])
        }
    }

    func sendJob(packetPath: String, delay: Double, dryRun: Bool, waitForReply: Double? = nil) throws -> JobResponse {
        let url = URL(fileURLWithPath: packetPath)
        let data = try Data(contentsOf: url)
        let packets = try parsePackets(data)
        let totalBytes = packets.reduce(0) { $0 + $1.count }
        if dryRun {
            return JobResponse(ok: true, message: "dry run", packets: packets.count, bytes: totalBytes, sawRequest: nil, sawAck: nil, reply: nil)
        }
        try openRFCOMM()
        delegate.resetRx()

        guard let first = packets.first else {
            throw NSError(domain: "DivoomDaemon", code: 4, userInfo: [NSLocalizedDescriptionKey: "No packets"])
        }
        try sendPacket(first)

        // Single-packet jobs (e.g. brightness, a raw opcode) are fire-and-forget:
        // only the chunked GIF/photo transfer protocol produces a request/ACK
        // handshake, so waiting up to 4.6s for frames that will never arrive
        // just serializes unrelated quick commands behind a pointless timeout.
        // A caller can opt into waiting a bit for a JSON reply instead (e.g. a
        // ".../Get" query) via waitForReply, since the device does send one.
        if packets.count == 1 {
            var reply: String?
            if let waitForReply, waitForReply > 0 {
                reply = waitForJSONReply(timeout: waitForReply)
            }
            return JobResponse(ok: true, message: "sent", packets: 1, bytes: totalBytes, sawRequest: nil, sawAck: nil, reply: reply)
        }

        let sawRequestEarly = waitFor(requestFrame, timeout: 0.6)

        for (idx, pkt) in packets.dropFirst().enumerated() {
            try sendPacket(pkt)
            if idx == 0 || (idx + 1) % 25 == 0 || idx == packets.count - 2 {
                print("sent chunk \(idx + 1)/\(packets.count - 1) len=\(pkt.count)")
                fflush(stdout)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(delay))
        }
        let sawAck = waitFor(ackFrame, timeout: 4.0)
        let sawRequest = sawRequestEarly || delegate.contains(requestFrame)
        return JobResponse(ok: sawAck, message: sawAck ? "sent" : "sent but final ACK not observed", packets: packets.count, bytes: totalBytes, sawRequest: sawRequest, sawAck: sawAck, reply: nil)
    }

    // Polls the RFCOMM delegate's captured inbound bytes for a frame carrying
    // a JSON payload (cmd 0x04, the device's generic response wrapper — see
    // PROTOCOL.md). Frames are `0x01 <len LE16> <cmd> <body...> <chk LE16>
    // 0x02`; the body of a JSON-bearing reply contains the actual `{...}`
    // text after a couple of header bytes whose exact meaning isn't fully
    // decoded, so this just extracts the first-to-last `{`/`}` span instead
    // of assuming a fixed offset.
    func waitForJSONReply(timeout: Double) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let json = Self.extractJSONReply(from: delegate.rxSnapshot()) { return json }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return Self.extractJSONReply(from: delegate.rxSnapshot())
    }

    static func extractJSONReply(from data: Data) -> String? {
        var off = 0
        var found: String?
        while off + 4 <= data.count {
            guard data[off] == 0x01 else { off += 1; continue }
            let len = Int(data[off + 1]) | (Int(data[off + 2]) << 8)
            let frameEnd = off + 4 + len
            guard len >= 3, frameEnd <= data.count, data[frameEnd - 1] == 0x02 else { off += 1; continue }
            let cmd = data[off + 3]
            if cmd == 0x04 {
                let body = data[(off + 4)..<(frameEnd - 3)]
                if let openBrace = body.firstIndex(of: 0x7b), let closeBrace = body.lastIndex(of: 0x7d), openBrace < closeBrace {
                    let candidate = body[openBrace...closeBrace]
                    if let text = String(data: candidate, encoding: .utf8),
                       (try? JSONSerialization.jsonObject(with: candidate)) != nil {
                        found = text
                    }
                }
            }
            off = frameEnd
        }
        return found
    }

    func startServer() throws {
        try openRFCOMM()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener?.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener?.start(queue: queue)
        print("divoom daemon listening on 127.0.0.1:\(port)")
        fflush(stdout)
    }

    func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                self.reply(conn, JobResponse(ok: false, message: "receive error: \(error)", packets: nil, bytes: nil, sawRequest: nil, sawAck: nil, reply: nil))
                return
            }
            guard let data, !data.isEmpty else {
                self.reply(conn, JobResponse(ok: false, message: "empty request", packets: nil, bytes: nil, sawRequest: nil, sawAck: nil, reply: nil))
                return
            }
            self.sendQueue.async {
                do {
                    let req = try JSONDecoder().decode(JobRequest.self, from: data)
                    guard let packets = req.packets else {
                        throw NSError(domain: "DivoomDaemon", code: 5, userInfo: [NSLocalizedDescriptionKey: "Missing packets path"])
                    }
                    let resp = try self.sendJob(packetPath: packets, delay: req.delay ?? 0.012, dryRun: req.dryRun ?? false, waitForReply: req.waitForReply)
                    self.reply(conn, resp)
                } catch {
                    self.reply(conn, JobResponse(ok: false, message: String(describing: error), packets: nil, bytes: nil, sawRequest: nil, sawAck: nil, reply: nil))
                }
            }
        }
    }

    func reply(_ conn: NWConnection, _ resp: JobResponse) {
        let data = (try? JSONEncoder().encode(resp)) ?? Data("{\"ok\":false,\"message\":\"encode error\"}".utf8)
        conn.send(content: data + Data([0x0a]), completion: .contentProcessed { _ in conn.cancel() })
    }
}

let args = CommandLine.arguments
let address = args.count > 1 ? args[1] : "B1:21:81:6F:4D:F0"
let channel = args.count > 2 ? UInt8(args[2])! : 1
let port = args.count > 3 ? UInt16(args[3])! : 40583

do {
    let daemon = DivoomDaemon(address: address, channelID: channel, port: port)
    try daemon.startServer()
    RunLoop.main.run()
} catch {
    fputs("fatal: \(error)\n", stderr)
    exit(1)
}
