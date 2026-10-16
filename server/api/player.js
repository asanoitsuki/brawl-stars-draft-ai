// Brawl Board のプロフィール自動入力用。アプリからプレイヤータグを受け取り、
// ブロスタ公式 API（RoyaleAPI の固定 IP プロキシ経由）でプロフィールを引いて、
// アプリが使う項目だけに絞って返す。API キーはこのサーバーの環境変数にだけ置く。
//
//   GET /api/player?tag=#2PP  →  { tag, name, iconId, trophies, ..., topBrawlers: [...] }
//
// 環境変数: BRAWLSTARS_API_TOKEN（https://developer.brawlstars.com/ で許可 IP 45.79.218.79 のキー）

const API_BASE = "https://bsproxy.royaleapi.dev/v1";
// ブロスタのタグに使われる文字だけを許す（入力の打ち間違いで O と 0 が混ざりやすいので寄せる）
const TAG_RE = /^[0289PYLQGRJCUV]{3,14}$/;

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
  if (!upstream.ok) return res.status(502).json({ error: "upstream_error", status: upstream.status });

  const p = await upstream.json();
  const brawlers = Array.isArray(p.brawlers) ? p.brawlers : [];
  const topBrawlers = [...brawlers]
    .sort((a, b) => (b.trophies || 0) - (a.trophies || 0))
    .slice(0, 5)
    .map((b) => ({ id: b.id, name: b.name, power: b.power, rank: b.rank, trophies: b.trophies }));

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
    trioVictories: p["3vs3Victories"] ?? null,
    soloVictories: p.soloVictories ?? null,
    duoVictories: p.duoVictories ?? null,
    club: p.club && p.club.name ? p.club.name : null,
    brawlerCount: brawlers.length,
    topBrawlers,
  });
}
