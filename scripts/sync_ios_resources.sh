#!/usr/bin/env bash
# 生成済みのデータを iOS アプリのバンドルへコピーする。
# （アプリ同梱ぶん = オフライン / 初回起動時のフォールバック。
#   通常は起動後に rules.json をサーバーから取り直す）
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/ios/BrawlDraftAI/Sources/Resources"
mkdir -p "$DEST"

copy() {
  local src="$1" dst="$2"
  if [ ! -f "$src" ]; then
    echo "✖ $src がありません。先に scripts/download_icons.py と scripts/update_meta.py を実行してください。" >&2
    exit 1
  fi
  cp "$src" "$dst"
  echo "  $(basename "$dst")  $(du -h "$dst" | cut -f1)"
}

echo "▶ iOS バンドルへコピー中 …"
# 端末に載せるのはローテーション版（軽い）。全マップ版が欲しければ rules.json に差し替える。
if [ -f "$ROOT/rules/rules_rotation.json" ]; then
  copy "$ROOT/rules/rules_rotation.json" "$DEST/rules.json"
else
  copy "$ROOT/rules/rules.json" "$DEST/rules.json"
fi
copy "$ROOT/assets/brawler_templates/templates.json" "$DEST/templates.json"
echo "✔ 完了: $DEST"
