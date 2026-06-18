import Foundation

/// Matches the PairingPayload from packages/protocol (stable JSON contract).
struct PairingPayload: Codable {
    let version: Int
    let host: String
    let port: Int
    let token: String
    let fingerprint: String
    let tls: Bool
}