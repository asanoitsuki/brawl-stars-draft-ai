# ストア用プレビュー画像 — ChatGPT 用プロンプト集

## 進め方（元のアプリ画面は一切変えない）

1. ChatGPT で **背景だけ** を作る（文字・スマホ・ゲームキャラは入れない）。下のプロンプトを 1 枚ずつ貼る。
2. 出来た画像を `appstore/bg/` に `1.png` 〜 `5.png` で保存する（縦長 1024×1536 で出してもらう）。
3. Claude が、本物のスクリーンショット（`appstore/screenshots/`）を端末フレームにはめ、日本語のキャッチコピーを **自分で描いて**合成する。
   - 日本語の文字を AI 画像生成に任せると崩れるため、文字は必ず合成側で入れる。
   - 画面の中身（アプリの実画面）は加工しない。

## 共通ルール（毎回プロンプトの最後に付ける）

```
Vertical 2:3 poster background for a mobile game-tool app. Deep navy to violet cosmic palette with cyan and magenta glow, the same mood as a glowing nebula sphere.
STRICT: no text, no letters, no logos, no UI, no phones, no characters, no people, no game characters.
Keep the center 60% of the image calm and low-detail (a phone screenshot will be placed there). Put the decoration only around the edges and corners.
Flat clean modern style with soft gradients, subtle grain. High resolution.
```

## 1 枚目: 常に最新（毎日更新）

- 画面: ホーム（`1_home.png`）
- キャッチ: **「データは毎日、自動で更新。」** / 小さく「公式の実戦データを毎朝集計」
- プロンプト:
```
A glowing nebula sphere floating at the top, with thin orbit rings and small particles being sucked into it. Faint circular clock-like arcs around it suggesting daily refresh, without any numbers or text. Particles streaming in from the bottom corners.
```

## 2 枚目: 新しい形式のチーム募集

- 画面: チーム募集（`2_team.png`）
- キャッチ: **「招待リンクを貼るだけ。新しいチーム募集。」** / 小さく「条件でしぼって、あと1人を集める」
- プロンプト:
```
Soft flame-like wavy aura ribbons in orange, magenta and cyan curling along the left and right edges, as if a card is glowing with energy. Small floating spark particles. A warm glow in the lower corners.
```

## 3 枚目: AI がピックを判定

- 画面: ピック提案（`3_profile.png` ではなくピック結果の画面。未撮影なら撮り直す）
- キャッチ: **「スクショを撮るだけ。AI が次の1体を判定。」**
- プロンプト:
```
A constellation network: glowing nodes connected by fine lines forming a branching decision map around the edges, with one node brighter than the rest as if highlighted. Cyan and violet lines on deep navy.
```

## 4 枚目: マップごとの最新メタ

- 画面: マップ詳細（`8_map.png`）
- キャッチ: **「マップごとの最新メタが、ひと目で。」**
- プロンプト:
```
Abstract topographic map contour lines in glowing cyan flowing around the edges, with a few bright dots like pins on the map. Hex-grid patterns fading in the corners.
```

## 5 枚目: 公式の実戦データで判定

- 画面: プロフィール or キャラ詳細（`5_detail.png`）
- キャッチ: **「判定の元は、公式の実戦戦績データ。」** / 小さく「広告なし・追跡なし・無料」
- プロンプト:
```
Rising bar-chart-like glowing pillars of light made of tiny particles, rising from the bottom corners, with a soft shield-shaped glow in the upper corner suggesting trust. Teal and violet palette.
```

## 6 枚目: Discord ですぐ通話へ

- 画面: 募集カード（Discord のヘッドホンボタンが見える一覧。`2_team.png` を撮り直し、招待リンク付きの募集を映す）
- キャッチ: **「ワンタップで Discord 通話へ。」** / 小さく「集まったその場で、声でつながる」
- プロンプト:
```
Soft indigo and blue sound-wave ripples spreading from the bottom corners, with floating abstract speech-bubble and headphone-like shapes made only of glowing outlines (no logos, no brand marks). Calm purple-blue glow along the edges.
```
- 注意: Discord のロゴは画像に入れない（ヘッドホンの形などの一般的な絵だけにする）。

## 注意

- ゲームのキャラクター画像は背景に入れない（Supercell の知的財産。審査で 5.2 を指摘されやすい）。
- 最終的なキャッチコピーの言い回しは、合成の前に一緒に直す。
