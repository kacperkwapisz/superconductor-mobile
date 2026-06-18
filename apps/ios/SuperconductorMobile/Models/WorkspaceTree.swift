import SwiftUI

// Mirrors the bridge /v1/workspaces tree: workspace -> project -> worktree -> agent.

struct WorkspaceNode: Identifiable, Decodable, Equatable {
    var id: String
    var name: String
    var projects: [ProjectNode]

    var liveAgentCount: Int { projects.reduce(0) { $0 + $1.liveAgentCount } }
}

struct ProjectNode: Identifiable, Decodable, Equatable {
    var id: String
    var name: String
    var color: String?
    var repoPath: String?
    var hasAvatar: Bool
    var liveAgentCount: Int
    var worktrees: [WorktreeNode]

    enum CodingKeys: String, CodingKey {
        case id, name, color
        case repoPath = "repo_path"
        case hasAvatar = "has_avatar"
        case liveAgentCount = "live_agent_count"
        case worktrees
    }

    /// Project accent from the hue Superconductor stores ("0"..."360").
    var accent: Color {
        guard let color, let hue = Double(color) else { return .accentColor }
        return Color(hue: hue / 360.0, saturation: 0.62, brightness: 0.95)
    }
}

struct WorktreeNode: Identifiable, Decodable, Equatable {
    var name: String
    var path: String
    var displayName: String
    var gitBranch: String?
    var isMain: Bool
    var lastInteractionAt: String?
    var agents: [AgentLeaf]

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, path
        case displayName = "display_name"
        case gitBranch = "git_branch"
        case isMain = "is_main"
        case lastInteractionAt = "last_interaction_at"
        case agents
    }

    /// Compact relative time like the Mac sidebar ("6h", "1m", "3d").
    var relativeTime: String? {
        guard let lastInteractionAt,
              let date = ISO8601DateFormatter.flexible.date(from: lastInteractionAt) else { return nil }
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "now" }
        if secs < 3600 { return "\(secs / 60)m" }
        if secs < 86400 { return "\(secs / 3600)h" }
        return "\(secs / 86400)d"
    }
}

extension ISO8601DateFormatter {
    static let flexible: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

struct AgentLeaf: Identifiable, Decodable, Equatable {
    var target: String
    var providerKey: String
    var state: String
    var capabilities: AgentLeafCaps?
    var label: String?
    var selector: String?
    var ui: String?
    var tabTitleFromHost: String?

    var id: String { target }

    enum CodingKeys: String, CodingKey {
        case target, state
        case providerKey = "provider_key"
        case capabilities, label, selector, ui
        case tabTitleFromHost = "tab_title"
    }

    var isInteractive: Bool {
        (capabilities?.send ?? false) && (capabilities?.subscribe ?? false)
    }

    /// Tab number parsed from a selector like "view:1/tab:2/pane:1".
    var tabNumber: Int? {
        guard let selector, let r = selector.range(of: "tab:") else { return nil }
        let rest = selector[r.upperBound...].prefix { $0.isNumber }
        return Int(rest)
    }

    /// Human tab title: Superconductor's own tab title, else label, else provider.
    var tabTitle: String {
        if let t = tabTitleFromHost, !t.isEmpty { return t }
        if let label, !label.isEmpty { return label }
        switch providerKey {
        case "pi": return "Pi"
        case "terminal": return "Shell"
        default: return providerKey.capitalized
        }
    }

    /// Build the AgentRow the session view consumes.
    func toAgentRow(title: String, worktreePath: String) -> AgentRow {
        let sid = target.hasPrefix("id:") ? String(target.dropFirst(3)) : target
        return AgentRow(
            stableTargetId: sid,
            selector: title,
            providerKey: providerKey,
            ui: "terminal",
            state: state,
            phase: state,
            label: nil,
            capabilities: AgentCapabilities(
                canSend: capabilities?.send ?? false,
                canRead: capabilities?.read ?? false,
                canSubscribe: capabilities?.subscribe ?? false,
                canInterrupt: capabilities?.interrupt ?? false
            ),
            worktreePath: worktreePath
        )
    }
}

struct AgentLeafCaps: Decodable, Equatable {
    var send: Bool?
    var read: Bool?
    var subscribe: Bool?
    var interrupt: Bool?
}
