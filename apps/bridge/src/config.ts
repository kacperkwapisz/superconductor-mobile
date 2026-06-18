import { homedir } from "node:os";
import { join } from "node:path";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { randomBytes, createHash } from "node:crypto";

const CONFIG_DIR = join(homedir(), ".superconductor-mobile");
const CONFIG_PATH = join(CONFIG_DIR, "bridge.json");

export type BridgeConfig = {
  token: string;
  fingerprint: string;
  port: number;
  bind: string;
};

export async function loadOrCreateConfig(): Promise<BridgeConfig> {
  await mkdir(CONFIG_DIR, { recursive: true });
  try {
    const raw = await readFile(CONFIG_PATH, "utf8");
    const parsed = JSON.parse(raw) as BridgeConfig;
    if (parsed.token && parsed.fingerprint) return parsed;
  } catch {
    /* create */
  }
  const token = randomBytes(32).toString("base64url");
  const fingerprint = createHash("sha256").update(token).digest("hex").slice(0, 16);
  const config: BridgeConfig = {
    token,
    fingerprint,
    port: Number(process.env.SC_MOBILE_BRIDGE_PORT ?? 9477),
    bind: process.env.SC_MOBILE_BRIDGE_BIND ?? "0.0.0.0",
  };
  await writeFile(CONFIG_PATH, JSON.stringify(config, null, 2), "utf8");
  return config;
}

export function configPath(): string {
  return CONFIG_PATH;
}