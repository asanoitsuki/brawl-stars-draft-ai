# ガチバトルピックAI

ブロスタ（Brawl Stars）ガチバトルのドラフト画面を、**スクリーンショット1枚から 0.5 秒以内に**解析して
「いま取るべきキャラ」をバナー通知＋音声で返すシステム一式。

LLM はリアルタイム経路に一切入っていない。判定はすべて端末内のテンプレートマッチングと、
前日までに生成済みのルール JSON の参照だけで完結する。

```
背面ダブルタップ → ショートカット → App Intent
        → スクショをテンプレートマッチ（マップ・BAN・ピック）
        → rules.json を参照してピック順ごとのロジックを適用
        → 通知バナー ＋ 音声読み上げ
```

**実測値（M4 Mac 上の結合テスト / `scripts/run_swift_e2e.sh`）**

| 処理 | 時間 |
|---|---|
| 画像解析（切り出し→記述子→照合→ピック順判定→提案） | **5 ms**（初回 13 ms） |
| rules.json のデコード（起動時に 1 回だけ） | 約 100 ms |
| 枠の自動検出（オフライン・`calibrate_layout.sh`） | 約 4.5 秒 |

判定の直前に I/O が残らないよう、ルールとテンプレートは起動時にメモリへ載せきる設計。

---

## 1. セットアップ

```bash
pip3 install -r requirements.txt     # Pillow のみ
./scripts/run_all.sh                 # アイコン取得 → ルール生成 → 検証 → iOS へ同梱
```

`run_all.sh` が回すもの:

| スクリプト | 役割 |
|---|---|
| `scripts/download_icons.py` | 全キャラのアイコン PNG を取得し、照合用の記述子 `templates.json` を生成 |
| `scripts/update_meta.py` | ローテーション・勝率を取得して `rules/rules.json` を生成 |
| `scripts/validate_rules.py` | 生成物の構造検証（CI でも同じものを使う） |
| `scripts/sync_ios_resources.sh` | 生成物を iOS バンドルへコピー |

---

## 2. キャラアイコン一括収集 — `scripts/download_icons.py`

```bash
python3 scripts/download_icons.py                # 差分取得 + テンプレ生成
python3 scripts/download_icons.py --force        # 全部取り直す
python3 scripts/download_icons.py --variants all # borders / borderless / emoji すべて
```

出力:

```
assets/brawler_icons/borders/<id>.png       枠付きポートレート（照合の主役。ゲーム内表示に近い）
assets/brawler_icons/borderless/<id>.png    枠なし
assets/brawler_icons/index.json             ID / 名前 / レアリティ / ファイル対応表
assets/brawler_templates/templates.json     iOS が読む記述子パック
```

**API ホストは自動フォールバックする。** `api.brawlify.com` が Cloudflare に弾かれる
ネットワークでは、旧ドメインのミラー `api.brawlapi.com` へ自動で切り替わる
（`scripts/brawl_api.py`）。CDN 未反映の新キャラ（404）は警告のみで処理を止めない。

### 記述子の作り方（Python と Swift で完全に一致させてある）

1. 透過部分を除いてクロップ → グレー 128 の上に合成
2. 長辺に合わせた正方形へ中央配置（余白もグレー 128）
3. **面積平均（BOX フィルタ）** で縮小
4. BT.601 で輝度化 → 平均 0 / ノルム 1 へ正規化

4 は「内積＝正規化相互相関（NCC）」にするための正規化。
3 を LANCZOS にすると CoreGraphics 側で同じ結果を再現できず、
Python↔Swift の自己相関が 0.90 まで落ちて似たキャラの判別が不安定になる。
BOX にそろえた現在は **0.9996**（最も紛らわしいペア Frank↔Byron でも 0.876 なので十分な余裕がある）。

この一致は `scripts/run_swift_e2e.sh` が毎回チェックする。
**片方の前処理を変えたら、必ずもう片方も変えること。**

---

## 3. 毎夜のメタ更新 — `scripts/update_meta.py`

```bash
python3 scripts/update_meta.py                          # ランクモード全マップ
python3 scripts/update_meta.py --rotation-only          # 現在ローテ中のマップのみ
python3 scripts/update_meta.py --rotation-out rules/rules_rotation.json
python3 scripts/update_meta.py --require-stats          # 勝率が取れなければ失敗（CI 用）
```

