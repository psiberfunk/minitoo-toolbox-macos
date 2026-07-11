import Foundation

/// Shared 256-byte chunked-transfer framing, used identically by Photo
/// Album's SPP_LOCAL_PICTURE (0x8F, divoom_album.py's photo_upload_packets)
/// and Send Media's CMD_APP_NEW_GIF_2020 (0x8B, send_divoom_image.py's
/// build_packets) -- only the opcode differs, the announce/chunk framing is
/// byte-for-byte the same scheme in both.
enum DivoomChunkedUpload {
    static func packets(cmd: UInt8, payload: Data, chunkSize: Int = 256) -> [Data] {
        // Guards against a chunkSize <= 0 hanging forever below (offset would
        // never advance) -- no call site passes anything but the default
        // today, but nothing stops a future one from doing so by mistake.
        let chunkSize = max(chunkSize, 1)
        var packets: [Data] = []
        var announceBody = Data([0x00])
        announceBody.append(u32le(payload.count))
        packets.append(DivoomRawFrame.build(cmd: cmd, body: announceBody))

        var offset = 0
        var seq: UInt16 = 0
        while offset < payload.count {
            let end = min(offset + chunkSize, payload.count)
            var body = Data([0x01])
            body.append(u32le(payload.count))
            body.append(u16le(seq))
            body.append(payload[offset..<end])
            packets.append(DivoomRawFrame.build(cmd: cmd, body: body))
            offset = end
            seq += 1
        }
        return packets
    }

    private static func u32le(_ n: Int) -> Data {
        Data([UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)])
    }

    private static func u16le(_ n: UInt16) -> Data {
        Data([UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF)])
    }
}
