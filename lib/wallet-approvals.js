// ══════════════════════════════════════════════════════════
//  lib/wallet-approvals.js   — shared module (not a function)
//  Wallet Safety Check (member tool #1): lists the ERC-20 token
//  approvals a wallet has given on Polygon and flags risky ones.
//
//    GET /api/osg-wallet-flow?mode=approvals&address=0x...
//
//  Served through api/osg-wallet-flow.js so the project stays within
//  the Vercel plan's serverless-function limit.
//
//  How it works (read-only, no keys reach the browser):
//    1. Etherscan V2 getLogs by topics: every ERC-20 Approval event
//       whose owner (topic1) is the wallet. POLYGONSCAN_KEY (Vercel env).
//    2. Keep the latest event per (token, spender) pair.
//    3. Read the CURRENT allowance(owner, spender), token symbol and
//       decimals, and whether the spender has code, over JSON-RPC
//       (dRPC key from DRPC_KEY env, public nodes as fallback).
//    4. For unknown contract spenders, ask Etherscan whether the
//       source code is verified (capped, sequential).
//    5. Label each spender (OSG official / known / unknown) and give a
//       risk level with reason codes. Allowances that are already 0
//       are counted but not returned.
//
//  Response:
//  {
//    ok: true, address, scannedAt,
//    approvals: [ { token, tokenSymbol, tokenDecimals, spender,
//                   spenderLabel, category, allowanceRaw, allowance,
//                   unlimited, isContract, verified, risk, reasons,
//                   lastApprovalBlock, lastApprovalTx, lastApprovalTime } ],
//    revokedCount, truncated
//  }
//  category: "official" | "official_old" | "known" | "unknown"
//  risk:     "none" | "low" | "medium" | "high"
//  reasons:  "unlimited", "unknown_spender", "not_verified",
//            "not_a_contract", "old_osg_contract"
//
//  Only ERC-20 approvals (3 topics). ERC-721 Approval (4 topics) and
//  ApprovalForAll are skipped in this version. Nothing here can move
//  funds; revoking is done in the member's own wallet.
// ══════════════════════════════════════════════════════════

const ETHERSCAN_BASE = "https://api.etherscan.io/v2/api";
const CHAIN_ID = 137;
const PUBLIC_RPCS = ["https://polygon-bor-rpc.publicnode.com", "https://polygon.drpc.org"];
const RPC_TIMEOUT_MS = 6000;
const RPC_BATCH = 20;

const TOPIC_APPROVAL = "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925";
const SEL_ALLOWANCE = "0xdd62ed3e";
const SEL_SYMBOL = "0x95d89b41";
const SEL_DECIMALS = "0x313ce567";

const PAGE_SIZE = 1000;   // Etherscan getLogs maximum per page
const MAX_PAGES = 10;     // up to 10,000 approval events per wallet
const MAX_VERIFY_LOOKUPS = 15;
const ETHERSCAN_RETRIES = 3;

// 2^128: anything at or above this is shown as "unlimited".
const UNLIMITED_FROM = 1n << 128n;