### rules.json に入るもの

マップごとに:

| キー | 内容 |
|---|---|
| `name` / `mode` / `modeJa` / `environment` | マップ名・モード（ガチバトルの 7 モード） |
| `bans` | BAN 推奨 6 体（強さ×人気＝放置すると必ず取られる順） |
| `picks.first` | **初手**: 強く、かつ「対策されにくい」キャラ（被カウンター指数で減点） |
| `picks.middle.general` | **中盤**: シナジー＋部分カウンターの合成 |
| `picks.middle.byAllyRole` | 味方の役割別に噛み合うキャラ |
| `picks.middle.byEnemyRole` | 相手の役割別に刺さるキャラ |
| `picks.last.byEnemyRole` | **ラスト**: タンク対策・長射程対策など、相手構成への決定的カウンター |
| `candidates` | iOS がライブ計算に使う候補（素点付き） |
| `template` | マップ画像の記述子（**OCR を使わずに画像でマップを判別する**ため） |

全体には `advantage`（相性表）/ `synergy`（噛み合い表）/ `archetypes`（役割の日本語名）も入る。
iOS 側はこれらを使って、実際の敵味方構成に合わせてスコアを再計算する。

### 判定ロジックの中身

- **アーキタイプ**: タンク / アサシン / スナイパー / 投擲 / コントローラー / サポート / アタッカー
- **相性表** `data/archetypes.json`: 反対称行列（A→B = -(B→A)）。生成時に検証される
- **モード補正**: ブロストライカーならスナイパー +1.2 / タンク -1.0、といったモード別の素点
- **スコア**: 実測勝率があるとき `勝率z×0.65 + 役割適性×0.35 + 手動ティア×0.20`、
  無いとき `役割適性 + 手動ティア`
- **多様性**: 同じ役割ばかり並ばないよう、既出ロールに減点しながら選ぶ

手で調整できるファイル（自動更新で壊されない）:

| ファイル | 用途 |
|---|---|
| `data/archetypes.json` | 相性表・シナジー表・モード補正・BAN 数 |
| `data/brawler_roles.json` | キャラの役割。`"source": "manual"` にすると自動分類で上書きされない |
| `data/tier_overrides.json` | 自分の感覚での強さ補正（-2.0 〜 +2.0） |
| `data/brawler_names_ja.json` | 読み上げ用のカタカナ表記 |

役割は Brawlify が持つ「立ち回りのコツ」文からキーワード加点で自動分類している
（`scripts/classify.py`）。現状 **83 体が手動確定 / 26 体が自動推定**。
自動推定のままのキャラは `data/brawler_roles.json` で `"source": "heuristic"` と印が付く。

---

## 4. 毎日の自動実行

### GitHub Actions（推奨）

`.github/workflows/daily_update.yml` が **毎日 08:40 UTC（17:40 JST）** に実行される。
ブロスタのデイリーリセット（08:00 UTC）の 40 分後。

やること: アイコン差分取得 → ルール生成 → 検証 → 変更があればコミット＆プッシュ →
実行サマリーに「実測勝率が取れたか」を出力。

セットアップ:

1. このフォルダを GitHub の **public** リポジトリとして push する
   （iPhone から raw URL で読むため。private にするなら別途配信先が必要）
2. Settings → Actions → General → Workflow permissions を **Read and write** にする
3. アプリの設定画面に raw URL を入れる:
   `https://raw.githubusercontent.com/<ユーザー名>/<リポジトリ>/main/rules/rules_rotation.json`

### ローカル cron（Mac の launchd）

```bash
./scripts/install_cron.sh          # 毎日 17:40 に実行するよう登録
./scripts/install_cron.sh 03 30    # 時刻指定
./scripts/install_cron.sh --run-now
./scripts/install_cron.sh --uninstall
```

ログは `logs/meta_update.log`。

---

## 5. iOS アプリ

```bash
cd ios/BrawlDraftAI
xcodegen generate          # project.yml から .xcodeproj を作る（brew install xcodegen）
open BrawlDraftAI.xcodeproj
```

Xcode 側で必要な設定:

- **Signing & Capabilities** で自分の Team を選ぶ（Bundle ID も自分のものに変える）
- **Time Sensitive Notifications** を有効にする
  （`Sources/BrawlDraftAI.entitlements` に入れてあるが、Team を設定すると再確認が要る）
