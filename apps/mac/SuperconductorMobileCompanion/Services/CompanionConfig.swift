import Foundation
import CryptoKit

struct CompanionConfig: Codable {
    var token: String
    var fingerprint: String
    var port: Int
    var bind: String
}

enum CompanionConfigManager {
    static let configDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".superconductor-mobile")
    }()

    static let configPath: URL = {
        configDir.appendingPathComponent("bridge.json")
    }()

    static func loadOrCreate() -> CompanionConfig {
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: configPath),
           let config = try? JSONDecoder().decode(CompanionConfig.self, from: data) {
            // Basic validation
            if !config.token.isEmpty && !config.fingerprint.isEmpty {
                return config
            }
        }

        // Generate new token (base64url, 32 random bytes)
        let random = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let tokenData = Data(random)
        var token = tokenData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        // Fingerprint: first 16 hex chars of sha256(token)
        let digest = SHA256.hash(data: Data(token.utf8))
        let fingerprint = digest.map { String(format: "%02x", $0) }.joined().prefix(16)

        let config = CompanionConfig(
            token: token,
            fingerprint: String(fingerprint),
            port: 9477,
            bind: "0.0.0.0"
        )

        save(config)
        return config
    }

    static func regenerate() -> CompanionConfig {
        try? FileManager.default.removeItem(at: configPath)
        return loadOrCreate()
    }

    static func save(_ config: CompanionConfig) {
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: configPath, options: .atomic)
        }
    }

    static func currentPath() -> String {
        configPath.path
    }
}