// OSG contracts (current). Lower-case keys.
const OSG_OFFICIAL = {
  "0xba05176748347944cc26900c821abfebebc57415": "OSG Token",
  "0xe2e82a8acdd3af7fa74eacb3331231a769d80d4c": "OSG TimelockDAO",
  "0xa0b2dcb18cf0bdf61bcb9d33f538167df501becb": "OSG Reward Storage",
  "0xdc4fe983ed301ad42f4e4c43951aa07a7a182855": "OSG Reward Pool",
  "0x048e814c02e85ec1438ab8c1d2e9150a5289a886": "OSG Staking",
  "0x06263828484e36106edf20a6d5a38c3be9612269": "OSG Bond",
  "0x29c63cd4c3f03b1f64e929b0b8bac691deb5fa5c": "OSG Messenger",
  "0x88e64cbc22a35c2928038f2bc13f06630c93d07a": "OSG Media Storage",
  "0x4f1eff6fc4a0271096dd78b6f6284d4c9f1904f1": "OSG Referral Distributor",
  "0x269eca6adb7c9c1befdc6c0be48a545b1920e1bb": "OSG P2P Exchange",
  "0xa15214b09a9b3e1c821b94fb97d6d3bca8201cd2": "OSG/WPOL QuickSwap Pool",
  "0x4669b2d38098ae28d0332f03d1630b334adddf50": "OSG Treasury",
  "0xb3de3956df62a069c9ac428ec58120b3d9cd7ccc": "OSG Term Staking",
  "0x1f04f1441208ee8ddd3a124defc4a493d768d0fc": "OSG LP Mining",
  "0x333a6c51baa2d19af036f45f32eacf10234f17c8": "OSG LP Mining Tiers",
  "0x7ee98ae2beaef2251a8bbb3810006495f62b7c92": "OSG Spot Reward",
  "0x7cbfd31fc4ea31d5390f20adbffd0cbfb839912e": "OSG Spot Adapter (Term)",
  "0xdd065840f5bd458dc4e9deeaed7f1946812870a6": "OSG Spot Adapter (LP)",
  "0xb452a678539f18ca6492a72db9a69d9b7a340b74": "OSG Referral v6",
  "0x41f955dcf8e45e14406b7fbd846ff2d56ce2bce1": "OSG Spot v6",
};

// OSG contracts that are no longer used. Safe origin, but an open
// approval to them is not needed any more.
const OSG_OLD = {
  "0x4bfad548efd22e2fe75bbc77b6114380f8ef1ba3": "OSG LP Mining (old)",
  "0x82cfa8cb35176bac5d9d2ec791aa22b33abaa381": "OSG Referral v4 (old)",
  "0x58383a8171014a8008d28e7cbb509e21412ec52a": "OSG Referral v5 (old)",
  "0x9432b8c2b67c4c86c26edb98893611013fadf562": "OSG Term Staking v1 (old)",
  "0xb0510d6f707df47fe7427732d5507290d847b736": "OSG LP Mining v6 (old)",
  "0xfa1cc9d7a9643156d797142d47e3930895401565": "OSG LP Referral v1 (old)",
  "0x0a7a88b23076f35ee2c0b41e85a892c17ae2ac92": "OSG Referral v3 (old)",
  "0xdc172cbbb940c8af717de1cb46a89a6d91afa567": "OSG P2P Exchange v2 (old)",
  "0x72a4387cc07cf105feec4615b40d2ef9ca0aee6b": "OSG P2P Exchange v1 (old)",
};

// Widely used routers/aggregators on Polygon.
const KNOWN = {
  "0xa5e0829caced8ffdd4de3c43696c57f7d7a678ff": "QuickSwap V2 Router",
  "0xf5b509bb0909a69b1c207e495f687a596c168e12": "QuickSwap V3 Router",
  "0x000000000022d473030f116ddee9f6b43ac78ba3": "Uniswap Permit2",
  "0x1111111254eeb25477b68fb85ed929f73a960582": "1inch Router v5",
  "0x111111125421ca6dc452d289314280a0f8842a65": "1inch Router v6",
  "0x1231deb6f5749ef6ce6943a275a1d3e7486f4eae": "LI.FI Diamond",
  "0xdef171fe48cf0115b1d80b88dc8eab59176fee57": "ParaSwap Augustus v5",
};

function sleep(ms) {
  return new Promise(function (r) { setTimeout(r, ms); });
}

function isAddress(a) {
  return typeof a === "string" && /^0x[0-9a-fA-F]{40}$/.test(a);
}

function pad32(addr) {
  return "0x" + addr.toLowerCase().replace(/^0x/, "").padStart(64, "0");
}

function topicToAddress(t) {
  return ("0x" + String(t).slice(-40)).toLowerCase();
}

