#!/usr/bin/env bash
# スクリーンショット 1 枚から、枠合わせの初期値を自動で求める。
#
#   ./scripts/calibrate_layout.sh path/to/draft.png
#   ./scripts/calibrate_layout.sh path/to/draft.png --adopt     # 既定プロファイルへ反映
#   ./scripts/calibrate_layout.sh --self-test                   # 合成画像で探索器を検証
#
# 画像全体をマルチスケールで走査してキャラアイコンとマップ画像を見つけるので、
# 既定の枠がどれだけズレていても関係なく動く。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/ios/BrawlDraftAI/Sources"
BUILD="${TMPDIR:-/tmp}/brawldraft-calibrate"
rm -rf "$BUILD"; mkdir -p "$BUILD"

cp "$ROOT/ios/BrawlDraftAI/Tests/CalibrateMain.swift" "$BUILD/main.swift"
for f in RulesModels RulesStore TemplateMatcher ImageDescriptor \
         ScreenLayout DraftState DraftAnalyzer Recommender AppSettings; do
  cp "$SRC/Core/$f.swift" "$BUILD/$f.swift"
done

ARCH="$(uname -m)"
swiftc -O -target "${ARCH}-apple-macos14.0" "$BUILD"/*.swift -o "$BUILD/calibrate"

if [ "${1:-}" = "--self-test" ]; then
  # 合成ドラフト画面で「探索器そのもの」を検証する。
  # ⚠️ ここで得られる枠は合成画像の配置であって、実機ゲーム画面の配置ではない。
  #    既定プロファイルへは反映しない（--adopt を付けない）。
  IMG="$ROOT/assets/synthetic_draft_test.png"
  [ -f "$IMG" ] || { echo "✖ $IMG がありません。先に ./scripts/run_swift_e2e.sh を実行してください。" >&2; exit 1; }
  echo "▶ セルフテスト: 合成ドラフト画面から枠を復元できるか"
  BRAWLDRAFT_ROOT="$ROOT" "$BUILD/calibrate" "$IMG" \
    --out "$ROOT/assets/calibration_selftest.json" \
    --name "セルフテスト（合成画像・実機用ではない）" \
    --expect-map "Alchemy" \
    --expect-picks "Piper,Poco,Bull,Mortis,Barley"
  exit $?
fi

BRAWLDRAFT_ROOT="$ROOT" "$BUILD/calibrate" "$@"
