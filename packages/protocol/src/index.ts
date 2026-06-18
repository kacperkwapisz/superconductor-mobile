/** Shared contract between Mac bridge and iOS client (JSON field names stable). */

export type BridgeHealth = {
  ok: true;
  service: "superconductor-mobile-bridge";
  version: string;
};

export type BridgeError = {
  ok: false;
  error: { code: string; message: string };
};

export type PairingPayload = {
  version: 1;
  host: string;
  port: number;
  token: string;
  fingerprint: string;
  tls: boolean;
};

export type AgentSummary = {
  stable_target_id: string;
  current_selector: string;
  ui: string;
  provider_key: string;
  state: string;
  phase: string;
  label?: string;
};

export type TerminalSnapshotPayload = {
  ok: boolean;
  stable_target_id?: string;
  provider_key?: string;
  ui?: string;
  content_mode?: string;
  lines?: string[];
  session_id?: string;
  conversation_id?: string;
};

export type AgentStreamEvent = {
  kind: "agent_event";
  type: string;
  sequence: number;
  timestamp_ms: number;
  stable_target_id?: string;
  payload?: TerminalSnapshotPayload;
};

export type SendMessageRequest = {
  text: string;
  prefill?: boolean;
  queue?: boolean;
};

export type SendMessageResponse = {
  ok: boolean;
  result?: unknown;
  error?: { code: string; message: string };
};