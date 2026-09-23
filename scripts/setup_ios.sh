#!/usr/bin/env bash
# iOS プロジェクトを開ける状態にする。
#
#   ./scripts/setup_ios.sh                 # チーム ID を証明書から自動検出
#   ./scripts/setup_ios.sh --team ABCDE12345 --bundle com.you.app
#
# Local.xcconfig（.gitignore 済み）を作ってから xcodegen を回す。
# project.yml に署名設定を書かないのは、GitHub に載せないためと、
# xcodegen generate のたびに Xcode 上の設定が消えるのを防ぐため。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$ROOT/ios/BrawlDraftAI"
CONFIG="$IOS_DIR/Local.xcconfig"

TEAM=""
BUNDLE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --team)   TEAM="${2:-}"; shift 2 ;;
    --bundle) BUNDLE="${2:-}"; shift 2 ;;
    *) echo "不明な引数: $1" >&2; exit 2 ;;
  esac
done

# チーム ID を署名証明書から拾う
if [ -z "$TEAM" ] && [ -f "$CONFIG" ]; then
  TEAM="$(awk -F'= *' '/^DEVELOPMENT_TEAM/{print $2}' "$CONFIG" | tr -d ' ')"
  [ "$TEAM" = "CHANGEME" ] && TEAM=""
fi
if [ -z "$TEAM" ]; then
  TEAM="$(security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | tr ',' '\n' | awk -F'=' '/OU/{gsub(/ /,"",$2); print $2}' | head -1)"
fi
if [ -z "$TEAM" ]; then
  echo "✖ チーム ID を自動検出できませんでした。" >&2
  echo "  Xcode > Settings > Accounts で Apple ID を追加してから再実行するか、" >&2
  echo "  ./scripts/setup_ios.sh --team ABCDE12345 のように指定してください。" >&2
  exit 1
fi

if [ -z "$BUNDLE" ] && [ -f "$CONFIG" ]; then
  BUNDLE="$(awk -F'= *' '/^PRODUCT_BUNDLE_IDENTIFIER/{print $2}' "$CONFIG" | tr -d ' ')"
fi
[ -n "$BUNDLE" ] || BUNDLE="com.example.brawldraftai"

cat > "$CONFIG" <<CFGEOF
// scripts/setup_ios.sh が生成。手で編集して構いません（.gitignore 済み）。
DEVELOPMENT_TEAM = $TEAM
PRODUCT_BUNDLE_IDENTIFIER = $BUNDLE
CFGEOF

echo "▶ $CONFIG"
echo "    DEVELOPMENT_TEAM          = $TEAM"
echo "    PRODUCT_BUNDLE_IDENTIFIER = $BUNDLE"
case "$BUNDLE" in
  com.example.*)
    echo "  ⚠️ バンドル ID が com.example.* のままです。Apple 全体で一意なので、"
    echo "     他人に登録済みだと実機ビルドが失敗します。失敗したら --bundle で変更してください。" ;;
esac

echo "▶ xcodegen でプロジェクトを生成中 …"
cd "$IOS_DIR"
xcodegen generate
echo "✔ 完了:  open $IOS_DIR/BrawlDraftAI.xcodeproj"
