// ══════════════════════════════════════════════════════════
//  /api/pinata-upload.js   — Vercel serverless function
//  Pins an (already-encrypted) string to IPFS via Pinata and
//  returns its CID. The Pinata JWT lives ONLY here (server-side,
//  from the PINATA_JWT env var) — it never reaches the browser.
// ══════════════════════════════════════════════════════════

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

    const r = await fetch("https://api.pinata.cloud/pinning/pinJSONToIPFS", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: Bearer ${jwt},
      },
      body: JSON.stringify({
        pinataContent: { osg: content },
        pinataMetadata: { name: "osg-msg" },
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
