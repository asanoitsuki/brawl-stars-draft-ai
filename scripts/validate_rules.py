#!/usr/bin/env python3
"""生成された rules.json の構造を検証する（CI とローカル cron の両方から呼ぶ）。

使い方:
    python3 scripts/validate_rules.py rules/rules.json
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from brawl_api import PROJECT_ROOT  # noqa: E402

REQUIRED_MAP_KEYS = ("id", "name", "mode", "modeJa", "bans", "picks", "candidates")
REQUIRED_PICK_KEYS = ("first", "middle", "last")
GRAY_DIM, COLOR_DIM = 256, 48


def fail(msg: str) -> None:
    print(f"✖ {msg}", file=sys.stderr)
    raise SystemExit(1)


def main() -> int:
    path = Path(sys.argv[1] if len(sys.argv) > 1 else PROJECT_ROOT / "rules" / "rules.json")
    if not path.exists():
        fail(f"{path} がありません")

    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(f"JSON が壊れています: {exc}")

    if doc.get("schema") != 2:
        fail(f"未知の schema: {doc.get('schema')}")

    maps = doc.get("maps") or []
    if not maps:
        fail("maps が空です")

    roles = {b["name"]: b["role"] for b in doc.get("brawlers", [])}
    if not roles:
        fail("brawlers が空です")

    archetypes = set(doc.get("archetypes", {}))
    adv = doc.get("advantage", {})
    for a in archetypes:
        for b in archetypes:
            if adv.get(a, {}).get(b) != -adv.get(b, {}).get(a, 0):
                fail(f"advantage が反対称ではありません: {a}->{b}")

    templates_path = PROJECT_ROOT / "assets" / "brawler_templates" / "templates.json"
    known_icons: set[str] = set()
    if templates_path.exists():
        pack = json.loads(templates_path.read_text(encoding="utf-8"))
        known_icons = {t["name"] for t in pack["templates"]}
        for t in pack["templates"][:5]:
            if len(t["gray"]) != GRAY_DIM or len(t["color"]) != COLOR_DIM:
                fail(f"テンプレート次元が不正: {t['name']}")

    problems: list[str] = []
    with_template = 0
    for m in maps:
        for k in REQUIRED_MAP_KEYS:
            if k not in m:
                problems.append(f"map {m.get('id')} に {k} がありません")
        picks = m.get("picks", {})
        for k in REQUIRED_PICK_KEYS:
            if k not in picks:
                problems.append(f"map {m.get('name')} の picks に {k} がありません")
        if not m.get("bans"):
            problems.append(f"map {m.get('name')} の BAN 推奨が空です")
        if not picks.get("first"):
            problems.append(f"map {m.get('name')} の初手候補が空です")
        for enemy, lst in (picks.get("last", {}).get("byEnemyRole") or {}).items():
            if enemy not in archetypes:
                problems.append(f"map {m.get('name')} に未知のアーキタイプ {enemy}")
            if not lst:
                problems.append(f"map {m.get('name')} の vs{enemy} ラストピックが空です")
        tmpl = m.get("template")
        if tmpl:
            with_template += 1
            if len(tmpl["gray"]) != GRAY_DIM or len(tmpl["color"]) != COLOR_DIM:
                problems.append(f"map {m.get('name')} のテンプレート次元が不正")
        for entry in m.get("candidates", []):
            if entry["name"] not in roles:
                problems.append(f"candidates に未知のブラウラー: {entry['name']}")

    if problems:
        for p in problems[:25]:
            print(f"  - {p}", file=sys.stderr)
        fail(f"{len(problems)} 件の問題が見つかりました")

    missing_icons = sorted({e["name"] for m in maps for e in m["candidates"]} - known_icons) \
        if known_icons else []

    print(f"✔ {path.name} OK")
    print(f"    マップ {len(maps)} / 画像テンプレあり {with_template}")
    print(f"    ブラウラー {len(roles)} / アイコンテンプレ {len(known_icons)}")
    print(f"    実測勝率: {'あり' if doc['dataQuality']['liveStats'] else 'なし（役割適性のみ）'}")
    if missing_icons:
        print(f"    · アイコン未取得のため画像照合できないキャラ: {', '.join(missing_icons)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
