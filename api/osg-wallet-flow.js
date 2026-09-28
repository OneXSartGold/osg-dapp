// ══════════════════════════════════════════════════════════
//  /api/osg-wallet-flow.js   — Vercel serverless function
//  Where one wallet's OSG came from and where it went, plus who
//  first sent it POL (gas). For the admin page's wallet check.
//
//  Read-only. Only the OSG token, the OSG/WPOL pair (for liquidity)
//  and the wallet's own POL history are read. The Etherscan key
//  stays on the server.
//
//  GET /api/osg-wallet-flow?addr=0x...
//  Response:
//  {
//    ok, addr, updatedAt, truncated,
//    totals: { in: {bought, rewards, unstaked, p2p, fromWallets, lp, other},
//              out: {sold, staked, p2p, toWallets, lp, other} },
//    senders:   [ { address, osg, count } ]   // wallets that sent it OSG
//    receivers: [ { address, osg, count } ]   // wallets it sent OSG to
//    funder:    { from, pol, time, hash, via } | null
//    rows:      [ { hash, time, dir, osg, other, label, kind } ]  // newest first, max 200
//  }
// ══════════════════════════════════════════════════════════

const BASE  = "https://api.etherscan.io/v2/api";
const TOKEN = "0xba05176748347944cc26900c821abfebebc57415";
const PAIR  = "0xa15214b09a9b3e1c821b94fb97d6d3bca8201cd2";
const ZERO  = "0x0000000000000000000000000000000000000000";
const MAX_ROWS = 200;

// Known OSG addresses. kind decides how a transfer is counted.
const KNOWN = {
  [PAIR]: ["QuickSwap pool", "pair"],
  "0xdc4fe983ed301ad42f4e4c43951aa07a7a182855": ["Reward Pool", "reward"],
  "0xa0b2dcb18cf0bdf61bcb9d33f538167df501becb": ["Reward Storage", "reward"],
  "0x58383a8171014a8008d28e7cbb509e21412ec52a": ["Referral v5", "reward"],
  "0x82cfa8cb35176bac5d9d2ec791aa22b33abaa381": ["Referral v4", "reward"],
  "0x4f1eff6fc4a0271096dd78b6f6284d4c9f1904f1": ["Referral Distributor", "reward"],
  "0x4669b2d38098ae28d0332f03d1630b334addddf50": ["Treasury", "reward"],
  "0x4581b50e6eaf62edfa618f55a55f60cb3a13c897": ["TaskBoard", "reward"],
  "0xb3de3956df62a069c9ac428ec58120b3d9cd7ccc": ["Term Staking", "stake"],
  "0x1f04f1441208ee8ddd3a124defc4a493d768d0fc": ["LP Mining", "stake"],
  "0x4bfad548efd22e2fe75bbc77b6114380f8ef1ba3": ["LP Mining (old)", "stake"],
  "0x048e814c02e85ec1438ab8c1d2e9150a5289a886": ["Staking (old)", "stake"],
  "0x06263828484e36106edf20a6d5a38c3be9612269": ["Bond", "stake"],
  "0x269eca6adb7c9c1befdc6c0be48a545b1920e1bb": ["P2P Exchange v3", "p2p"],
  "0xdc172cbbb940c8af717de1cb46a89a6d91afa567": ["P2P Exchange v2", "p2p"],
  "0x72a4387cc07cf105feec4615b40d2ef9ca0aee6b": ["P2P Exchange v1", "p2p"],
  "0xe2e82a8acdd3af7fa74eacb3331231a769d80d4c": ["TimelockDAO", "other"],
  "0xf8acaa5617dff6db3d0cb44ca8de0e50a449bb83": ["OSG-MAIN", "other"],
  "0xadc33f3cc10c44a9902a1b3f8257e6867dd242e6": ["Vesting (Team)", "other"],
  [ZERO]: ["New OSG (reward)", "reward"],
};

async function getWithTimeout(url, ms) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), ms);
  try {
    return await fetch(url, { signal: ctrl.signal });
  } finally {
    clearTimeout(timer);
  }
}

async function call(key, params) {
  const qs = new URLSearchParams(Object.assign({ chainid: "137", apikey: key }, params));
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const r = await getWithTimeout(BASE + "?" + qs.toString(), 8000);
      const j = await r.json();
      if (Array.isArray(j.result)) return j.result;
      if (j && j.message && /no transactions/i.test(j.message)) return [];
    } catch (e) {
      // retry below
    }
    await new Promise((res) => setTimeout(res, 400 * (attempt + 1)));
  }
  throw new Error("Etherscan did not answer (" + params.action + ")");
}

function toUnits(value, decimals) {
  const d = Number(decimals || 18);
  const s = String(value || "0").padStart(d + 1, "0");
  return Number(s.slice(0, s.length - d) + "." + s.slice(s.length - d));
}

