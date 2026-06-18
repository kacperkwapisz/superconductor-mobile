import SwiftUI

struct WorkspacesView: View {
    @Environment(AppSession.self) private var session
    @State private var collapsed: Set<String> = []

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
            .task { if session.workspaces.isEmpty { await refresh() } }
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
            project.accent.opacity(0.9)
            Text(String(project.name.prefix(1)).uppercased())
                .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private func worktreeRow(project: ProjectNode, wt: WorktreeNode) -> some View {
        let agent = wt.agents.first(where: \.isInteractive)
        let row = HStack(spacing: 8) {
            Text(wt.displayName)
                .font(.subheadline)
                .foregroundStyle(agent != nil ? .primary : .secondary)
                .lineLimit(1).truncationMode(.tail)
            if wt.isMain {
                Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            trailing(wt: wt, agent: agent)
        }
        .padding(.leading, 53).padding(.trailing, 16).padding(.vertical, 7)
        .contentShape(Rectangle())

        if let agent {
            NavigationLink(value: agent.toAgentRow(title: wt.displayName, worktreePath: wt.path)) { row }
                .buttonStyle(.plain)
        } else {
            row
        }
    }

    @ViewBuilder
    private func trailing(wt: WorktreeNode, agent: AgentLeaf?) -> some View {
        HStack(spacing: 7) {
            if let agent, agent.state == "working" || agent.state == "running" {
                Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(.green)
            } else if let agent, agent.state == "review" {
                Circle().fill(.orange).frame(width: 7, height: 7)
            }
            if let t = wt.relativeTime {
                Text(t).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
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
