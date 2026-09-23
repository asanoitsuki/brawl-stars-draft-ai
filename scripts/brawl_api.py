"""Brawlify API への共通アクセス層。

Brawlify は同じ内容を 2 つのドメインで配信している:

  * https://api.brawlify.com/v1/...  (現行ドメイン / Cloudflare 保護あり)
  * https://api.brawlapi.com/v1/...  (旧ドメインのミラー)

ネットワークによっては前者が 403 (Cloudflare のボット判定) を返すため、
両方を順に試し、最初に成功したものを使う。
"""

from __future__ import annotations

import gzip
import json
import os
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

API_HOSTS = (
    "https://api.brawlify.com/v1",
    "https://api.brawlapi.com/v1",
)

# Cloudflare の WAF / Bot Fight Mode 対策。実際の Chrome が送るヘッダを一式そろえる。
#
# ⚠️ 実測（2026-09）: api.brawlify.com / brawlify.com はヘッダを完全に揃えても 403 を返す。
#    ヘッダ無しのリクエストと結果が同じであることから、判定は User-Agent ではなく
#    TLS フィンガープリント + JS チャレンジで行われている。つまり
#    **ヘッダだけでは通らない**。それでも以下は付けておく意味がある:
#      * ヘッダを見るタイプの WAF には効く
#      * CDN (cdn.brawlify.com) や旧ドメイン (api.brawlapi.com) では現に通っている
#      * ブラウザから cf_clearance Cookie を持ってくれば突破できる（下の環境変数）
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

BROWSER_HEADERS = {
    "User-Agent": USER_AGENT,
    "Accept": "application/json, text/plain, */*",
    "Accept-Language": "ja,en-US;q=0.9,en;q=0.8",
    "Accept-Encoding": "gzip, deflate",
    "Referer": "https://brawlify.com/",
    "Origin": "https://brawlify.com",
    "sec-ch-ua": '"Chromium";v="131", "Not_A Brand";v="24", "Google Chrome";v="131"',
    "sec-ch-ua-mobile": "?0",
    "sec-ch-ua-platform": '"macOS"',
    "Sec-Fetch-Dest": "empty",
    "Sec-Fetch-Mode": "cors",
    "Sec-Fetch-Site": "same-site",
    "Connection": "keep-alive",
    "DNT": "1",
}

# ブラウザで Cloudflare のチャレンジを通したあとの Cookie を渡すための逃げ道。
#   export BRAWLIFY_COOKIE='cf_clearance=...'
#   export BRAWLIFY_EXTRA_HEADERS='{"X-Foo": "bar"}'
COOKIE_ENV = "BRAWLIFY_COOKIE"
EXTRA_HEADERS_ENV = "BRAWLIFY_EXTRA_HEADERS"

DEFAULT_TIMEOUT = 30
MAX_RETRY = 3

PROJECT_ROOT = Path(__file__).resolve().parent.parent


class BrawlAPIError(RuntimeError):
    pass


class NotFoundError(BrawlAPIError):
    """404。CDN にまだ画像が用意されていない新キャラなどで発生する。"""


def request_headers(for_image: bool = False) -> dict[str, str]:
    """実ブラウザ相当のヘッダ一式（＋環境変数で足したぶん）を返す。"""
    headers = dict(BROWSER_HEADERS)
    if for_image:
        headers["Accept"] = "image/avif,image/webp,image/png,image/*,*/*;q=0.8"
        headers["Sec-Fetch-Dest"] = "image"
        headers["Sec-Fetch-Mode"] = "no-cors"

    cookie = os.environ.get(COOKIE_ENV, "").strip()
    if cookie:
        headers["Cookie"] = cookie

    extra = os.environ.get(EXTRA_HEADERS_ENV, "").strip()
    if extra:
        try:
            headers.update(json.loads(extra))
        except json.JSONDecodeError:
            print(f"  ! {EXTRA_HEADERS_ENV} が JSON として読めません。無視します。")
    return headers


def _open(url: str, timeout: int = DEFAULT_TIMEOUT) -> bytes:
    req = urllib.request.Request(
        url, headers=request_headers(for_image=url.endswith(".png"))
    )
    with urllib.request.urlopen(req, timeout=timeout) as res:
        raw = res.read()
        if res.headers.get("Content-Encoding") == "gzip":
            raw = gzip.decompress(raw)
        return raw


def _describe_http_error(exc: urllib.error.HTTPError, url: str) -> str:
    """403 が「Cloudflare に弾かれた」のか別の理由かを切り分けて説明する。"""
    if exc.code != 403:
        return f"HTTP {exc.code} {exc.reason}"
    body = b""
    try:
        body = exc.read()[:4096]
    except Exception:  # noqa: BLE001
        pass
    text = body.decode("utf-8", errors="replace").lower()
    server = (exc.headers.get("server") or "").lower() if exc.headers else ""
    if "cloudflare" in server or "just a moment" in text or "request blocked" in text:
        ray = exc.headers.get("cf-ray", "?") if exc.headers else "?"
        return (
            f"HTTP 403 / Cloudflare にブロックされました (cf-ray={ray})。\n"
            f"        ヘッダだけでは回避できません（TLS フィンガープリント + JS チャレンジ判定）。\n"
            f"        回避するなら: ブラウザで {url} を開いてチャレンジを通し、\n"
            f"        cf_clearance Cookie を {COOKIE_ENV} 環境変数に入れて再実行してください。"
        )
    return f"HTTP 403 {exc.reason}"