/** Raw integer -> decimal string, cut (not rounded) to 6 decimals. */
export function formatUnits(v, decimals) {
  const d = BigInt(decimals);
  const base = 10n ** d;
  const whole = v / base;
  let frac = "";
  if (d > 0n) {
    const keep = d < 6n ? d : 6n;
    frac = ((v % base) / 10n ** (d - keep)).toString().padStart(Number(keep), "0").replace(/0+$/, "");
  }
  return whole.toString() + (frac ? "." + frac : "");
}

/** Decode an ABI string return (or a bytes32 one, used by some old tokens). */
export function decodeString(hex) {
  if (typeof hex !== "string" || !/^0x[0-9a-fA-F]*$/.test(hex) || hex.length < 66) return null;
  const body = hex.slice(2);
  try {
    if (body.length >= 128) {
      const off = parseInt(body.slice(0, 64), 16);
      const len = parseInt(body.slice(off * 2, off * 2 + 64), 16);
      if (len > 0 && len <= 64) {
        const bytes = body.slice(off * 2 + 64, off * 2 + 64 + len * 2);
        return Buffer.from(bytes, "hex").toString("utf8").replace(/[^\x20-\x7e]/g, "") || null;
      }
    }
    const raw = Buffer.from(body.slice(0, 64), "hex").toString("utf8");
    return raw.replace(/\u0000+$/g, "").replace(/[^\x20-\x7e]/g, "") || null;
  } catch (e) {
    return null;
  }
}

async function callEtherscan(params) {
  const apikey = process.env.POLYGONSCAN_KEY;
  if (!apikey) throw new Error("POLYGONSCAN_KEY not set");
  const qs = new URLSearchParams({ chainid: String(CHAIN_ID), apikey, ...params });
  let lastErr = null;
  for (let attempt = 0; attempt < ETHERSCAN_RETRIES; attempt++) {
    try {
      const res = await fetch(ETHERSCAN_BASE + "?" + qs.toString());
      if (res.status === 429 || res.status >= 500) {
        lastErr = new Error("Etherscan HTTP " + res.status);
        await sleep(400 * (attempt + 1));
        continue;
      }
      if (!res.ok) throw new Error("Etherscan HTTP " + res.status);
      const json = await res.json();
      const msg = String((json && (json.result || json.message)) || "");
      if (json && json.status === "0" && /rate limit|max calls/i.test(msg)) {
        lastErr = new Error("Etherscan rate limited");
        await sleep(400 * (attempt + 1));
        continue;
      }
      return json;
    } catch (e) {
      lastErr = e;
      await sleep(400 * (attempt + 1));
    }
  }
  throw lastErr || new Error("Etherscan call failed");
}

/** All ERC-20 Approval logs where topic1 = owner, newest pages last. */
async function getApprovalLogs(owner) {
  const logs = [];
  let truncated = false;
  for (let page = 1; page <= MAX_PAGES; page++) {
    const data = await callEtherscan({
      module: "logs",
      action: "getLogs",
      fromBlock: "0",
      toBlock: "latest",
      topic0: TOPIC_APPROVAL,
      topic0_1_opr: "and",
      topic1: pad32(owner),
      page: String(page),
      offset: String(PAGE_SIZE),
    });
    const rows = Array.isArray(data && data.result) ? data.result : [];
    if (!Array.isArray(data && data.result) && data && data.status === "0" && !/no records/i.test(String(data.message || ""))) {
      throw new Error("getLogs failed: " + String(data.message || "unknown"));
    }
    logs.push(...rows);
    if (rows.length < PAGE_SIZE) break;
    if (page === MAX_PAGES) truncated = true;
    await sleep(220);
  }
  return { logs, truncated };
}

function rpcUrls() {
  const key = process.env.DRPC_KEY || "";
  return (key ? ["https://lb.drpc.live/polygon/" + key] : []).concat(PUBLIC_RPCS);
}

/** One JSON-RPC batch; tries each RPC in turn. Returns results by id. */
async function rpcBatch(calls) {
  for (const url of rpcUrls()) {
    const ctrl = new AbortController();
    const timer = setTimeout(function () { ctrl.abort(); }, RPC_TIMEOUT_MS);
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
      for (const o of out) if (o && o.id !== undefined) byId[o.id] = o;
      return byId;
    } catch (e) {
      // try the next RPC
    } finally {
      clearTimeout(timer);
    }
  }
  throw new Error("RPC unavailable");
}

