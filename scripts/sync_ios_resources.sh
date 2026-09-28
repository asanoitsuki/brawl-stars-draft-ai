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

# マップ一覧画面（信頼性確認用: 全マップの画像とスコア根拠を見られるようにする）用の画像。
MAP_SRC="$ROOT/assets/map_thumbs"
MAP_DEST="$DEST/MapThumbs"
if [ -d "$MAP_SRC" ]; then
  mkdir -p "$MAP_DEST"
  rm -f "$MAP_DEST"/*.png
  cp "$MAP_SRC"/*.png "$MAP_DEST"/
  n=$(ls "$MAP_DEST" | wc -l | tr -d ' ')
  echo "  MapThumbs/  ${n} 枚  $(du -sh "$MAP_DEST" | cut -f1)"
else
  echo "  ⚠️ $MAP_SRC が無いので、マップ画像は同梱しません（先に update_meta.py を実行してください）" >&2
fi

# ガジェット・スターパワーの画像（現状このネットワークでは cdn.brawlify.com が
# ファイアウォールにブロックされておりダウンロードできていない可能性がある。
# 0 枚でも失敗にはせず、名前・説明文だけは rules.json 側で表示できる）。
for pair in "gadgets:Gadgets" "star_powers:StarPowers"; do
  SRC_NAME="${pair%%:*}"; DEST_NAME="${pair##*:}"
  ITEM_SRC="$ROOT/assets/$SRC_NAME"
  ITEM_DEST="$DEST/$DEST_NAME"
  if [ -d "$ITEM_SRC" ] && [ -n "$(ls -A "$ITEM_SRC" 2>/dev/null)" ]; then
    mkdir -p "$ITEM_DEST"
    rm -f "$ITEM_DEST"/*.png
    cp "$ITEM_SRC"/*.png "$ITEM_DEST"/
    n=$(ls "$ITEM_DEST" | wc -l | tr -d ' ')
    echo "  $DEST_NAME/  ${n} 枚  $(du -sh "$ITEM_DEST" | cut -f1)"
  else
    echo "  ⚠️ $ITEM_SRC に画像が無いので $DEST_NAME は同梱しません（名前・説明文のみ表示されます）" >&2
  fi
done

echo "✔ 完了: $DEST"
