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
//  Cost guards (the Origin check alone can be faked by a bot):
//  - eth_getLogs must name numeric fromBlock/toBlock (or one blockHash)
//    and span at most MAX_LOG_BLOCKS blocks;
//  - each IP may send at most MAX_CALLS_PER_MIN calls a minute to this
//    instance. Over the limit the route answers 429 and the app's
//    failover uses the public nodes instead.
//
//  If the key is missing or dRPC fails, the route answers with an HTTP
//  error and the app's failover moves on to the public nodes.
// ══════════════════════════════════════════════════════════

const UPSTREAM = "https://lb.drpc.live/polygon/";
const MAX_BATCH = 20;
const TIMEOUT_MS = 3500; // must stay below the client timeout (4000 ms in src/App.jsx)
const MAX_LOG_BLOCKS = 10000; // admin payout scan reads 10,000-block chunks
const MAX_CALLS_PER_MIN = 1200;
const WINDOW_MS = 60 * 1000;

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

const HEX_NUM = /^0x[0-9a-fA-F]{1,16}$/;

/** eth_getLogs only with a small, explicit block range. */
function logsOk(c) {
  const f = Array.isArray(c.params) ? c.params[0] : null;
  if (!f || typeof f !== "object") return false;
  if (f.blockHash !== undefined) {
    return typeof f.blockHash === "string" && f.fromBlock === undefined && f.toBlock === undefined;
  }
  if (!HEX_NUM.test(String(f.fromBlock)) || !HEX_NUM.test(String(f.toBlock))) return false;
  const from = parseInt(f.fromBlock, 16);
  const to = parseInt(f.toBlock, 16);
  return to >= from && to - from + 1 <= MAX_LOG_BLOCKS;
}

// Calls per IP in the current minute, per warm instance (best effort).
const seen = new Map();
function clientIp(req) {
  const xf = String(req.headers["x-forwarded-for"] || "").split(",")[0].trim();
  return xf || String(req.headers["x-real-ip"] || "") || "unknown";
}
function overLimit(ip, n) {
  const now = Date.now();
  let e = seen.get(ip);
  if (!e || now - e.start >= WINDOW_MS) {
    if (seen.size > 5000) {
      for (const [k, v] of seen) if (now - v.start >= WINDOW_MS) seen.delete(k);
    }
    e = { start: now, calls: 0 };
    seen.set(ip, e);
  }
  e.calls += n;
  return e.calls > MAX_CALLS_PER_MIN;
}

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
    if (c.method === "eth_getLogs" && !logsOk(c)) {
      return res.status(400).json({ error: "log range too wide or not numeric" });
    }
  }
  if (overLimit(clientIp(req), calls.length)) {
    res.setHeader("Retry-After", "60");
    return res.status(429).json({ error: "too many requests" });
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