async function rpcMany(calls) {
  const all = {};
  for (let i = 0; i < calls.length; i += RPC_BATCH) {
    Object.assign(all, await rpcBatch(calls.slice(i, i + RPC_BATCH)));
  }
  return all;
}

function hexToBig(h) {
  return typeof h === "string" && /^0x[0-9a-fA-F]+$/.test(h) ? BigInt(h) : null;
}

/** Keep the newest Approval per (token, spender). ERC-20 only (3 topics). */
export function latestPairs(logs) {
  const map = new Map();
  for (const l of logs) {
    if (!l || !Array.isArray(l.topics) || l.topics.length !== 3) continue;
    const token = String(l.address || "").toLowerCase();
    const spender = topicToAddress(l.topics[2]);
    if (!isAddress(token) || !isAddress(spender)) continue;
    const block = parseInt(l.blockNumber, 16) || 0;
    const logIndex = parseInt(l.logIndex, 16) || 0;
    const key = token + "|" + spender;
    const prev = map.get(key);
    if (!prev || block > prev.block || (block === prev.block && logIndex > prev.logIndex)) {
      map.set(key, {
        token,
        spender,
        block,
        logIndex,
        tx: l.transactionHash || null,
        time: parseInt(l.timeStamp, 16) || null,
      });
    }
  }
  return Array.from(map.values());
}

export function classify(spender) {
  if (OSG_OFFICIAL[spender]) return { category: "official", label: OSG_OFFICIAL[spender] };
  if (OSG_OLD[spender]) return { category: "official_old", label: OSG_OLD[spender] };
  if (KNOWN[spender]) return { category: "known", label: KNOWN[spender] };
  return { category: "unknown", label: null };
}

/** Risk level + reason codes for one approval. */
export function assessRisk(item) {
  const reasons = [];
  if (item.unlimited) reasons.push("unlimited");
  if (item.category === "official_old") reasons.push("old_osg_contract");
  if (item.category === "unknown") {
    reasons.push("unknown_spender");
    if (item.isContract === false) reasons.push("not_a_contract");
    if (item.verified === false) reasons.push("not_verified");
  }
  let risk = "none";
  if (item.category === "unknown") {
    risk = item.unlimited || item.isContract === false || item.verified === false ? "high" : "medium";
  } else if (item.category === "official_old") {
    risk = "low";
  } else if (item.category === "known") {
    risk = item.unlimited ? "low" : "none";
  }
  return { risk, reasons };
}

async function isVerified(addr) {
  try {
    const data = await callEtherscan({ module: "contract", action: "getsourcecode", address: addr });
    const row = Array.isArray(data && data.result) ? data.result[0] : null;
    if (!row) return null;
    return typeof row.SourceCode === "string" && row.SourceCode.length > 0;
  } catch (e) {
    return null;
  }
}

const RISK_ORDER = { high: 0, medium: 1, low: 2, none: 3 };

