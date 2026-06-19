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

    /// Pi's status footer (model / branch / cost / context%) parsed from the terminal snapshot.
    static func fetchFooter(connection: BridgeConnection, target: String, worktree: String? = nil) async -> AgentFooter? {
        let encoded = AgentTargetEncoding.encode(target)
        let url = withWorktree(BridgeURL.v1(connection, path: BridgeURL.agentPath(encodedTarget: encoded, suffix: "/footer")), worktree)
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await BridgeURLSession.http.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let env = try? JSONDecoder().decode(FooterEnvelope.self, from: data) else { return nil }
        // Keep the response even when the pill fields are empty: it still carries `working`.
        return env.response
    }

    static func fetchModels(connection: BridgeConnection, provider: String = "pi") async throws -> [ModelOption] {
        var comp = URLComponents(url: BridgeURL.v1(connection, path: "/v1/models"), resolvingAgainstBaseURL: true)!
        comp.queryItems = [URLQueryItem(name: "provider", value: provider)]
        var req = URLRequest(url: comp.url!)
        req.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await BridgeURLSession.http.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw BridgeAPIError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let env = try JSONDecoder().decode(ModelsEnvelope.self, from: data)
        return env.response.models.map { ModelOption(id: $0.id, label: $0.label) }
    }

    static func setMirroredModel(
        connection: BridgeConnection,
        target: String,
        modelId: String,
        worktree: String?,
        queue: Bool = false
    ) async throws {
        let encoded = AgentTargetEncoding.encode(target)
        let url = withWorktree(BridgeURL.v1(connection, path: BridgeURL.agentPath(encodedTarget: encoded, suffix: "/set-model")), worktree)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(SetModelBody(modelId: modelId, queue: queue))
        let (data, resp) = try await BridgeURLSession.http.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            if let http = resp as? HTTPURLResponse, let msg = String(data: data, encoding: .utf8) {
                throw BridgeAPIError.message("HTTP \(http.statusCode): \(msg)")
            }
            throw BridgeAPIError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }


    static func fetchWorktreeActions(connection: BridgeConnection) async throws -> [WorktreeActionItem] {
        let url = BridgeURL.v1(connection, path: "/v1/worktree/actions")
        var req = URLRequest(url: url)
        req.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await BridgeURLSession.http.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw BridgeAPIError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(WorktreeActionsEnvelope.self, from: data).response.actions
    }

    static func runWorktreeAction(connection: BridgeConnection, worktreePath: String, action: String, target: String? = nil, provider: String = "pi") async throws {
        let enc = worktreePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? worktreePath
        let url = BridgeURL.v1(connection, path: "/v1/worktrees/\(enc)/action")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(WorktreeActionBody(action: action, target: target, provider: provider))
        let (data, resp) = try await BridgeURLSession.http.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            if let http = resp as? HTTPURLResponse, let msg = String(data: data, encoding: .utf8) {
                throw BridgeAPIError.message("HTTP \(http.statusCode): \(msg)")
            }
            throw BridgeAPIError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
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

private struct FooterEnvelope: Decodable { var response: AgentFooter }

private struct ModelsEnvelope: Decodable {
    var response: ModelsBody
    struct ModelsBody: Decodable {
        var models: [ModelDTO]
    }
    struct ModelDTO: Decodable { var id: String; var label: String }
}

private struct SetModelBody: Encodable {
    var modelId: String
    var queue: Bool
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

struct WorktreeActionItem: Identifiable, Decodable, Equatable {
    var id: String
    var title: String
    var kind: String
}

private struct WorktreeActionsEnvelope: Decodable {
    var response: WorktreeActionsBody
    struct WorktreeActionsBody: Decodable { var actions: [WorktreeActionItem] }
}

private struct WorktreeActionBody: Encodable {
    var action: String
    var target: String?
    var provider: String
}
