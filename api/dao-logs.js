// ══════════════════════════════════════════════════════════
//  /api/dao-logs.js   — Vercel serverless function
//  Returns every event log of the OSG TimelockDAO (Queued,
//  Executed, Cancelled, TxExpired, admin changes, pause) via the
//  Etherscan V2 API, server-side, so the key never reaches the
//  browser. The DAO address is fixed here: this route cannot be
//  used to read any other contract.
//
//  Read-only. The admin page decodes the logs with the DAO ABI
//  and then reads the live state of each id with getTx().
// ══════════════════════════════════════════════════════════

const DAO = "0xE2E82A8ACdd3Af7FA74Eacb3331231A769d80D4c";

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
  const key = process.env.POLYGONSCAN_KEY || "";
  if (!key) {
    return res.status(200).json({ ok: false, error: "No API key set (POLYGONSCAN_KEY)", logs: [] });
  }

  const url =
    "https://api.etherscan.io/v2/api" +
    "?chainid=137" +
    "&module=logs&action=getLogs" +
    "&address=" + DAO +
    "&fromBlock=0" +
    "&toBlock=latest" +
    "&page=1&offset=1000" +
    "&apikey=" + key;

  try {
    const r = await getWithTimeout(url, 12000);
    const j = await r.json();

    if (j && j.status === "1" && Array.isArray(j.result)) {
      const logs = j.result.map((lg) => ({
        topics: lg.topics,
        data: lg.data,
        block: parseInt(lg.blockNumber, 16),
        time: parseInt(lg.timeStamp, 16),
        tx: lg.transactionHash,
      }));
      res.setHeader("Cache-Control", "public, max-age=60");
      return res.status(200).json({ ok: true, count: logs.length, full: logs.length >= 1000, logs });
    }

    if (j && j.message && /no records/i.test(j.message)) {
      return res.status(200).json({ ok: true, count: 0, full: false, logs: [] });
    }

    return res.status(200).json({ ok: false, error: (j && (j.result || j.message)) || "Etherscan returned no rows", logs: [] });
  } catch (e) {
    return res.status(502).json({ ok: false, error: "Etherscan fetch failed", logs: [] });
  }
}
