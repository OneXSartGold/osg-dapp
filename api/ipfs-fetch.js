// ══════════════════════════════════════════════════════════
//  /api/ipfs-fetch.js   — Vercel serverless function
//  Fetches a pinned JSON object back from IPFS by CID and
//  returns it. Server-side proxy → no browser CORS issues and
//  it tries several public gateways for reliability.
//  No secret needed (IPFS content is public; it's encrypted).
// ══════════════════════════════════════════════════════════

const GATEWAYS = [
  "https://gateway.pinata.cloud/ipfs/",
  "https://ipfs.io/ipfs/",
  "https://dweb.link/ipfs/",
];

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
  const cid = req.query.cid;
  // CIDs are alphanumeric (base58/base32). Reject anything else.
  if (!cid || !/^[a-zA-Z0-9]+$/.test(cid) || cid.length > 80) {
    return res.status(400).json({ error: "Bad cid" });
  }

  for (const base of GATEWAYS) {
    try {
      const r = await getWithTimeout(base + cid, 6000);
      if (r.ok) {
        const data = await r.json();
        // cache a bit at the edge (content is immutable per-CID)
        res.setHeader("Cache-Control", "public, max-age=86400");
        return res.status(200).json(data);
      }
    } catch {
      // try next gateway
    }
  }
  return res.status(502).json({ error: "IPFS fetch failed" });
}