def fetch_bytes(url: str, timeout: int = DEFAULT_TIMEOUT) -> bytes:
    """単一 URL を取得。指数バックオフ付きリトライ。"""
    last: Exception | None = None
    for attempt in range(MAX_RETRY):
        try:
            return _open(url, timeout)
        except urllib.error.HTTPError as exc:
            if exc.code == 404:  # リトライしても無駄
                raise NotFoundError(f"404: {url}") from exc
            if exc.code == 403:  # Cloudflare。リトライしても結果は変わらない
                raise BrawlAPIError(_describe_http_error(exc, url)) from exc
            last = exc
            time.sleep(0.6 * (2**attempt))
        except (urllib.error.URLError, TimeoutError) as exc:
            last = exc
            time.sleep(0.6 * (2**attempt))
    raise BrawlAPIError(f"取得失敗: {url} ({last})")


def fetch_json(path: str, timeout: int = DEFAULT_TIMEOUT) -> Any:
    """`/brawlers` のような API パスを、ホストをフォールバックしつつ取得する。"""
    errors: list[str] = []
    for host in API_HOSTS:
        url = f"{host}/{path.lstrip('/')}"
        try:
            raw = _open(url, timeout)
        except urllib.error.HTTPError as exc:
            errors.append(f"{host}: {_describe_http_error(exc, url)}")
            continue
        except Exception as exc:  # noqa: BLE001 - ホストを変えて再試行するため広く捕捉
            errors.append(f"{host}: {exc}")
            continue
        try:
            return json.loads(raw)
        except json.JSONDecodeError as exc:
            # Cloudflare のチャレンジ HTML が返ってきたケース
            errors.append(f"{host}: JSON ではない応答 ({exc})")
            continue
    raise BrawlAPIError(f"全ホストで失敗: /{path}\n  " + "\n  ".join(errors))


def load_json(path: Path, default: Any = None) -> Any:
    if not path.exists():
        return default
    with path.open(encoding="utf-8") as fp:
        return json.load(fp)


def save_json(path: Path, data: Any, compact: bool = False) -> None:
    """compact=True は機械が読むだけの大きいファイル向け（インデントを付けない）。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as fp:
        if compact:
            json.dump(data, fp, ensure_ascii=False, separators=(",", ":"))
        else:
            json.dump(data, fp, ensure_ascii=False, indent=2, sort_keys=False)
        fp.write("\n")
    tmp.replace(path)


# --------------------------------------------------------------------------
# Supercell 公式 API（任意）
# --------------------------------------------------------------------------
#
# Brawlify の勝率 API は 2026-09 時点で公開 JSON としては提供されていないが、
# **マップローテーションだけは Supercell の公式 API から確実に取れる**。
#
#   1. https://developer.brawlstars.com/ で無料アカウントを作る
#   2. 実行元のグローバル IP を許可した API キーを発行する
#   3. export BRAWLSTARS_API_TOKEN='...'
#
# ⚠️ 公式キーは IP 固定のため、GitHub Actions のランナー（IP が毎回変わる）では使えない。
#    ローカル cron 運用（scripts/install_cron.sh）向けの機能。
OFFICIAL_API = "https://api.brawlstars.com/v1"
OFFICIAL_TOKEN_ENV = "BRAWLSTARS_API_TOKEN"


def official_token() -> str:
    return os.environ.get(OFFICIAL_TOKEN_ENV, "").strip()


def fetch_official_rotation(timeout: int = DEFAULT_TIMEOUT) -> list[dict]:
    """公式 API から現在のイベントローテーションを取得する。

    トークンが無ければ空リストを返す（呼び出し側はフォールバックすればよい）。
    戻り値は Supercell のスキーマそのまま:
        [{"startTime", "endTime", "slotId", "event": {"id", "mode", "map", ...}}, ...]
    """
    token = official_token()
    if not token:
        return []

    url = f"{OFFICIAL_API}/events/rotation"
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
        "User-Agent": USER_AGENT,
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            payload = json.loads(res.read())
    except urllib.error.HTTPError as exc:
        if exc.code == 403:
            raise BrawlAPIError(
                "公式 API に拒否されました (403)。API キーに登録した IP と "
                "実行元のグローバル IP が一致しているか確認してください。"
            ) from exc
        raise BrawlAPIError(f"公式 API エラー: HTTP {exc.code} {exc.reason}") from exc
    except Exception as exc:  # noqa: BLE001
        raise BrawlAPIError(f"公式 API へ接続できません: {exc}") from exc

    if not isinstance(payload, list):
        raise BrawlAPIError("公式 API の応答が想定と違います（配列ではありません）")
    return payload
