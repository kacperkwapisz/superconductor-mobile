import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { readFile, open, stat } from "node:fs/promises";

const SESSIONS_ROOT = join(homedir(), ".pi", "agent", "sessions");
const PREVIEW_LIMIT = 2000;

export type ChatMessage = {
  role: "user" | "assistant" | "toolResult" | "system" | "custom";
  ts?: string;
  text?: string;
  thinking?: string;
  toolCalls?: { id: string; name: string; argsPreview: string }[];
  toolResult?: { toolCallId: string; toolName: string; isError: boolean; preview: string };
  model?: string;
};

/** Only allow reading Pi session transcripts under ~/.pi/agent/sessions (trust boundary). */
export function isSafeSessionPath(p: string): boolean {
  if (!p.endsWith(".jsonl")) return false;
  const real = resolve(p);
  return real.startsWith(SESSIONS_ROOT + "/");
}

function preview(s: string): string {
  return s.length > PREVIEW_LIMIT ? s.slice(0, PREVIEW_LIMIT) + "\n…[truncated]" : s;
}

/** Map one parsed JSONL `message` entry to a compact ChatMessage, or null to skip. */
export function mapEntry(entry: unknown): ChatMessage | null {
  if (!entry || typeof entry !== "object") return null;
  const e = entry as Record<string, unknown>;
  if (e.type !== "message" || !e.message || typeof e.message !== "object") return null;
  const m = e.message as Record<string, unknown>;
  const role = m.role as ChatMessage["role"];
  const content = m.content;
  const out: ChatMessage = { role, ts: m.timestamp as string | undefined };
  if (typeof m.model === "string") out.model = m.model;

  const texts: string[] = [];
  const thinks: string[] = [];
  const toolCalls: { id: string; name: string; argsPreview: string }[] = [];

  if (typeof content === "string") {
    texts.push(content);
  } else if (Array.isArray(content)) {
    for (const blk of content) {
      if (!blk || typeof blk !== "object") continue;
      const b = blk as Record<string, unknown>;
      switch (b.type) {
        case "text":
          if (typeof b.text === "string") texts.push(b.text);
          break;
        case "thinking":
          if (typeof b.text === "string") thinks.push(b.text);
          else if (typeof b.thinking === "string") thinks.push(b.thinking);
          break;
        case "toolCall":
          toolCalls.push({
            id: String(b.id ?? ""),
            name: String(b.name ?? "tool"),
            argsPreview: preview(typeof b.arguments === "string" ? b.arguments : JSON.stringify(b.arguments ?? {})),
          });
          break;
      }
    }
  }

  if (role === "toolResult") {
    out.toolResult = {
      toolCallId: String(m.toolCallId ?? ""),
      toolName: String(m.toolName ?? "tool"),
      isError: m.isError === true,
      preview: preview(texts.join("\n")),
    };
    return out;
  }

  if (texts.length) out.text = texts.join("\n");
  if (thinks.length) out.thinking = thinks.join("\n");
  if (toolCalls.length) out.toolCalls = toolCalls;
  // Skip empty system/custom noise but keep anything with content.
  if (!out.text && !out.thinking && !out.toolCalls && !out.toolResult) return null;
  return out;
}

/** Parse a full JSONL transcript file into ChatMessages. Missing file => empty (new session). */
export async function parseTranscript(path: string): Promise<ChatMessage[]> {
  let raw: string;
  try {
    raw = await readFile(path, "utf8");
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ENOENT") return [];
    throw e;
  }
  return parseJsonl(raw);
}

export function parseJsonl(raw: string): ChatMessage[] {
  const out: ChatMessage[] = [];
  for (const line of raw.split("\n")) {
    const msg = parseJsonlLine(line);
    if (msg) out.push(msg);
  }
  return out;
}

function parseJsonlLine(line: string): ChatMessage | null {
  const t = line.trim();
  if (!t) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(t);
  } catch {
    return null;
  }
  return mapEntry(parsed);
}

/** Incremental tail: read only bytes appended since `state.offset`. */
export type TailState = { offset: number; partial: string };

export async function tailNewMessages(path: string, state: TailState): Promise<ChatMessage[]> {
  let size: number;
  try {
    size = (await stat(path)).size;
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ENOENT") return [];
    throw e;
  }
  if (size < state.offset) state.offset = 0; // truncated / rotated
  if (size === state.offset) return [];

  const fh = await open(path, "r");
  try {
    const len = size - state.offset;
    const buf = Buffer.alloc(len);
    const { bytesRead } = await fh.read(buf, 0, len, state.offset);
    state.offset += bytesRead;
    const chunk = state.partial + buf.subarray(0, bytesRead).toString("utf8");
    const lines = chunk.split("\n");
    state.partial = lines.pop() ?? "";
    const out: ChatMessage[] = [];
    for (const line of lines) {
      const msg = parseJsonlLine(line);
      if (msg) out.push(msg);
    }
    return out;
  } finally {
    await fh.close();
  }
}

// --- self-check (ponytail) ---
if (import.meta.main) {
  const sample = [
    JSON.stringify({ type: "session" }),
    JSON.stringify({ type: "message", message: { role: "user", content: [{ type: "text", text: "hi" }] } }),
    JSON.stringify({
      type: "message",
      message: {
        role: "assistant",
        model: "claude",
        content: [
          { type: "thinking", text: "hmm" },
          { type: "text", text: "doing it" },
          { type: "toolCall", id: "t1", name: "bash", arguments: { cmd: "ls" } },
        ],
      },
    }),
    JSON.stringify({ type: "message", message: { role: "toolResult", toolName: "bash", isError: false, content: [{ type: "text", text: "out" }] } }),
  ].join("\n");
  const msgs = parseJsonl(sample);
  if (msgs.length !== 3) throw new Error(`expected 3 messages, got ${msgs.length}`);
  if (msgs[0]!.role !== "user" || msgs[0]!.text !== "hi") throw new Error("user map failed");
  if (msgs[1]!.text !== "doing it" || msgs[1]!.thinking !== "hmm" || msgs[1]!.toolCalls?.[0]!.name !== "bash") throw new Error("assistant map failed");
  if (msgs[2]!.toolResult?.toolName !== "bash" || msgs[2]!.toolResult?.preview !== "out") throw new Error("toolResult map failed");
  if (isSafeSessionPath("/etc/passwd") || isSafeSessionPath("/tmp/x.jsonl")) throw new Error("path guard too loose");
  console.log("transcript.ts self-check OK");
}
