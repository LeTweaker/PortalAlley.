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
  # v1.3: surfaces, boundary styles, Resize/Rotate (default style: subtle cut edge)
  "19_floor_portal|0,1.55,0.35|0,0,-1.7|&mode=floor"
  "20_floor_oblique|1.0,1.5,0.6|0,0,-1.6|&mode=floor"
  "21_ceiling_portal|0,1.35,0.2|0,2.6,-1.5|&mode=ceiling"
  "22_ceiling_oblique|0.8,1.4,0.4|0,2.6,-1.4|&mode=ceiling"
  "23_classic_frame|0,1.5,2.2|0,1.1,0|&style=classic"
  "24_floor_resized_rotated|0,1.55,0.35|0,0,-1.7|&mode=floor&scale=0.7&rot=30"
  "25_wall_resized_120|0,1.5,2.6|0,1.2,0|&scale=1.2"
  "26_floor_overhead_close|0,1.3,-1.15|0,0,-1.75|&mode=floor"
  "27_wall_no_bake_ios17|0,1.5,2.2|0,1.1,0|&noBake=1"
)
for v in "${VIEWS[@]}"; do
  IFS="|" read -r name eye look extra <<<"$v"
  url="http://127.0.0.1:$PORT/Tools/preview/index.html?eye=$eye&look=$look$extra$EXTRA"
  "$CHROME" --headless=new --no-sandbox --use-angle=swiftshader --enable-unsafe-swiftshader \
    --ignore-gpu-blocklist --hide-scrollbars --window-size=540,1170 --virtual-time-budget=60000 \
    --screenshot="$OUT/$name.png" "$url" >/dev/null 2>&1 || echo "render failed: $name"
  echo "rendered $name"
done
