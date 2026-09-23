#!/usr/bin/env python3
"""ガチバトル用ドラフトルール (rules/rules.json) を毎日自動生成する。

やること:
  1. Brawlify API から ブラウラー / マップ / モード / 現在のローテーションを取得
  2. マップ別の実測勝率・使用率を取得（取得できない場合はアーキタイプ適性のみで計算）
  3. BAN 推奨 / 初手 / 中盤 / ラストピック のロジックを計算
  4. マップ画像のテンプレート記述子を同梱（iOS 側がマップを画像で判別するため）
  5. rules/rules.json として書き出す

使い方:
    python3 scripts/update_meta.py                 # ランクモードの全マップ
    python3 scripts/update_meta.py --rotation-only # 現在ローテ入りのマップのみ
    python3 scripts/update_meta.py --top 30        # 1マップあたりの候補数
"""

from __future__ import annotations

import argparse
import datetime as dt
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from brawl_api import (  # noqa: E402
    OFFICIAL_TOKEN_ENV,
    PROJECT_ROOT,
    BrawlAPIError,
    NotFoundError,
    fetch_bytes,
    fetch_json,
    fetch_official_rotation,
    load_json,
    official_token,
    save_json,
)
from classify import merge_roles  # noqa: E402
from download_icons import build_descriptor  # noqa: E402

DATA_DIR = PROJECT_ROOT / "data"
RULES_PATH = PROJECT_ROOT / "rules" / "rules.json"
MAP_THUMB_DIR = PROJECT_ROOT / "assets" / "map_thumbs"

ROLES_PATH = DATA_DIR / "brawler_roles.json"

# 役割ごとに最低この数だけ candidates へ入れる（iOS のライブ計算でカウンターを切らさないため）
CANDIDATES_PER_ROLE = 4
ARCH_PATH = DATA_DIR / "archetypes.json"
TIERS_PATH = DATA_DIR / "tier_overrides.json"
NAMES_JA_PATH = DATA_DIR / "brawler_names_ja.json"


# --------------------------------------------------------------------------
# 入力
# --------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="rules.json の生成")
    ap.add_argument("--top", type=int, default=24, help="1マップあたりに載せる候補数")
    ap.add_argument("--rotation-only", action="store_true",
                    help="現在ローテーション中のマップだけを対象にする")
    ap.add_argument("--max-maps", type=int, default=0, help="デバッグ用の上限（0=無制限）")
    ap.add_argument("--workers", type=int, default=6, help="API 並列数")
    ap.add_argument("--no-thumbs", action="store_true", help="マップ画像を取得しない")
    ap.add_argument("--require-stats", action="store_true",
                    help="実測勝率が1マップも取れなかったら失敗させる（CI 用）")
    ap.add_argument("--rotation-out", default="",
                    help="ローテ中マップだけの軽量版をこのパスにも書き出す")
    ap.add_argument("--out", default=str(RULES_PATH))
    return ap.parse_args()


def load_knowledge() -> tuple[dict, dict, dict]:
    arch = load_json(ARCH_PATH)
    if not arch:
        raise SystemExit(f"{ARCH_PATH} がありません")
    validate_matrices(arch)
    roles_doc = load_json(ROLES_PATH, {"brawlers": []})
    tiers = (load_json(TIERS_PATH, {}) or {}).get("tiers", {})
    return arch, roles_doc, tiers


def validate_matrices(arch: dict) -> None:
    """相性表が反対称か / シナジー表が対称かを検査する（手編集の事故防止）。"""
    adv, syn = arch["advantage"], arch["synergy"]
    for a in adv:
        for b in adv[a]:
            if adv[a][b] != -adv[b][a]:
                raise SystemExit(f"advantage が反対称ではありません: {a}->{b}")
            if syn[a][b] != syn[b][a]:
                raise SystemExit(f"synergy が対称ではありません: {a}<->{b}")


# --------------------------------------------------------------------------
# API 取得
# --------------------------------------------------------------------------

