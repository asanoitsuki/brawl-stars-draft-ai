#!/usr/bin/env python3
"""全ブラウラーのアイコン画像を一括取得し、テンプレートマッチ用の記述子を生成する。

使い方:
    python3 scripts/download_icons.py                 # 差分ダウンロード + テンプレ生成
    python3 scripts/download_icons.py --force         # 既存ファイルも上書き
    python3 scripts/download_icons.py --variants all  # 3 種類すべて取得
    python3 scripts/download_icons.py --no-templates  # PNG だけ取得

出力:
    assets/brawler_icons/<variant>/<id>.png   … 生アイコン
    assets/brawler_icons/index.json           … ID / 名前 / ファイルの対応表
    assets/brawler_templates/templates.json   … iOS が読む記述子パック
"""

from __future__ import annotations

import argparse
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from brawl_api import (  # noqa: E402
    PROJECT_ROOT,
    BrawlAPIError,
    NotFoundError,
    fetch_bytes,
    fetch_json,
    save_json,
)

ICON_DIR = PROJECT_ROOT / "assets" / "brawler_icons"
TEMPLATE_DIR = PROJECT_ROOT / "assets" / "brawler_templates"

# Brawlify が配信する 3 種類のアイコン。
#   borders    … 枠付きポートレート（ゲーム内の選択画面に最も近い）
#   borderless … 枠なし（背景透過）
#   emoji      … ピン風の小アイコン
VARIANT_FIELDS = {
    "borders": "imageUrl",
    "borderless": "imageUrl2",
    "emoji": "imageUrl3",
}
DEFAULT_VARIANTS = ("borders", "borderless")

# 記述子の解像度。Swift 側 (TemplateMatcher.swift) と必ず一致させること。
GRAY_SIZE = 16   # 16x16 = 256 次元の輝度ベクトル (正規化相互相関用)
COLOR_SIZE = 4   # 4x4 ブロックの平均 RGB = 48 次元
HASH_SIZE = 8    # dHash 8x8 -> 64bit


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="ブラウラーアイコンの一括ダウンロード")
    ap.add_argument("--variants", default=",".join(DEFAULT_VARIANTS),
                    help="borders,borderless,emoji または all")
    ap.add_argument("--force", action="store_true", help="既存ファイルを再取得する")
    ap.add_argument("--workers", type=int, default=8, help="並列ダウンロード数")
    ap.add_argument("--template-variant", default="borders",
                    help="記述子生成に使うバリアント")
    ap.add_argument("--no-templates", action="store_true",
                    help="templates.json を生成しない")
    return ap.parse_args()


def fetch_brawlers() -> list[dict]:
    data = fetch_json("brawlers")
    brawlers = data["list"] if isinstance(data, dict) else data
    if not brawlers:
        raise BrawlAPIError("ブラウラー一覧が空です")
    brawlers.sort(key=lambda b: b["id"])
    return brawlers


def download_one(url: str, dest: Path, force: bool) -> str:
    if dest.exists() and not force and dest.stat().st_size > 0:
        return "skip"
    dest.parent.mkdir(parents=True, exist_ok=True)
    try:
        payload = fetch_bytes(url)
    except NotFoundError:
        # 実装直後の新キャラは CDN 未反映のことがある。致命傷にはしない。
        return "missing"
    if not payload.startswith(b"\x89PNG"):
        raise BrawlAPIError(f"PNG ではありません: {url}")
    tmp = dest.with_suffix(".part")
    tmp.write_bytes(payload)
    tmp.replace(dest)
    return "ok"


def download_all(brawlers: list[dict], variants: list[str], force: bool, workers: int) -> dict:
    jobs: list[tuple[str, Path, str]] = []
    for b in brawlers:
        for variant in variants:
            url = b.get(VARIANT_FIELDS[variant])
            if not url:
                continue
            jobs.append((url, ICON_DIR / variant / f"{b['id']}.png", b["name"]))

    counts = {"ok": 0, "skip": 0, "missing": 0, "fail": 0}
    missing_names: set[str] = set()
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(download_one, url, dest, force): (dest, name)
                   for url, dest, name in jobs}
        for fut in as_completed(futures):
            dest, name = futures[fut]
            try:
                result = fut.result()
            except Exception as exc:  # noqa: BLE001
                counts["fail"] += 1
                print(f"  ! {name} ({dest.name}): {exc}", file=sys.stderr)
                continue
            counts[result] += 1
            if result == "missing":
                missing_names.add(name)
    if missing_names:
        print("  · CDN 未反映（新キャラ等）: " + ", ".join(sorted(missing_names)))
    counts["missing_names"] = sorted(missing_names)  # type: ignore[assignment]
    return counts


# --------------------------------------------------------------------------
# テンプレート記述子
# --------------------------------------------------------------------------

