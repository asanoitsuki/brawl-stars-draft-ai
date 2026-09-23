#!/usr/bin/env python3
"""data/tier_overrides.json を扱いやすくするための小道具。

実測勝率が取れない間は、このティア値がスコアの主役になる。
手で JSON を開かなくても、役割別に眺めたり 1 体だけ直したりできるようにしてある。

    python3 scripts/tiers.py list                # 役割別に一覧
    python3 scripts/tiers.py list --role tank    # タンクだけ
    python3 scripts/tiers.py missing             # 未設定（中立扱い）のキャラ
    python3 scripts/tiers.py set Angelo 1.5      # 1 体だけ変更
    python3 scripts/tiers.py set Edgar D         # S/A/B/D/F でも指定できる
    python3 scripts/tiers.py unset Edgar         # 中立に戻す

変更後は `python3 scripts/update_meta.py` を回すと rules.json へ反映される。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from brawl_api import PROJECT_ROOT, load_json, save_json  # noqa: E402

TIERS_PATH = PROJECT_ROOT / "data" / "tier_overrides.json"
ROLES_PATH = PROJECT_ROOT / "data" / "brawler_roles.json"

# ラベル指定を数値へ
LABELS = {"S": 1.5, "A": 1.0, "B": 0.5, "C": 0.0, "N": 0.0, "D": -0.8, "F": -1.5}
ROLE_JA = {
    "tank": "タンク", "assassin": "アサシン", "marksman": "スナイパー",
    "thrower": "投擲", "controller": "コントローラー", "support": "サポート",
    "damage": "アタッカー",
}


def label_of(value: float) -> str:
    for name, v in (("S", 1.5), ("A", 1.0), ("B", 0.5), ("D", -0.8), ("F", -1.5)):
        if abs(value - v) < 0.01:
            return name
    return f"{value:+.1f}"


def load() -> tuple[dict, dict[str, str]]:
    doc = load_json(TIERS_PATH)
    if not doc:
        raise SystemExit(f"{TIERS_PATH} がありません")
    roles_doc = load_json(ROLES_PATH, {"brawlers": []})
    roles = {b["name"]: b["role"] for b in roles_doc["brawlers"]}
    if not roles:
        raise SystemExit("data/brawler_roles.json が空です。先に update_meta.py を実行してください。")
    return doc, roles


def cmd_list(args: argparse.Namespace) -> int:
    doc, roles = load()
    tiers: dict[str, float] = doc["tiers"]

    by_role: dict[str, list[tuple[str, float]]] = {}
    for name, value in tiers.items():
        role = roles.get(name, "?")
        by_role.setdefault(role, []).append((name, float(value)))

    targets = [args.role] if args.role else sorted(by_role)
    for role in targets:
        entries = sorted(by_role.get(role, []), key=lambda e: (-e[1], e[0]))
        if not entries:
            continue
        print(f"\n■ {ROLE_JA.get(role, role)}  ({len(entries)} 体)")
        for name, value in entries:
            print(f"    {label_of(value):>4}  {value:+5.2f}  {name}")

    unset = sorted(set(roles) - set(tiers))
    print(f"\n設定済み {len(tiers)} 体 / 未設定 {len(unset)} 体（中立 0 として扱われます）")
    return 0


def cmd_missing(_args: argparse.Namespace) -> int:
    doc, roles = load()
    unset = sorted(set(roles) - set(doc["tiers"]))
    if not unset:
        print("未設定のキャラはありません。")
        return 0
    print(f"未設定（中立 0 扱い）{len(unset)} 体:\n")
    by_role: dict[str, list[str]] = {}
    for name in unset:
        by_role.setdefault(roles[name], []).append(name)
    for role, names in sorted(by_role.items()):
        print(f"  {ROLE_JA.get(role, role):<12} {', '.join(sorted(names))}")
    print("\n例:  python3 scripts/tiers.py set Kaze A")
    return 0


def cmd_set(args: argparse.Namespace) -> int:
    doc, roles = load()
    name = args.name
    if name not in roles:
        close = [n for n in roles if n.lower().startswith(name.lower()[:3])]
        hint = f"  もしかして: {', '.join(sorted(close)[:5])}" if close else ""
        raise SystemExit(f"そのキャラは存在しません: {name}\n{hint}")

    raw = args.value.upper()
    if raw in LABELS:
        value = LABELS[raw]
    else:
        try:
            value = float(args.value)
        except ValueError:
            raise SystemExit(f"値は数値か {'/'.join(LABELS)} のどれかにしてください: {args.value}")
    if not -2.0 <= value <= 2.0:
        raise SystemExit("値は -2.0 〜 +2.0 の範囲にしてください")

    before = doc["tiers"].get(name)
    doc["tiers"][name] = value
    doc["tiers"] = dict(sorted(doc["tiers"].items()))
    save_json(TIERS_PATH, doc)

    arrow = f"{before:+.2f} → " if before is not None else ""
    print(f"✔ {name}（{ROLE_JA.get(roles[name], roles[name])}）: {arrow}{value:+.2f} [{label_of(value)}]")
    print("  反映するには: python3 scripts/update_meta.py --rotation-out rules/rules_rotation.json")
    return 0


def cmd_unset(args: argparse.Namespace) -> int:
    doc, roles = load()
    if args.name not in doc["tiers"]:
        raise SystemExit(f"{args.name} は設定されていません")
    removed = doc["tiers"].pop(args.name)
    save_json(TIERS_PATH, doc)
    print(f"✔ {args.name}: {removed:+.2f} → 中立（未設定）")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="ティア補正の確認・編集")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("list", help="役割別に一覧表示")
    p.add_argument("--role", choices=sorted(ROLE_JA), help="この役割だけ表示")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("missing", help="未設定のキャラを表示")
    p.set_defaults(func=cmd_missing)

    p = sub.add_parser("set", help="ティアを設定")
    p.add_argument("name", help="キャラ名（英語表記）")
    p.add_argument("value", help="数値 (-2.0〜2.0) または S/A/B/C/D/F")
    p.set_defaults(func=cmd_set)

    p = sub.add_parser("unset", help="ティアを削除して中立に戻す")
    p.add_argument("name")
    p.set_defaults(func=cmd_unset)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
