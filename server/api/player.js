// Brawl Board のプロフィール自動入力用。アプリからプレイヤータグを受け取り、
// ブロスタ公式 API（RoyaleAPI の固定 IP プロキシ経由）でプロフィールを引いて、
// アプリが使う項目に整えて返す。API キーはこのサーバーの環境変数にだけ置く。
//
//   GET /api/player?tag=2PP0Y8LQ
//
// 公式が返すものは、プロフィールの数値（トロフィー・勝利数・レベル・最高記録）と
// 全キャラの状態（パワー・ランク・トロフィー・ギア・ガジェット・スターパワー・ハイパーチャージ …）。
// 公式 API に将来項目が増えても落とさないよう、知らない項目は `extra` にそのまま入れて返す。
//
// 環境変数: BRAWLSTARS_API_TOKEN（https://developer.brawlstars.com/ で許可 IP 45.79.218.79 のキー）

const API_BASE = "https://bsproxy.royaleapi.dev/v1";
// ブロスタのタグに使われる文字だけを許す（入力の打ち間違いで O と 0 が混ざりやすいので寄せる）
const TAG_RE = /^[0289PYLQGRJCUV]{3,14}$/;

const KNOWN_TOP = new Set([
  "tag", "name", "nameColor", "icon", "trophies", "highestTrophies", "expLevel", "expPoints",
  "3vs3Victories", "soloVictories", "duoVictories", "bestRoboRumbleTime", "bestTimeAsBigBrawler",
  "isQualifiedFromChampionshipChallenge", "club", "brawlers",
]);

function slimBrawler(b) {
  const count = (v) => (Array.isArray(v) ? v.length : null);
  const out = {
    id: b.id,
    name: b.name,
    power: b.power,
    rank: b.rank,
    trophies: b.trophies,
    highestTrophies: b.highestTrophies ?? null,
    gears: count(b.gears),
    gadgets: count(b.gadgets),
    starPowers: count(b.starPowers),
    hyperCharges: count(b.hyperCharges),
    buffies: count(b.buffies),
  };
  // 上記以外に増えた項目（スキン・ガチバトル用の値 など）もそのまま渡す
  const known = new Set(["id", "name", "power", "rank", "trophies", "highestTrophies", "gears", "gadgets",
    "starPowers", "hyperCharges", "buffies"]);
  const extra = Object.fromEntries(Object.entries(b).filter(([k]) => !known.has(k)));
  if (Object.keys(extra).length) out.extra = extra;
  return out;
}

export default async function handler(req, res) {
  if (req.method !== "GET") {
    res.setHeader("Allow", "GET");
    return res.status(405).json({ error: "method_not_allowed" });
  }

  const raw = String(req.query.tag || "")
    .trim()
    .toUpperCase()
    .replace(/^#/, "")
    .replace(/O/g, "0");
  if (!TAG_RE.test(raw)) {
    return res.status(400).json({ error: "invalid_tag" });
  }

  const token = process.env.BRAWLSTARS_API_TOKEN;
  if (!token) {
    return res.status(503).json({ error: "server_not_configured" });
  }

  let upstream;
  try {
    upstream = await fetch(`${API_BASE}/players/%23${raw}`, {
      headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
    });
  } catch {
    return res.status(502).json({ error: "upstream_unreachable" });
  }

  if (upstream.status === 404) return res.status(404).json({ error: "not_found" });
  if (upstream.status === 429) return res.status(429).json({ error: "rate_limited" });
  if (!upstream.ok) {
    // 公式がメンテナンス中は 503 + {"reason":"inMaintenance"}。アプリ側で分かるようにする
    let reason = null;
    try {
      reason = (await upstream.json()).reason || null;
    } catch {
      /* 本文が JSON でなければ無視 */
    }
    if (upstream.status === 503 && reason === "inMaintenance") {
      return res.status(503).json({ error: "maintenance" });
    }
    return res.status(502).json({ error: "upstream_error", status: upstream.status, reason });
  }

  const p = await upstream.json();
  const brawlers = (Array.isArray(p.brawlers) ? p.brawlers : []).map(slimBrawler)
    .sort((a, b) => (b.trophies || 0) - (a.trophies || 0));
  const extra = Object.fromEntries(Object.entries(p).filter(([k]) => !KNOWN_TOP.has(k)));

  // 公開プロフィールなので数分キャッシュしてよい（公式 API への負荷も減る）
  res.setHeader("Cache-Control", "public, s-maxage=300, stale-while-revalidate=600");
  return res.status(200).json({
    tag: p.tag,
    name: p.name,
    nameColor: p.nameColor || null,
    iconId: p.icon && p.icon.id ? p.icon.id : null,
    trophies: p.trophies ?? null,
    highestTrophies: p.highestTrophies ?? null,
    expLevel: p.expLevel ?? null,
    expPoints: p.expPoints ?? null,
    trioVictories: p["3vs3Victories"] ?? null,
    soloVictories: p.soloVictories ?? null,
    duoVictories: p.duoVictories ?? null,
    bestRoboRumbleTime: p.bestRoboRumbleTime ?? null,
    bestTimeAsBigBrawler: p.bestTimeAsBigBrawler ?? null,
    qualifiedChampionship: p.isQualifiedFromChampionshipChallenge ?? null,
    club: p.club && p.club.name ? p.club.name : null,
    brawlerCount: brawlers.length,
    // 全キャラ（トロフィーの多い順）。先頭 5 体を「よく使うキャラ」に使う
    brawlers,
    topBrawlers: brawlers.slice(0, 5),
    // 公式が新しく追加した項目（ガチバトルのレートなど）が来ていればここに入る
    extra,
  });
}
