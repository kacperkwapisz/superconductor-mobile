import Foundation

extension Error {
    /// True for benign WebSocket/task teardown (URLError.cancelled -999 or CancellationError).
    var isCancellation: Bool {
        if self is CancellationError { return true }
        let ns = self as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }
}

@MainActor
@Observable
final class ChatViewModel {
    enum Mode {
        case transcript(target: String, worktree: String?)  // A: mirror a Mac Pi agent
        case rpc(rpcId: String)                             // B: phone-owned live agent
    }

    private(set) var messages: [ChatMessage] = []
    private(set) var streamingText: String = ""
    private(set) var isStreaming = false
    private(set) var isConnected = false
    private(set) var notPi = false
    private(set) var footer: AgentFooter?
    var lastError: String?

    private let mode: Mode
    private let connection: BridgeConnection
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var committedCount = 0  // for stable ids
    private var didInitialBacklog = false
    private var quietTask: Task<Void, Never>?  // transcript: clear "Working…" after a lull
    private var footerTask: Task<Void, Never>?

    var canSend: Bool {
        switch mode {
        case .transcript: return true
        case .rpc: return isConnected
        }
    }

    var canSwitchModel: Bool { true }

    func loadModels() async throws -> [ModelOption] {
        try await BridgeAPI.fetchModels(connection: connection, provider: "pi")
    }

    func switchModel(to modelId: String) async {
        switch mode {
        case let .transcript(target, worktree):
            do {
                try await BridgeAPI.setMirroredModel(
                    connection: connection,
                    target: target,
                    modelId: modelId,
                    worktree: worktree,
                    queue: isStreaming
                )
                var f = footer ?? AgentFooter()
                f.model = modelId.contains("/") ? String(modelId.split(separator: "/").last!) : modelId
                footer = f
            } catch {
                lastError = error.localizedDescription
            }
        case .rpc:
            let parts = modelId.split(separator: "/", maxSplits: 1).map(String.init)
            let provider = parts.count > 1 ? parts[0] : "anthropic"
            let mid = parts.count > 1 ? parts[1] : modelId
            sendRaw(["type": "set_model", "id": "set_model", "provider": provider, "modelId": mid])
        }
    }

    /// Committed messages + a live bubble: typed text for RPC, a working spinner for transcript.
    var displayMessages: [ChatMessage] {
        guard isStreaming else { return messages }
        let bubble = ChatMessage(
            id: "streaming", role: "assistant",
            text: streamingText.isEmpty ? nil : streamingText, isStreaming: true
        )
        return messages + [bubble]
    }

