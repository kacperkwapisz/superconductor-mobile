import type { ServerWebSocket } from "bun";
import { scJson, scSubscribe, ScError } from "@superconductor-mobile/sc-client";
import type { PairingPayload } from "@superconductor-mobile/protocol";
import { loadOrCreateConfig, configPath } from "./config.ts";
import { networkInterfaces, homedir } from "node:os";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { spawn } from "node:child_process";

const VERSION = "0.1.0";

type WsData = { target: string; worktree?: string; subscription?: { stop: () => void } };

function decodeTarget(encoded: string): string {
  return decodeURIComponent(encoded);
}

// Agents live in a specific worktree; sc needs --worktree to find them outside the active view.
function worktreeArgs(url: URL): string[] {
  const wt = url.searchParams.get("worktree");
  return wt ? ["--worktree", wt] : [];
}

function pickLanHost(): string {
  const nets = networkInterfaces();
  for (const name of Object.keys(nets)) {
    for (const net of nets[name] ?? []) {
      if (net.family === "IPv4" && !net.internal) {
        return net.address;
      }
    }
  }
  return "127.0.0.1";
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function unauthorized(): Response {
  return json({ ok: false, error: { code: "unauthorized", message: "Invalid bearer token" } }, 401);
}

async function main() {
  const config = await loadOrCreateConfig();
  const isManaged = process.env.SC_MOBILE_MANAGED === "1" || process.env.SC_MOBILE_MANAGED === "true";

  try {
    await scJson<unknown>(["status", "--json"]);
  } catch (e) {
    const msg = e instanceof ScError ? e.message : String(e);
    console.error(
      "\nSuperconductor is not reachable. Launch Superconductor.app, then restart the bridge.\n",
      msg,
    );
    if (!isManaged) {
      process.exit(1);
    }
  }

  const host = process.env.SC_MOBILE_BRIDGE_HOST ?? pickLanHost();

  const pairing: PairingPayload = {
    version: 1,
    host,
    port: config.port,
    token: config.token,
    fingerprint: config.fingerprint,
    tls: false,
  };

  if (!isManaged) {
    console.log(`
Superconductor Mobile Bridge v${VERSION}
──────────────────────────────────────
Listening: http://${config.bind}:${config.port}
Pairing:   saved token in ${configPath()}
LAN host:  ${host} (override SC_MOBILE_BRIDGE_HOST)

Pair this iPhone with GET /v1/pairing (requires auth) or copy token from config.
`);
  } else {
    console.log(`[bridge] listening on ${config.bind}:${config.port} (managed)`);
  }

  try {
    Bun.serve({
    port: config.port,
    hostname: config.bind,
    fetch(req, server) {
      const url = new URL(req.url);
      const auth = req.headers.get("Authorization");
      const bearer = auth?.startsWith("Bearer ") ? auth.slice(7) : null;
      const authed = bearer === config.token;

      if (url.pathname === "/v1/health") {
        return json({ ok: true, service: "superconductor-mobile-bridge", version: VERSION });
      }

      // Avatar images are loaded by <AsyncImage> which can't set headers, so accept ?token=.
      const avatarMatch = url.pathname.match(/^\/v1\/projects\/([^/]+)\/avatar$/);
      if (avatarMatch && req.method === "GET") {
        if (!authed && url.searchParams.get("token") !== config.token) return unauthorized();
        return serveAvatar(decodeURIComponent(avatarMatch[1]!))
          .catch(() => new Response("not found", { status: 404 }));
      }

      if (!authed) {
        if (url.pathname.startsWith("/v1/")) return unauthorized();
      }

      if (url.pathname === "/v1/pairing" && req.method === "GET") {
        return json(pairing);
      }

      if (url.pathname === "/v1/status" && req.method === "GET") {
        return scJson<unknown>(["status", "--json"])
          .then((body) => json(body))
          .catch((e) => json({ ok: false, error: formatErr(e) }, 502));
      }

      if (url.pathname === "/v1/agents" && req.method === "GET") {
        return listAllAgents()
          .then((agents) => json({ kind: "agents", response: { agents } }))
          .catch((e) => json({ ok: false, error: formatErr(e) }, 502));
      }

      if (url.pathname === "/v1/workspaces" && req.method === "GET") {
        return buildWorkspaceTree()
          .then((body) => json(body))
          .catch((e) => json({ ok: false, error: formatErr(e) }, 502));
      }


      const snapshotMatch = url.pathname.match(/^\/v1\/agents\/([^/]+)\/snapshot$/);
      if (snapshotMatch && req.method === "GET") {
        const target = decodeTarget(snapshotMatch[1]!);
        const last = url.searchParams.get("last") ?? "80";
        return scJson<unknown>([
          "agent",
          "read",
          "--to",
          target,
          "--last",
          last,
          ...worktreeArgs(url),
          "--output",
          "json",
        ])
          .then((body) => json(body))
          .catch((e) => json({ ok: false, error: formatErr(e) }, 502));
      }

      const sendMatch = url.pathname.match(/^\/v1\/agents\/([^/]+)\/send$/);
      if (sendMatch && req.method === "POST") {
        const target = decodeTarget(sendMatch[1]!);
        return req
          .json()
          .then((body: { text?: string; prefill?: boolean; queue?: boolean }) => {
            if (!body.text?.trim()) {
              return json({ ok: false, error: { code: "validation", message: "text required" } }, 400);
            }
            const args = ["agent", "send", "--to", target, "--prompt", body.text, ...worktreeArgs(url), "--output", "json"];
            if (body.prefill) args.push("--prefill");
            if (body.queue) args.push("--queue");
            return scJson<unknown>(args).then((result) => json({ ok: true, result }));
          })
          .catch((e) => json({ ok: false, error: formatErr(e) }, 502));
      }

      const interruptMatch = url.pathname.match(/^\/v1\/agents\/([^/]+)\/interrupt$/);
      if (interruptMatch && req.method === "POST") {
        const target = decodeTarget(interruptMatch[1]!);
        return scJson<unknown>(["agent", "interrupt", "--to", target, ...worktreeArgs(url), "--output", "json"])
          .then((result) => json({ ok: true, result }))
          .catch((e) => json({ ok: false, error: formatErr(e) }, 502));
      }

      const stopMatch = url.pathname.match(/^\/v1\/agents\/([^/]+)\/stop$/);
      if (stopMatch && req.method === "POST") {
        const target = decodeTarget(stopMatch[1]!);
        return scJson<unknown>(["agent", "stop", "--to", target, ...worktreeArgs(url), "--output", "json"])
          .then((result) => json({ ok: true, result }))
          .catch((e) => json({ ok: false, error: formatErr(e) }, 502));
      }

      if (url.pathname === "/v1/worktree/status" && req.method === "GET") {
        const worktreePath = url.searchParams.get("path");
        if (!worktreePath) {
          return json({ ok: false, error: { code: "validation", message: "path query required" } }, 400);
        }
        return scJson<unknown>(["worktree", "status", "--json"], { cwd: worktreePath })
          .then((body) => json(body))
          .catch((e) => json({ ok: false, error: formatErr(e) }, 502));
      }

      const streamMatch = url.pathname.match(/^\/v1\/agents\/([^/]+)\/stream$/);
      if (streamMatch && req.method === "GET") {
        const upgrade = req.headers.get("Upgrade")?.toLowerCase();
        if (upgrade === "websocket") {
          const target = decodeTarget(streamMatch[1]!);
          const worktree = url.searchParams.get("worktree") ?? undefined;
          const ok = server.upgrade(req, { data: { target, worktree } satisfies WsData });
          if (ok) return undefined as unknown as Response;
          return new Response("WebSocket upgrade failed", { status: 500 });
        }
      }

      return json({ ok: false, error: { code: "not_found", message: "Unknown route" } }, 404);
    },
    websocket: {
      open(ws: ServerWebSocket<WsData>) {
        const target = ws.data.target;
        const sub = scSubscribe(
          [
            "agent",
            "subscribe",
            "--to",
            target,
            "--live-only",
            ...(ws.data.worktree ? ["--worktree", ws.data.worktree] : []),
            "--output",
            "json",
          ],
          {
            onEvent: (event) => ws.send(JSON.stringify(event)),
            onError: (err) => {
              ws.send(JSON.stringify({ kind: "bridge_error", message: err.message }));
            },
            onClose: () => {
              /* sc process ended */
            },
          },
        );
        ws.data.subscription = sub;
      },
      close(ws: ServerWebSocket<WsData>) {
        ws.data.subscription?.stop();
      },
      message() {
        /* client → server not used in v1 */
      },
    },
  });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    if (msg.includes("EADDRINUSE") || msg.includes("in use")) {
      console.error(`\nPort ${config.port} is already in use. Stop the other bridge or change SC_MOBILE_BRIDGE_PORT.\n`);
    } else {
      console.error("\nFailed to start bridge server:\n", msg);
    }
    process.exit(1);
  }
}

type RawAgent = { stable_target_id: string; [k: string]: unknown };

async function listAllAgents(): Promise<RawAgent[]> {
  const { worktreesByProject, agentsByPath } = await gatherLiveAgents();
  const projectName = new Map<string, string>(); // pid -> first branch's project (unused name here)
  const byId = new Map<string, RawAgent>();
  for (const [pid, wts] of worktreesByProject) {
    for (const w of wts) {
      for (const a of agentsByPath.get(w.path) ?? []) {
        if (!byId.has(a.stable_target_id)) byId.set(a.stable_target_id, { ...a, branch: w.name, project: pid });
      }
    }
  }
  void projectName;
  return [...byId.values()];
}

// --- Workspace tree (Mac-sidebar shape): workspaces -> projects -> worktrees -> agents ---

type FeatureLabel = { automatic_label?: string; cached_pr_label?: string; first_prompt_excerpt?: string };
type WorktreeUsage = { last_interaction_at?: string };
type ProjectUIState = {
  color?: string;
  project_avatar?: { local_path?: string };
  worktree_feature_labels?: Record<string, FeatureLabel>;
  worktree_usage?: Record<string, WorktreeUsage>;
};
type SettingsProject = { id: string; name: string; main_repo_path?: string; ui_state?: ProjectUIState };
type SettingsWorkspace = { id: string; name: string; project_ids: string[] };
type Selection = { key?: { project_id?: string; worktree_name?: string }; value?: { tabs?: { working_directory_path?: string }[] } };

async function readJson<T>(...parts: string[]): Promise<T> {
  return JSON.parse(await readFile(join(homedir(), ".superconductor", ...parts), "utf8")) as T;
}

// A branch worktree lives at .../worktrees/<project>/<branch>; main worktrees use main_repo_path.
function worktreeRoot(cwd: string, branch: string, mainRepoPath?: string): string | null {
  if (branch === "main") return mainRepoPath ?? null;
  const m = cwd.match(/^(.*\/worktrees\/[^/]+\/[^/]+)/);
  return m ? m[1]! : cwd;
}

async function gitBranch(path: string): Promise<string | null> {
  return new Promise((resolve) => {
    const child = spawn("git", ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"], { stdio: ["ignore", "pipe", "ignore"] });
    let out = "";
    child.stdout.on("data", (c: Buffer) => { out += c.toString(); });
    child.on("error", () => resolve(null));
    child.on("close", () => resolve(out.trim() || null));
  });
}

type Worktree = { name: string; path: string; gitBranch: string | null };

async function gatherLiveAgents(): Promise<{
  settings: { projects: SettingsProject[]; workspaces: SettingsWorkspace[]; active_workspace_id?: string };
  worktreesByProject: Map<string, Worktree[]>;
  agentsByPath: Map<string, RawAgent[]>;
}> {
  const settings = await readJson<{ projects: SettingsProject[]; workspaces: SettingsWorkspace[]; active_workspace_id?: string }>("settings.json");
  const session = await readJson<{ selections?: Selection[] }>("session.json");
  const projectById = new Map(settings.projects.map((p) => [p.id, p]));

  const worktreesByProject = new Map<string, Worktree[]>();
  const queryPaths = new Set<string>();
  for (const sel of session.selections ?? []) {
    const pid = sel.key?.project_id;
    const name = sel.key?.worktree_name ?? "main";
    const cwd = sel.value?.tabs?.find((t) => t.working_directory_path)?.working_directory_path;
    if (!pid || !cwd) continue;
    const path = worktreeRoot(cwd, name, projectById.get(pid)?.main_repo_path);
    if (!path) continue;
    if (!worktreesByProject.has(pid)) worktreesByProject.set(pid, []);
    const list = worktreesByProject.get(pid)!;
    if (!list.some((w) => w.path === path)) list.push({ name, path, gitBranch: null });
    queryPaths.add(path);
  }

  // Live agents + git branch per worktree path, in parallel.
  const agentsByPath = new Map<string, RawAgent[]>();
  const allWorktrees = [...worktreesByProject.values()].flat();
  await Promise.all([
    ...[...queryPaths].map((path) =>
      scJson<{ response?: { agents?: RawAgent[] } }>(["agents", "list", "--worktree", path, "--output", "json"])
        .then((body) => { agentsByPath.set(path, body.response?.agents ?? []); })
        .catch(() => { agentsByPath.set(path, []); }),
    ),
    ...allWorktrees.map((w) => gitBranch(w.path).then((b) => { w.gitBranch = b; })),
  ]);

  return { settings, worktreesByProject, agentsByPath };
}

async function buildWorkspaceTree() {
  const { settings, worktreesByProject, agentsByPath } = await gatherLiveAgents();
  const projectById = new Map(settings.projects.map((p) => [p.id, p]));

  const workspaces = settings.workspaces.map((ws) => ({
    id: ws.id,
    name: ws.name,
    projects: ws.project_ids
      .map((pid) => projectById.get(pid))
      .filter((p): p is SettingsProject => !!p)
      .map((p) => {
        const labels = p.ui_state?.worktree_feature_labels ?? {};
        const usage = p.ui_state?.worktree_usage ?? {};
        const worktrees = (worktreesByProject.get(p.id) ?? []).map((w) => {
          const label = labels[w.name];
          const featureLabel = label?.automatic_label ?? label?.cached_pr_label ?? null;
          return {
            name: w.name,
            path: w.path,
            is_main: w.name === "main",
            git_branch: w.gitBranch,
            display_name: featureLabel ?? w.gitBranch ?? w.name,
            last_interaction_at: usage[w.name]?.last_interaction_at ?? null,
            agents: (agentsByPath.get(w.path) ?? []).map((a) => ({
              target: `id:${a.stable_target_id}`,
              provider_key: a.provider_key,
              state: a.state,
              capabilities: a.capabilities,
            })),
          };
        });
        return {
          id: p.id,
          name: p.name,
          color: p.ui_state?.color ?? null,
          repo_path: p.main_repo_path ?? null,
          has_avatar: !!p.ui_state?.project_avatar?.local_path,
          live_agent_count: worktrees.reduce((n, w) => n + w.agents.length, 0),
          worktrees,
        };
      }),
  }));

  return { kind: "workspaces", response: { active_workspace_id: settings.active_workspace_id ?? null, workspaces } };
}

async function serveAvatar(projectId: string): Promise<Response> {
  const settings = await readJson<{ projects: SettingsProject[] }>("settings.json");
  const local = settings.projects.find((p) => p.id === projectId)?.ui_state?.project_avatar?.local_path;
  if (!local) return new Response("not found", { status: 404 });
  const file = Bun.file(local);
  if (!(await file.exists())) return new Response("not found", { status: 404 });
  return new Response(file, { headers: { "Content-Type": "image/png", "Cache-Control": "max-age=86400" } });
}

function formatErr(e: unknown): { code: string; message: string } {
  if (e instanceof ScError) return { code: e.code, message: e.message };
  if (e instanceof Error) return { code: "error", message: e.message };
  return { code: "error", message: String(e) };
}

main();