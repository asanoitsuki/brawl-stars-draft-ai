#!/usr/bin/env python3
"""公式 API が返す項目を調べる診断用（値ではなく「どんな項目があるか」を出す）。

プロフィールに入れられるデータの範囲（ガチバトルのレートが取れるか等）を確かめるために使う。
  python3 scripts/probe_api.py [#タグ]     … タグ省略時は世界ランキング 1 位のプレイヤー
"""
from __future__ import annotations

import json
import sys
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from brawl_api import _SSL_CONTEXT, USER_AGENT, official_base, official_token  # noqa: E402


def get(path: str):
    req = urllib.request.Request(f"{official_base()}/{path}", headers={
        "Authorization": f"Bearer {official_token()}", "Accept": "application/json", "User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=30, context=_SSL_CONTEXT) as res:
        return json.loads(res.read())


def shape(v, depth=0):
    if isinstance(v, dict):
        return {k: shape(x, depth + 1) for k, x in v.items()}
    if isinstance(v, list):
        return [shape(v[0], depth + 1)] if v else []
    return type(v).__name__


def main() -> None:
    tag = sys.argv[1] if len(sys.argv) > 1 else None
    if not tag:
        tag = get("rankings/global/players?limit=1")["items"][0]["tag"]
    q = urllib.parse.quote(tag)
    p = get(f"players/{q}")
    print("== /players: トップレベルの項目 ==")
    print(json.dumps(shape({k: v for k, v in p.items() if k != "brawlers"}), ensure_ascii=False, indent=1))
    b = (p.get("brawlers") or [None])[0]
    print("== brawlers[0] の項目 ==")
    print(json.dumps(shape(b), ensure_ascii=False, indent=1))
    print("== brawlers[0] の値（キャラの数値のみ）==")
    print(json.dumps({k: v for k, v in (b or {}).items() if not isinstance(v, (list, dict))}, ensure_ascii=False))
    for key in ("gears", "gadgets", "starPowers", "hyperCharges", "buffies"):
        if b and key in b:
            print(f"   {key}:", json.dumps(b[key][:2], ensure_ascii=False))
    print("brawlers 数:", len(p.get("brawlers", [])))

    log = get(f"players/{q}/battlelog").get("items", [])
    print("== /battlelog ==", len(log), "件 / type:", sorted({(i.get('battle') or {}).get('type') for i in log}, key=str))
    ranked = [i for i in log if (i.get("battle") or {}).get("type") in ("soloRanked", "teamRanked")]
    sample = ranked[0] if ranked else (log[0] if log else None)
    if sample:
        print("== 対戦 1 件の項目（ガチバトル優先）==")
        print(json.dumps(shape(sample), ensure_ascii=False, indent=1))
        battle = sample.get("battle") or {}
        teams = battle.get("teams") or []
        if teams:
            print("チーム 0 のプレイヤー値:", json.dumps(teams[0], ensure_ascii=False)[:600])
        print("battle の直下の値:", json.dumps({k: v for k, v in battle.items() if k not in ("teams", "players")}, ensure_ascii=False))
    print("== クラブ ==", json.dumps(p.get("club"), ensure_ascii=False))
    print("プレイヤーランキング項目:", json.dumps(shape(get("rankings/global/players?limit=1")["items"][0]), ensure_ascii=False))
    for ep in ("rankings/global/brawlers/16000000?limit=1", "rankings/JP/clubs?limit=1"):
        try:
            print(ep, "→", json.dumps(shape(get(ep)["items"][0]), ensure_ascii=False))
        except Exception as e:  # noqa: BLE001
            print(ep, "→ 失敗", e)


if __name__ == "__main__":
    main()
