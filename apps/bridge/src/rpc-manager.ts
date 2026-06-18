import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

function resolvePiPath(): string {
  const candidates = [
    process.env.PI_BIN,
    join(homedir(), ".superconductor", "bin", "pi"),
    "/usr/local/bin/pi",
    "/opt/homebrew/bin/pi",
  ].filter(Boolean) as string[];
  for (const c of candidates) if (existsSync(c)) return c;
  return "pi"; // last resort: rely on PATH
}

export type RpcSpawnOptions = { worktree: string; provider?: string; model?: string; name?: string };

type Subscriber = (event: unknown) => void;

class RpcAgent {
  readonly id = randomUUID();
  readonly createdAt = Date.now();
  status: "running" | "exited" = "running";
  private buffer: unknown[] = [];
  private subscribers = new Set<Subscriber>();
  private stdoutBuf = "";
  private child: ChildProcessWithoutNullStreams;

  constructor(readonly opts: RpcSpawnOptions) {
    const args = ["--mode", "rpc"];
    if (opts.provider) args.push("--provider", opts.provider);
    if (opts.model) args.push("--model", opts.model);
    if (opts.name) args.push("--name", opts.name);
    this.child = spawn(resolvePiPath(), args, {
      cwd: opts.worktree,
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env },
    }) as ChildProcessWithoutNullStreams;

    this.child.stdout.on("data", (c: Buffer) => this.onStdout(c.toString()));
    this.child.stderr.on("data", () => { /* pi draws TUI escapes to stderr; ignore */ });
    this.child.on("exit", (code) => {
      this.status = "exited";
      this.emit({ type: "rpc_exit", code });
    });
    this.child.on("error", (e) => this.emit({ type: "rpc_error", message: String(e) }));
  }

  // Strict JSONL framing: split on \n only, strip trailing \r (per rpc.md).
  private onStdout(chunk: string) {
    this.stdoutBuf += chunk;
    let nl: number;
    while ((nl = this.stdoutBuf.indexOf("\n")) >= 0) {
      let line = this.stdoutBuf.slice(0, nl);
      this.stdoutBuf = this.stdoutBuf.slice(nl + 1);
      if (line.endsWith("\r")) line = line.slice(0, -1);
      const t = line.trim();
      if (!t) continue;
      let event: unknown;
      try { event = JSON.parse(t); } catch { continue; }
      this.emit(event);
    }
  }

  private emit(event: unknown) {
    // ponytail: cap replay buffer at 5000 events; older history drops if a run is huge.
    this.buffer.push(event);
    if (this.buffer.length > 5000) this.buffer.splice(0, this.buffer.length - 5000);
    for (const s of this.subscribers) s(event);
  }

  attach(sub: Subscriber): () => void {
    for (const e of this.buffer) sub(e); // replay history
    this.subscribers.add(sub);
    return () => this.subscribers.delete(sub);
  }

  send(command: Record<string, unknown>) {
    if (this.status !== "running") return;
    this.child.stdin.write(JSON.stringify(command) + "\n");
  }

  stop() {
    try { this.child.kill("SIGTERM"); } catch { /* already gone */ }
  }

  meta() {
    return {
      id: this.id,
      worktree: this.opts.worktree,
      name: this.opts.name ?? null,
      model: this.opts.model ?? null,
      provider: this.opts.provider ?? null,
      status: this.status,
      created_at: this.createdAt,
    };
  }
}

const agents = new Map<string, RpcAgent>();

export function spawnRpcAgent(opts: RpcSpawnOptions): RpcAgent {
  const agent = new RpcAgent(opts);
  agents.set(agent.id, agent);
  return agent;
}

export function getRpcAgent(id: string): RpcAgent | undefined {
  return agents.get(id);
}

export function listRpcAgents() {
  return [...agents.values()].map((a) => a.meta());
}

export function stopRpcAgent(id: string): boolean {
  const a = agents.get(id);
  if (!a) return false;
  a.stop();
  agents.delete(id);
  return true;
}

export type { RpcAgent };
