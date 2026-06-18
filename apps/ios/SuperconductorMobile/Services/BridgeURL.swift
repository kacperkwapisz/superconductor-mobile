import Foundation

enum BridgeURL {
    /// Builds `/v1/...` without `appendingPathComponent` mangling `%` in encoded targets.
    static func v1(_ connection: BridgeConnection, path: String) -> URL {
        var base = connection.baseURL.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        let p = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: base + p) else {
            fatalError("Invalid bridge URL: \(base)\(p)")
        }
        return url
    }

    static func ws(_ connection: BridgeConnection, path: String) -> URL {
        var base = connection.wsBaseURL.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        let p = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: base + p) else {
            fatalError("Invalid bridge WS URL: \(base)\(p)")
        }
        return url
    }

    static func agentPath(encodedTarget: String, suffix: String) -> String {
        "/v1/agents/\(encodedTarget)\(suffix)"
    }
}