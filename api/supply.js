// ══════════════════════════════════════════════════════════
//  /api/supply.js   — Vercel serverless function
//  Public OSG supply figures for data aggregators (CoinGecko, CMC).
//
//    GET /api/supply?q=circulating   (default)
//    GET /api/supply?q=total
//    GET /api/supply?q=max
//
//  Answers text/plain: the bare number, up to 6 decimals, no thousands
//  separator (e.g. 640418.123456). Errors answer 503 "unavailable".
//
//  circulating = totalSupply - balanceOf(Treasury) - balanceOf(Reward
//  Storage), the same method as the whitepaper. Read-only and public,
//  so there is no same-site check. The dRPC key (Vercel env DRPC_KEY)
//  is used on the server only, with public nodes as fallback.
// ══════════════════════════════════════════════════════════

const TOKEN = "0xba05176748347944CC26900c821AbFeBeBC57415";
const TREASURY = "0x4669b2d38098Ae28D0332F03D1630B334aDDDF50";
const REWARD_STORAGE = "0xa0b2DcB18Cf0BdF61bcB9D33F538167dF501BEcB";
const MAX_SUPPLY = "23000000";
const PUBLIC_RPCS = ["https://polygon-bor-rpc.publicnode.com", "https://polygon.drpc.org"];
const TIMEOUT_MS = 4000;

const SEL_TOTAL_SUPPLY = "0x18160ddd";
const SEL_BALANCE_OF = "0x70a08231";

function balanceOfData(addr) {
  return SEL_BALANCE_OF + addr.toLowerCase().replace(/^0x/, "").padStart(64, "0");
}

/** 18-decimal integer -> plain decimal string, cut (not rounded) to 6 decimals. */
export function formatUnits6(v) {
  const neg = v < 0n;
  if (neg) v = -v;
  const whole = v / 10n ** 18n;
  const frac = ((v % 10n ** 18n) / 10n ** 12n).toString().padStart(6, "0").replace(/0+$/, "");
  return (neg ? "-" : "") + whole.toString() + (frac ? "." + frac : "");
}

function rpcUrls() {
  const key = process.env.DRPC_KEY || "";
  return (key ? ["https://lb.drpc.live/polygon/" + key] : []).concat(PUBLIC_RPCS);
}

/** One batch of three eth_calls; tries each RPC in turn. */
async function readSupply() {
  const calls = [
    { jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to: TOKEN, data: SEL_TOTAL_SUPPLY }, "latest"] },
    { jsonrpc: "2.0", id: 2, method: "eth_call", params: [{ to: TOKEN, data: balanceOfData(TREASURY) }, "latest"] },
    { jsonrpc: "2.0", id: 3, method: "eth_call", params: [{ to: TOKEN, data: balanceOfData(REWARD_STORAGE) }, "latest"] },
  ];
  for (const url of rpcUrls()) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
    try {
      const r = await fetch(url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(calls),
        signal: ctrl.signal,
      });
      if (!r.ok) continue;
      const out = await r.json();
      if (!Array.isArray(out)) continue;
      const byId = {};
      for (const o of out) if (o && typeof o.result === "string" && /^0x[0-9a-f]+$/i.test(o.result)) byId[o.id] = BigInt(o.result);
      if (byId[1] === undefined || byId[2] === undefined || byId[3] === undefined) continue;
      return { total: byId[1], treasury: byId[2], storage: byId[3] };
    } catch (e) {
      // try the next RPC
    } finally {
      clearTimeout(timer);
    }
  }
  throw new Error("RPC unavailable");
}

export default async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Content-Type", "text/plain; charset=utf-8");
  if (req.method !== "GET") {
    res.setHeader("Cache-Control", "no-store");
    return res.status(405).send("GET only");
  }
  const q = String((req.query && req.query.q) || "circulating").toLowerCase();
  if (q !== "total" && q !== "circulating" && q !== "max") {
    res.setHeader("Cache-Control", "no-store");
    return res.status(400).send("q must be total, circulating or max");
  }
  if (q === "max") {
    res.setHeader("Cache-Control", "public, s-maxage=300, stale-while-revalidate=600");
    return res.status(200).send(MAX_SUPPLY);
  }
  try {
    const s = await readSupply();
    const value = q === "total" ? s.total : s.total - s.treasury - s.storage;
    res.setHeader("Cache-Control", "public, s-maxage=300, stale-while-revalidate=600");
    return res.status(200).send(formatUnits6(value));
  } catch (e) {
    res.setHeader("Cache-Control", "no-store");
    return res.status(503).send("unavailable");
  }
}
