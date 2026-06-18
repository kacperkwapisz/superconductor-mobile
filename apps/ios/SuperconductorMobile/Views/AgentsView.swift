import SwiftUI

struct AgentsView: View {
    @Environment(AppSession.self) private var session

    private var visibleAgents: [AgentRow] {
        session.showAllAgents ? session.agents : session.agents.filter(\.isInteractive)
    }

    var body: some View {
        NavigationStack {
            Group {
                if session.isLoadingAgents && session.agents.isEmpty {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Loading agents…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visibleAgents.isEmpty {
                    ContentUnavailableView(
                        session.agents.isEmpty ? "No agents" : "No remote agents",
                        systemImage: "terminal",
                        description: Text(emptyDescription)
                    )
                } else {
                    List(visibleAgents) { agent in
                        NavigationLink(value: agent) {
                            AgentRowView(agent: agent)
                        }
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background { AppTheme.screenBackground }
            .navigationTitle("Agents")
            .navigationDestination(for: AgentRow.self) { agent in
                AgentSessionView(agent: agent)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Toggle("Show shell tabs", isOn: Bindable(session).showAllAgents)
                        Divider()
                        Button("Sign out", role: .destructive) {
                            session.signOut()
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await refresh() }
                    }
                }
            }
            .refreshable { await refresh() }
            .task { await refresh() }
            .alert("Error", isPresented: .init(
                get: { session.lastError != nil },
                set: { if !$0 { session.lastError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(session.lastError ?? "")
            }
        }
    }

    private var emptyDescription: String {
        if session.agents.isEmpty {
            return "Open a Pi or chat session in Superconductor on your Mac, then refresh."
        }
        return "Turn on “Show shell tabs” in the menu to include read-only terminals."
    }

    private func refresh() async {
        guard let connection = session.connection else { return }
        session.isLoadingAgents = true
        defer { session.isLoadingAgents = false }
        do {
            let agents = try await BridgeAPI.fetchAgents(connection: connection)
            session.agents = agents.sorted { a, b in
                if a.isInteractive != b.isInteractive { return a.isInteractive }
                if a.providerKey == "pi" && b.providerKey != "pi" { return true }
                if b.providerKey == "pi" && a.providerKey != "pi" { return false }
                return a.displayTitle < b.displayTitle
            }
            session.lastError = nil
        } catch {
            session.lastError = error.localizedDescription
        }
    }
}

struct AgentRowView: View {
    let agent: AgentRow

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.providerTint(agent.providerKey).opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: AppTheme.providerSymbol(agent.providerKey))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(AppTheme.providerTint(agent.providerKey))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(agent.displayTitle)
                        .font(.body.weight(.semibold))
                    if agent.providerKey == "pi" {
                        Text("Pi")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .foregroundStyle(.orange)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                }
                HStack(spacing: 6) {
                    statusDot(agent.state)
                    Text(agent.state.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !agent.isInteractive {
                        Text("· View only")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusDot(_ state: String) -> some View {
        Circle()
            .fill(state == "working" || state == "running" ? Color.green : Color(uiColor: .tertiaryLabel))
            .frame(width: 6, height: 6)
    }
}