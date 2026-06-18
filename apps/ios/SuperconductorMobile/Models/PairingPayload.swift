import Foundation

/// Matches the JSON emitted by the Mac companion QR code and bridge /v1/pairing (when accessible).
struct PairingPayload: Codable, Equatable {
    let version: Int
    let host: String
    let port: Int
    let token: String
    let fingerprint: String
    let tls: Bool
}
