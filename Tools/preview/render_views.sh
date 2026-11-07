#!/usr/bin/env bash
# Renders the validation viewpoints with headless Chrome (SwiftShader WebGL2).
# Usage: Tools/preview/render_views.sh [out_dir] [extra query string]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$ROOT/docs/validation}"
EXTRA="${2:-}"
mkdir -p "$OUT"
PORT=8765
CHROME="${CHROME:-google-chrome}"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$ROOT" >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 1

# name | eye | look | extra
VIEWS=(
  "01_head_on|0,1.5,2.2|0,1.1,0|"
  "02_left_1m|-1.0,1.5,2.0|0,1.1,0|"
  "03_right_1m|1.0,1.5,2.0|0,1.1,0|"
  "04_high|0,2.0,2.0|0,1.0,0|"
  "05_low_crouch|0,0.75,1.6|0,1.5,0|"
  "06_oblique_right|2.1,1.45,1.0|0,1.1,0|"
  "07_close_0.7m|0.08,1.45,0.70|0,1.3,-1.5|"
  "08_side_edge_on|2.2,1.4,-0.02|0,1.1,0|"
  "09_rear|0.4,1.5,-2.4|0,1.1,0|"
  "10_boundary_0.4m|0,1.45,0.40|0,1.3,-1|"
  "11_far_3.5m|0.3,1.55,3.6|0,1.1,0|"
  "12_opening_half|0,1.5,2.2|0,1.1,0|&open=0.5"
  "13_low_tier|0,1.5,2.2|0,1.1,0|&quality=low"
  "14_debug_no_occluder|0,1.5,2.2|0,1.1,0|&noOccluder=1"
  "15_boundary_0.30m_veiled|0,1.45,0.30|0,1.3,-1|"
  "16_car_sweep_t1.6|0.4,1.5,2.0|0,1.1,0|&t=1.6"
  "17_opening_leaves_20pct|0,1.5,2.2|0,1.1,0|&open=0.2"
  "18_left_far_corner|-1.6,1.5,2.4|0,1.1,0|"
)
for v in "${VIEWS[@]}"; do
  IFS="|" read -r name eye look extra <<<"$v"
  url="http://127.0.0.1:$PORT/Tools/preview/index.html?eye=$eye&look=$look$extra$EXTRA"
  "$CHROME" --headless=new --no-sandbox --use-angle=swiftshader --enable-unsafe-swiftshader \
    --ignore-gpu-blocklist --hide-scrollbars --window-size=540,1170 --virtual-time-budget=60000 \
    --screenshot="$OUT/$name.png" "$url" >/dev/null 2>&1 || echo "render failed: $name"
  echo "rendered $name"
done
