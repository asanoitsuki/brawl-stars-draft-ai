#!/usr/bin/env bash
# iOS アプリの認識コアを macOS 上で通しで動かす結合テスト。
#
#   * rules.json / templates.json を実データで読み込む
#   * 既知のマップ画像とキャラアイコンから「ドラフト画面のような画像」を合成する
#   * 切り出し → 記述子 → テンプレートマッチ → ピック順判定 → 提案 まで通す
#   * 認識結果が仕込んだ内容と一致するか検証し、処理時間も出す
#
# シミュレータも実機も要らないので、CI でもローカルでもそのまま走る。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/ios/BrawlDraftAI/Sources"
BUILD="${TMPDIR:-/tmp}/brawldraft-e2e"
rm -rf "$BUILD"
mkdir -p "$BUILD"

# SwiftUI / Photos に依存しないコアだけを集める。
# 直前に生成スクリプトが走っていると mtime の粒度で swiftc が
# 「ビルド中にファイルが変更された」と誤検出するため、必ず複製してから渡す。
cp "$ROOT/ios/BrawlDraftAI/Tests/E2EMain.swift" "$BUILD/main.swift"
for f in RulesModels RulesStore TemplateMatcher ImageDescriptor \
         ScreenLayout DraftState DraftAnalyzer Recommender AppSettings ModeRecognizer; do
  cp "$SRC/Core/$f.swift" "$BUILD/$f.swift"
done

ARCH="$(uname -m)"
echo "▶ ビルド中 …"
swiftc -O -target "${ARCH}-apple-macos14.0" "$BUILD"/*.swift -o "$BUILD/e2e"

echo "▶ 実行"
BRAWLDRAFT_ROOT="$ROOT" "$BUILD/e2e"
