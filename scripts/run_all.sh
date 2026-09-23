#!/usr/bin/env bash
# 一連の更新とテストをまとめて実行する。
#
#   ./scripts/run_all.sh            通常の更新 + テスト
#   ./scripts/run_all.sh --no-test  データ生成だけ
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PY="${PYTHON:-python3}"

RUN_TESTS=1
ARGS=()
for a in "$@"; do
  if [ "$a" = "--no-test" ]; then RUN_TESTS=0; else ARGS+=("$a"); fi
done

echo "═══ 1/5 キャラアイコン ═══"
"$PY" scripts/download_icons.py ${ARGS[@]+"${ARGS[@]}"}

echo
echo "═══ 2/5 ルールデータ生成 ═══"
"$PY" scripts/update_meta.py --rotation-out rules/rules_rotation.json

echo
echo "═══ 3/5 生成物の検証 ═══"
"$PY" scripts/validate_rules.py rules/rules.json

echo
echo "═══ 4/5 iOS バンドルへ同梱 ═══"
bash scripts/sync_ios_resources.sh

if [ "$RUN_TESTS" -eq 1 ]; then
  echo
  echo "═══ 5/5 テスト ═══"
  echo "── 認識コアの結合テスト ──"
  bash scripts/run_swift_e2e.sh
  echo
  echo "── 枠検出（キャリブレーション）のセルフテスト ──"
  bash scripts/calibrate_layout.sh --self-test
else
  echo
  echo "═══ 5/5 テスト（--no-test のためスキップ）═══"
fi

echo
echo "✔ すべて完了。iOS 側をビルドするには:"
echo "    cd ios/BrawlDraftAI && xcodegen generate && open BrawlDraftAI.xcodeproj"
