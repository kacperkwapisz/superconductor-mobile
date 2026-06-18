import { loadOrCreateConfig } from "./config.ts";
import { networkInterfaces } from "node:os";
import type { PairingPayload } from "@superconductor-mobile/protocol";

function pickLanHost(): string {
  const nets = networkInterfaces();
  for (const name of Object.keys(nets)) {
    for (const net of nets[name] ?? []) {
      if (net.family === "IPv4" && !net.internal) return net.address;
    }
  }
  return "127.0.0.1";
}

const config = await loadOrCreateConfig();
const host = process.env.SC_MOBILE_BRIDGE_HOST ?? pickLanHost();

const payload: PairingPayload = {
  version: 1,
  host,
  port: config.port,
  token: config.token,
  fingerprint: config.fingerprint,
  tls: false,
};

console.log(JSON.stringify(payload, null, 2));
console.error("\nPaste token into the iOS app, or encode this JSON in a QR for a future scanner build.\n");