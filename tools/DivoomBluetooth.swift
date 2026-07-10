import Foundation
import IOBluetooth

/// Native replacement for the app's former blueutil dependency. It uses the
/// public IOBluetooth APIs for device lookup, inquiry, pairing, and baseband
/// connection lifecycle; the daemon itself owns the RFCOMM channel.
enum DivoomBluetooth {
    private static var activePair: IOBluetoothDevicePair?
    static func device(address: String) -> IOBluetoothDevice? {
        IOBluetoothDevice(addressString: address)
    }

    static func pairedDevices() -> [IOBluetoothDevice] {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    }

    static func isPoweredOn() -> Bool {
        IOBluetoothHostController.default().powerState == kBluetoothHCIPowerStateON
    }

    /// Performs a real inquiry. Paired devices intentionally are not included:
    /// callers show the system pairing registry separately from nearby results.
    static func nearbyDevices(seconds: TimeInterval) -> [IOBluetoothDevice] {
        let delegate = InquiryDelegate()
        guard let inquiry = IOBluetoothDeviceInquiry(delegate: delegate) else { return [] }
        // Inquiry units are 1.28 seconds. Eight units is about ten seconds.
        inquiry.inquiryLength = UInt8(max(1, min(255, Int((seconds / 1.28).rounded(.up)))))
        guard inquiry.start() == kIOReturnSuccess else { return [] }
        let deadline = Date().addingTimeInterval(seconds + 3)
        while !delegate.finished && Date() < deadline {
            RunLoop.current.run(mode: .default, before: deadline)
        }
        if !delegate.finished { inquiry.stop() }
        return delegate.devices
    }

    static func isConnected(address: String) -> Bool {
        device(address: address)?.isConnected() ?? false
    }

    static func disconnect(address: String) -> IOReturn? {
        guard let device = device(address: address) else { return nil }
        return device.closeConnection()
    }

    static func connect(address: String) -> IOReturn? {
        guard let device = device(address: address) else { return nil }
        return device.openConnection()
    }

    static func pair(address: String) -> IOReturn? {
        guard let device = device(address: address) else { return nil }
        guard let pair = IOBluetoothDevicePair(device: device) else { return nil }
        activePair = pair
        return pair.start()
    }
}

private final class InquiryDelegate: NSObject, IOBluetoothDeviceInquiryDelegate {
    private(set) var devices: [IOBluetoothDevice] = []
    private(set) var finished = false

    @objc func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry, device: IOBluetoothDevice) {
        guard !devices.contains(where: { $0.addressString == device.addressString }) else { return }
        devices.append(device)
    }

    @objc func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry, error: IOReturn, aborted: Bool) {
        finished = true
    }
}
