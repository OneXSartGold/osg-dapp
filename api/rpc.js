// ══════════════════════════════════════════════════════════
//  /api/rpc.js   — Vercel serverless function
//  Polygon JSON-RPC proxy for the DApp's read calls, using the paid
//  dRPC plan. The key stays on the server (Vercel env DRPC_KEY) and
//  never reaches the browser.
//
//  Read-only: only the methods in ALLOWED are forwarded, so this route
//  cannot send transactions. Wallet writes still go through the user's
//  own wallet. Requests from other websites are refused, and a batch
//  may hold at most MAX_BATCH calls.
//
//  If the key is missing or dRPC fails, the route answers with an HTTP
//  error and the app's failover moves on to the public nodes.
// ══════════════════════════════════════════════════════════

const UPSTREAM = "https://lb.drpc.live/polygon/";
const MAX_BATCH = 20;
const TIMEOUT_MS = 8000;

const ALLOWED = new Set([
  "eth_chainId",
  "net_version",
  "eth_blockNumber",
  "eth_call",
  "eth_getBalance",
  "eth_getCode",
  "eth_getStorageAt",
  "eth_getTransactionCount",
  "eth_getTransactionByHash",
  "eth_getTransactionReceipt",
  "eth_getBlockByNumber",
  "eth_getBlockByHash",
  "eth_getLogs",
  "eth_gasPrice",
  "eth_maxPriorityFeePerGas",
  "eth_feeHistory",
  "eth_estimateGas",
]);

// Same site only: the Origin (or Referer) host must match this host.
function sameSite(req) {
  const host = String(req.headers.host || "").toLowerCase();
  const from = req.headers.origin || req.headers.referer || "";
  if (!from) return false;
  try {
    return new URL(from).host.toLowerCase() === host;
  } catch (e) {
    return false;
  }
}

export default async function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");

  if (req.method !== "POST") {
    return res.status(405).json({ error: "POST only" });
  }
  if (!sameSite(req)) {
    return res.status(403).json({ error: "forbidden" });
  }

  const key = process.env.DRPC_KEY || "";
  if (!key) {
    return res.status(503).json({ error: "rpc not configured" });
  }

  let body = req.body;
  if (typeof body === "string") {
    try {
      body = JSON.parse(body);
    } catch (e) {
      return res.status(400).json({ error: "bad json" });
    }
  }

  const calls = Array.isArray(body) ? body : [body];
  if (calls.length === 0 || calls.length > MAX_BATCH) {
    return res.status(400).json({ error: "batch size" });
  }
  for (const c of calls) {
    if (!c || typeof c.method !== "string" || !ALLOWED.has(c.method)) {
      return res.status(400).json({ error: "method not allowed" });
    }
  }

  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const up = await fetch(UPSTREAM + key, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
      signal: ctrl.signal,
    });
    const text = await up.text();
    if (!up.ok) {
      return res.status(502).json({ error: "upstream " + up.status });
    }
    res.setHeader("content-type", "application/json");
    return res.status(200).send(text);
  } catch (e) {
    return res.status(504).json({ error: "upstream timeout" });
  } finally {
    clearTimeout(timer);
  }
}
