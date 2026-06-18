import Foundation

@MainActor
@Observable
final class AgentStreamService {
    private(set) var lines: [String] = []
    private(set) var isConnected = false
    private(set) var lastStreamError: String?
    private var task: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?

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
                switch message {
                case .string(let text):
                    applyEvent(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        applyEvent(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                isConnected = false
                if !Task.isCancelled && !error.isCancellation { lastStreamError = error.localizedDescription }
                break
            }
        }
    }

    private func applyEvent(_ text: String) {
        if let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let kind = json["kind"] as? String,
           kind == "bridge_error",
           let message = json["message"] as? String {
            lastStreamError = message
            return
        }
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = json["kind"] as? String,
              kind == "agent_event",
              let payload = json["payload"] as? [String: Any],
              let newLines = payload["lines"] as? [String]
        else { return }
        lines = newLines
    }
}