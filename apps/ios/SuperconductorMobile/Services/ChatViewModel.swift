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
    private(set) var streamingMessage: ChatMessage? = nil  // live bubble: text + thinking + tool calls
    private(set) var streamingTick = 0                     // bumps each flush (cheap scroll trigger)
    private var pendingPartial: [String: Any]? = nil       // latest full message-so-far
    private var flushScheduled = false
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
    private var indexById: [String: Int] = [:]        // message id -> index (O(1) markdown fold)
    private var toolCallOwner: [String: Int] = [:]    // toolCallId -> owning message index
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

    /// Rebuild the live bubble from the latest `partial` (full message-so-far) ~20x/sec.
    /// Using the partial — not raw deltas — keeps text, thinking, and tool calls correct
    /// and in sync, and never leaks thinking/tool-call deltas into the answer text.
    private func scheduleStreamFlush(_ partial: [String: Any]) {
        pendingPartial = partial
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self, let p = self.pendingPartial else { return }
            self.flushScheduled = false
            if var m = ChatMessage.fromRawMessage(p, id: "streaming") {
                m.isStreaming = true
                self.streamingMessage = m
                self.streamingTick &+= 1
            }
        }
    }

    private func resetStreaming() {
        pendingPartial = nil
        streamingMessage = nil
    }

    /// Mark the agent as actively working and cancel any pending idle clear.
    private func markActive() {
        if !isStreaming { isStreaming = true }
        quietTask?.cancel(); quietTask = nil
    }

    /// Clear "Working…" after a grace period; any new activity cancels it. Bridges tool
    /// runs and inter-turn gaps so the indicator persists until the agent is really done.
    // ponytail: time-based heuristic; transcript mode has no explicit "done" event.
    private func markIdleSoon(_ seconds: Double) {
        quietTask?.cancel()
        quietTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { self?.isStreaming = false }
        }
    }

    // Transcript (Mac agent): "Working…" is driven by the polled agent state (startFooterPolling).
    // markActivity gives instant-on from file writes; the 12s timer is only a safety net in case
    // polling dies — the poll re-arms it every couple seconds while the agent is working.
    private func markActivity() {
        markActive()
        markIdleSoon(12)
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
                    switch f.working {
                    case true?:
                        self.markActivity()              // keep "Working…" alive while the turn runs
                    case false?:
                        self.quietTask?.cancel(); self.quietTask = nil
                        if self.isStreaming { self.isStreaming = false }
                    default:
                        break                            // unknown: leave the safety timer to it
                    }
                }
                try? await Task.sleep(for: .seconds(2))
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
            appendMessage(ChatMessage(id: "u-\(committedCount)", role: "user", text: trimmed))
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
            appendMessage(ChatMessage(id: "u-\(committedCount)", role: "user", text: trimmed))
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
                let raw: String?
                switch msg {
                case .string(let s): raw = s
                case .data(let d): raw = String(data: d, encoding: .utf8)
                @unknown default: raw = nil
                }
                // Parse off the main actor: transcript backlog frames can be hundreds of KB.
                if let raw, let obj = await Self.parseJSON(raw) { handle(obj) }
            } catch {
                // Transport drops/teardown are not user-facing errors; real failures arrive as
                // bridge_error / rpc_error / send failures. Just mark disconnected.
                isConnected = false
                break
            }
        }
    }

    private nonisolated static func parseJSON(_ s: String) async -> [String: Any]? {
        await Task.detached(priority: .utility) {
            guard let data = s.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }.value
    }

    private func handle(_ obj: [String: Any]) {
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
            markActive()
        case "message_start":
            // Some RPC servers skip agent_start/turn_start; treat the first assistant
            // token as the start of work so "Working…" always shows.
            if (obj["message"] as? [String: Any])?["role"] as? String == "assistant" {
                markActive()
                resetStreaming()
            }
        case "message_update":
            if let ev = obj["assistantMessageEvent"] as? [String: Any] {
                markActive()  // cancels any pending idle timer from a prior turn_end
                if let partial = ev["partial"] as? [String: Any] { scheduleStreamFlush(partial) }
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
            // Assistant message ended, but tools / more turns may follow: stay "Working…".
            markActive()
            resetStreaming()
        case "agent_end", "turn_end":
            // Don't drop "Working…" instantly: a multi-turn/tool loop emits turn_end between
            // turns. Grace period; the next turn_start cancels it, real completion clears it.
            markIdleSoon(type == "agent_end" ? 0.5 : 3)
            resetStreaming()
        case "rpc_exit":
            quietTask?.cancel(); quietTask = nil
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
            // Map the dict directly — no JSONEncoder/JSONDecoder roundtrip per message on main.
            guard let msg = ChatMessage.fromTranscriptDict(raw, id: "m-\(committedCount)") else { continue }
            // Skip the user message we already echoed optimistically on send.
            if msg.isUser, let last = messages.last, last.isUser, last.text == msg.text { continue }
            absorb(msg)
            committedCount += 1
        }
    }

    /// Single append path: keeps id→index and toolCallId→owner maps in sync so
    /// mergeToolResult / scheduleMarkdown stay O(1) instead of scanning the array.
    private func appendMessage(_ msg: ChatMessage) {
        indexById[msg.id] = messages.count
        for c in msg.toolCalls where !c.id.isEmpty { toolCallOwner[c.id] = messages.count }
        messages.append(msg)
    }

    /// Fold tool results into the matching assistant tool-call chip instead of a separate row.
    private func absorb(_ msg: ChatMessage) {
        if msg.isToolResult, let tr = msg.toolResult {
            if mergeToolResult(tr) { return }
        }
        appendMessage(msg)
        if msg.isAssistant, let t = msg.text, !t.isEmpty { scheduleMarkdown(id: msg.id, src: t) }
    }

    /// Parse markdown off the main thread, then store it on the message. The view shows
    /// plain text until this lands, so a long reply never blocks the main thread.
    private func scheduleMarkdown(id: String, src: String) {
        Task.detached(priority: .utility) { [weak self] in
            let parsed = (try? AttributedString(markdown: src, options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(src)
            await MainActor.run {
                guard let self, let i = self.indexById[id], self.messages.indices.contains(i),
                      self.messages[i].text == src else { return }
                self.messages[i].attributedText = parsed
            }
        }
    }

    private func mergeToolResult(_ tr: ChatToolResult) -> Bool {
        // Fast path: jump straight to the owning message via the id map.
        if let tid = tr.toolCallId, !tid.isEmpty, let i = toolCallOwner[tid],
           messages.indices.contains(i),
           let j = messages[i].toolCalls.firstIndex(where: { $0.id == tid }) {
            messages[i].toolCalls[j].resultPreview = tr.preview
            messages[i].toolCalls[j].isError = tr.isError
            return true
        }
        // Fallback: name-based match (blank/missing tool-call id) — scan recent assistant rows.
        for i in messages.indices.reversed() {
            guard messages[i].isAssistant else { continue }
            guard let j = messages[i].toolCalls.firstIndex(where: { $0.resultPreview == nil && $0.name == tr.toolName }) else { continue }
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
