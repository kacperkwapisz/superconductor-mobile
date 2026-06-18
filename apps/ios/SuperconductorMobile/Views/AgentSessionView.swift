import SwiftUI

struct AgentSessionView: View {
    let agent: AgentRow
    @Environment(AppSession.self) private var session
    @State private var stream = AgentStreamService()
    @State private var draft = ""
    @State private var isSending = false
    @State private var localError: String?
    @FocusState private var composerFocused: Bool

    private var target: String { agent.bridgeTarget }

    @State private var chatModel: ChatViewModel?
    @State private var forceRaw = false
    @State private var fellBack = false

    var body: some View {
        Group {
            if agent.providerKey == "pi" && !forceRaw && !fellBack {
                if let chatModel {
                    ChatView(model: chatModel, title: agent.displayTitle, onNotPi: { fellBack = true })
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                terminalSession
            }
        }
        .toolbar {
            if agent.providerKey == "pi" && !fellBack {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(forceRaw ? "Chat" : "Raw",
                           systemImage: forceRaw ? "bubble.left.and.bubble.right" : "terminal") {
                        forceRaw.toggle()
                    }
                }
            }
        }
        .task {
            if agent.providerKey == "pi", chatModel == nil, let c = session.connection {
                chatModel = ChatViewModel(
                    mode: .transcript(target: agent.bridgeTarget, worktree: agent.worktreePath),
                    connection: c
                )
            }
        }
    }

    private var terminalSession: some View {
        VStack(spacing: 0) {
            sessionHeader

            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if stream.lines.isEmpty {
                            emptyTerminal
                        } else {
                            TerminalTextView(lines: stream.lines)
                                .padding(16)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("terminal-bottom")
                }
                .background(terminalBackground)
                .onChange(of: stream.lines.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo("terminal-bottom", anchor: .bottom)
                    }
                }
            }

            GlassChrome.composerDock {
                HStack(alignment: .bottom, spacing: 12) {
                    GlassChrome.capsuleField {
                        TextField(composerPlaceholder, text: $draft, axis: .vertical)
                            .lineLimit(1...6)
                            .textFieldStyle(.plain)
                            .focused($composerFocused)
                            .disabled(!agent.capabilities.canSend)
                    }
                    .frame(maxWidth: .infinity)

                    GlassChrome.sendButton(
                        enabled: agent.capabilities.canSend
                            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && !isSending
                    ) {
                        Task { await send() }
                    }
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(agent.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if agent.capabilities.canInterrupt {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Stop", systemImage: "stop.fill") {
                        Task { await interrupt() }
                    }
                    .tint(.red)
                }
            }
        }
        .task { await bootstrapSession() }
        .onDisappear { stream.disconnect() }
        .alert("Error", isPresented: .init(
            get: { localError != nil },
            set: { if !$0 { localError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(localError ?? "")
        }
    }

    private var terminalBackground: some View {
        RoundedRectangle(cornerRadius: 0)
            .fill(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private var emptyTerminal: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Waiting for output")
                .font(.headline)
            Text(emptyHint)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var sessionHeader: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(stream.isConnected ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(stream.isConnected ? "Live" : "Connecting")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)

            Spacer()

            Text(agent.selector)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyHint: String {
        if !agent.isInteractive {
            return "This tab is view-only. Use a Pi agent tab on your Mac for remote control."
        }
        if let err = stream.lastStreamError {
            return err
        }
        return "Keep Superconductor and the Mac bridge running."
    }

    private var composerPlaceholder: String {
        agent.capabilities.canSend ? "Message…" : "Read-only"
    }

    private func bootstrapSession() async {
        guard let connection = session.connection else { return }
        stream.connect(connection: connection, target: target, worktree: agent.worktreePath)
        do {
            let snap = try await BridgeAPI.snapshot(connection: connection, target: target, worktree: agent.worktreePath)
            stream.applySnapshot(snap)
        } catch {
            localError = error.localizedDescription
        }
    }

    private func send() async {
        guard let connection = session.connection, agent.capabilities.canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        do {
            try await BridgeAPI.send(connection: connection, target: target, text: text, worktree: agent.worktreePath)
            draft = ""
        } catch {
            localError = error.localizedDescription
        }
    }

    private func interrupt() async {
        guard let connection = session.connection else { return }
        do {
            try await BridgeAPI.interrupt(connection: connection, target: target, worktree: agent.worktreePath)
        } catch {
            localError = error.localizedDescription
        }
    }
}

struct TerminalTextView: View {
    let lines: [String]

    var body: some View {
        Text(attributedLines)
            .font(AppTheme.terminalFont)
            .lineSpacing(AppTheme.terminalLineSpacing)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributedLines: AttributedString {
        var result = AttributedString(lines.joined(separator: "\n"))
        result.foregroundColor = Color(uiColor: .label)
        return result
    }
}