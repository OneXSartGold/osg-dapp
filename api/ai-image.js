// ══════════════════════════════════════════════════════════
//  /api/ai-image.js   — Vercel serverless function
//  Makes one family-friendly picture for the assistant ("/image ...").
//
//  Who:    OSG members only. Same upload pass as pinata-upload:
//          the wallet signs  OSG-UPLOAD|137|<wallet>|<expiry>  once a day.
//  Limits: 3 images per wallet per UTC hour, and DAILY_CAP images for
//          everyone together per UTC day (Upstash). The Cloudflare
//          Workers AI free plan gives roughly 170 images a day.
//  Guard:  Groq first turns the request into a safe image prompt plus a
//          short caption in the member's own language, or refuses it.
//          FLUX draws no text or logo; the app adds the caption and the
//          real logo. Nothing is stored; the image goes straight back.
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
const DAILY_CAP = 100; // images for everyone together per UTC day
const MODEL = "@cf/black-forest-labs/flux-1-schnell";

const GUARD = [
  "You plan ONE picture for the assistant of OSG (OneX Smart Gold), a community token. The picture is made by an image model that cannot draw text or logos.",
  "Input: an English idea and the member's own words (they show the member's language).",
  'Reply with JSON only, nothing else: {"ok":true,"prompt":"...","caption":"..."} or {"ok":false,"reason":"..."}.',
  "ALLOWED (make it, do not refuse): any ordinary, family-friendly picture - good morning, good night and weekday greetings; festivals of every religion and region shown respectfully (Diwali, Ganesh Chaturthi, Navratri, Dussehra, Holi, Eid, Christmas, Guru Purab, Pongal, Onam, Makar Sankranti, Independence Day, New Year and others); birthdays, anniversaries, congratulations, thank-you, get-well; motivation and success themes; nature, flowers, sunrise, mountains, sea, rain; animals and birds; temples, monuments and landscapes in general; food and sweets; sports; education, books, technology, space; villages, cities, farms; cartoon, watercolor, oil painting, 3D, realistic or anime style (original characters only); and OSG themes (gold, the community, teamwork, wallet safety, learning) - for OSG themes use a dark #08080B background with gold #E9B949 light.",
  "REFUSE (ok:false) only: real or recognisable people, celebrities, politicians, or religious figures drawn as real people in a disrespectful way; copyrighted characters or brands and logos (Disney, Marvel, Pokemon, company logos, other tokens); nudity or sexual content; anything sexual or suggestive involving minors; gore, violence, weapons; drugs; hate, or mocking any religion, caste or community; fake documents, IDs, currency notes or cheques; money piles, price charts, profit, returns, guaranteed income, 'moon', luxury cars as rewards; any claim that OSG is backed by or redeemable for gold.",
  "PROMPT: English, at most 70 words, rich and concrete: subject, setting, lighting, colours, mood, art style, composition. NEVER ask for any words, letters, numbers, logos, watermarks or signs in the image. NEVER ask to draw the OSG logo or a diamond emblem - the app adds the real logo afterwards. Keep the bottom-right corner simple (the logo goes there) and the top 20% calm (the caption goes there). Friendly, generic, non-identifiable people are fine.",
  "CAPTION: the short text that belongs ON the picture, in the member's own language and script (from the member's own words), for example \"शुभ सकाळ\", \"शुभ दीपावली\", \"ದೀಪಾವಳಿ ಹಬ್ಬದ ಶುಭಾಶಯಗಳು\", \"Happy Birthday\". At most 40 characters. Use \"\" when no text is needed. Never put prices, promises or links in a caption.",
  "REASON (when ok:false): one short, polite sentence in the member's language that says what can be made instead.",
].join("\n");

const NO_TEXT =
  ". No text, no letters, no numbers, no logos, no watermark. Calm top area and calm bottom-right corner. Sharp, highly detailed, high resolution.";

/** Cleans the caption for drawing: one line, no links, at most 40 characters. */
export function cleanCaption(c) {
  let t = typeof c === "string" ? c : "";
  t = t.replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/\s+/g, " ").trim();
  t = t.replace(/^["'\u201c\u201d]+|["'\u201c\u201d]+$/g, "").trim();
  if (/https?:|www\.|\.(com|app|io|org|net|in)\b/i.test(t)) return "";
  if (typeof Intl !== "undefined" && Intl.Segmenter) {
    const parts = Array.from(new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(t), (x) => x.segment);
    return parts.length > 40 ? parts.slice(0, 40).join("").trim() : t;
  }
  return Array.from(t).slice(0, 40).join("").trim();
}

/**
 * Reads the guard's reply. Returns { prompt, caption }, { refused, reason }
 * or { bad: true } when the reply cannot be used.
 */
export function readPlan(txt) {
  const s = String(txt || "");
  let plan = null;
  try {
    plan = JSON.parse(s.slice(s.indexOf("{"), s.lastIndexOf("}") + 1));
  } catch (e) {
    plan = null;
  }
  if (!plan || typeof plan.ok !== "boolean") return { bad: true };
  if (!plan.ok) {
    return {
      refused: true,
      reason: String(plan.reason || "This picture cannot be made. Please try a different idea.").slice(0, 200),
    };
  }
  const prompt = String(plan.prompt || "").slice(0, 600);
  if (!prompt) return { bad: true };
  return { prompt, caption: cleanCaption(plan.caption) };
}

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
    const original = typeof body.original === "string" ? body.original.trim().slice(0, 300) : "";
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

    // Guard: Groq rewrites the idea into a safe prompt and caption, or refuses.
    const g = await fetch("https://api.groq.com/openai/v1/chat/completions", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: "Bearer " + process.env.GROQ_API_KEY },
      body: JSON.stringify({
        model: "openai/gpt-oss-120b",
        messages: [
          { role: "system", content: GUARD },
          { role: "user", content: "Idea (English): " + idea + "\nMember's own words: " + (original || "same") },
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
    const plan = readPlan(txt);
    if (plan.bad) {
      return res.status(502).json({ error: "Could not prepare the picture, please try again." });
    }
    if (plan.refused) {
      return res.status(200).json({ refused: true, reason: plan.reason });
    }
    const prompt = plan.prompt;

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
      body: JSON.stringify({ prompt: prompt + NO_TEXT, steps: 8 }),
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
    return res.status(200).json({ image: "data:image/jpeg;base64," + b64, caption: plan.caption });
  } catch (e) {
    console.error("ai-image:", e?.message || e);
    return res.status(500).json({ error: "Something went wrong, please try again." });
  }
}