- 最低 iOS 17.0（App Intents の `IntentFile` を使うため）

### 構成

| ファイル | 役割 |
|---|---|
| `Core/ImageDescriptor.swift` | CGImage → 記述子。ラスタライズは解析ごとに 1 回だけ |
| `Core/TemplateMatcher.swift` | vDSP による NCC 照合。全テンプレを 1 本のバッファに詰めてある |
| `Core/ScreenLayout.swift` | 画面内の枠位置（0〜1 の比率）。キャリブレーション結果は端末に保存 |
| `Core/DraftAnalyzer.swift` | マップ判定・BAN/ピック枠の読み取り・ピック順の判定 |
| `Core/Recommender.swift` | 実構成に合わせたライブ計算と、日本語の理由文の生成 |
| `Core/RulesStore.swift` | rules.json / templates.json の読み込み・キャッシュ・自動更新 |
| `Intents/AnalyzeDraftIntent.swift` | ショートカットから呼ぶ入口 |
| `Output/NotificationPresenter.swift` | Time Sensitive バナー |
| `Output/SpeechAnnouncer.swift` | AVSpeechSynthesizer（ゲーム音にかぶせるダッキング付き） |

### ピック順の判定

ガチバトルのドラフト順は `A1 → B1 → B2 → A2 → A3 → B3` の 6 手。
アプリは **埋まっている枠の数**から何手目かを決める:

| 状況 | 適用ロジック |
|---|---|
| ピック 0・BAN 枠が埋まりきっていない | BAN 推奨 |
| ピック 0 | 初手（対策されにくい最強） |
| ピック 1〜4 | 中盤（シナジー 0.45 ＋ カウンター 0.35） |
| ピック 5 | ラスト（カウンター 1.60 ＝ ほぼカウンター一択） |

### 入口は 3 つ

| 入口 | 使い方 |
|---|---|
| App Intent「最新スクショでドラフト解析」 | 背面タップに割り当てるならこれが最短 |
| App Intent「ドラフトを解析」 | ショートカットが渡した画像を解析（画像なしなら最新スクショ） |
| URL スキーム | `brawldraft://analyze` / `brawldraft://analyze?path=…` / `brawldraft://refresh` |

### 背面タップの設定

1. ショートカットアプリで新規ショートカットを作り、アクション
   **「最新スクショでドラフト解析」** を追加して名前を付ける
2. 設定 → アクセシビリティ → タッチ → **背面タップ** → ダブルタップ にそのショートカットを割り当て
3. 対戦中: 電源＋音量上でスクショ → 背面ダブルタップ

> iOS のショートカットには「スクリーンショットを撮る」アクションが無いため、
> 撮影そのものは本体操作で行う。背面タップは「撮る」か「解析する」のどちらか一方にしか
> 割り当てられないので、**撮影＝ハードウェアボタン、解析＝背面タップ**の分担になる。

---

## 6. 初回に必ずやること — 枠合わせ（キャリブレーション）

同梱している枠の位置は**あくまで目安**で、実機のスクリーンショットとは必ずズレる。
アプリの「枠合わせ」画面で、自分の端末のドラフト画面に合わせて調整する。

1. ガチバトルのドラフト画面をスクショしておく
2. アプリ → 枠合わせ → スクショを選ぶ
3. 枠をドラッグ／右下ハンドルでリサイズ／矢印ボタンで微調整
4. **「この配置で解析テスト」** で、マップ名とキャラ名が正しく出るか確認
5. 保存

解析器は位置 ±6% / 拡大縮小 ±8% のジッタ探索でズレをある程度吸収するが、
枠が正確なほど速く・安定する（1 発で一致したら探索そのものを省く）。

`assets/synthetic_draft_test.png` に、結合テストが生成した疑似ドラフト画面がある。
実機のスクショが無い状態で UI を触ってみたいときの練習台に使える。

### 枠の自動検出

手で合わせる前に、スクリーンショットから枠を自動で割り出せる。

```bash
./scripts/calibrate_layout.sh ~/Desktop/draft.png            # 検出して結果を書き出すだけ
./scripts/calibrate_layout.sh ~/Desktop/draft.png --adopt    # 既定プロファイルへ反映
./scripts/calibrate_layout.sh --self-test                    # 探索器そのものを検証
```