function addTo(list, address, osg) {
  if (!list[address]) list[address] = { address, osg: 0, count: 0 };
  list[address].osg += osg;
  list[address].count += 1;
}

export default async function handler(req, res) {
  const key = process.env.POLYGONSCAN_KEY || "";
  const addr = String((req.query && req.query.addr) || "").toLowerCase();
  if (!/^0x[0-9a-f]{40}$/.test(addr)) {
    return res.status(400).json({ ok: false, error: "Give a wallet address: ?addr=0x..." });
  }
  if (!key) {
    return res.status(200).json({ ok: false, error: "No API key set (POLYGONSCAN_KEY)" });
  }

  try {
    // Sequential, to stay under the free plan's calls per second.
    const osgRows = await call(key, {
      module: "account", action: "tokentx", contractaddress: TOKEN, address: addr,
      page: "1", offset: "1000", sort: "desc",
    });
    const lpRows = await call(key, {
      module: "account", action: "tokentx", contractaddress: PAIR, address: addr,
      page: "1", offset: "1000", sort: "desc",
    });
    const firstNormal = await call(key, {
      module: "account", action: "txlist", address: addr,
      page: "1", offset: "10", sort: "asc",
    });
    const firstInternal = await call(key, {
      module: "account", action: "txlistinternal", address: addr,
      page: "1", offset: "10", sort: "asc",
    });

    // Transactions that moved this wallet's LP tokens are liquidity changes.
    const lpHash = {};
    for (const t of lpRows) lpHash[t.hash.toLowerCase()] = true;

    const totals = {
      in: { bought: 0, rewards: 0, unstaked: 0, p2p: 0, fromWallets: 0, lp: 0, other: 0 },
      out: { sold: 0, staked: 0, p2p: 0, toWallets: 0, lp: 0, other: 0 },
    };
    const senders = {};
    const receivers = {};
    const rows = [];

    for (const t of osgRows) {
      const h = t.hash.toLowerCase();
      const from = t.from.toLowerCase();
      const to = t.to.toLowerCase();
      if (from !== addr && to !== addr) continue;
      const dir = to === addr ? "IN" : "OUT";
      const other = dir === "IN" ? from : to;
      const osg = toUnits(t.value, t.tokenDecimal);
      const known = KNOWN[other];
      let kind = known ? known[1] : "wallet";
      if (kind === "pair" && lpHash[h]) kind = "lp";

      if (dir === "IN") {
        if (kind === "pair") totals.in.bought += osg;
        else if (kind === "reward") totals.in.rewards += osg;
        else if (kind === "stake") totals.in.unstaked += osg;
        else if (kind === "p2p") totals.in.p2p += osg;
        else if (kind === "lp") totals.in.lp += osg;
        else if (kind === "wallet") { totals.in.fromWallets += osg; addTo(senders, other, osg); }
        else totals.in.other += osg;
      } else {
        if (kind === "pair") totals.out.sold += osg;
        else if (kind === "stake") totals.out.staked += osg;
        else if (kind === "p2p") totals.out.p2p += osg;
        else if (kind === "lp") totals.out.lp += osg;
        else if (kind === "wallet") { totals.out.toWallets += osg; addTo(receivers, other, osg); }
        else totals.out.other += osg;
      }

      if (rows.length < MAX_ROWS) {
        rows.push({
          hash: h,
          time: Number(t.timeStamp),
          dir,
          osg,
          other,
          label: known ? known[0] : "",
          kind,
        });
      }
    }

    // Who first sent this wallet POL: the earliest incoming value, whether
    // a plain transfer or one made from inside a contract (exchanges often
    // pay out that way).
    let funder = null;
    for (const t of firstNormal) {
      if (t.to && t.to.toLowerCase() === addr && t.value !== "0" && t.isError !== "1") {
        funder = { from: t.from.toLowerCase(), pol: toUnits(t.value, 18), time: Number(t.timeStamp), hash: t.hash.toLowerCase(), via: "transfer" };
        break;
      }
    }
    for (const t of firstInternal) {
      if (t.to && t.to.toLowerCase() === addr && t.value !== "0" && t.isError !== "1") {
        const time = Number(t.timeStamp);
        if (!funder || time < funder.time) {
          funder = { from: t.from.toLowerCase(), pol: toUnits(t.value, 18), time, hash: t.hash.toLowerCase(), via: "contract" };
        }
        break;
      }
    }

    const sortDesc = (o) => Object.values(o).sort((a, b) => b.osg - a.osg).slice(0, 10);

    res.setHeader("Cache-Control", "public, max-age=60, s-maxage=300");
    return res.status(200).json({
      ok: true,
      addr,
      updatedAt: Date.now(),
      truncated: osgRows.length >= 1000,
      totals,
      senders: sortDesc(senders),
      receivers: sortDesc(receivers),
      funder,
      rows,
    });
  } catch (e) {
    return res.status(200).json({ ok: false, error: String((e && e.message) || e) });
  }
}
