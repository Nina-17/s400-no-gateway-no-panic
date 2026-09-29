import Foundation

/// Reads only the public MiBeacon header; never decrypts a measurement.
struct MiBeaconIdentity: Equatable {
    let productID: UInt16
    let advertisedMAC: String?

    init?(serviceData: Data) {
        let bytes = Array(serviceData)
        guard bytes.count >= 5 else { return nil }
        let frameControl = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        guard frameControl >> 12 >= 4 else { return nil }
        productID = UInt16(bytes[2]) | UInt16(bytes[3]) << 8
        if frameControl & 0x10 != 0 {
            guard bytes.count >= 11 else { return nil }
            advertisedMAC = bytes[5..<11].reversed().map { String(format: "%02X", $0) }.joined(separator: ":")
        } else {
            advertisedMAC = nil
        }
    }

    var isKnownScaleFamily: Bool {
        [UInt16(0x30D9), 0x3BD5, 0x48CF].contains(productID)
    }
}
