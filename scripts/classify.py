"""ブラウラーをアーキタイプ（タンク / アサシン / スナイパー …）へ分類する。

Brawlify API は各ブラウラーに「立ち回りのコツ」を短文で持っている
（例: Shelly = "Counter Tanks And Assassins With Burst Damage."）。
この文面はロールを非常によく表しているので、キーワード加点方式で自動分類する。

自動分類は完璧ではないため、data/brawler_roles.json に手動オーバーライドを置ける。
  * "source": "manual"    … 人間が確定させた。自動更新で絶対に上書きされない。
  * "source": "heuristic" … 自動推定。新キャラ追加時に毎回上書きされる。
"""

from __future__ import annotations

import re
from typing import Iterable

ARCHETYPES = ("tank", "assassin", "marksman", "thrower", "controller", "support", "damage")

# (正規表現, アーキタイプ, 重み)
KEYWORD_RULES: tuple[tuple[str, str, float], ...] = (
    # --- support ---
    (r"heal\s+teammates?", "support", 3.0),
    (r"instant heals?", "support", 3.0),
    (r"buff (your )?team", "support", 3.0),
    (r"shield teammates?", "support", 3.0),
    (r"get your team into", "support", 2.0),
    (r"\bheal\b", "support", 1.0),

    # --- marksman / 長射程 ---
    (r"\bsnipe", "marksman", 3.0),
    (r"(huge|massive|more|extra|for) range", "marksman", 2.5),
    (r"long range", "marksman", 2.5),
    (r"poke from range", "marksman", 2.0),
    (r"from a distance", "marksman", 2.0),
    (r"mid-?range", "marksman", 1.0),
    (r"charged attacks", "marksman", 1.0),

    # --- thrower / 壁裏 ---
    (r"behind walls", "thrower", 3.0),
    (r"through walls", "thrower", 2.5),
    (r"\bthrow(ing)?\b", "thrower", 2.0),
    (r"bombard", "thrower", 2.5),
    (r"bottles", "thrower", 2.0),
    (r"from safety", "thrower", 2.0),

    # --- assassin / 飛び込み ---
    (r"assassinate", "assassin", 3.0),
    (r"jump (in|to|around)", "assassin", 2.5),
    (r"dive in", "assassin", 2.5),
    (r"sneak in", "assassin", 2.5),
    (r"ambush", "assassin", 2.5),
    (r"get close", "assassin", 2.0),
    (r"isolated enemies", "assassin", 2.0),
    (r"\bdash\b", "assassin", 1.5),
    (r"leap over", "assassin", 1.5),
    (r"chase down", "assassin", 1.5),
    (r"strike", "assassin", 1.0),

    # --- tank / 前線 ---
    (r"high health", "tank", 3.0),
    (r"soak up damage", "tank", 3.0),
    (r"close the distance", "tank", 2.5),
    (r"charge in", "tank", 2.5),
    (r"hold (your )?ground", "tank", 2.0),
    (r"break walls", "tank", 1.5),
    (r"self-?revival", "tank", 1.5),
    (r"big close range", "tank", 1.5),
    (r"roll in", "tank", 1.5),
    (r"engage", "tank", 1.0),

    # --- controller / 制圧 ---
    (r"control (space|the map|objectives|multiple lanes)", "controller", 3.0),
    (r"\bzone\b|zoning|zone enemies", "controller", 2.5),
    (r"deny space", "controller", 2.5),
    (r"take space", "controller", 2.5),
    (r"\bstun", "controller", 2.0),
    (r"freeze", "controller", 2.0),
    (r"\bslow\b", "controller", 2.0),
    (r"push enemies away", "controller", 2.0),
    (r"traps?\b", "controller", 2.0),
    (r"(place|use) your (turret|cannon)", "controller", 2.0),
    (r"porters|portals", "controller", 1.5),
    (r"remove them from play", "controller", 2.0),
    (r"\bcontrol\b", "controller", 1.0),

    # --- damage / 汎用火力 ---
    (r"burst (damage|down|tanks)", "damage", 2.0),
    (r"big damage", "damage", 1.5),
    (r"consistent damage", "damage", 2.0),
    (r"large area damage", "damage", 1.5),
    (r"shred", "damage", 1.5),
    (r"explode brawlers", "damage", 1.5),
    (r"bounce shots", "damage", 1.5),
    (r"\bpoke\b", "damage", 0.5),
    (r"pressure", "damage", 1.0),
)


def classify(tip: str | None, name: str = "") -> tuple[str, float, list[str]]:
    """コツ文からアーキタイプを推定して (role, confidence, 根拠キーワード) を返す。"""
    text = (tip or "").lower()
    scores = dict.fromkeys(ARCHETYPES, 0.0)
    hits: list[str] = []
    for pattern, role, weight in KEYWORD_RULES:
        if re.search(pattern, text):
            scores[role] += weight
            hits.append(f"{role}:{pattern}")

    top = max(scores.items(), key=lambda kv: kv[1])
    if top[1] <= 0:
        # 手掛かりゼロ（例: 情報未登録の新キャラ）。汎用アタッカー扱い。
        return "damage", 0.0, []

    ordered = sorted(scores.values(), reverse=True)
    margin = ordered[0] - (ordered[1] if len(ordered) > 1 else 0.0)
    confidence = round(min(1.0, (top[1] * 0.18) + (margin * 0.15)), 3)
    return top[0], confidence, hits


def merge_roles(
    brawlers: Iterable[dict],
    existing: dict | None,
) -> tuple[dict, list[str]]:
    """既存の roles ファイルと API の最新一覧をマージする。

    manual エントリは温存し、heuristic エントリと新キャラだけ作り直す。
    """
    existing = existing or {}
    old_entries: dict[str, dict] = {e["name"]: e for e in existing.get("brawlers", [])}

    merged: list[dict] = []
    newly_added: list[str] = []
    for b in brawlers:
        name = b["name"]
        prev = old_entries.get(name)
        if prev and prev.get("source") == "manual":
            entry = dict(prev)
            entry["id"] = b["id"]
            merged.append(entry)
            continue

        role, conf, hits = classify((b.get("class") or {}).get("name"), name)
        if prev is None:
            newly_added.append(name)
        merged.append({
            "id": b["id"],
            "name": name,
            "role": role,
            "source": "heuristic",
            "confidence": conf,
            "tip": (b.get("class") or {}).get("name"),
            "matched": hits[:4],
        })

    merged.sort(key=lambda e: e["id"])
    return {
        "schema": 1,
        "_comment": (
            "role を直したいときは該当エントリの role を書き換え、"
            '"source" を "manual" にしてください。以後の自動更新で上書きされません。'
        ),
        "archetypes": list(ARCHETYPES),
        "count": len(merged),
        "brawlers": merged,
    }, newly_added
