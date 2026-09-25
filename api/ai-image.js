// ══════════════════════════════════════════════════════════
//  /api/ai-image.js   — Vercel serverless function
//  Makes one OSG-themed picture for the assistant ("/image ...").
//
//  Who:    OSG members only. Same upload pass as pinata-upload:
//          the wallet signs  OSG-UPLOAD|137|<wallet>|<expiry>  once a day.
//  Limits: 3 images per wallet per UTC hour, and DAILY_CAP images for
//          everyone together per UTC day (Upstash). The Cloudflare
//          Workers AI free plan gives roughly 170 images a day.
//  Theme:  Groq first turns the request into an OSG-brand prompt,
//          or refuses it. Nothing is stored; the image goes straight back.
//  Keys:   CF_ACCOUNT_ID, CF_AI_TOKEN, GROQ_API_KEY, UPSTASH_REDIS_REST_*
//          (server only, never VITE_).
// ══════════════════════════════════════════════════════════

import { verifyMessage, JsonRpcProvider, Contract } from "ethers";

const RPCS = ["https://polygon-bor-rpc.publicnode.com", "https://polygon.drpc.org"];
const TOKEN = "0xba05176748347944CC26900c821AbFeBeBC57415";
const REFERRAL = "0x58383A8171014a8008d28e7CbB509e21412ec52A";
const MIN_OSG = 100000000000000000n; // 0.1 OSG, same rule as uploads
const MAX_LIFE = 90000; // a pass may not live longer than 25 hours
const WALLET_HOURLY = 3; // images per wallet per UTC hour
const DAILY_CAP = 150; // images for everyone together per UTC day
const MODEL = "@cf/black-forest-labs/flux-1-schnell";

const GUARD = [
  "You turn a user's picture request into ONE image prompt for OSG (OneX Smart Gold), a community crypto token on the Polygon blockchain.",
  'Reply with JSON only, nothing else: {"ok":true,"prompt":"..."} or {"ok":false,"reason":"..."}.',
  "Allowed themes: the OSG token and coin, the OSG community, blockchain and Polygon ideas, staking, liquidity, wallets, wallet safety tips, learning about crypto, community events in general, festival greetings from OSG.",
  "Refuse (ok:false) anything not about OSG or crypto learning, and anything that shows or mentions: real or recognisable people, celebrities or politicians; other companies' logos, brands or tokens; nudity, violence, weapons, drugs or hate; religion in a mocking way; price predictions, rising charts, piles of money, profit, returns, guaranteed income, 'moon', luxury cars or any promise of earnings; any claim that OSG is backed by or redeemable for gold.",
  "When ok: write the prompt in English, at most 60 words. Always include: dark background (#08080B), gold accents (#E9B949), clean modern digital-art style, the OSG emblem as the subject or clearly visible: a faceted golden diamond engraved with the letters OSG, standing on a glowing blue octagonal base. Never use the words crypto, cryptocurrency, Bitcoin, blockchain, coin, token or digital currency in the prompt; show networks only as abstract glowing gold lines. The golden OSG diamond is the only emblem in the picture. No other words or letters in the picture except OSG. People only as simple faceless silhouettes.",
  "The reason must be one short, polite sentence in the same language the user wrote in.",
].join("\n");

