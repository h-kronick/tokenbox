import Foundation

/// Stub for future USB serial communication with physical split-flap device.
/// Will use IOKit for device discovery and serial port communication.
final class USBDeviceService: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var deviceName: String?

    func startScanning() {
        // Future: IOKit USB device enumeration
    }

    func stopScanning() {
        // Future: Stop IOKit notifications
    }

    func sendTokenCount(_ count: Int) {
        // Future: Serial protocol to physical device
    }
}
