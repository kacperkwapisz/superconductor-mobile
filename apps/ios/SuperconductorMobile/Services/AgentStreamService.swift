import Foundation

@MainActor
@Observable
final class AgentStreamService {
    private(set) var lines: [String] = []
    private(set) var isConnected = false
    private(set) var lastStreamError: String?
    private var task: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?
    private static let maxLines = 1500  // TerminalTextView joins the whole array each render

    func connect(connection: BridgeConnection, target: String, worktree: String? = nil) {
        disconnect()
        lastStreamError = nil
        let encoded = AgentTargetEncoding.encode(target)
        var url = BridgeURL.ws(connection, path: BridgeURL.agentPath(encodedTarget: encoded, suffix: "/stream"))
        if let worktree, var c = URLComponents(url: url, resolvingAgainstBaseURL: true) {
            c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "worktree", value: worktree)]
            url = c.url ?? url
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        task = BridgeURLSession.http.webSocketTask(with: req)
        task?.resume()
        isConnected = true
        receiveLoopTask = Task { await self.receiveLoop() }
    }

    func applySnapshot(_ newLines: [String]) {
        if !newLines.isEmpty {
            lines = newLines
        }
    }

    func disconnect() {
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
    }

    private func receiveLoop() async {
        guard let task else { return }
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                let raw: String?
                switch message {
                case .string(let text): raw = text
                case .data(let data): raw = String(data: data, encoding: .utf8)
                @unknown default: raw = nil
                }
                if let raw, let json = await Self.parseJSON(raw) { applyEvent(json) }
            } catch {
                isConnected = false
                if !Task.isCancelled && !error.isCancellation { lastStreamError = error.localizedDescription }
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

    private func applyEvent(_ json: [String: Any]) {
        guard let kind = json["kind"] as? String else { return }
        if kind == "bridge_error" { lastStreamError = json["message"] as? String; return }
        guard kind == "agent_event",
              let payload = json["payload"] as? [String: Any],
              let newLines = payload["lines"] as? [String] else { return }
        lines = newLines.count > Self.maxLines ? Array(newLines.suffix(Self.maxLines)) : newLines
    }
}