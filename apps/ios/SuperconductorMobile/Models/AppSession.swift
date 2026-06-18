import Foundation
import Observation

@Observable
final class AppSession {
    var connection: BridgeConnection?
    var agents: [AgentRow] = []
    var isLoadingAgents = false
    var lastError: String?
    var showAllAgents = false

    var workspaces: [WorkspaceNode] = []
    var selectedWorkspaceId: String?
    var isLoadingWorkspaces = false

    var isPaired: Bool { connection != nil }

    func loadConnectionFromKeychain() {
        guard var c = BridgeCredentials.load() else {
            connection = nil
            return
        }
        c.useTLS = false
        connection = c
    }

    func savePairing(host: String, port: Int, token: String, useTLS: Bool = false) {
        let c = BridgeConnection(host: host, port: port, token: token, useTLS: false)
        BridgeCredentials.save(c)
        connection = c
    }

    /// Accepts a decoded PairingPayload (from QR JSON).
    func applyPairingPayload(_ payload: PairingPayload) {
        savePairing(host: payload.host, port: payload.port, token: payload.token, useTLS: false)
    }

    /// Attempts to parse a raw string (JSON or superconductor-mobile:// URL) and apply it.
    /// Returns true on success.
    @discardableResult
    func applyPairingString(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // JSON first
        if let data = trimmed.data(using: .utf8),
           let payload = try? JSONDecoder().decode(PairingPayload.self, from: data) {
            applyPairingPayload(payload)
            return true
        }

        // URL form
        if let url = URL(string: trimmed),
           let payload = parsePairingURL(url) {
            applyPairingPayload(payload)
            return true
        }

        return false
    }

    private func parsePairingURL(_ url: URL) -> PairingPayload? {
        guard url.scheme == "superconductor-mobile" || url.absoluteString.contains("pair") else { return nil }

        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let items = comps?.queryItems else { return nil }

        var dict: [String: String] = [:]
        for item in items { if let v = item.value { dict[item.name] = v } }

        guard let host = dict["host"],
              let portStr = dict["port"], let port = Int(portStr),
              let token = dict["token"] else { return nil }

        let tls = (dict["tls"] ?? "false").lowercased() == "true"
        let fp = dict["fingerprint"] ?? ""
        return PairingPayload(version: 1, host: host, port: port, token: token, fingerprint: fp, tls: tls)
    }

    func signOut() {
        BridgeCredentials.clear()
        connection = nil
        agents = []
        workspaces = []
        selectedWorkspaceId = nil
    }
}

struct BridgeConnection: Codable, Equatable {
    var host: String
    var port: Int
    var token: String
    var useTLS: Bool

    var baseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }

    var wsBaseURL: URL {
        URL(string: "ws://\(host):\(port)")!
    }

    func avatarURL(projectId: String) -> URL? {
        URL(string: "http://\(host):\(port)/v1/projects/\(projectId)/avatar?token=\(token)")
    }
}

struct AgentCapabilities: Equatable, Hashable {
    var canSend: Bool
    var canRead: Bool
    var canSubscribe: Bool
    var canInterrupt: Bool

    static let none = AgentCapabilities(canSend: false, canRead: false, canSubscribe: false, canInterrupt: false)
}

struct AgentRow: Identifiable, Equatable, Hashable {
    var id: String { stableTargetId }
    var stableTargetId: String
    var selector: String
    var providerKey: String
    var ui: String
    var state: String
    var phase: String
    var label: String?
    var capabilities: AgentCapabilities
    /// Worktree root the agent lives in; required for `sc --worktree`. nil = active view.
    var worktreePath: String? = nil

    /// `sc agent` target: `id:` + stable_target_id (already `terminal:uuid`).
    var bridgeTarget: String { "id:\(stableTargetId)" }

    var isInteractive: Bool {
        capabilities.canSend && capabilities.canSubscribe && capabilities.canRead
    }

    var displayTitle: String {
        if let label, !label.isEmpty { return label }
        if providerKey == "terminal" { return "Shell tab" }
        return providerKey.uppercased()
    }

    var subtitle: String {
        let cap = isInteractive ? "remote control" : "view only"
        return "\(selector) · \(state) · \(cap)"
    }
}