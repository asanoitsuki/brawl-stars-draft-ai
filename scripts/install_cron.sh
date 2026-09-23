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

if [ "${1:-}" = "--uninstall" ]; then
  uninstall
  exit 0
fi

mkdir -p "$LOG_DIR" "$(dirname "$PLIST")"

# 実際の更新処理。launchd からも手動からも同じものを呼ぶ。
cat > "$RUNNER" <<'RUNEOF'
#!/usr/bin/env bash
set -uo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# launchd はログインシェルを通さないので、.zshrc などの環境は一切引き継がれない。
# PATH と、トークン類を書いた .env はここで自前で読み込む。
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
if [ -f "$PROJECT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$PROJECT_DIR/.env"
  set +a
  echo "  .env を読み込みました"
fi

PY="${PYTHON:-python3}"
echo "=== $(date '+%F %T') 更新開始 ==="
if [ -n "${BRAWLSTARS_API_TOKEN:-}" ]; then
  echo "  公式 API トークン: あり（ローテーションを公式から取得します）"
else
  echo "  公式 API トークン: なし（.env に BRAWLSTARS_API_TOKEN を書くとローテが確実に取れます）"
fi

"$PY" scripts/download_icons.py || { echo "✖ アイコン取得で失敗"; exit 1; }
"$PY" scripts/update_meta.py --rotation-out rules/rules_rotation.json || { echo "✖ ルール生成で失敗"; exit 1; }
"$PY" scripts/validate_rules.py rules/rules.json || { echo "✖ 検証で失敗"; exit 1; }

# git リポジトリなら自動コミット（リモートがあれば push まで）
if [ -d .git ]; then
  git add -A assets rules data
  if ! git diff --cached --quiet; then
    git commit -q -m "chore(meta): ルールデータを自動更新 ($(date -u '+%F %H:%M UTC'))"
    if git remote get-url origin >/dev/null 2>&1; then
      # launchd 環境では git の認証情報ヘルパーが効かないことがあるので、
      # gh が入っていればそれを明示的に使う。
      GIT_PUSH=(git)
      if command -v gh >/dev/null 2>&1; then
        GIT_PUSH=(git -c "credential.helper=!gh auth git-credential")
      fi
      # GitHub Actions 側も同じ生成物をコミットしているとここで枝分かれする。
      # 先に取り込んでから push する。
      if ! "${GIT_PUSH[@]}" pull --rebase --autostash -q origin main; then
        git rebase --abort 2>/dev/null || true
        echo "  ! リモートと競合しました。生成物の衝突なので、"
        echo "    GitHub Actions とローカル cron のどちらか一方に寄せてください（README §4）。"
      fi
      "${GIT_PUSH[@]}" push -q origin HEAD && echo "  push しました" \
        || echo "  ! push に失敗（gh auth status を確認してください）"
    fi
    echo "コミットしました"
  else
    echo "変更なし"
  fi
fi
echo "=== $(date '+%F %T') 更新完了 ==="
RUNEOF
chmod +x "$RUNNER"

# --run-now は launchd への登録をせず、いま 1 回だけ実行して終わる（動作確認用）
if [ "${1:-}" = "--run-now" ]; then
  exec "$RUNNER"
fi

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