def fetch_rotation() -> tuple[set[int], dict]:
    """現在 / 次のローテーションに入っているマップ ID を返す。

    1. Supercell 公式 API（BRAWLSTARS_API_TOKEN があれば。こちらが確実）
    2. Brawlify の /events（ミラー経由だと空で返ってくることがある）
    """
    ids, detail = _rotation_from_official()
    if ids:
        return ids, detail

    try:
        events = fetch_json("events")
    except BrawlAPIError as exc:
        print(f"  ! ローテーション取得に失敗: {exc}", file=sys.stderr)
        return set(), {"active": [], "upcoming": [], "source": "none"}

    ids: set[int] = set()
    detail: dict = {"active": [], "upcoming": [], "source": "brawlify"}
    for bucket in ("active", "upcoming"):
        for slot in events.get(bucket) or []:
            m = slot.get("map") or {}
            if not m.get("id"):
                continue
            ids.add(m["id"])
            detail[bucket].append({
                "mapId": m["id"],
                "mapName": m.get("name"),
                "mode": ((m.get("gameMode") or {}).get("name")),
                "startTime": slot.get("startTime"),
                "endTime": slot.get("endTime"),
            })
    return ids, detail


def _rotation_from_official() -> tuple[set[int], dict]:
    """公式 API 版。トークン未設定なら黙って空を返す。"""
    if not official_token():
        return set(), {}
    try:
        rotation = fetch_official_rotation()
    except BrawlAPIError as exc:
        print(f"  ! 公式 API でのローテーション取得に失敗: {exc}", file=sys.stderr)
        return set(), {}

    now = dt.datetime.now(dt.timezone.utc)
    ids: set[int] = set()
    detail: dict = {"active": [], "upcoming": [], "source": "official"}

    def parse_time(value: str | None) -> dt.datetime | None:
        if not value:
            return None
        try:  # Supercell の形式: 20260923T080000.000Z
            return dt.datetime.strptime(value, "%Y%m%dT%H%M%S.%fZ").replace(
                tzinfo=dt.timezone.utc
            )
        except ValueError:
            return None

    for slot in rotation:
        event = slot.get("event") or {}
        map_id = event.get("id")
        if not map_id:
            continue
        ids.add(int(map_id))
        start = parse_time(slot.get("startTime"))
        bucket = "upcoming" if start and start > now else "active"
        detail[bucket].append({
            "mapId": int(map_id),
            "mapName": event.get("map"),
            "mode": event.get("mode"),
            "startTime": slot.get("startTime"),
            "endTime": slot.get("endTime"),
        })
    if ids:
        print(f"  公式 API からローテーションを取得しました（{len(ids)} マップ）")
    return ids, detail


def fetch_map_stats(map_id: int) -> list[dict]:
    """マップ別のブラウラー統計。取得できないときは空リスト。"""
    try:
        doc = fetch_json(f"maps/{map_id}")
    except (BrawlAPIError, NotFoundError):
        return []
    out = []
    for row in doc.get("stats") or []:
        bid = row.get("brawler") or row.get("id")
        if bid is None:
            continue
        out.append({
            "id": int(bid),
            "winRate": float(row.get("winRate", row.get("winrate", 0)) or 0),
            "useRate": float(row.get("useRate", row.get("userate", 0)) or 0),
        })
    return out


def download_thumb(map_doc: dict) -> Path | None:
    url = map_doc.get("imageUrl")
    if not url:
        return None
    dest = MAP_THUMB_DIR / f"{map_doc['id']}.png"
    if dest.exists() and dest.stat().st_size > 0:
        return dest
    try:
        payload = fetch_bytes(url)
    except BrawlAPIError:
        return None
    if not payload.startswith(b"\x89PNG"):
        return None
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(payload)
    return dest


# --------------------------------------------------------------------------
# スコアリング
# --------------------------------------------------------------------------

def quality_note(maps_with_stats: int, tier_count: int) -> str:
    """rules.json を読む側（アプリ・人間）へ、スコアの出どころを正確に伝える。"""
    if maps_with_stats:
        return (
            "スコア = 実測勝率z値×0.65 + アーキタイプ適性×0.35 + 手動ティア×0.20。"
            "マップごとの実測勝率が入っているので順位には意味があります。"
        )
    if tier_count:
        return (
            f"実測勝率が取得できていないため、スコア = アーキタイプ適性 + 手動ティア×0.50。"
            f"data/tier_overrides.json の手入力値 {tier_count} 件で同点は解消されていますが、"
            "これは測定値ではなく手入力の初期値です。"
        )
    return (
        "実測勝率も手動ティアも無いため、スコアはアーキタイプ適性のみです。"
        "同じ役割のキャラは同点になり、並び順は名前順（＝順位に意味なし）です。"
    )


