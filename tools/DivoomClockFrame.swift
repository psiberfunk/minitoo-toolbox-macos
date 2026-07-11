import Foundation

/// Native port of divoom_clock.py's build_select_clock_packet: a single
/// Channel/SetClockSelectId JSON frame, same shape as setScreen's
/// Channel/OnOffScreen — no image/zstd work involved.
enum DivoomClockFrame {
    static let shortcuts: [String: Int] = [
        "1": 984, "custom1": 984, "face1": 984,
        "2": 986, "custom2": 986, "face2": 986,
        "3": 988, "custom3": 988, "face3": 988,
    ]

    static func resolveClockId(_ shortcut: String) -> Int? {
        if let id = shortcuts[shortcut.lowercased()] { return id }
        return Int(shortcut)
    }

    static func selectPacket(
        clockId: Int,
        deviceId: Int = 600111083,
        devicePassword: Int = 1777733348,
        token: Int = 1777741943,
        userId: Int = 404779143
    ) -> Data? {
        let job: [String: Any] = [
            "ClockId": clockId,
            "Command": "Channel/SetClockSelectId",
            "DeviceId": deviceId,
            "DevicePassword": devicePassword,
            "Language": "en",
            "LcdIndependence": 0,
            "LcdIndex": 0,
            "PageIndex": 0,
            "ParentClockId": 0,
            "ParentItemId": "",
            "Token": token,
            "UserId": userId,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: job) else { return nil }
        return DivoomRawFrame.build(cmd: 0x01, body: body)
    }
}
