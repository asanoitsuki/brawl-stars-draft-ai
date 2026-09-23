#!/usr/bin/env bash
# GitHub Actions を使わず、Mac 上で毎日ルールデータを更新したい場合のインストーラ。
# macOS では cron ではなく launchd (LaunchAgent) を使う。
#
#   ./scripts/install_cron.sh            # 毎日 17:40 JST に実行するよう登録
#   ./scripts/install_cron.sh 03 30      # 毎日 03:30 に実行
#   ./scripts/install_cron.sh --uninstall
#   ./scripts/install_cron.sh --run-now  # 動作確認
set -euo pipefail

LABEL="com.brawldraft.metaupdate"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="$PROJECT_DIR/logs"
RUNNER="$PROJECT_DIR/scripts/run_update.sh"

HOUR="${1:-17}"
MINUTE="${2:-40}"

uninstall() {
  launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
  rm -f "$PLIST"
  echo "✔ ${LABEL} を解除しました"
}

case "${1:-}" in
  --uninstall) uninstall; exit 0 ;;
  --run-now)   exec "$RUNNER" ;;
esac

mkdir -p "$LOG_DIR" "$(dirname "$PLIST")"

# 実際の更新処理。launchd からも手動からも同じものを呼ぶ。
cat > "$RUNNER" <<'RUNEOF'
#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
PY="${PYTHON:-python3}"
echo "=== $(date '+%F %T') 更新開始 ==="
"$PY" scripts/download_icons.py
"$PY" scripts/update_meta.py --rotation-out rules/rules_rotation.json
"$PY" scripts/validate_rules.py rules/rules.json
# git リポジトリなら自動コミット（リモートがあれば push まで）
if [ -d .git ]; then
  git add -A assets rules data
  if ! git diff --cached --quiet; then
    git commit -q -m "chore(meta): ルールデータを自動更新 ($(date -u '+%F %H:%M UTC'))"
    git remote get-url origin >/dev/null 2>&1 && git push -q || true
    echo "コミットしました"
  else
    echo "変更なし"
  fi
fi
echo "=== $(date '+%F %T') 更新完了 ==="
RUNEOF
chmod +x "$RUNNER"

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${RUNNER}</string>
  </array>
  <key>WorkingDirectory</key><string>${PROJECT_DIR}</string>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>${HOUR#0}</integer>
    <key>Minute</key><integer>${MINUTE#0}</integer>
  </dict>
  <!-- スリープで実行時刻を逃した場合、復帰時に一度だけ走らせる -->
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>${LOG_DIR}/meta_update.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/meta_update.err.log</string>
</dict>
</plist>
PLISTEOF

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "✔ 登録しました: ${LABEL}  (毎日 ${HOUR}:${MINUTE})"
echo "   plist : $PLIST"
echo "   ログ  : $LOG_DIR/meta_update.log"
echo "   即実行: ./scripts/install_cron.sh --run-now"
echo "   解除  : ./scripts/install_cron.sh --uninstall"