画像全体をマルチスケールのスライディングウィンドウで走査し、キャラアイコンとマップ画像が
写っている位置を総当たりで探す。**既定の枠がどれだけズレていても関係なく動く**
（既定値からの局所探索ではないため）。

1. 縮小画像（長辺 800px）で粗探索 → 2. 非最大抑制で重複を除去 →
3. 等倍画像で位置・大きさ・縦横比を微調整 → 4. 大きさで BAN / ピックに分け、
左右で味方 / 相手に振り分け

背景への誤検出は「最良スコアの 80%」という相対しきい値と、
同じキャラが 2 回出ないという制約で落としている。

`--self-test` は合成ドラフト画面で探索器を検証する。仕込んだ位置を復元できる:

```
マップ : Alchemy    一致度 0.978  枠 x=0.434 y=0.055 w=0.121 h=0.425   （仕込み値 x=0.435 w=0.130）
味方1 : Piper      一致度 0.943  枠 x=0.057 y=0.602 w=0.085 h=0.184   （仕込み値 x=0.060 w=0.085）
BAN 1 : Angelo     一致度 0.948  枠 x=0.039 y=0.059 w=0.050 h=0.108   （仕込み値 x=0.040 w=0.050）
```

> ⚠️ **セルフテストで出た枠は「合成画像の配置」であって、実機のゲーム画面の配置ではない。**
> 探索器が正しく動くことの確認にしかならないので、`--self-test` は `--adopt` しない。
> 実機の枠を出すには、**本物のドラフト画面のスクショ**を渡すこと。

---

## 7. テスト

```bash
./scripts/run_all.sh          # 更新 + 全テスト
./scripts/run_swift_e2e.sh    # 認識コアの結合テストだけ
./scripts/calibrate_layout.sh --self-test   # 枠検出のセルフテストだけ
```

iOS アプリの認識コアを macOS 上でそのまま動かす結合テスト。シミュレータも実機も要らない。

- rules.json / templates.json を実データで読み込む
- 既知のマップ画像とキャラアイコンから疑似ドラフト画面を合成する
- 切り出し → 記述子 → 照合 → ピック順判定 → 提案 まで通す
- 仕込んだ内容と一致するか検証し、処理時間を出す

```
Alchemy（ブロストライカー）一致度 0.91
自陣: Piper, Poco, Bull
相手: Mortis, Barley
BAN: Angelo, Edgar, Tick, Max
フェーズ: ラストピック（6番目） / 解析 5 ms
→ ラストピック（アサシン対策）：Jessie（ジェシー）
✔ すべて一致
```

---

## 8. 実測勝率について（調査結果）

`rules/rules.json` は現在 **実測勝率なし / 手動ティア 84 件で補正** の状態で生成される。
原因を切り分けたので、対処の当たりを付けやすいようにそのまま書いておく。

### 分かったこと

| 対象 | 結果 |
|---|---|
| `api.brawlify.com/v1/*` | **API 自体が廃止済み**。実ブラウザで開いても `{"error":{"code":"not_found"}}` |
| `brawlify.com/maps/<id>` | 勝率は SSR された HTML の中にある。ただし **Cloudflare の JS チャレンジ**が挟まる |
| curl（ヘッダ完全再現） | 403。**ヘッダ無しの素のリクエストと結果が同じ** |
| 実ブラウザ | チャレンジを通過して閲覧できる |
| `api.brawlapi.com/v1/*`（旧ドメインのミラー） | 生きている。ただし `events` と `stats` は空配列 |

つまり判定は User-Agent ではなく **TLS フィンガープリント + JS チャレンジ**で行われており、
**リクエストヘッダをどう盛っても突破できない**。

### それでも入れてある対策

1. **実ブラウザ相当のヘッダ一式**（`scripts/brawl_api.py` の `BROWSER_HEADERS`）。
   ヘッダを見るタイプの WAF には効くし、CDN と旧ドメインでは現に通っている
2. **403 の原因を切り分けて表示する**。Cloudflare 起因なら cf-ray 付きでそう言う:
   ```
   HTTP 403 / Cloudflare にブロックされました (cf-ray=...)。
           ヘッダだけでは回避できません（TLS フィンガープリント + JS チャレンジ判定）。
           回避するなら: ブラウザで ... を開いてチャレンジを通し、
           cf_clearance Cookie を BRAWLIFY_COOKIE 環境変数に入れて再実行してください。
   ```
