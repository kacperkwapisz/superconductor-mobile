#!/usr/bin/env bash
# Liquid Glass icon: opaque full-bleed base + glass foreground (no black corners).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$ROOT/SuperconductorMobile/AppIcon.icon/Assets"
ICNS="/Applications/Superconductor.app/Contents/Resources/Superconductor.icns"

[[ -f "$ICNS" ]] || { echo "Install Superconductor.app first." >&2; exit 1; }
mkdir -p "$ASSETS"

export ICNS ASSETS
python3 <<'PY'
from PIL import Image, ImageDraw
import subprocess, tempfile, os, json

ICNS = os.environ["ICNS"]
ASSETS = os.environ["ASSETS"]
BUNDLE = os.path.dirname(ASSETS)

src = tempfile.mktemp(suffix=".png")
subprocess.run(["sips", "-s", "format", "png", ICNS, "--out", src], check=True, capture_output=True)
im = Image.open(src).convert("RGBA")
bbox = im.split()[3].getbbox()
crop = im.crop(bbox)
cw, ch = crop.size

opaque = [p[:3] for p in crop.getdata() if p[3] > 128]
rs, gs, bs = [sorted(c) for c in zip(*opaque)] if opaque else ([229],[229],[229])
m = len(rs) // 2
bg_rgb = (rs[m], gs[m], bs[m])
fill_str = f"srgb:{bg_rgb[0]/255:.6f},{bg_rgb[1]/255:.6f},{bg_rgb[2]/255:.6f},1.0"

SIZE = 1024
# Opaque plate — entire canvas (shows through any foreground transparency)
plate = Image.new("RGB", (SIZE, SIZE), bg_rgb)
plate.save(os.path.join(ASSETS, "BackgroundFull.png"), "PNG")

# Foreground: artwork only, centered on transparent 1024 (glass layer)
pad = int(SIZE * 0.06)
scale = min((SIZE - 2 * pad) / cw, (SIZE - 2 * pad) / ch)
nw, nh = max(1, int(cw * scale)), max(1, int(ch * scale))
resized = crop.resize((nw, nh), Image.Resampling.LANCZOS)
fg = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
fg.paste(resized, ((SIZE - nw) // 2, (SIZE - nh) // 2), resized)
fg.save(os.path.join(ASSETS, "ForegroundGlass.png"), "PNG")

icon = {
  "fill": fill_str,
  "groups": [
    {
      "name": "Base",
      "lighting": "combined",
      "specular": False,
      "translucency": 0.0,
      "layers": [
        {
          "name": "Background",
          "image-name": "BackgroundFull.png",
          "glass": False,
          "opacity": 1.0,
        }
      ],
    },
    {
      "name": "Mark",
      "lighting": "individual",
      "specular": True,
      "translucency": 0.35,
      "shadow": {"kind": "neutral", "opacity": 0.45},
      "layers": [
        {
          "name": "Foreground",
          "image-name": "ForegroundGlass.png",
          "glass": True,
          "opacity": 1.0,
        }
      ],
    },
  ],
  "supported-platforms": {"squares": "shared"},
}

with open(os.path.join(BUNDLE, "icon.json"), "w") as f:
  json.dump(icon, f, indent=2)
  f.write("\n")

print(f"Glass icon: fill {bg_rgb}, base opaque + foreground glass")
PY

rm -f "$ASSETS/Foreground.png" "$ASSETS/Background.png" "$ASSETS/AppIconOpaque.png" 2>/dev/null || true
echo "Updated AppIcon.icon — rebuild app to refresh Home Screen icon."