async function isMember(w) {
  for (const url of RPCS) {
    try {
      const p = new JsonRpcProvider(url, 137, { staticNetwork: true, batchMaxCount: 3 });
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

/** Runs one Redis command via the Upstash REST API. */
async function redis(args) {
  const url = process.env.UPSTASH_REDIS_REST_URL;
  const token = process.env.UPSTASH_REDIS_REST_TOKEN;
  if (!url || !token) throw new Error("Upstash env vars not configured");
  const r = await fetch(url, {
    method: "POST",
    headers: { Authorization: "Bearer " + token, "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  if (!r.ok) throw new Error("Upstash responded " + r.status);
  const data = await r.json();
  return data.result;
}

function minutesLeftInHour() {
  return Math.max(1, 60 - Math.floor((Date.now() % 3600000) / 60000));
}

export default async function handler(req, res) {
  if (req.method !== "POST") {
    return res.status(405).json({ error: "Method not allowed" });
  }
  const acct = process.env.CF_ACCOUNT_ID;
  const cfToken = process.env.CF_AI_TOKEN;
  if (!acct || !cfToken || !process.env.GROQ_API_KEY) {
    return res.status(500).json({ error: "Image service is not configured" });
  }

  try {
    const body = req.body || {};
    const idea = typeof body.prompt === "string" ? body.prompt.trim().slice(0, 400) : "";
    if (idea.length < 3) {
      return res.status(400).json({ error: "Please describe the picture you want." });
    }

    // Upload pass: proves who is asking.
    const a = body.auth || {};
    const w = String(a.w || "").toLowerCase();
    const exp = Number(a.exp);
    const now = Math.floor(Date.now() / 1000);
    if (!/^0x[0-9a-f]{40}$/.test(w) || !Number.isInteger(exp) || typeof a.sig !== "string") {
      return res.status(401).json({ error: "Please sign in with your wallet and try again." });
    }
    if (exp < now || exp > now + MAX_LIFE) {
      return res.status(401).json({ error: "Your daily pass expired. Please try again." });
    }
    let signer = "";
    try {
      signer = verifyMessage("OSG-UPLOAD|137|" + w + "|" + exp, a.sig).toLowerCase();
    } catch (e) {
      signer = "";
    }
    if (signer !== w) {
      return res.status(401).json({ error: "Wallet signature did not match. Please try again." });
    }
    let member = false;
    try {
      member = await isMember(w);
    } catch (e) {
      return res.status(503).json({ error: "Could not check membership, please try again." });
    }
    if (!member) {
      return res.status(403).json({ error: "Only OSG holders or stakers can create images." });
    }

    // Limits. Images cost real quota, so this fails CLOSED if Redis is down.
    const hour = Math.floor(Date.now() / 3600000);
    const day = Math.floor(Date.now() / 86400000);
    const wKey = "img:" + w + ":" + hour;
    const dKey = "img:all:" + day;
    let used = 0;
    let usedDay = 0;
    try {
      used = Number(await redis(["GET", wKey])) || 0;
      usedDay = Number(await redis(["GET", dKey])) || 0;
    } catch (e) {
      return res.status(503).json({ error: "Limit check is unavailable, please try again." });
    }
    if (used >= WALLET_HOURLY) {
      return res.status(429).json({
        error: "You have made 3 images this hour. Please try again in " + minutesLeftInHour() + " minutes.",
      });
    }
    if (usedDay >= DAILY_CAP) {
      return res.status(429).json({ error: "Today's picture limit for the community is reached. Please try again tomorrow." });
    }

    // Theme guard: Groq rewrites the idea into an OSG prompt, or refuses.
    const g = await fetch("https://api.groq.com/openai/v1/chat/completions", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: "Bearer " + process.env.GROQ_API_KEY },
      body: JSON.stringify({
        model: "openai/gpt-oss-120b",
        messages: [
          { role: "system", content: GUARD },
          { role: "user", content: idea },
        ],
        temperature: 0.2,
        max_tokens: 1000,
      }),
    });
    if (!g.ok) {
      console.error("ai-image guard error:", g.status);
      return res.status(502).json({ error: "Could not prepare the picture, please try again." });
    }
    const gd = await g.json();
    const txt = String(gd?.choices?.[0]?.message?.content || "");
    let plan = null;
    try {
      plan = JSON.parse(txt.slice(txt.indexOf("{"), txt.lastIndexOf("}") + 1));
    } catch (e) {
      plan = null;
    }
    if (!plan || typeof plan.ok !== "boolean") {
      return res.status(502).json({ error: "Could not prepare the picture, please try again." });
    }
    if (!plan.ok) {
      return res.status(200).json({
        refused: true,
        reason: String(plan.reason || "Only OSG-themed pictures can be made.").slice(0, 200),
      });
    }
    const prompt = String(plan.prompt || "").slice(0, 600);
    if (!prompt) {
      return res.status(502).json({ error: "Could not prepare the picture, please try again." });
    }

    // Count only real generations. INCR is atomic, so two quick taps cannot both pass.
    try {
      const n = Number(await redis(["INCR", wKey]));
      if (n === 1) await redis(["EXPIRE", wKey, 3600]);
      if (n > WALLET_HOURLY) {
        await redis(["DECR", wKey]);
        return res.status(429).json({
          error: "You have made 3 images this hour. Please try again in " + minutesLeftInHour() + " minutes.",
        });
      }
      const d = Number(await redis(["INCR", dKey]));
      if (d === 1) await redis(["EXPIRE", dKey, 86400]);
    } catch (e) {
      return res.status(503).json({ error: "Limit check is unavailable, please try again." });
    }

    const cf = await fetch("https://api.cloudflare.com/client/v4/accounts/" + acct + "/ai/run/" + MODEL, {
      method: "POST",
      headers: { Authorization: "Bearer " + cfToken, "Content-Type": "application/json" },
      body: JSON.stringify({ prompt: prompt + ". The only emblem is the golden OSG diamond. Background ornaments are plain shapes with no letters, numbers or symbols. Sharp, highly detailed, high resolution.", steps: 8 }),
    });
    if (!cf.ok) {
      const t = await cf.text();
      console.error("ai-image cloudflare error:", cf.status, String(t).slice(0, 200));
      return res.status(502).json({ error: "The picture service is busy, please try again later." });
    }
    const cd = await cf.json();
    const b64 = cd?.result?.image;
    if (!b64 || typeof b64 !== "string") {
      return res.status(502).json({ error: "The picture service is busy, please try again later." });
    }
    return res.status(200).json({ image: "data:image/jpeg;base64," + b64 });
  } catch (e) {
    console.error("ai-image:", e?.message || e);
    return res.status(500).json({ error: "Something went wrong, please try again." });
  }
}