export async function scanApprovals(owner) {
  const ownerLc = owner.toLowerCase();
  const { logs, truncated } = await getApprovalLogs(ownerLc);
  const pairs = latestPairs(logs);
  if (pairs.length === 0) {
    return { approvals: [], revokedCount: 0, truncated };
  }

  // Current allowance for every pair; symbol/decimals per token; code per spender.
  const tokens = Array.from(new Set(pairs.map(function (p) { return p.token; })));
  const spenders = Array.from(new Set(pairs.map(function (p) { return p.spender; })));
  const calls = [];
  pairs.forEach(function (p, i) {
    calls.push({
      jsonrpc: "2.0", id: "a" + i, method: "eth_call",
      params: [{ to: p.token, data: SEL_ALLOWANCE + pad32(ownerLc).slice(2) + pad32(p.spender).slice(2) }, "latest"],
    });
  });
  tokens.forEach(function (t, i) {
    calls.push({ jsonrpc: "2.0", id: "s" + i, method: "eth_call", params: [{ to: t, data: SEL_SYMBOL }, "latest"] });
    calls.push({ jsonrpc: "2.0", id: "d" + i, method: "eth_call", params: [{ to: t, data: SEL_DECIMALS }, "latest"] });
  });
  spenders.forEach(function (s, i) {
    calls.push({ jsonrpc: "2.0", id: "c" + i, method: "eth_getCode", params: [s, "latest"] });
  });
  const res = await rpcMany(calls);

  const tokenInfo = {};
  tokens.forEach(function (t, i) {
    const s = res["s" + i];
    const d = res["d" + i];
    const dec = d && hexToBig(d.result);
    tokenInfo[t] = {
      symbol: (s && decodeString(s.result)) || null,
      decimals: dec !== null && dec <= 36n ? Number(dec) : 18,
    };
  });
  const codeOf = {};
  spenders.forEach(function (s, i) {
    const c = res["c" + i];
    codeOf[s] = c && typeof c.result === "string" ? c.result !== "0x" && c.result !== "0x0" : null;
  });

  let revokedCount = 0;
  const items = [];
  pairs.forEach(function (p, i) {
    const a = res["a" + i];
    const allowance = a ? hexToBig(a.result) : null;
    if (allowance === 0n) {
      revokedCount++;
      return;
    }
    const cls = classify(p.spender);
    const info = tokenInfo[p.token] || { symbol: null, decimals: 18 };
    items.push({
      token: p.token,
      tokenSymbol: info.symbol,
      tokenDecimals: info.decimals,
      spender: p.spender,
      spenderLabel: cls.label,
      category: cls.category,
      allowanceRaw: allowance === null ? null : allowance.toString(),
      allowance: allowance === null ? null : allowance >= UNLIMITED_FROM ? "unlimited" : formatUnits(allowance, info.decimals),
      unlimited: allowance !== null && allowance >= UNLIMITED_FROM,
      isContract: codeOf[p.spender],
      verified: null,
      lastApprovalBlock: p.block,
      lastApprovalTx: p.tx,
      lastApprovalTime: p.time,
    });
  });

  // Verified-source check only for unknown contract spenders (capped).
  const toVerify = Array.from(new Set(items
    .filter(function (x) { return x.category === "unknown" && x.isContract === true; })
    .map(function (x) { return x.spender; }))).slice(0, MAX_VERIFY_LOOKUPS);
  const verifiedOf = {};
  for (const s of toVerify) {
    verifiedOf[s] = await isVerified(s);
    await sleep(220);
  }

  for (const it of items) {
    if (verifiedOf[it.spender] !== undefined) it.verified = verifiedOf[it.spender];
    const r = assessRisk(it);
    it.risk = r.risk;
    it.reasons = r.reasons;
  }
  items.sort(function (x, y) {
    return (RISK_ORDER[x.risk] - RISK_ORDER[y.risk]) || (y.lastApprovalBlock - x.lastApprovalBlock);
  });
  return { approvals: items, revokedCount, truncated };
}

export async function approvalsHandler(req, res) {
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  if (req.method !== "GET") {
    res.setHeader("Cache-Control", "no-store");
    return res.status(405).json({ ok: false, error: "GET only" });
  }
  const address = String((req.query && req.query.address) || "").trim();
  if (!isAddress(address)) {
    res.setHeader("Cache-Control", "no-store");
    return res.status(400).json({ ok: false, error: "address must be a 0x wallet address" });
  }
  try {
    const out = await scanApprovals(address);
    res.setHeader("Cache-Control", "public, s-maxage=60, stale-while-revalidate=120");
    return res.status(200).json(Object.assign({ ok: true, address: address.toLowerCase(), scannedAt: Date.now() }, out));
  } catch (e) {
    res.setHeader("Cache-Control", "no-store");
    return res.status(503).json({ ok: false, error: "scan unavailable, please try again" });
  }
}
