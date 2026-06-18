import Foundation

enum BridgeAPI {
    static func fetchAgents(connection: BridgeConnection) async throws -> [AgentRow] {
        let url = BridgeURL.v1(connection, path: "/v1/agents")
        var req = URLRequest(url: url)
        req.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await BridgeURLSession.http.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw BridgeAPIError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoded = try JSONDecoder().decode(AgentsListEnvelope.self, from: data)
        return decoded.response.agents.map { a in
            let caps = a.capabilities
            return AgentRow(
                stableTargetId: a.stable_target_id,
                selector: a.current_selector,
                providerKey: a.provider_key,
                ui: a.ui,
                state: a.state,
                phase: a.phase,
                label: a.label,
                capabilities: AgentCapabilities(
                    canSend: caps?.send ?? false,
                    canRead: caps?.read ?? false,
                    canSubscribe: caps?.subscribe ?? false,
                    canInterrupt: caps?.interrupt ?? false
                )
            )
        }
    }

    static func fetchWorkspaces(connection: BridgeConnection) async throws -> (workspaces: [WorkspaceNode], activeId: String?) {
        let url = BridgeURL.v1(connection, path: "/v1/workspaces")
        var req = URLRequest(url: url)
        req.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await BridgeURLSession.http.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw BridgeAPIError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoded = try JSONDecoder().decode(WorkspacesEnvelope.self, from: data)
        return (decoded.response.workspaces, decoded.response.active_workspace_id)
    }

    /// Appends the agent's worktree so sc can resolve agents outside the active view.
    private static func withWorktree(_ url: URL, _ worktree: String?) -> URL {
        guard let worktree, var c = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url }
        c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "worktree", value: worktree)]
        return c.url ?? url
    }

    static func send(
        connection: BridgeConnection,
        target: String,
        text: String,
        worktree: String? = nil,
        prefill: Bool = false
    ) async throws {
        let encoded = AgentTargetEncoding.encode(target)
        let url = withWorktree(BridgeURL.v1(connection, path: BridgeURL.agentPath(encodedTarget: encoded, suffix: "/send")), worktree)
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        let body = SendBody(text: text, prefill: prefill, queue: false)
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await BridgeURLSession.http.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            if let http = resp as? HTTPURLResponse, let msg = String(data: data, encoding: .utf8) {
                throw BridgeAPIError.message("HTTP \(http.statusCode): \(msg)")
            }
            throw BridgeAPIError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    static func interrupt(connection: BridgeConnection, target: String, worktree: String? = nil) async throws {
        let encoded = AgentTargetEncoding.encode(target)
        let url = withWorktree(BridgeURL.v1(connection, path: BridgeURL.agentPath(encodedTarget: encoded, suffix: "/interrupt")), worktree)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        let (_, resp) = try await BridgeURLSession.http.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw BridgeAPIError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    static func snapshot(connection: BridgeConnection, target: String, worktree: String? = nil, last: Int = 80) async throws -> [String] {
        let encoded = AgentTargetEncoding.encode(target)
        var comp = URLComponents(url: BridgeURL.v1(connection, path: BridgeURL.agentPath(encodedTarget: encoded, suffix: "/snapshot")), resolvingAgainstBaseURL: true)!
        comp.queryItems = [URLQueryItem(name: "last", value: String(last))]
        if let worktree { comp.queryItems?.append(URLQueryItem(name: "worktree", value: worktree)) }
        var req = URLRequest(url: comp.url!)
        req.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await BridgeURLSession.http.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw BridgeAPIError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoded = try JSONDecoder().decode(AgentReadResponse.self, from: data)
        guard let first = decoded.response.targets.first, first.ok == true else {
            return []
        }
        return first.lines ?? []
    }

    /// Spawn a phone-owned Pi agent in RPC live mode; returns its rpc id.
    static func startRpcAgent(connection: BridgeConnection, worktree: String, name: String? = nil) async throws -> String {
        let url = BridgeURL.v1(connection, path: "/v1/rpc/agents")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        var bodyObj: [String: Any] = ["worktree": worktree]
        if let name { bodyObj["name"] = name }
        req.httpBody = try JSONSerialization.data(withJSONObject: bodyObj)
        let (data, resp) = try await BridgeURLSession.http.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw BridgeAPIError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoded = try JSONDecoder().decode(RpcAgentEnvelope.self, from: data)
        return decoded.response.id
    }

    static func stopRpcAgent(connection: BridgeConnection, rpcId: String) async {
        let url = BridgeURL.v1(connection, path: "/v1/rpc/agents/\(rpcId)/stop")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        _ = try? await BridgeURLSession.http.data(for: req)
    }
}

private struct RpcAgentEnvelope: Decodable {
    var response: RpcAgentDTO
    struct RpcAgentDTO: Decodable { var id: String }
}

enum BridgeAPIError: Error, LocalizedError {
    case http(Int)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .http(let code): return "Server returned HTTP \(code)."
        case .message(let m): return m
        }
    }
}

private struct SendBody: Encodable {
    var text: String
    var prefill: Bool
    var queue: Bool
}

private struct AgentsListEnvelope: Decodable {
    var response: AgentsListBody
}

private struct WorkspacesEnvelope: Decodable {
    var response: WorkspacesBody
}

private struct WorkspacesBody: Decodable {
    var active_workspace_id: String?
    var workspaces: [WorkspaceNode]
}

private struct AgentsListBody: Decodable {
    var agents: [AgentDTO]
}

private struct AgentDTO: Decodable {
    var stable_target_id: String
    var current_selector: String
    var provider_key: String
    var ui: String
    var state: String
    var phase: String
    var label: String?
    var capabilities: CapabilitiesDTO?
}

private struct CapabilitiesDTO: Decodable {
    var send: Bool?
    var read: Bool?
    var subscribe: Bool?
    var interrupt: Bool?
}

private struct AgentReadResponse: Decodable {
    var response: AgentReadInner
}

private struct AgentReadInner: Decodable {
    var targets: [ReadTarget]
}

private struct ReadTarget: Decodable {
    var ok: Bool?
    var lines: [String]?
}