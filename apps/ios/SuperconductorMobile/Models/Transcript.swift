import Foundation

struct ModelOption: Identifiable, Equatable {
    var id: String
    var label: String
}

struct AgentFooter: Decodable, Equatable {
    var model: String? = nil
    var branch: String? = nil
    var cost: String? = nil
    var contextPct: Int? = nil
    var time: String? = nil
    var working: Bool? = nil   // live agent state (mirror): true while the turn is running

    var isEmpty: Bool { model == nil && branch == nil && cost == nil && contextPct == nil }
}

struct ChatToolCall: Identifiable, Equatable {
    var id: String
    var name: String
    var argsPreview: String
    var resultPreview: String? = nil
    var isError: Bool = false

    var hasResult: Bool { resultPreview != nil }
}

struct ChatToolResult: Equatable {
    var toolCallId: String? = nil
    var toolName: String
    var isError: Bool
    var preview: String
}

struct ChatMessage: Identifiable, Equatable {
    var id: String
    var role: String          // user | assistant | toolResult | system | custom
    var text: String?
    var thinking: String?
    var toolCalls: [ChatToolCall] = []
    var toolResult: ChatToolResult?
    var isStreaming: Bool = false
    var attributedText: AttributedString? = nil  // markdown pre-rendered off-main at commit

    var isUser: Bool { role == "user" }
    var isAssistant: Bool { role == "assistant" }
    var isToolResult: Bool { role == "toolResult" }
}

/// Decodes the bridge's compact transcript schema (A: `/transcript/stream`).
struct ChatMessageDTO: Decodable {
    var role: String
    var text: String?
    var thinking: String?
    var toolCalls: [ToolCallDTO]?
    var toolResult: ToolResultDTO?

    struct ToolCallDTO: Decodable { var id: String; var name: String; var argsPreview: String }
    struct ToolResultDTO: Decodable {
        var toolCallId: String?
        var toolName: String
        var isError: Bool
        var preview: String
    }

    func toMessage(id: String) -> ChatMessage {
        ChatMessage(
            id: id,
            role: role,
            text: text,
            thinking: thinking,
            toolCalls: (toolCalls ?? []).map { ChatToolCall(id: $0.id, name: $0.name, argsPreview: $0.argsPreview) },
            toolResult: toolResult.map { ChatToolResult(toolName: $0.toolName, isError: $0.isError, preview: $0.preview) }
        )
    }
}

extension ChatMessage {
    /// Maps the bridge's compact transcript dict (A) straight to a ChatMessage — no
    /// JSONEncoder/JSONDecoder roundtrip (this runs per backlog message).
    static func fromTranscriptDict(_ raw: [String: Any], id: String) -> ChatMessage? {
        guard let role = raw["role"] as? String else { return nil }
        let calls: [ChatToolCall] = (raw["toolCalls"] as? [[String: Any]] ?? []).map {
            ChatToolCall(id: ($0["id"] as? String) ?? "",
                         name: ($0["name"] as? String) ?? "tool",
                         argsPreview: ($0["argsPreview"] as? String) ?? "")
        }
        var result: ChatToolResult? = nil
        if let tr = raw["toolResult"] as? [String: Any] {
            result = ChatToolResult(
                toolCallId: tr["toolCallId"] as? String,
                toolName: (tr["toolName"] as? String) ?? "tool",
                isError: (tr["isError"] as? Bool) ?? false,
                preview: (tr["preview"] as? String) ?? "")
        }
        return ChatMessage(id: id, role: role,
                           text: raw["text"] as? String, thinking: raw["thinking"] as? String,
                           toolCalls: calls, toolResult: result)
    }

    /// Maps a raw Pi `message` object (B: RPC `message_end` events) to a ChatMessage.
    static func fromRawMessage(_ m: [String: Any], id: String) -> ChatMessage? {
        guard let role = m["role"] as? String else { return nil }
        var texts: [String] = []
        var thinks: [String] = []
        var calls: [ChatToolCall] = []

        if let s = m["content"] as? String {
            texts.append(s)
        } else if let blocks = m["content"] as? [[String: Any]] {
            for b in blocks {
                switch b["type"] as? String {
                case "text": if let t = b["text"] as? String { texts.append(t) }
                case "thinking":
                    if let t = b["text"] as? String { thinks.append(t) }
                    else if let t = b["thinking"] as? String { thinks.append(t) }
                case "toolCall":
                    let args: String
                    if let a = b["arguments"] as? String { args = a }
                    else if let a = b["arguments"], let d = try? JSONSerialization.data(withJSONObject: a),
                            let s = String(data: d, encoding: .utf8) { args = s }
                    else { args = "" }
                    calls.append(ChatToolCall(id: (b["id"] as? String) ?? "", name: (b["name"] as? String) ?? "tool", argsPreview: args))
                default: break
                }
            }
        }

        if role == "toolResult" {
            return ChatMessage(
                id: id, role: role,
                toolResult: ChatToolResult(
                    toolCallId: m["toolCallId"] as? String,
                    toolName: (m["toolName"] as? String) ?? "tool",
                    isError: (m["isError"] as? Bool) ?? false,
                    preview: texts.joined(separator: "\n")
                )
            )
        }

        let text = texts.isEmpty ? nil : texts.joined(separator: "\n")
        let thinking = thinks.isEmpty ? nil : thinks.joined(separator: "\n")
        if text == nil, thinking == nil, calls.isEmpty { return nil }
        return ChatMessage(id: id, role: role, text: text, thinking: thinking, toolCalls: calls)
    }
}
