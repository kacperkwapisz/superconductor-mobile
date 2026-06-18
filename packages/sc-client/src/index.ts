import { homedir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";

const DEFAULT_SC = join(homedir(), ".superconductor", "bin", "sc");

export type ScRunOptions = {
  scPath?: string;
  cwd?: string;
  env?: NodeJS.ProcessEnv;
};

export async function resolveScPath(override?: string): Promise<string> {
  if (override) return override;
  return DEFAULT_SC;
}

export async function readLocalApiDiscovery(): Promise<{
  version: number;
  socket_path: string;
  pid: number;
}> {
  const path = join(homedir(), ".superconductor", "local-api.json");
  const raw = await readFile(path, "utf8");
  return JSON.parse(raw) as {
    version: number;
    socket_path: string;
    pid: number;
  };
}

export async function scJson<T>(
  args: string[],
  options: ScRunOptions = {},
): Promise<T> {
  const scPath = await resolveScPath(options.scPath);
  const stdout = await scRaw(args, { ...options, scPath });
  const trimmed = stdout.trim();
  if (!trimmed) {
    throw new ScError("empty_output", "sc produced no output");
  }
  const lastLine = trimmed.includes("\n")
    ? trimmed.split("\n").filter(Boolean).at(-1)!
    : trimmed;
  let parsed: unknown;
  try {
    parsed = JSON.parse(lastLine);
  } catch {
    throw new ScError("invalid_json", `Could not parse sc output: ${lastLine.slice(0, 200)}`);
  }
  const obj = parsed as { kind?: string; error?: { code: string; message: string } };
  if (obj.kind === "cli_error" && obj.error) {
    throw new ScError(obj.error.code, obj.error.message);
  }
  return parsed as T;
}

export async function scRaw(
  args: string[],
  options: ScRunOptions & { scPath?: string } = {},
): Promise<string> {
  const scPath = options.scPath ?? (await resolveScPath());
  return new Promise((resolve, reject) => {
    const child = spawn(scPath, args, {
      cwd: options.cwd,
      env: { ...process.env, ...options.env },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let out = "";
    let err = "";
    child.stdout.on("data", (c: Buffer) => {
      out += c.toString();
    });
    child.stderr.on("data", (c: Buffer) => {
      err += c.toString();
    });
    child.on("error", (e) => reject(e));
    child.on("close", (code) => {
      if (code !== 0) {
        reject(new ScError("sc_exit", err || out || `sc exited ${code}`));
        return;
      }
      resolve(out);
    });
  });
}

export class ScError extends Error {
  constructor(
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "ScError";
  }
}

export type SubscribeHandlers = {
  onEvent: (event: unknown) => void;
  onError: (error: Error) => void;
  onClose: (code: number | null) => void;
};

/** Spawns `sc agent subscribe` and parses newline-delimited JSON events. */
export function scSubscribe(
  args: string[],
  handlers: SubscribeHandlers,
  options: ScRunOptions = {},
): { stop: () => void } {
  let scPath = DEFAULT_SC;
  let buffer = "";
  let child: ReturnType<typeof spawn> | null = null;

  void resolveScPath(options.scPath).then((p) => {
    scPath = p;
    child = spawn(scPath, args, {
      cwd: options.cwd,
      env: { ...process.env, ...options.env },
      stdio: ["ignore", "pipe", "pipe"],
    });

    child.stdout?.on("data", (chunk: Buffer) => {
      buffer += chunk.toString();
      let idx: number;
      while ((idx = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, idx).trim();
        buffer = buffer.slice(idx + 1);
        if (!line) continue;
        try {
          handlers.onEvent(JSON.parse(line));
        } catch (e) {
          handlers.onError(e instanceof Error ? e : new Error(String(e)));
        }
      }
    });

    child.stderr?.on("data", (chunk: Buffer) => {
      const text = chunk.toString().trim();
      if (text) handlers.onError(new ScError("subscribe_stderr", text));
    });

    child.on("error", (e) => handlers.onError(e));
    child.on("close", (code) => handlers.onClose(code));
  });

  return {
    stop: () => {
      if (child && !child.killed) {
        child.kill("SIGTERM");
      }
    },
  };
}