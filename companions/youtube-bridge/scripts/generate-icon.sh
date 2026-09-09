#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
menu_bar_dist="$(mktemp -d)"
trap 'rm -rf "$menu_bar_dist"' EXIT
menu_bar_resources="$repo_root/assets"
iconset="$menu_bar_dist/AppIcon.iconset"
mkdir -p "$iconset"
python3 - "$iconset" <<'PY'
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

iconset = Path(sys.argv[1])
base = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
draw = ImageDraw.Draw(base)
draw.rounded_rectangle((64, 64, 960, 960), radius=220, fill=(18, 21, 27, 255))
draw.rounded_rectangle((104, 104, 920, 920), radius=180, outline=(92, 199, 123, 255), width=28)
draw.polygon([(292, 264), (292, 760), (684, 512)], fill=(255, 255, 255, 255))
draw.rounded_rectangle((652, 272, 742, 752), radius=34, fill=(255, 255, 255, 255))
draw.rounded_rectangle((782, 272, 872, 752), radius=34, fill=(255, 255, 255, 255))
try:
  font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 124)
except Exception:
  font = ImageFont.load_default()
draw.text((174, 776), "YT", fill=(255, 48, 48, 255), font=font)
draw.text((664, 776), "SP", fill=(30, 215, 96, 255), font=font)

sizes = [
  ("icon_16x16.png", 16),
  ("icon_16x16@2x.png", 32),
  ("icon_32x32.png", 32),
  ("icon_32x32@2x.png", 64),
  ("icon_128x128.png", 128),
  ("icon_128x128@2x.png", 256),
  ("icon_256x256.png", 256),
  ("icon_256x256@2x.png", 512),
  ("icon_512x512.png", 512),
  ("icon_512x512@2x.png", 1024),
]

for name, size in sizes:
  base.resize((size, size), Image.Resampling.LANCZOS).save(iconset / name)
PY
iconutil -c icns "$iconset" -o "$menu_bar_resources/AppIcon.icns"
rm -rf "$iconset"
