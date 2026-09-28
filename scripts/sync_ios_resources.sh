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

# キャラ一覧画面（持っているキャラ管理）用のアイコン。
# borders バリアント（レアリティ色の背景付き正方形）をそのまま使う。107 体で 1MB 弱。
ICON_SRC="$ROOT/assets/brawler_icons/borders"
ICON_DEST="$DEST/BrawlerIcons"
if [ -d "$ICON_SRC" ]; then
  mkdir -p "$ICON_DEST"
  # 前回コピー分の掃除（キャラが減ることは無いはずだが、念のため）
  rm -f "$ICON_DEST"/*.png
  cp "$ICON_SRC"/*.png "$ICON_DEST"/
  n=$(ls "$ICON_DEST" | wc -l | tr -d ' ')
  echo "  BrawlerIcons/  ${n} 枚  $(du -sh "$ICON_DEST" | cut -f1)"
else
  echo "  ⚠️ $ICON_SRC が無いので、キャラアイコンは同梱しません（先に download_icons.py を実行してください）" >&2
fi

echo "✔ 完了: $DEST"
