import SwiftUI

struct WorkspacesView: View {
    @Environment(AppSession.self) private var session
    @State private var collapsed: Set<String> = []
    @State private var expandedWorktrees: Set<String> = []
    @State private var pendingRpc: RpcSession?
    @State private var launching = false
    @State private var worktreeActions: [WorktreeActionItem] = []
    @State private var runningAction: String?

    struct RpcSession: Identifiable, Hashable { var id: String; var title: String }

    private var selectedWorkspace: WorkspaceNode? {
        session.workspaces.first { $0.id == session.selectedWorkspaceId } ?? session.workspaces.first
    }

    var body: some View {
        NavigationStack {
            Group {
                if session.isLoadingWorkspaces && session.workspaces.isEmpty {
                    loading
                } else if session.workspaces.isEmpty {
                    ContentUnavailableView(
                        "No workspaces",
                        systemImage: "square.stack.3d.up",
                        description: Text("Open Superconductor on your Mac, then pull to refresh.")
                    )
                } else {
                    content
                }
            }
            .background { AppTheme.screenBackground }
            .navigationTitle("Superconductor")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: AgentRow.self) { AgentSessionView(agent: $0) }
            .navigationDestination(item: $pendingRpc) { rpc in
                if let c = session.connection {
                    ChatView(model: ChatViewModel(mode: .rpc(rpcId: rpc.id), connection: c), title: rpc.title)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Sign out", role: .destructive) { session.signOut() }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .refreshable { await refresh() }
            .task {
                if session.workspaces.isEmpty { await refresh() }
                await ensureActions()
            }
            .alert("Error", isPresented: .init(
                get: { session.lastError != nil },
                set: { if !$0 { session.lastError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: { Text(session.lastError ?? "") }
        }
    }

    private var loading: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading workspaces…").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        VStack(spacing: 0) {
            workspaceSwitcher
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        if let workspace = selectedWorkspace {
                            ForEach(workspace.projects) { project in
                                projectBlock(project)
                            }
                        }
                    } header: {
                        Text((selectedWorkspace?.name ?? "").uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .tracking(0.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.bar)
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: Workspace switcher chips

    private var workspaceSwitcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(session.workspaces) { ws in
                    let active = ws.id == (session.selectedWorkspaceId ?? selectedWorkspace?.id)
                    Button { session.selectedWorkspaceId = ws.id } label: {
                        HStack(spacing: 6) {
                            Text(ws.name).font(.subheadline.weight(.semibold))
                            if ws.liveAgentCount > 0 {
                                Text("\(ws.liveAgentCount)")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(active ? Color.white.opacity(0.25) : Color(uiColor: .tertiarySystemFill), in: Capsule())
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .foregroundStyle(active ? Color.white : Color.primary)
                        .background(active ? Color.accentColor : Color(uiColor: .secondarySystemBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    // MARK: Project + worktrees

    @ViewBuilder
    private func projectBlock(_ project: ProjectNode) -> some View {
        let isOpen = !collapsed.contains(project.id)

        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                if isOpen { collapsed.insert(project.id) } else { collapsed.remove(project.id) }
            }
        } label: {
            HStack(spacing: 11) {
                avatar(project)
                Text(project.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if project.liveAgentCount > 0 {
                    Text("\(project.liveAgentCount)")
                        .font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
                Image(systemName: "plus").font(.system(size: 14, weight: .medium)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if isOpen {
            ForEach(project.worktrees) { wt in
                worktreeRow(project: project, wt: wt)
            }
        }
    }

    @ViewBuilder
    private func avatar(_ project: ProjectNode) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        if project.hasAvatar, let url = session.connection?.avatarURL(projectId: project.id) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    letterTile(project)
                }
            }
            .frame(width: 26, height: 26)
            .clipShape(shape)
        } else {
            letterTile(project).frame(width: 26, height: 26).clipShape(shape)
        }
    }

    private func letterTile(_ project: ProjectNode) -> some View {
        ZStack {
            project.tileColor
            Text(String(project.name.prefix(1)).uppercased())
                .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private func worktreeRow(project: ProjectNode, wt: WorktreeNode) -> some View {
        let agents = wt.agents
        let multi = agents.count > 1
        let expanded = expandedWorktrees.contains(wt.path)
        let header = HStack(spacing: 8) {
            Text(wt.displayName)
                .font(.subheadline)
                .foregroundStyle(agents.isEmpty ? .secondary : .primary)
                .lineLimit(1).truncationMode(.tail)
            if wt.isMain {
                Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            if multi {
                Text("\(agents.count) tabs").font(.caption2).foregroundStyle(.secondary)
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
            }
            worktreeStatus(wt: wt)
        }
        .padding(.leading, 53).padding(.trailing, 16).padding(.vertical, 7)
        .contentShape(Rectangle())

        Group {
            if multi {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if expanded { expandedWorktrees.remove(wt.path) } else { expandedWorktrees.insert(wt.path) }
                    }
                } label: { header }.buttonStyle(.plain)
            } else if let agent = agents.first {
                NavigationLink(value: agent.toAgentRow(title: wt.displayName, worktreePath: wt.path)) { header }
                    .buttonStyle(.plain)
            } else {
                header
            }
        }
        .contextMenu {
            if !worktreeActions.isEmpty {
                Section("Worktree") {
                    ForEach(worktreeActions) { act in
                        Button(act.title, systemImage: iconForAction(act.id)) {
                            Task { await runAction(act.id, wt: wt) }
                        }
                        .disabled(runningAction != nil)
                    }
                }
            }
            Button("Start live agent", systemImage: "bolt.fill") {
                Task { await startLive(path: wt.path, title: wt.displayName) }
            }
        }

        if multi, expanded {
            ForEach(agents) { a in
                NavigationLink(value: a.toAgentRow(title: a.tabTitle, worktreePath: wt.path)) {
                    tabRow(a)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func tabRow(_ a: AgentLeaf) -> some View {
        HStack(spacing: 8) {
            Image(systemName: a.providerKey == "pi" ? "sparkle" : "terminal")
                .font(.caption2).foregroundStyle(a.providerKey == "pi" ? Color.accentColor : .secondary)
            Text(a.tabTitle)
                .font(.caption).foregroundStyle(.primary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            if a.state == "working" || a.state == "running" {
                Image(systemName: "play.fill").font(.system(size: 8)).foregroundStyle(.green)
            } else if a.state == "review" {
                Circle().fill(.orange).frame(width: 6, height: 6)
            }
        }
        .padding(.leading, 72).padding(.trailing, 16).padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func startLive(path: String, title: String) async {
        guard let c = session.connection, !launching else { return }
        launching = true
        defer { launching = false }
        do {
            let id = try await BridgeAPI.startRpcAgent(connection: c, worktree: path, name: title)
            pendingRpc = RpcSession(id: id, title: title)
        } catch {
            session.lastError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func worktreeStatus(wt: WorktreeNode) -> some View {
        let working = wt.agents.contains { $0.state == "working" || $0.state == "running" }
        let review = wt.agents.contains { $0.state == "review" }
        HStack(spacing: 7) {
            if working {
                Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(.green)
            } else if review {
                Circle().fill(.orange).frame(width: 7, height: 7)
            }
            if let t = wt.relativeTime {
                Text(t).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
    }

    private func ensureActions() async {
        guard worktreeActions.isEmpty, let c = session.connection else { return }
        if let list = try? await BridgeAPI.fetchWorktreeActions(connection: c) {
            worktreeActions = list
        }
    }

    private func iconForAction(_ id: String) -> String {
        switch id {
        case "create_pr": return "arrow.triangle.pull"
        case "commit_push", "inline_commit": return "arrow.up.doc"
        case "resolve_conflicts": return "wand.and.stars"
        case "fix_ci": return "checkmark.circle"
        case "fix_merge_blocked": return "exclamationmark.triangle"
        case "squash_merge", "merge_commit", "rebase_merge": return "arrow.triangle.merge"
        default: return "gearshape"
        }
    }

    private func runAction(_ action: String, wt: WorktreeNode) async {
        guard let c = session.connection, runningAction == nil else { return }
        runningAction = action
        defer { runningAction = nil }
        // Prefer an existing Pi agent so the action runs in that tab/conversation.
        let target = (wt.agents.first { $0.providerKey == "pi" } ?? wt.agents.first)?.target
        do {
            try await BridgeAPI.runWorktreeAction(connection: c, worktreePath: wt.path, action: action, target: target)
        } catch {
            session.lastError = error.localizedDescription
        }
    }

    private func refresh() async {
        guard let connection = session.connection else { return }
        session.isLoadingWorkspaces = true
        defer { session.isLoadingWorkspaces = false }
        do {
            let result = try await BridgeAPI.fetchWorkspaces(connection: connection)
            session.workspaces = result.workspaces
            if session.selectedWorkspaceId == nil {
                session.selectedWorkspaceId = result.activeId ?? result.workspaces.first?.id
            }
            session.lastError = nil
        } catch {
            session.lastError = error.localizedDescription
        }
    }
}