def zscore(values: list[float]) -> list[float]:
    if not values:
        return []
    mean = sum(values) / len(values)
    var = sum((v - mean) ** 2 for v in values) / len(values)
    sd = var**0.5 or 1.0
    return [(v - mean) / sd for v in values]


def meta_scores(stats: list[dict]) -> dict[int, dict]:
    """勝率・使用率を z 値へ。勝率を主、使用率を従とする。"""
    if not stats:
        return {}
    wins = zscore([s["winRate"] for s in stats])
    uses = zscore([s["useRate"] for s in stats])
    return {
        s["id"]: {
            "winRate": round(s["winRate"], 2),
            "useRate": round(s["useRate"], 2),
            "z": round(0.75 * w + 0.25 * u, 4),
            "pressure": round(0.5 * w + 0.5 * u, 4),  # BAN 判定用（強さ×人気）
        }
        for s, w, u in zip(stats, wins, uses)
    }


def pool_distribution(pool: list[dict]) -> dict[str, float]:
    """候補プールのアーキタイプ構成比。相手に出てきやすい役割の重み付けに使う。"""
    total = len(pool) or 1
    dist = {}
    for e in pool:
        dist[e["role"]] = dist.get(e["role"], 0.0) + 1.0 / total
    return dist


def build_map_entry(
    map_doc: dict,
    brawlers: list[dict],
    role_of: dict[int, str],
    arch: dict,
    tiers: dict[str, float],
    stats: list[dict],
    top: int,
    in_rotation: bool,
    thumb: Path | None,
) -> dict:
    mode_name = (map_doc.get("gameMode") or {}).get("name") or "Unknown"
    mode_cfg = arch["modes"].get(mode_name, {})
    weights = mode_cfg.get("weights", {})
    adv, syn = arch["advantage"], arch["synergy"]
    arch_ja = {k: v["ja"] for k, v in arch["archetypes"].items()}

    metas = meta_scores(stats)
    has_stats = bool(metas)

    # --- 素点 ---
    scored: list[dict] = []
    for b in brawlers:
        role = role_of.get(b["id"])
        if not role:
            continue
        fit = float(weights.get(role, 0.0))
        tier = float(tiers.get(b["name"], 0.0))
        m = metas.get(b["id"])
        if has_stats and m:
            base = 0.65 * m["z"] + 0.35 * fit + 0.20 * tier
        elif has_stats:
            continue  # 統計はあるのに載っていない = そのマップでは実質使われていない
        else:
            base = fit + 0.50 * tier
        scored.append({
            "id": b["id"],
            "name": b["name"],
            "role": role,
            "roleJa": arch_ja[role],
            "base": round(base, 4),
            "winRate": (m or {}).get("winRate"),
            "useRate": (m or {}).get("useRate"),
            "pressure": (m or {}).get("pressure", 0.0) or 0.0,
        })

    # 同点は名前順で安定させる（統計が無い日でも出力がブレないように）
    scored.sort(key=lambda e: (-e["base"], e["name"]))
    pool = scored[: max(top, 20)]
    dist = pool_distribution(pool)

    # 相性計算には全キャラを使う。上位プールだけだとカウンター役が候補から消える。
    for e in scored:
        r = e["role"]
        e["vulnerability"] = round(
            sum(dist.get(en, 0.0) * max(0.0, -adv[r][en]) for en in dist), 4
        )
        e["expAdvantage"] = round(sum(dist.get(en, 0.0) * adv[r][en] for en in dist), 4)
        e["expSynergy"] = round(sum(dist.get(al, 0.0) * syn[r][al] for al in dist), 4)

    # iOS 側はこの candidates だけを見てライブ計算するので、素点の上位だけだと
    # 「カウンター役がそもそも候補に載っていない」状態になる。
    # 各アーキタイプの上位も必ず混ぜておく。
    candidate_pool = list(pool[:top])
    seen_ids = {e["id"] for e in candidate_pool}
    for role_key in arch["archetypes"]:
        for e in [x for x in scored if x["role"] == role_key][:CANDIDATES_PER_ROLE]:
            if e["id"] not in seen_ids:
                candidate_pool.append(e)
                seen_ids.add(e["id"])
    candidate_pool.sort(key=lambda e: (-e["base"], e["name"]))

    def stat_phrase(e: dict) -> str:
        if e.get("winRate") is None:
            return ""
        return f"（勝率 {e['winRate']}% / 使用率 {e['useRate']}%）"

    def full(e: dict, score: float, reason: str, **extra) -> dict:
        out = {"id": e["id"], "name": e["name"], "role": e["role"], "roleJa": e["roleJa"],
               "score": round(score, 3), "reason": reason}
        if e.get("winRate") is not None:
            out["winRate"] = e["winRate"]
            out["useRate"] = e["useRate"]
        out.update(extra)
        return out

    def slim(e: dict, score: float, **extra) -> dict:
        """iOS 側が文面を組み立てる前提の軽量エントリ。"""
        out = {"id": e["id"], "name": e["name"], "role": e["role"], "score": round(score, 3)}
        out.update(extra)
        return out

    def diversified(entries: list[dict], key, limit: int, penalty: float = 0.25) -> list[dict]:
        """同じ役割ばかり並ばないよう、既出ロールに減点しながら選ぶ。"""
        remaining = list(entries)
        seen: dict[str, int] = {}
        picked: list[tuple[dict, float]] = []
        while remaining and len(picked) < limit:
            best = max(remaining, key=lambda e: key(e) - penalty * seen.get(e["role"], 0))
            picked.append((best, key(best)))
            seen[best["role"]] = seen.get(best["role"], 0) + 1
            remaining.remove(best)
        return picked

    # --- BAN 推奨: 強くて人気 = 放置すると必ず相手に使われる ---
    ban_key = ((lambda e: e["pressure"]) if has_stats
               else (lambda e: e["base"] - 0.3 * e["vulnerability"]))
    ban_list = [
        full(e, score,
             f"{e['roleJa']}。このマップの環境トップ{stat_phrase(e)}。"
             f"先に消さないと確実に相手に使われる。")
        for e, score in diversified(pool, ban_key, arch["ban"]["count"], penalty=0.30)
    ]
    banned_ids = {e["id"] for e in ban_list}
    available = [e for e in scored if e["id"] not in banned_ids]
    top_available = [e for e in pool if e["id"] not in banned_ids]

    # --- 初手（1番目）: 強く、かつ対策されにくい ---
    first_key = lambda e: e["base"] - 0.35 * e["vulnerability"]  # noqa: E731
    first_list = [
        full(e, score,
             f"対策されにくい{e['roleJa']}{stat_phrase(e)}。"
             f"苦手な相手が環境に少なく（被カウンター指数 {e['vulnerability']:.2f}）、初手で腐らない。",
             vulnerability=e["vulnerability"])
        for e, score in diversified(top_available, first_key, 5)
    ]

    # --- 中盤（2〜5番目）: シナジー + 部分的カウンター ---
    middle_key = lambda e: e["base"] + 0.45 * e["expSynergy"] + 0.35 * e["expAdvantage"]  # noqa: E731
    middle_general = [
        full(e, score,
             f"{e['roleJa']}。味方と噛み合いつつ相手にも部分的に刺さる{stat_phrase(e)}。",
             synergy=e["expSynergy"], advantage=e["expAdvantage"])
        for e, score in diversified(top_available, middle_key, 8)
    ]
    middle_by_ally = {
        ally: [
            slim(e, e["base"] + 0.8 * syn[e["role"]][ally], synergy=syn[e["role"]][ally])
            for e in sorted(available,
                            key=lambda x: (-(x["base"] + 0.8 * syn[x["role"]][ally]), x["name"]))[:4]
        ]
        for ally in arch["archetypes"]
    }
    middle_by_enemy = {
        enemy: [
            slim(e, e["base"] + 0.6 * adv[e["role"]][enemy], advantage=adv[e["role"]][enemy])
            for e in sorted(available,
                            key=lambda x: (-(x["base"] + 0.6 * adv[x["role"]][enemy]), x["name"]))[:4]
        ]
        for enemy in arch["archetypes"]
    }

    # --- ラスト（6番目）: 相手構成への絶対的カウンター ---
    def last_reason(e: dict, enemy: str) -> str:
        a = adv[e["role"]][enemy]
        if a >= 2:
            head = f"{arch_ja[enemy]}に対する決定打"
        elif a == 1:
            head = f"{arch_ja[enemy]}に有利"
        else:
            head = f"{arch_ja[enemy]}への明確なカウンターは薄い。素の強さで押す"
        return f"{head}。{e['roleJa']}として相性 {a:+d}{stat_phrase(e)}。"

    last_by_enemy = {}
    for enemy in arch["archetypes"]:
        key = lambda e, en=enemy: 1.6 * adv[e["role"]][en] + 0.5 * e["base"]  # noqa: E731
        last_by_enemy[enemy] = [
            full(e, score, last_reason(e, enemy), advantage=adv[e["role"]][enemy])
            for e, score in diversified(available, key, 5, penalty=0.4)
        ]

    entry = {
        "id": map_doc["id"],
        "name": map_doc["name"],
        "hash": map_doc.get("hash"),
        "mode": mode_name,
        "modeJa": mode_cfg.get("ja", mode_name),
        "environment": (map_doc.get("environment") or {}).get("name"),
        "inRotation": in_rotation,
        "hasLiveStats": has_stats,
        "imageUrl": map_doc.get("imageUrl"),
        "nameAliases": [],   # 日本語マップ名などを手で追記できる欄
        "bans": ban_list,
        "picks": {
            "first": first_list,
            "middle": {
                "general": middle_general,
                "byAllyRole": middle_by_ally,
                "byEnemyRole": middle_by_enemy,
            },
            "last": {"byEnemyRole": last_by_enemy},
        },
        "candidates": [
            {"id": e["id"], "name": e["name"], "role": e["role"], "base": e["base"],
             "winRate": e.get("winRate"), "useRate": e.get("useRate")}
            for e in candidate_pool
        ],
    }

    if thumb is not None:
        desc = build_descriptor(thumb)
        if desc:
            entry["template"] = {
                "gray": [round(v, 4) for v in desc["gray"]],
                "color": [round(v, 4) for v in desc["color"]],
                "dhash": desc["dhash"],
            }
    return entry