    // Transcript (Mac agent) has no explicit "done" signal; treat a lull in file writes as idle.
    private func markActivity() {
        isStreaming = true
        quietTask?.cancel()
        quietTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { self?.isStreaming = false }
        }
    }

    init(mode: Mode, connection: BridgeConnection) {
        self.mode = mode
        self.connection = connection
    }

    func start() {
        let path: String
        switch mode {
        case let .transcript(target, worktree):
            let enc = AgentTargetEncoding.encode(target)
            var url = BridgeURL.ws(connection, path: BridgeURL.agentPath(encodedTarget: enc, suffix: "/transcript/stream"))
            if let worktree, var c = URLComponents(url: url, resolvingAgainstBaseURL: true) {
                c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "worktree", value: worktree)]
                url = c.url ?? url
            }
            openSocket(url)
            startFooterPolling(target: target, worktree: worktree)
            return
        case let .rpc(rpcId):
            path = "/v1/rpc/agents/\(rpcId)/stream"
        }
        openSocket(BridgeURL.ws(connection, path: path))
        startRpcStatsPolling()
    }

    private func openSocket(_ url: URL) {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        let t = BridgeURLSession.http.webSocketTask(with: req)
        task = t
        t.resume()
        isConnected = true
        receiveTask = Task { await receiveLoop() }
    }

    // RPC agents expose get_session_stats over the same socket (exact cost + context%).
    private func startRpcStatsPolling() {
        footerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if self.isConnected { self.sendRaw(["type": "get_session_stats", "id": "stats"]) }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func startFooterPolling(target: String, worktree: String?) {
        footerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if let f = await BridgeAPI.fetchFooter(connection: self.connection, target: target, worktree: worktree) {
                    self.footer = f
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        footerTask?.cancel(); footerTask = nil
        quietTask?.cancel(); quietTask = nil
        receiveTask?.cancel(); receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil); task = nil
        isConnected = false
    }

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch mode {
        case let .transcript(target, worktree):
            messages.append(ChatMessage(id: "u-\(committedCount)", role: "user", text: trimmed))
            committedCount += 1
            markActivity()
            do {
                try await BridgeAPI.send(connection: connection, target: target, text: trimmed, worktree: worktree)
            } catch {
                lastError = error.localizedDescription
                isStreaming = false
            }
        case .rpc:
            // Optimistic echo; the user message_end will not be appended again (see handling).
            messages.append(ChatMessage(id: "u-\(committedCount)", role: "user", text: trimmed))
            committedCount += 1
            let cmd: [String: Any] = isStreaming
                ? ["type": "prompt", "message": trimmed, "streamingBehavior": "steer"]
                : ["type": "prompt", "message": trimmed]
            sendRaw(cmd)
        }
    }

    private func sendRaw(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(s)) { _ in }
    }

    private func receiveLoop() async {
        guard let task else { return }
        while !Task.isCancelled {
            do {
                let msg = try await task.receive()
                switch msg {
                case .string(let s): handle(s)
                case .data(let d): if let s = String(data: d, encoding: .utf8) { handle(s) }
                @unknown default: break
                }
            } catch {
                // Transport drops/teardown are not user-facing errors; real failures arrive as
                // bridge_error / rpc_error / send failures. Just mark disconnected.
                isConnected = false
                break
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // Bridge envelope kinds (A + error)
        switch obj["kind"] as? String {
        case "not_pi":
            notPi = true; return
        case "bridge_error":
            lastError = obj["message"] as? String; return
        case "transcript_append":
            if let arr = obj["messages"] as? [[String: Any]] {
                appendTranscript(arr)
                if didInitialBacklog { markActivity() } else { didInitialBacklog = true }
            }
            return
        default:
            break
        }

        // RPC event types (B)
        guard let type = obj["type"] as? String else { return }
        switch type {
        case "agent_start", "turn_start":
            isStreaming = true
        case "message_start":
            if (obj["message"] as? [String: Any])?["role"] as? String == "assistant" {
                streamingText = ""
            }
        case "message_update":
            if let ev = obj["assistantMessageEvent"] as? [String: Any],
               let delta = ev["delta"] as? String {
                streamingText += delta
            }
        case "response":
            let cmd = obj["command"] as? String
            if cmd == "get_session_stats", let data = obj["data"] as? [String: Any] {
                var f = footer ?? AgentFooter()
                if let cost = data["cost"] as? Double { f.cost = String(format: "%.2f", cost) }
                if let cu = data["contextUsage"] as? [String: Any], let pct = cu["percent"] as? Double {
                    f.contextPct = Int(pct)
                }
                footer = f
            } else if cmd == "set_model", obj["success"] as? Bool == true, let data = obj["data"] as? [String: Any] {
                var f = footer ?? AgentFooter()
                if let id = data["id"] as? String { f.model = id }
                else if let name = data["name"] as? String { f.model = name }
                footer = f
            } else if cmd == "set_model", obj["success"] as? Bool == false {
                lastError = (obj["error"] as? String) ?? "Model switch failed"
            }
        case "message_end":
            if let m = obj["message"] as? [String: Any] {
                if m["role"] as? String == "assistant", let model = m["model"] as? String {
                    var f = footer ?? AgentFooter(); f.model = model; footer = f
                }
                commitRawMessage(m)
            }
            streamingText = ""
        case "agent_end", "turn_end":
            isStreaming = false
            streamingText = ""
        case "rpc_exit":
            isConnected = false; isStreaming = false
            lastError = "Agent process exited."
        case "rpc_error":
            lastError = obj["message"] as? String
        default:
            break
        }
    }

    private func appendTranscript(_ arr: [[String: Any]]) {
        for raw in arr {
            guard let d = try? JSONSerialization.data(withJSONObject: raw),
                  let dto = try? JSONDecoder().decode(ChatMessageDTO.self, from: d) else { continue }
            // Skip the user message we already echoed optimistically on send.
            if dto.role == "user", let last = messages.last, last.isUser, last.text == dto.text {
                continue
            }
            absorb(dto.toMessage(id: "m-\(committedCount)"))
            committedCount += 1
        }
    }

    /// Fold tool results into the matching assistant tool-call chip instead of a separate row.
    private func absorb(_ msg: ChatMessage) {
        if msg.isToolResult, let tr = msg.toolResult {
            if mergeToolResult(tr) { return }
        }
        messages.append(msg)
    }

    private func mergeToolResult(_ tr: ChatToolResult) -> Bool {
        for i in messages.indices.reversed() {
            guard messages[i].isAssistant else { continue }
            let idx: Int? = {
                if let tid = tr.toolCallId, !tid.isEmpty,
                   let j = messages[i].toolCalls.firstIndex(where: { $0.id == tid }) { return j }
                return messages[i].toolCalls.firstIndex(where: { $0.resultPreview == nil && $0.name == tr.toolName })
            }()
            guard let j = idx else { continue }
            messages[i].toolCalls[j].resultPreview = tr.preview
            messages[i].toolCalls[j].isError = tr.isError
            return true
        }
        return false
    }

    private func commitRawMessage(_ m: [String: Any]) {
        // Skip the user echo we already added optimistically.
        if m["role"] as? String == "user",
           let last = messages.last, last.isUser,
           last.text == ((m["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")) {
            return
        }
        guard let msg = ChatMessage.fromRawMessage(m, id: "m-\(committedCount)") else { return }
        absorb(msg)
        committedCount += 1
    }
}
