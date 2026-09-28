// ══════════════════════════════════════════════════════════
//  /api/osg-trades.js   — Vercel serverless function
//  The latest buys and sells of OSG on the QuickSwap OSG/WPOL pair,
//  for the admin page's Trades card.
//
//  Read-only. The token, pair and WPOL addresses are fixed here, so
//  this route cannot be used to read anything else. The Etherscan key
//  stays on the server. Who each wallet is (member, trader, contract)
//  is worked out by the admin page itself from the chain.
//
//  Response:
//  { ok, updatedAt, trades: [ { hash, time, side, osg, pol, wallet } ] }
//    side   "BUY" (OSG left the pair) | "SELL" (OSG entered the pair)
//           | "LP_ADD" | "LP_REMOVE" (liquidity, not a trade)
//    wallet who received (BUY) or sent (SELL) the OSG. For a trade made
//           through a bot or aggregator this is that contract; the admin
//           page looks up the real sender of the transaction.
// ══════════════════════════════════════════════════════════

const BASE  = "https://api.etherscan.io/v2/api";
const TOKEN = "0xba05176748347944cc26900c821abfebebc57415";
const PAIR  = "0xa15214b09a9b3e1c821b94fb97d6d3bca8201cd2";
const WPOL  = "0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270";
const ZERO  = "0x0000000000000000000000000000000000000000";
const LIMIT = 100;

async function getWithTimeout(url, ms) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), ms);
  try {
    return await fetch(url, { signal: ctrl.signal });
  } finally {
    clearTimeout(timer);
  }
}

// One tokentx page: transfers of `contract` to or from the pair, newest first.
async function tokenTx(key, contract, offset) {
  const qs = new URLSearchParams({
    chainid: "137",
    module: "account",
    action: "tokentx",
    contractaddress: contract,
    address: PAIR,
    page: "1",
    offset: String(offset),
    sort: "desc",
    apikey: key,
  });
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const r = await getWithTimeout(BASE + "?" + qs.toString(), 8000);
      const j = await r.json();
      if (Array.isArray(j.result)) return j.result;
      // "No transactions found" is an empty answer, not an error.
      if (j && j.message && /no transactions/i.test(j.message)) return [];
    } catch (e) {
      // retry below
    }
    await new Promise((res) => setTimeout(res, 400 * (attempt + 1)));
  }
  throw new Error("Etherscan did not answer for " + contract);
}

function toUnits(value, decimals) {
  // Enough precision for display; amounts are shown to 2-4 decimals.
  const d = Number(decimals || 18);
  const s = String(value || "0").padStart(d + 1, "0");
  return Number(s.slice(0, s.length - d) + "." + s.slice(s.length - d));
}

export default async function handler(req, res) {
  const key = process.env.POLYGONSCAN_KEY || "";
  if (!key) {
    return res.status(200).json({ ok: false, error: "No API key set (POLYGONSCAN_KEY)", trades: [] });
  }

  try {
    // Sequential, to stay under the free plan's calls per second.
    const osgRows = await tokenTx(key, TOKEN, LIMIT);
    const wpolRows = await tokenTx(key, WPOL, LIMIT * 2);
    const lpRows = await tokenTx(key, PAIR, LIMIT);

    // WPOL moved by the pair in each transaction.
    const polByHash = {};
    for (const t of wpolRows) {
      const h = t.hash.toLowerCase();
      polByHash[h] = (polByHash[h] || 0) + toUnits(t.value, t.tokenDecimal);
    }

    // Transactions where LP tokens were minted or burned are liquidity
    // changes, not trades.
    const lpKind = {};
    for (const t of lpRows) {
      const h = t.hash.toLowerCase();
      if (t.from.toLowerCase() === ZERO) lpKind[h] = "LP_ADD";
      else if (t.to.toLowerCase() === ZERO) lpKind[h] = "LP_REMOVE";
    }

    const trades = [];
    for (const t of osgRows) {
      const h = t.hash.toLowerCase();
      const from = t.from.toLowerCase();
      const to = t.to.toLowerCase();
      let side;
      let wallet;
      if (from === PAIR) { side = "BUY"; wallet = to; }
      else if (to === PAIR) { side = "SELL"; wallet = from; }
      else continue;
      if (lpKind[h]) side = lpKind[h];
      trades.push({
        hash: h,
        time: Number(t.timeStamp),
        side,
        osg: toUnits(t.value, t.tokenDecimal),
        pol: polByHash[h] || 0,
        wallet,
      });
    }

    res.setHeader("Cache-Control", "public, max-age=60, s-maxage=120");
    return res.status(200).json({ ok: true, updatedAt: Date.now(), trades });
  } catch (e) {
    return res.status(200).json({ ok: false, error: String((e && e.message) || e), trades: [] });
  }
}