3. **Cookie の注入口**:
   ```bash
   export BRAWLIFY_COOKIE='cf_clearance=...'          # ブラウザから取ってくる
   export BRAWLIFY_EXTRA_HEADERS='{"X-Foo":"bar"}'    # 追加ヘッダが要るとき
   ```
4. **Supercell 公式 API によるローテーション取得**（任意）。
   勝率は公式には無いが、**マップローテーションは公式から確実に取れる**:
   ```bash
   export BRAWLSTARS_API_TOKEN='...'    # https://developer.brawlstars.com/ で無料発行
   python3 scripts/update_meta.py --rotation-out rules/rules_rotation.json
   ```
   ローテが判明すると `rules_rotation.json` が実際にローテ中のマップだけになり、
   端末が落とすデータが 3.4 MB → 100 KB 程度まで小さくなる。
   ⚠️ 公式キーは IP 固定なので、IP が毎回変わる GitHub Actions では使えない。
   ローカル cron（`scripts/install_cron.sh`）向けの機能。
   ⚠️ このプロジェクトの環境ではトークンを発行できなかったため、**この経路は未検証**。

### 勝率が無い間の補強 — 手動ティア

`data/tier_overrides.json` に **84 体ぶんの初期値**を入れてある。これで
「同じ役割のキャラが全部同点」という状態は解消され、BAN / 初手 / ラストの並びに差が付く。

```
BAN 推奨: Angelo 1.95 → Mandy 1.95 → Belle 1.70 → Charlie 1.05 → Surge 0.95 → Grom 0.85
```

> ⚠️ **これは測定値ではない。**「ランクでどれだけ採用されやすいか」を手で入れた初期値で、
> その時点のパッチの実勝率とは一致しない。自分の感覚や最新のティア表に合わせて必ず調整すること。
> 載っていない 25 体は 0（中立）として扱われる。

スケールは `S=+1.5 / A=+1.0 / B=+0.5 / 中立=0 / D=-0.8 / F=-1.5`。
実測勝率が入り始めると重みは 0.50 倍 → 0.20 倍に下がり、自動的に実測が主役になる。

アプリ側の表示も 3 段階になっている:

| 状態 | 表示 |
|---|---|
| 実測勝率あり | 緑「実測勝率あり」 |
| 実測なし・手動ティアあり | 黄「手動ティア 84 件で補正」 |
| どちらも無し | 橙「役割適性のみ（同点多数）」 |

### その他の制約

- **新キャラ 2 体（Cosmo / Vince）はアイコンが CDN 未反映**のため画像照合できない。
  CDN に載れば次回の `download_icons.py` で自動的に入る
- **役割分類は 26 体が自動推定のまま**。`data/brawler_roles.json` で直せる
- 相性表は「タンク⇄長射程」のような一般的なアーキタイプ相性であって、
  個別キャラ同士の細かい有利不利までは表現していない

---

## 9. ファイル構成

```
.
├── scripts/
│   ├── brawl_api.py            API クライアント（ホスト自動フォールバック）
│   ├── classify.py             役割の自動分類
│   ├── download_icons.py       ① アイコン一括収集 + 記述子生成
│   ├── update_meta.py          ② ルールデータ生成
│   ├── validate_rules.py       生成物の検証
│   ├── sync_ios_resources.sh   iOS バンドルへ同梱
│   ├── install_cron.sh         ローカル launchd 登録
│   ├── run_swift_e2e.sh        認識コアの結合テスト
│   ├── calibrate_layout.sh     スクショから枠を自動検出
│   └── run_all.sh              まとめて実行 + 全テスト
├── data/                       手で調整するナレッジ（相性表・役割・ティア・カタカナ）
├── assets/
│   ├── brawler_icons/          キャラアイコン PNG（214 枚）
│   ├── brawler_templates/      照合用記述子（107 体）
│   ├── map_thumbs/             マップ画像（159 枚）
│   └── synthetic_draft_test.png  テストが生成する疑似ドラフト画面
├── rules/
│   ├── rules.json              ランクモード全 159 マップ
│   └── rules_rotation.json     ローテ中のみ（端末が読む軽量版）
├── .github/workflows/daily_update.yml   ③ 毎日の自動更新
└── ios/BrawlDraftAI/           ④ iOS アプリ（XcodeGen プロジェクト）
```
