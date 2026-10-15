#!/usr/bin/env python3
"""ガチバトル（ランク）の実測勝率を、Supercell 公式 API の対戦履歴から集計する。

Brawlify の勝率 API は Cloudflare に阻まれて取れない（README §8）。そこで
**公式 API の対戦履歴（直近 25 戦 / 人）を自前でクロールして勝率を出す**。
Brawlify や BrawlTime などの統計サイトも中身は同じ方法で作っている。

    ランキング上位プレイヤー ──▶ 対戦履歴 ──▶ type が soloRanked の試合だけ抽出
            ▲                                     │
            └──── その試合に出ていた他プレイヤー ◀─┘（芋づる式に広げる）

集計結果は data/ranked_stats.json に「日ごとに減衰する累積値」として持つ。
毎日 0.9 倍してから新しい試合を足すので、実効的には直近 2 週間ほどの重みになり、
バランス調整が入っても数日で新しい環境に追従する。同じ試合は最大 6 人の履歴に
重複して現れるので、試合キー（時刻＋参加者タグ）で重複を除く。

API キー（無料）:
  1. https://developer.brawlstars.com/ でアカウントを作り「Create New Key」
  2. 許可 IP に 45.79.218.79 を登録する（RoyaleAPI の公開プロキシの IP）
  3. そのキーを BRAWLSTARS_API_TOKEN に入れる（GitHub なら Repository secrets）

公式 API は IP 固定キーなので、IP が毎回変わる GitHub Actions からは直接叩けない。
RoyaleAPI が公開している固定 IP のプロキシ（bsproxy.royaleapi.dev）を経由すれば、
同じキーでどこからでも呼べる。直接叩ける環境なら BRAWLSTARS_API_BASE で切り替える。

使い方:
    python3 scripts/ranked_stats.py                 # クロールして data/ranked_stats.json を更新
    python3 scripts/ranked_stats.py --max-requests 300 --minutes 2   # お試し
    python3 scripts/ranked_stats.py --fixture tests/battlelog.json   # オフライン検証
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter, deque
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from brawl_api import (  # noqa: E402
    _SSL_CONTEXT,
    OFFICIAL_TOKEN_ENV,
    PROJECT_ROOT,
    USER_AGENT,
    load_json,
    official_base,
    official_token,
    save_json,
)

STATS_PATH = PROJECT_ROOT / "data" / "ranked_stats.json"

# ガチバトルの試合種別。trophy 戦は "ranked"（紛らわしいが別物）なので含めない。
RANKED_TYPES = {"soloRanked", "teamRanked"}

# 種まきに使う国別ランキング。日本の上位帯を厚めに取りつつ、母数のために主要地域も混ぜる。
SEED_COUNTRIES = ("global", "JP", "KR", "US", "BR", "MX", "DE", "FR", "ES", "TR", "IT", "GB")

DECAY_PER_DAY = 0.90
SEEN_KEEP_DAYS = 3
MAX_SEEDS = 4000


# --------------------------------------------------------------------------
# API
# --------------------------------------------------------------------------

class ApiError(RuntimeError):
    pass


class Client:
    def __init__(self, token: str, base: str) -> None:
        self.token = token
        self.base = base.rstrip("/")
        self.requests = 0
        self._lock = threading.Lock()

    def get(self, path: str) -> dict:
        url = f"{self.base}/{path.lstrip('/')}"
        req = urllib.request.Request(url, headers={
            "Authorization": f"Bearer {self.token}",
            "Accept": "application/json",
            "User-Agent": USER_AGENT,
        })
        last = ""
        for attempt in range(4):
            with self._lock:
                self.requests += 1
            try:
                with urllib.request.urlopen(req, timeout=20, context=_SSL_CONTEXT) as res:
                    return json.loads(res.read())
            except urllib.error.HTTPError as exc:
                if exc.code == 404:
                    return {}
                if exc.code == 403:
                    body = exc.read()[:300].decode("utf-8", "replace")
                    raise ApiError(
                        "公式 API に拒否されました (403)。キーの許可 IP に 45.79.218.79 "
                        f"（プロキシ経由の場合）が入っているか確認してください: {body}"
                    ) from exc
                if exc.code in (429, 500, 502, 503, 504):
                    last = f"HTTP {exc.code}"
                    time.sleep(1.0 * (2**attempt))
                    continue
                raise ApiError(f"HTTP {exc.code}: {url}") from exc
            except (urllib.error.URLError, TimeoutError) as exc:
                last = str(exc)
                time.sleep(1.0 * (2**attempt))
        raise ApiError(f"取得失敗 ({last}): {url}")

    def ranking(self, country: str) -> list[str]:
        doc = self.get(f"rankings/{country}/players?limit=200")
        return [p["tag"] for p in doc.get("items", []) if p.get("tag")]

    def battlelog(self, tag: str) -> list[dict]:
        doc = self.get(f"players/{urllib.parse.quote(tag)}/battlelog")
        return doc.get("items", []) or []


# --------------------------------------------------------------------------
# 試合の取り出し
# --------------------------------------------------------------------------

def parse_battle(item: dict, owner: str | None) -> dict | None:
    """対戦履歴 1 件を「勝ったチーム / 負けたチーム」に正規化する。対象外なら None。"""
    battle = item.get("battle") or {}
    if battle.get("type") not in RANKED_TYPES:
        return None
    teams = battle.get("teams") or []
    if len(teams) != 2 or any(len(t) != 3 for t in teams):
        return None
    event = item.get("event") or {}
    map_id = event.get("id")
    if not map_id:
        return None

    result = battle.get("result")
    if result not in ("victory", "defeat"):
        return None  # 引き分けは勝率に入れない

    tags = [[p.get("tag", "") for p in t] for t in teams]
    ids = [[int((p.get("brawler") or {}).get("id", 0)) for p in t] for t in teams]
    if any(0 in t for t in ids):
        return None

    # result は履歴の持ち主から見た結果。持ち主がどちらのチームかで勝者を決める。
    owner_team = 0
    if owner:
        for i, t in enumerate(tags):
            if owner in t:
                owner_team = i
                break
    winner = owner_team if result == "victory" else 1 - owner_team

    all_tags = sorted(tags[0] + tags[1])
    key_src = f"{item.get('battleTime')}|{map_id}|{','.join(all_tags)}"
    key = hashlib.sha1(key_src.encode()).hexdigest()[:14]

    ranks = [int((p.get("brawler") or {}).get("trophies", 0) or 0) for t in teams for p in t]
    return {
        "key": key,
        "time": item.get("battleTime", ""),
        "mapId": int(map_id),
        "mode": battle.get("mode") or event.get("mode") or "unknown",
        "type": battle.get("type"),
        "winners": ids[winner],
        "losers": ids[1 - winner],
        "tags": all_tags,
        "rank": min(ranks) if ranks else 0,
    }


# --------------------------------------------------------------------------
# 集計（減衰付き累積）
# --------------------------------------------------------------------------

def empty_store() -> dict:
    return {
        "schema": 1,
        "updatedAt": None,
        "decayPerDay": DECAY_PER_DAY,
        "lastDecayDate": None,
        "battles": 0.0,
        "maps": {},
        "vs": {},
        "with": {},
        "seen": {},
        "seeds": [],
        "lastRun": {},
    }


def _scale_pairs(table: dict, factor: float) -> None:
    for a in list(table):
        inner = table[a]
        for b in list(inner):
            g, w = inner[b]
            g *= factor
            if g < 0.05:
                del inner[b]
            else:
                inner[b] = [g, w * factor]
        if not inner:
            del table[a]


def apply_decay(store: dict, today: dt.date) -> None:
    last = store.get("lastDecayDate")
    if not last:
        store["lastDecayDate"] = today.isoformat()
        return
    days = (today - dt.date.fromisoformat(last)).days
    if days <= 0:
        return
    factor = store.get("decayPerDay", DECAY_PER_DAY) ** days
    store["battles"] *= factor
    for m in list(store["maps"]):
        entry = store["maps"][m]
        entry["battles"] *= factor
        for b in list(entry["b"]):
            g, w = entry["b"][b]
            g *= factor
            if g < 0.05:
                del entry["b"][b]
            else:
                entry["b"][b] = [g, w * factor]
        if entry["battles"] < 0.05:
            del store["maps"][m]
    _scale_pairs(store["vs"], factor)
    _scale_pairs(store["with"], factor)
    store["lastDecayDate"] = today.isoformat()


def add_battle(store: dict, b: dict) -> None:
    mid = str(b["mapId"])
    entry = store["maps"].setdefault(mid, {"mode": b["mode"], "battles": 0.0, "b": {}, "lastSeen": ""})
    entry["battles"] += 1
    entry["mode"] = b["mode"]
    day = b["time"][:8]
    if day > entry.get("lastSeen", ""):
        entry["lastSeen"] = day
    store["battles"] += 1

    for team, won in ((b["winners"], 1), (b["losers"], 0)):
        for bid in team:
            g, w = entry["b"].get(str(bid), [0.0, 0.0])
            entry["b"][str(bid)] = [g + 1, w + won]

    # 対面: 小さい ID 側から見た勝敗だけを持つ（逆向きは 1 - 勝率で引ける）
    for x in b["winners"]:
        for y in b["losers"]:
            a, c = (x, y) if x < y else (y, x)
            won = 1 if a == x else 0
            row = store["vs"].setdefault(str(a), {})
            g, w = row.get(str(c), [0.0, 0.0])
            row[str(c)] = [g + 1, w + won]

    # 同じチーム
    for team, won in ((b["winners"], 1), (b["losers"], 0)):
        s = sorted(team)
        for i in range(3):
            for j in range(i + 1, 3):
                row = store["with"].setdefault(str(s[i]), {})
                g, w = row.get(str(s[j]), [0.0, 0.0])
                row[str(s[j])] = [g + 1, w + won]


def round_store(store: dict) -> None:
    """JSON を小さく保つため小数 2 桁に丸める。"""
    store["battles"] = round(store["battles"], 2)
    for entry in store["maps"].values():
        entry["battles"] = round(entry["battles"], 2)
        entry["b"] = {k: [round(g, 2), round(w, 2)] for k, (g, w) in entry["b"].items()}
    for table in (store["vs"], store["with"]):
        for a in table:
            table[a] = {k: [round(g, 2), round(w, 2)] for k, (g, w) in table[a].items()}


# --------------------------------------------------------------------------
# クロール
# --------------------------------------------------------------------------

def crawl(client: Client, store: dict, max_requests: int, minutes: float, workers: int,
          min_rank: int) -> dict:
    deadline = time.monotonic() + minutes * 60
    queue: deque[str] = deque()
    queued: set[str] = set()

    def enqueue(tag: str, front: bool = False) -> None:
        if tag and tag not in queued:
            queued.add(tag)
            (queue.appendleft if front else queue.append)(tag)

    # 前回見つけたランク勢を先に（ランク戦をよくやる人ほど情報が濃い）
    for tag in store.get("seeds", [])[:MAX_SEEDS]:
        enqueue(tag)
    for country in SEED_COUNTRIES:
        try:
            for tag in client.ranking(country):
                enqueue(tag)
        except ApiError as exc:
            if "403" in str(exc):
                raise
            print(f"  ! ランキング {country} の取得に失敗: {exc}", file=sys.stderr)
    print(f"  種まき: {len(queue)} 人")

    seen: dict = store["seen"]
    new_battles = 0
    types: Counter = Counter()
    ranked_players: Counter = Counter()
    fetched = 0
    lock = threading.Lock()

    def handle(tag: str, items: list[dict]) -> None:
        nonlocal new_battles
        for item in items:
            t = (item.get("battle") or {}).get("type") or "?"
            with lock:
                types[t] += 1
            b = parse_battle(item, tag)
            if not b or b["rank"] < min_rank:
                continue
            with lock:
                for other in b["tags"]:
                    ranked_players[other] += 1
                    enqueue(other, front=True)  # ランク勢の芋づるを優先
                if b["key"] in seen:
                    continue
                seen[b["key"]] = b["time"][:8]
                add_battle(store, b)
                new_battles += 1

    with ThreadPoolExecutor(max_workers=workers) as pool:
        running = {}
        while True:
            budget_left = client.requests < max_requests and time.monotonic() < deadline
            while budget_left and queue and len(running) < workers * 2:
                tag = queue.popleft()
                running[pool.submit(client.battlelog, tag)] = tag
            if not running:
                break
            done, _ = wait(running, timeout=30, return_when=FIRST_COMPLETED)
            for fut in done:
                tag = running.pop(fut)
                try:
                    handle(tag, fut.result())
                    fetched += 1
                except ApiError as exc:
                    if "403" in str(exc):
                        raise
            if fetched and fetched % 250 == 0:
                print(f"  … {fetched} 人 / 新規ランク戦 {new_battles}")

    # 次回の種: よくランク戦に出てくる人から
    previous = store.get("seeds", [])
    merged = [t for t, _ in ranked_players.most_common()] + previous
    dedup: list[str] = []
    s: set[str] = set()
    for t in merged:
        if t not in s:
            s.add(t)
            dedup.append(t)
    store["seeds"] = dedup[:MAX_SEEDS]

    return {
        "playersFetched": fetched,
        "requests": client.requests,
        "newRankedBattles": new_battles,
        "battleTypes": dict(types.most_common(12)),
    }


def prune_seen(store: dict, today: dt.date) -> None:
    cutoff = (today - dt.timedelta(days=SEEN_KEEP_DAYS)).strftime("%Y%m%d")
    store["seen"] = {k: d for k, d in store["seen"].items() if d >= cutoff}


# --------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description="ガチバトルの実測勝率を集計")
    ap.add_argument("--max-requests", type=int, default=4000)
    ap.add_argument("--minutes", type=float, default=9.0)
    ap.add_argument("--workers", type=int, default=10)
    ap.add_argument("--min-rank", type=int, default=0,
                    help="この値未満のランク帯（brawler.trophies の最小値）の試合を除外")
    ap.add_argument("--fixture", default="",
                    help="API の代わりに対戦履歴 JSON（{tag: items}）を読む。検証用")
    ap.add_argument("--out", default=str(STATS_PATH))
    args = ap.parse_args()

    out = Path(args.out)
    store = load_json(out, None) or empty_store()
    today = dt.datetime.now(dt.timezone.utc).date()
    apply_decay(store, today)

    if args.fixture:
        logs = json.loads(Path(args.fixture).read_text(encoding="utf-8"))
        before = len(store["seen"])
        for tag, items in logs.items():
            for item in items:
                b = parse_battle(item, tag)
                if b and b["key"] not in store["seen"]:
                    store["seen"][b["key"]] = b["time"][:8]
                    add_battle(store, b)
        run = {"fixture": args.fixture, "newRankedBattles": len(store["seen"]) - before}
    else:
        token = official_token()
        if not token:
            print(f"  · {OFFICIAL_TOKEN_ENV} が未設定のため、実測勝率の更新をスキップします。")
            return 0
        base = official_base()
        print(f"▶ ガチバトルの対戦履歴を収集中 …（{base}）")
        try:
            run = crawl(Client(token, base), store, args.max_requests, args.minutes,
                        args.workers, args.min_rank)
        except ApiError as exc:
            print(f"✖ {exc}", file=sys.stderr)
            return 1

    prune_seen(store, today)
    round_store(store)
    store["updatedAt"] = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
    run["date"] = today.isoformat()
    store["lastRun"] = run
    save_json(out, store, compact=True)

    maps_live = sum(1 for m in store["maps"].values() if m["battles"] >= 25)
    print(f"✔ {out}: 新規 {run.get('newRankedBattles', 0)} 試合 / 累積(減衰後) "
          f"{store['battles']:.0f} 試合 / 十分なデータのあるマップ {maps_live}")
    if run.get("battleTypes"):
        print(f"  試合種別の内訳: {run['battleTypes']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
