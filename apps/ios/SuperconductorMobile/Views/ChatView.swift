import SwiftUI

/// Markdown parsing is expensive; cache by source string so scrolling never re-parses.
private enum MarkdownCache {
    static var store: [String: AttributedString] = [:]
    static func get(_ s: String) -> AttributedString {
        if let hit = store[s] { return hit }
        let parsed = (try? AttributedString(markdown: s, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        ))) ?? AttributedString(s)
        if store.count > 1500 { store.removeAll(keepingCapacity: true) }
        store[s] = parsed
        return parsed
    }
}

struct ChatView: View {
    @State var model: ChatViewModel
    var title: String
    /// Called when the transcript backend reports the agent isn't a Pi agent.
    var onNotPi: (() -> Void)?

    @State private var draft = ""
    @State private var isSending = false
    @State private var showModelPicker = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.displayMessages) { msg in
                            MessageRow(message: msg).id(msg.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(16)
                }
                .onChange(of: model.displayMessages.count) { old, new in
                    // Animate small deltas (a reply landing); jump instantly for bulk backlog loads.
                    scrollToBottom(proxy, animated: new - old <= 2)
                }
                .onChange(of: model.streamingText) { _, _ in scrollToBottom(proxy, animated: false) }
            }

            composer
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(model: model)
        }
        .task { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.notPi) { _, isNotPi in if isNotPi { onNotPi?() } }
        .alert("Error", isPresented: .init(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(model.lastError ?? "") }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isStreaming ? Color.green : (model.isConnected ? Color.blue : Color.orange))
                .frame(width: 7, height: 7)
            Text(model.isStreaming ? "Working…" : (model.isConnected ? "Live" : "Connecting"))
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let f = model.footer {
                footerPills(f)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func footerPills(_ f: AgentFooter) -> some View {
        HStack(spacing: 6) {
            if model.canSwitchModel {
                Button { showModelPicker = true } label: {
                    pillLabel(text: f.model ?? "Model", system: "cpu", showChevron: true)
                }
                .buttonStyle(.plain)
            } else if let m = f.model {
                pillLabel(text: m, system: "cpu")
            }
            if let ctx = f.contextPct { pill(text: "\(ctx)%", system: "gauge.with.dots.needle.50percent") }
            if let cost = f.cost { pill(text: "$\(cost)", system: nil) }
        }
        .lineLimit(1)
    }

    private func pillLabel(text: String, system: String?, showChevron: Bool = false) -> some View {
        HStack(spacing: 3) {
            if let system { Image(systemName: system).font(.system(size: 9)) }
            Text(text).font(.caption2.weight(.medium)).lineLimit(1)
            if showChevron { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
    }

    private func pill(text: String, system: String?) -> some View {
        pillLabel(text: text, system: system)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(model.canSend ? "Message…" : "Read-only", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .focused($composerFocused)
                .disabled(!model.canSend)

            Button {
                let text = draft
                draft = ""
                isSending = true
                Task { await model.send(text); isSending = false }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
            }
            .disabled(!model.canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.bar)
    }
}

private struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        if message.isUser {
            HStack {
                Spacer(minLength: 40)
                Text(message.text ?? "")
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
            }
        } else if message.isToolResult {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let thinking = message.thinking, !thinking.isEmpty {
                    ThinkingView(text: thinking)
                }
                if let text = message.text, !text.isEmpty {
                    Text(markdown(text))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if message.isStreaming && (message.text?.isEmpty ?? true) {
                    ProgressView().controlSize(.small)
                }
                ForEach(message.toolCalls) { call in
                    ToolCallChip(call: call)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func markdown(_ s: String) -> AttributedString { MarkdownCache.get(s) }
}

private struct ThinkingView: View {
    let text: String
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text).font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        } label: {
            Label("Thinking", systemImage: "brain").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

private struct ToolCallChip: View {
    let call: ChatToolCall
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    if call.hasResult {
                        Image(systemName: call.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                            .font(.caption2).foregroundStyle(call.isError ? .red : .green)
                    } else {
                        Image(systemName: "wrench.and.screwdriver.fill").font(.caption2)
                    }
                    Text(call.name).font(.caption.weight(.semibold).monospaced())
                    if !call.hasResult {
                        ProgressView().controlSize(.mini)
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if expanded {
                if !call.argsPreview.isEmpty {
                    Text("Request").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    Text(call.argsPreview).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                if let out = call.resultPreview, !out.isEmpty {
                    Text("Output").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    Text(out).font(.caption2.monospaced())
                        .foregroundStyle(call.isError ? .red : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
            }
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
