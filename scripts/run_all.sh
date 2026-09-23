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
# CDN の一時的な障害（特定キャラだけ・ドメイン単位のことが多い）で
# パイプライン全体を止めたくない。既存キャッシュがあれば十分動くので、
# 失敗した場合は警告だけ出して続行する（rules 生成側は欠けたキャラを
# validate_rules.py がちゃんと警告してくれる）。
if ! "$PY" scripts/download_icons.py ${ARGS[@]+"${ARGS[@]}"}; then
  echo "  ⚠️ アイコン取得の一部が失敗しました（CDN の一時的な障害の可能性）。"
  echo "     既存のキャッシュ済みアイコンで続行します。"
fi

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
