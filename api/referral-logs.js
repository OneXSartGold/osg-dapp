// ══════════════════════════════════════════════════════════
//  /api/referral-logs.js   — Vercel serverless function
//  Fetches ReferralAccrued event logs from the Staking contract
//  via the Polygonscan API, server-side, so there is NO browser
//  CORS issue. Returns the unique list of referrer addresses
//  (the first indexed topic of each log).
//
//  The admin panel calls this, then reads owed/paid/pending for
//  each address on-chain. No secret key is exposed to the browser.
//
//  Optional: set POLYGONSCAN_KEY as a Vercel env var to raise the
//  rate limit. Works without a key on the free public tier too.
// ══════════════════════════════════════════════════════════

const STAKING = "0x048E814C02e85ec1438Ab8C1d2e9150A5289A886";
const FROM_BLOCK = 80000000;

async function getWithTimeout(url, ms) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), ms);
  try {
    return await fetch(url, { signal: ctrl.signal });
  } finally {
    clearTimeout(timer);
  }
}

export default async function handler(req, res) {
  // The real topic0 is passed by the client (computed with ethers.id),
  // so we never have to hard-code/verify it here. Validate its shape.
  const topic0 = (req.query.topic0 || "").toLowerCase();
  if (!/^0x[0-9a-f]{64}$/.test(topic0)) {
    return res.status(400).json({ error: "Bad topic0" });
  }

  const key = process.env.POLYGONSCAN_KEY || "";
  if (!key) {
    return res.status(200).json({
      ok: false,
      error: "No API key set (POLYGONSCAN_KEY)",
      referrers: [],
    });
  }

  // Etherscan V2 unified endpoint — Polygon = chainid 137.
  // (Old api.polygonscan.com endpoint is retired; V2 needs a key.)
  const base =
    "https://api.etherscan.io/v2/api" +
    "?chainid=137" +
    "&module=logs&action=getLogs" +
    "&address=" + STAKING +
    "&topic0=" + topic0 +
    "&fromBlock=" + FROM_BLOCK +
    "&toBlock=latest" +
    "&apikey=" + key;

  try {
    const r = await getWithTimeout(base, 12000);
    const j = await r.json();

    if (j && j.status === "1" && Array.isArray(j.result)) {
      const set = new Set();
      for (const lg of j.result) {
        // topics[1] = referrer (first indexed param), 32-byte hex
        if (lg.topics && lg.topics[1]) {
          const addr = "0x" + lg.topics[1].slice(26).toLowerCase();
          set.add(addr);
        }
      }
      res.setHeader("Cache-Control", "public, max-age=60");
      return res.status(200).json({
        ok: true,
        count: j.result.length,
        referrers: [...set],
      });
    }

    // status "0" with "No records found" is a valid empty result
    if (j && j.message && /no records/i.test(j.message)) {
      return res.status(200).json({ ok: true, count: 0, referrers: [] });
    }

    return res.status(200).json({
      ok: false,
      error: (j && j.message) || "Polygonscan returned no rows",
      referrers: [],
    });
  } catch (e) {
    return res
      .status(502)
      .json({ ok: false, error: "Polygonscan fetch failed", referrers: [] });
  }
}
