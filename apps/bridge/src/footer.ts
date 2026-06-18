// Parse Pi's terminal status footer, e.g.:
//   " bull ⎇ main • $0.00 • 32% → 01:49 AM                      claude-opus-4-8"
//   " wt ⎇ feat/x • $2.45 • ctx 84% • 29% → 03:50 PM            claude-opus-4-8"

export type Footer = {
  model?: string;
  branch?: string;
  cost?: string;
  contextPct?: number;
  time?: string;
};

export function parseFooter(lines: string[]): Footer | null {
  // The status line is the last one carrying the branch glyph or a "• $cost" segment.
  const line = [...lines].reverse().find((l) => l.includes("⎇") || /•\s*\$/.test(l));
  if (!line) return null;

  const f: Footer = {};
  const model = line.trim().split(/\s+/).pop();
  if (model && model !== "⎇") f.model = model;

  const branch = line.match(/⎇\s*(\S+)/);
  if (branch) f.branch = branch[1];

  const cost = line.match(/\$\s*([\d.]+)/);
  if (cost) f.cost = cost[1];

  // Prefer "ctx NN%"; else the percentage right before the time arrow.
  const ctx = line.match(/ctx\s*(\d+)%/) ?? line.match(/(\d+)%\s*→/);
  if (ctx) f.contextPct = parseInt(ctx[1]!, 10);

  const time = line.match(/→\s*(\d{1,2}:\d{2}\s*[AP]M)/i);
  if (time) f.time = time[1];

  return f;
}

// --- self-check (ponytail) ---
if (import.meta.main) {
  const a = parseFooter([" bull ⎇ main • $0.00 • 32% → 01:49 AM                claude-opus-4-8"]);
  if (!a || a.model !== "claude-opus-4-8" || a.branch !== "main" || a.cost !== "0.00" || a.contextPct !== 32 || a.time !== "01:49 AM")
    throw new Error("footer A parse failed: " + JSON.stringify(a));
  const b = parseFooter([" wt ⎇ feat/x • $2.45 • ctx 84% • 29% → 03:50 PM       claude-opus-4-8"]);
  if (!b || b.contextPct !== 84 || b.cost !== "2.45" || b.branch !== "feat/x")
    throw new Error("footer B parse failed: " + JSON.stringify(b));
  if (parseFooter(["just some content", "no footer here"]) !== null) throw new Error("false positive");
  console.log("footer.ts self-check OK");
}
