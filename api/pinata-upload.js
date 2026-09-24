// ══════════════════════════════════════════════════════════
//  /api/pinata-upload.js   — Vercel serverless function
//  Pins an (already-encrypted) string to IPFS via Pinata and
//  returns its CID. The Pinata JWT lives ONLY here (server-side,
//  from the PINATA_JWT env var) — it never reaches the browser.
//
//  Only OSG members may upload. The app sends an "upload pass":
//  the wallet signs  OSG-UPLOAD|137|<wallet>|<expiry>  once a day.
//  This route checks the signature, the expiry, and that the
//  wallet holds at least 0.1 OSG or has stake in Referral v5.
// ══════════════════════════════════════════════════════════

import { verifyMessage, JsonRpcProvider, Contract } from "ethers";

const RPCS = ["https://polygon-bor-rpc.publicnode.com", "https://polygon.drpc.org"];
const TOKEN = "0xba05176748347944CC26900c821AbFeBeBC57415";
const REFERRAL = "0x58383A8171014a8008d28e7CbB509e21412ec52A";
const MIN_OSG = 100000000000000000n; // 0.1 OSG = the message fee
const MAX_LIFE = 90000; // an upload pass may not live longer than 25 hours

async function isMember(w) {
  for (const url of RPCS) {
    try {
      const p = new JsonRpcProvider(url, 137, { staticNetwork: true });
      const bal = await new Contract(TOKEN, ["function balanceOf(address) view returns (uint256)"], p).balanceOf(w);
      if (bal >= MIN_OSG) return true;
      const st = await new Contract(REFERRAL, ["function stakeOf(address) view returns (uint256)"], p).stakeOf(w);
      return st > 0n;
    } catch (e) {
      // try the next RPC
    }
  }
  throw new Error("RPC unavailable");
}

export default async function handler(req, res) {
  if (req.method !== "POST") {
    return res.status(405).json({ error: "Method not allowed" });
  }

  const jwt = process.env.PINATA_JWT;
  if (!jwt) {
    return res.status(500).json({ error: "PINATA_JWT not configured" });
  }

  try {
    const body = req.body || {};
    const content = body.content;
    if (!content || typeof content !== "string") {
      return res.status(400).json({ error: "Missing content" });
    }
    // Hard safety cap so nobody can abuse the pin endpoint.
    if (content.length > 200000) {
      return res.status(413).json({ error: "Too large" });
    }

    // Upload pass
    const a = body.auth || {};
    const w = String(a.w || "").toLowerCase();
    const exp = Number(a.exp);
    const now = Math.floor(Date.now() / 1000);
    if (!/^0x[0-9a-f]{40}$/.test(w) || !Number.isInteger(exp) || typeof a.sig !== "string") {
      return res.status(401).json({ error: "Upload pass missing" });
    }
    if (exp < now || exp > now + MAX_LIFE) {
      return res.status(401).json({ error: "Upload pass expired" });
    }
    let signer = "";
    try {
      signer = verifyMessage("OSG-UPLOAD|137|" + w + "|" + exp, a.sig).toLowerCase();
    } catch (e) {
      signer = "";
    }
    if (signer !== w) {
      return res.status(401).json({ error: "Upload pass signature invalid" });
    }
    let ok = false;
    try {
      ok = await isMember(w);
    } catch (e) {
      return res.status(503).json({ error: "Could not check membership, try again" });
    }
    if (!ok) {
      return res.status(403).json({ error: "Only OSG holders or stakers can upload" });
    }

    const r = await fetch("https://api.pinata.cloud/pinning/pinJSONToIPFS", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: "Bearer " + jwt,
      },
      body: JSON.stringify({
        pinataContent: { osg: content },
        pinataMetadata: { name: "osg-msg", keyvalues: { from: w } },
      }),
    });

    if (!r.ok) {
      const detail = await r.text();
      return res.status(502).json({ error: "Pinata upload failed", detail });
    }

    const data = await r.json();
    return res.status(200).json({ cid: data.IpfsHash });
  } catch (e) {
    return res.status(500).json({ error: String(e?.message || e) });
  }
}