# --------------------------------------------------------------------------
# メイン
# --------------------------------------------------------------------------

def main() -> int:
    args = parse_args()
    arch, roles_doc, tiers = load_knowledge()
    if tiers:
        print(f"  data/tier_overrides.json を適用: {len(tiers)} 件")

    print("▶ ブラウラー / マップ / モードを取得中 …")
    brawlers = fetch_json("brawlers")["list"]
    maps = fetch_json("maps")["list"]
    print(f"  ブラウラー {len(brawlers)} / マップ {len(maps)}")

    # 新キャラを roles へ取り込む（manual は温存）
    roles_doc, newly = merge_roles(brawlers, roles_doc)
    if newly:
        print(f"  + 新キャラを自動分類: {', '.join(newly)}")
    save_json(ROLES_PATH, roles_doc)
    role_of = {e["id"]: e["role"] for e in roles_doc["brawlers"]}

    if not official_token():
        print(f"  · {OFFICIAL_TOKEN_ENV} 未設定（公式 API を使うとローテーションが確実に取れます）")

    print("▶ 現在のローテーションを取得中 …")
    rotation_ids, rotation_detail = fetch_rotation()
    print(f"  ローテ入り {len(rotation_ids)} マップ"
          + ("" if rotation_ids else " … 取得できなかったのでランクモード全マップを対象にします"))

    ranked_modes = {m for m, c in arch["modes"].items() if c.get("ranked")}
    targets = [
        m for m in maps
        if not m.get("disabled") and (m.get("gameMode") or {}).get("name") in ranked_modes
    ]
    if args.rotation_only and rotation_ids:
        targets = [m for m in targets if m["id"] in rotation_ids]
    targets.sort(key=lambda m: (m["gameMode"]["name"], m["name"]))
    if args.max_maps:
        targets = targets[: args.max_maps]
    print(f"▶ 対象マップ {len(targets)} 件（ランクモード: {', '.join(sorted(ranked_modes))}）")

    print("▶ マップ別の統計と画像を取得中 …")
    stats_by_map: dict[int, list[dict]] = {}
    thumbs: dict[int, Path | None] = {}
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        stat_futs = {pool.submit(fetch_map_stats, m["id"]): m["id"] for m in targets}
        thumb_futs = ({} if args.no_thumbs
                      else {pool.submit(download_thumb, m): m["id"] for m in targets})
        for fut in as_completed(stat_futs):
            stats_by_map[stat_futs[fut]] = fut.result()
        for fut in as_completed(thumb_futs):
            thumbs[thumb_futs[fut]] = fut.result()

    with_stats = sum(1 for v in stats_by_map.values() if v)
    print(f"  実測統計あり {with_stats} / {len(targets)} マップ"
          + ("" if with_stats else " … アーキタイプ適性のみで計算します"))
    print(f"  マップ画像 {sum(1 for v in thumbs.values() if v)} 件")

    entries = [
        build_map_entry(
            m, brawlers, role_of, arch, tiers,
            stats_by_map.get(m["id"], []), args.top,
            m["id"] in rotation_ids, thumbs.get(m["id"]),
        )
        for m in targets
    ]

    arch_ja = {k: v["ja"] for k, v in arch["archetypes"].items()}
    # モード単位の重み付け。マップ情報が読めない画面（ブラインドピック等）でも
    # 「モード名の OCR 結果」さえ分かればアーキタイプ適性を計算できるようにする。
    modes_export = {
        key: {"ja": cfg["ja"], "weights": cfg.get("weights", {})}
        for key, cfg in arch["modes"].items()
    }
    names_ja = (load_json(NAMES_JA_PATH, {}) or {}).get("names", {})
    missing_ja = [e["name"] for e in roles_doc["brawlers"] if e["name"] not in names_ja]
    if missing_ja:
        print(f"  · 読み上げ用カタカナ未登録（英語で読み上げます）: {', '.join(missing_ja)}")
    doc = {
        "schema": 2,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "source": "Brawlify API (api.brawlify.com / api.brawlapi.com)",
        "dataQuality": {
            "liveStats": with_stats > 0,
            "mapsWithLiveStats": with_stats,
            "rotationKnown": bool(rotation_ids),
            "rotationSource": rotation_detail.get("source", "none"),
            "manualTiers": len(tiers),
            "tiebreak": (
                "winRate" if with_stats
                else ("manualTier" if tiers else "alphabetical")
            ),
            "note": quality_note(with_stats, len(tiers)),
        },
        "draftOrder": arch["draftOrder"],
        "modes": modes_export,
        "archetypes": arch_ja,
        "advantage": arch["advantage"],
        "synergy": arch["synergy"],
        "rotation": rotation_detail,
        "brawlers": [
            {"id": e["id"], "name": e["name"], "nameJa": names_ja.get(e["name"]),
             "role": e["role"], "roleJa": arch_ja[e["role"]], "source": e["source"]}
            for e in roles_doc["brawlers"]
        ],
        "maps": entries,
    }

    out = Path(args.out)
    save_json(out, doc, compact=True)
    print(f"✔ {out} を書き出しました（{len(entries)} マップ / {out.stat().st_size / 1024:.0f} KB）")

    if args.rotation_out:
        rot_entries = [e for e in entries if e["inRotation"]] or entries
        rot_doc = dict(doc)
        rot_doc["maps"] = rot_entries
        rot_doc["subset"] = "rotation" if any(e["inRotation"] for e in entries) else "all"
        rot = Path(args.rotation_out)
        save_json(rot, rot_doc, compact=True)
        print(f"✔ {rot} を書き出しました（{len(rot_entries)} マップ / "
              f"{rot.stat().st_size / 1024:.0f} KB）")

    if args.require_stats and with_stats == 0:
        print("✖ 実測勝率を1マップも取得できませんでした（--require-stats）", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