def build_descriptor(png_path: Path) -> dict | None:
    """アイコン PNG から、iOS 側と同一仕様の記述子を作る。

    1. 透過部分を除いたバウンディングボックスへクロップ
    2. 正方形にパディング → リサイズ
    3. 輝度ベクトル (zero-mean / unit-norm) + 色シグネチャ + dHash を計算
    """
    try:
        from PIL import Image
    except ImportError:
        return None

    with Image.open(png_path) as im:
        im = im.convert("RGBA")
        bbox = im.getchannel("A").getbbox()
        if bbox:
            im = im.crop(bbox)
        # 透過を黒ではなく中間グレーで合成する（ゲーム内背景の影響を薄める）
        bg = Image.new("RGBA", im.size, (128, 128, 128, 255))
        im = Image.alpha_composite(bg, im).convert("RGB")

        side = max(im.size)
        square = Image.new("RGB", (side, side), (128, 128, 128))
        square.paste(im, ((side - im.width) // 2, (side - im.height) // 2))

        # ここから先は Swift 側 (ImageDescriptor.swift) と完全に同じ計算にする:
        #   面積平均 (BOX) で縮小 → RGB のまま輝度へ変換 (ITU-R BT.601)。
        #   LANCZOS だと CoreGraphics 側で同じ結果を再現できず、
        #   自己相関が 0.90 程度まで落ちて似たキャラの判別が不安定になる。
        def luma(px: tuple[int, int, int]) -> float:
            return 0.299 * px[0] + 0.587 * px[1] + 0.114 * px[2]

        gray_img = square.resize((GRAY_SIZE, GRAY_SIZE), Image.BOX)
        gray = [luma(px) / 255.0 for px in gray_img.getdata()]

        color_img = square.resize((COLOR_SIZE, COLOR_SIZE), Image.BOX)
        color = [c / 255.0 for px in color_img.getdata() for c in px]

        hash_img = square.resize((HASH_SIZE + 1, HASH_SIZE), Image.BOX)
        hp = [luma(px) for px in hash_img.getdata()]
        bits = 0
        for y in range(HASH_SIZE):
            for x in range(HASH_SIZE):
                bits <<= 1
                if hp[y * (HASH_SIZE + 1) + x] > hp[y * (HASH_SIZE + 1) + x + 1]:
                    bits |= 1

    mean = sum(gray) / len(gray)
    centered = [v - mean for v in gray]
    norm = sum(v * v for v in centered) ** 0.5 or 1.0
    gray_vec = [round(v / norm, 6) for v in centered]

    cmean = sum(color) / len(color)
    ccentered = [v - cmean for v in color]
    cnorm = sum(v * v for v in ccentered) ** 0.5 or 1.0
    color_vec = [round(v / cnorm, 6) for v in ccentered]

    return {"gray": gray_vec, "color": color_vec, "dhash": f"{bits:016x}"}


def build_templates(brawlers: list[dict], variant: str) -> dict:
    entries = []
    missing = 0
    for b in brawlers:
        png = ICON_DIR / variant / f"{b['id']}.png"
        if not png.exists():
            missing += 1
            continue
        desc = build_descriptor(png)
        if desc is None:
            raise SystemExit("Pillow が必要です:  pip3 install Pillow  (または --no-templates)")
        entries.append({
            "id": b["id"],
            "name": b["name"],
            "hash": b.get("hash") or b["name"],
            "rarity": (b.get("rarity") or {}).get("name"),
            **desc,
        })
    if missing:
        print(f"  · テンプレ未生成 {missing} 件（アイコン PNG が CDN 未反映）")
    return {
        "schema": 1,
        "variant": variant,
        "graySize": GRAY_SIZE,
        "colorSize": COLOR_SIZE,
        "count": len(entries),
        "templates": entries,
    }


def main() -> int:
    args = parse_args()
    variants = list(VARIANT_FIELDS) if args.variants == "all" else [
        v.strip() for v in args.variants.split(",") if v.strip()
    ]
    unknown = [v for v in variants if v not in VARIANT_FIELDS]
    if unknown:
        raise SystemExit(f"未知のバリアント: {unknown} / 使用可: {list(VARIANT_FIELDS)}")

    print("▶ ブラウラー一覧を取得中 …")
    brawlers = fetch_brawlers()
    print(f"  {len(brawlers)} 体")

    print(f"▶ アイコンをダウンロード中 … variants={variants}")
    counts = download_all(brawlers, variants, args.force, args.workers)
    print(f"  新規 {counts['ok']} / 既存 {counts['skip']} / "
          f"CDN未反映 {counts['missing']} / 失敗 {counts['fail']}")

    index = {
        "schema": 1,
        "count": len(brawlers),
        "variants": variants,
        "iconsUnavailable": counts.get("missing_names", []),
        "brawlers": [
            {
                "id": b["id"],
                "name": b["name"],
                "hash": b.get("hash") or b["name"],
                "rarity": (b.get("rarity") or {}).get("name"),
                "tip": (b.get("class") or {}).get("name"),
                "files": {v: f"{v}/{b['id']}.png" for v in variants
                          if (ICON_DIR / v / f"{b['id']}.png").exists()},
            }
            for b in brawlers
        ],
    }
    save_json(ICON_DIR / "index.json", index)
    print(f"  → {ICON_DIR / 'index.json'}")

    if not args.no_templates:
        print(f"▶ テンプレート記述子を生成中 … variant={args.template_variant}")
        pack = build_templates(brawlers, args.template_variant)
        save_json(TEMPLATE_DIR / "templates.json", pack)
        print(f"  {pack['count']} 件 → {TEMPLATE_DIR / 'templates.json'}")

    if counts["fail"]:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
