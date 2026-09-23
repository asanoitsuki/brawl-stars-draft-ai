#!/usr/bin/env bash
# 枠合わせのツール群。
#
#   ./scripts/calibrate_layout.sh --self-test
#       AutoDetector（アプリの「枠合わせ」が使う、既定位置からのスナップ方式）を
#       合成画像で検証する。実際にアプリが使っている経路そのものをテストする。
#
#   ./scripts/calibrate_layout.sh <screenshot.png>
#       画面全体をブラインドで総当たりスキャンする診断ツール（診断用途）。
#       ⚠️ ブロスタのキャラ選択画面は常に全キャラが並ぶ一覧グリッドを含むため、
#          このグリッドが誤検出のノイズ源になり、単体では実用的な初期値を出せない
#          ことが実機検証で分かっている。実際のキャリブレーションはアプリ内の
#          「枠合わせ」画面（AutoDetector = 既定位置からのスナップ方式）を使うこと。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/ios/BrawlDraftAI/Sources"
BUILD="${TMPDIR:-/tmp}/brawldraft-calibrate"
rm -rf "$BUILD"; mkdir -p "$BUILD"

CORE_FILES=(RulesModels RulesStore TemplateMatcher ImageDescriptor
            ScreenLayout DraftState DraftAnalyzer Recommender AppSettings
            ModeRecognizer AutoDetector)

build() {
  local main="$1" out="$2"
  cp "$main" "$BUILD/main.swift"
  for f in "${CORE_FILES[@]}"; do cp "$SRC/Core/$f.swift" "$BUILD/$f.swift"; done
  swiftc -O -target "$(uname -m)-apple-macos14.0" "$BUILD"/*.swift -o "$out"
}

if [ "${1:-}" = "--self-test" ]; then
  IMG="$ROOT/assets/synthetic_draft_test.png"
  [ -f "$IMG" ] || { echo "✖ $IMG がありません。先に ./scripts/run_swift_e2e.sh を実行してください。" >&2; exit 1; }
  echo "▶ ビルド中 …"
  build "$ROOT/ios/BrawlDraftAI/Tests/AutoDetectSelfTest.swift" "$BUILD/selftest"
  echo "▶ 実行"
  BRAWLDRAFT_ROOT="$ROOT" "$BUILD/selftest"
  exit $?
fi

echo "▶ ビルド中 …"
build "$ROOT/ios/BrawlDraftAI/Tests/CalibrateMain.swift" "$BUILD/calibrate"
BRAWLDRAFT_ROOT="$ROOT" "$BUILD/calibrate" "$@"
