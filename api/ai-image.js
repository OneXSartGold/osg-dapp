// ══════════════════════════════════════════════════════════
//  /api/ai-image.js   — Vercel serverless function
//  Makes one family-friendly picture for the assistant ("/image ...").
//
//  Who:    OSG members only. Same upload pass as pinata-upload:
//          the wallet signs  OSG-UPLOAD|137|<wallet>|<expiry>  once a day.
//  Limits: WALLET_DAILY (10) pictures per wallet per UTC day, a burst
//          limit of WALLET_HOURLY (5) per UTC hour, and DAILY_CAP (160) for
//          everyone together per UTC day (Upstash). UTC day = 05:30 IST.
//  Quota:  Cloudflare Workers AI free plan = 10,000 neurons a day.
//          flux-1-schnell = 4.80 neurons per 512x512 tile + 9.60 per step;
//          one 1024x1024 picture = 4 tiles. At 8 steps: 19.2 + 76.8 = 96
//          neurons (~104 a day). At 4 steps: 19.2 + 38.4 = 57.6 neurons
//          (~173 a day), so 160 keeps a margin.
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
const WALLET_DAILY = 10; // pictures per wallet per UTC day
const WALLET_HOURLY = 5; // burst limit: pictures per wallet per UTC hour
const DAILY_CAP = 160; // pictures for everyone together per UTC day (57.6 neurons each)
// FLUX.1 schnell is a 4-step distilled model, so 4 steps is its native
// setting: 57.6 neurons per 1024x1024 picture instead of 96 at 8 steps.
const STEPS = 4;
const MODEL = "@cf/black-forest-labs/flux-1-schnell";
const HOURLY_MSG = function () {
  return "You have made 5 pictures this hour. Please try again in " + minutesLeftInHour() + " minutes.";
};
const DAILY_MSG = "You have used your 10 pictures for today. New ones are ready after 05:30 IST.";

const GUARD = [
  "You plan ONE picture for the assistant of OSG (OneX Smart Gold), a community token. The picture is made by an image model that cannot draw text or logos.",
  "Input: an English idea, the member's own words (they show the member's language) and the text the member wants on the picture.",
  'Reply with JSON only, nothing else: {"ok":true,"prompt":"...","caption":"...","wish":"..."} or {"ok":false,"reason":"..."}.',
  "ALLOWED (make it, do not refuse): any ordinary, family-friendly picture - good morning, good night and weekday greetings; festivals of every religion and region shown respectfully (Diwali, Ganesh Chaturthi, Navratri, Dussehra, Holi, Eid, Christmas, Guru Purab, Pongal, Onam, Makar Sankranti, Independence Day, New Year and others); birthdays, anniversaries, congratulations, thank-you, get-well; motivation and success themes; nature, flowers, sunrise, mountains, sea, rain; animals and birds; temples, monuments and landscapes in general; food and sweets; sports; education, books, technology, space; villages, cities, farms; cartoon, watercolor, oil painting, 3D, realistic or anime style (original characters only); and OSG themes (gold, the community, teamwork, wallet safety, learning) - for OSG themes use a dark #08080B background with gold #E9B949 light.",
  "REFUSE (ok:false) only: real or recognisable people, celebrities, politicians, or religious figures drawn as real people in a disrespectful way; copyrighted characters or brands and logos (Disney, Marvel, Pokemon, company logos, other tokens); nudity or sexual content; anything sexual or suggestive involving minors; gore, violence, weapons; drugs; hate, or mocking any religion, caste or community; fake documents, IDs, currency notes or cheques; money piles, price charts, profit, returns, guaranteed income, 'moon', luxury cars as rewards; any claim that OSG is backed by or redeemable for gold.",
  "PROMPT: English, at most 70 words, rich and concrete: subject, setting, lighting, colours, mood, art style, composition. NEVER ask for any words, letters, numbers, logos, watermarks or signs in the image. NEVER ask to draw the OSG logo or a diamond emblem - the app adds the real logo afterwards. Keep the bottom-right corner simple (the logo goes there) and the top 20% calm (the caption goes there). Friendly, generic, non-identifiable people are fine.",
  "CAPTION: the short text that belongs ON the picture. If a 'Text the member wants on the picture' is given, use it exactly (only shorten to 40 characters or remove a link). Otherwise write it in the member's own language and script, for example \"शुभ सकाळ\", \"शुभ दीपावली\", \"ದೀಪಾವಳಿ ಹಬ್ಬದ ಶುಭಾಶಯಗಳು\", \"Happy Birthday\". At most 40 characters. Greetings, festivals, birthdays, wishes and congratulations MUST have a caption - never \"\". Only other pictures may use \"\". Never put prices, promises or links in a caption.",
  "WISH: for greetings, festivals, birthdays, congratulations and motivation pictures this is REQUIRED - one warm, uplifting MOTIVATIONAL message in the SAME language and script as the caption, 40-90 characters, a complete sentence, for example \"प्रत्येक संध्याकाळ नव्या स्वप्नांची सुरुवात असते — आनंदी राहा!\", \"Every sunset brings the promise of a brighter tomorrow.\", \"ಪ್ರತಿ ದಿನ ಹೊಸ ಅವಕಾಶ, ನಗುತ್ತಾ ಮುನ್ನಡೆಯಿರಿ!\". Original wording each time, not a famous quote, no person's name. No prices, promises, links, or earn, profit, income or returns words. Use \"\" only when the caption is \"\".",
  "REASON (when ok:false): one short, polite sentence in the member's language that says what can be made instead.",
].join("\n");

const NO_TEXT =
  ". No text, no letters, no numbers, no logos, no watermark. Calm top area and calm bottom-right corner. Sharp, highly detailed, high resolution.";

// A wish line must never talk about money. Whole words only, so "learning" or "hearts" survive.
const MONEY_WORDS = /\b(earn|earns|earning|earnings|profit|profits|income|returns?|guaranteed?|moon)\b|उत्पन्न|कमाई|नफा|[₹$€]/i;

// Server fallback motivation lines, by the caption's script (used when the guard gives no usable wish).
const FALLBACK_WISHES = Object.freeze({
  mr: Object.freeze([
    "प्रत्येक नवा दिवस नवी संधी घेऊन येतो — हसत हसत पुढे चला!",
    "स्वप्नांवर विश्वास ठेवा आणि रोज एक पाऊल पुढे टाका.",
    "आनंदी मन आणि सकारात्मक विचार हीच आपली खरी ताकद आहे.",
    "छोट्या प्रयत्नांतूनच मोठे बदल घडतात — आजच सुरुवात करा!",
    "तुमचा दिवस आनंद, शांतता आणि नव्या उमेदीने भरलेला जावो.",
    "प्रत्येक संध्याकाळ नव्या स्वप्नांची सुरुवात असते — आनंदी राहा!",
  ]),
  hi: Object.freeze([
    "हर नया दिन एक नया मौका लेकर आता है — मुस्कुराते रहिए!",
    "अपने सपनों पर भरोसा रखिए और हर दिन एक कदम आगे बढ़िए।",
    "खुश मन और सकारात्मक सोच ही हमारी सबसे बड़ी ताकत है।",
    "छोटे-छोटे प्रयासों से ही बड़े बदलाव आते हैं — आज ही शुरुआत करें!",
    "आपका दिन खुशियों, सुकून और नई उम्मीदों से भरा रहे।",
    "हर शाम नए सपनों की शुरुआत होती है — हमेशा खुश रहिए!",
  ]),
  kn: Object.freeze([
    "ಪ್ರತಿ ದಿನವೂ ಹೊಸ ಅವಕಾಶ ತರುತ್ತದೆ, ನಗುತ್ತಾ ಮುನ್ನಡೆಯಿರಿ!",
    "ನಿಮ್ಮ ಕನಸುಗಳನ್ನು ನಂಬಿ, ಪ್ರತಿದಿನ ಒಂದು ಹೆಜ್ಜೆ ಮುಂದೆ ಇಡಿ.",
    "ಸಂತೋಷದ ಮನಸ್ಸು ಮತ್ತು ಒಳ್ಳೆಯ ಯೋಚನೆಗಳೇ ನಮ್ಮ ನಿಜವಾದ ಶಕ್ತಿ.",
    "ಸಣ್ಣ ಪ್ರಯತ್ನಗಳಿಂದಲೇ ದೊಡ್ಡ ಬದಲಾವಣೆಗಳು ಬರುತ್ತವೆ, ಇಂದೇ ಆರಂಭಿಸಿ!",
    "ನಿಮ್ಮ ದಿನ ಸಂತೋಷ, ಶಾಂತಿ ಮತ್ತು ಹೊಸ ಭರವಸೆಯಿಂದ ತುಂಬಿರಲಿ.",
    "ಬೆಳಕಿನಂತೆ ನಿಮ್ಮ ಜೀವನವೂ ಸದಾ ಹೊಳೆಯುತ್ತಿರಲಿ, ಖುಷಿಯಾಗಿರಿ!",
  ]),
  te: Object.freeze([
    "ప్రతి కొత్త రోజు ఒక కొత్త అవకాశం, చిరునవ్వుతో ముందుకు సాగండి!",
    "మీ కలలను నమ్మండి, ప్రతిరోజూ ఒక అడుగు ముందుకు వేయండి.",
    "సంతోషమైన మనసు, మంచి ఆలోచనలే మనకు నిజమైన బలం.",
    "చిన్న ప్రయత్నాలతోనే పెద్ద మార్పులు వస్తాయి, ఈరోజే మొదలుపెట్టండి!",
    "మీ రోజు ఆనందం, ప్రశాంతత మరియు కొత్త ఆశలతో నిండి ఉండాలి.",
    "ప్రతి సాయంత్రం కొత్త కలలకు నాంది, ఎప్పుడూ సంతోషంగా ఉండండి!",
  ]),
  ta: Object.freeze([
    "ஒவ்வொரு புதிய நாளும் ஒரு புதிய வாய்ப்பு, புன்னகையுடன் முன்னேறுங்கள்!",
    "உங்கள் கனவுகளை நம்புங்கள், தினமும் ஒரு அடி முன்னே வையுங்கள்.",
    "மகிழ்ச்சியான மனமும் நல்ல எண்ணங்களுமே உண்மையான பலம்.",
    "சிறிய முயற்சிகளே பெரிய மாற்றங்களைத் தருகின்றன, இன்றே தொடங்குங்கள்!",
    "உங்கள் நாள் மகிழ்ச்சி, அமைதி மற்றும் புதிய நம்பிக்கையால் நிறையட்டும்.",
    "ஒவ்வொரு மாலையும் புதிய கனவுகளின் தொடக்கம், என்றும் மகிழ்ச்சியாக இருங்கள்!",
  ]),
  gu: Object.freeze([
    "દરેક નવો દિવસ નવી તક લઈને આવે છે, હસતાં હસતાં આગળ વધો!",
    "તમારાં સપનાં પર વિશ્વાસ રાખો અને રોજ એક ડગલું આગળ ભરો.",
    "ખુશ મન અને સકારાત્મક વિચાર જ આપણી સાચી તાકાત છે.",
    "નાના પ્રયત્નોથી જ મોટા ફેરફાર આવે છે, આજથી જ શરૂઆત કરો!",
    "તમારો દિવસ આનંદ, શાંતિ અને નવી આશાથી ભરેલો રહે.",
    "દરેક સાંજ નવાં સપનાંની શરૂઆત છે, હંમેશાં ખુશ રહો!",
  ]),
  en: Object.freeze([
    "Every sunset brings the promise of a brighter tomorrow.",
    "Believe in your dreams and take one small step every day.",
    "A happy heart and kind thoughts are the truest strength.",
    "Small efforts every day add up to big changes. Start today!",
    "May your day be filled with joy, peace and fresh hope.",
    "Keep smiling, keep learning and let your light shine bright.",
  ]),
});
// Marathi markers in the caption or the member's words; other Devanagari is treated as Hindi.
const MARATHI_HINT = /ची|चा|चे|च्या|आहे|बनव|ळ|शुभ सकाळ|शुभ संध्याकाळ|आणि|करा|द्या|ांना/;

/** One fallback motivation line in the caption's script, or "" for a script we have no list for. */
export function pickFallbackWish(caption, original, rnd = Math.random) {
  const c = String(caption || "");
  let lang = "";
  if (/[\u0900-\u097f]/.test(c)) lang = MARATHI_HINT.test(c + " " + String(original || "")) ? "mr" : "hi";
  else if (/[\u0c80-\u0cff]/.test(c)) lang = "kn";
  else if (/[\u0c00-\u0c7f]/.test(c)) lang = "te";
  else if (/[\u0b80-\u0bff]/.test(c)) lang = "ta";
  else if (/[\u0a80-\u0aff]/.test(c)) lang = "gu";
  else if (/[a-z]/i.test(c)) lang = "en";
  const list = FALLBACK_WISHES[lang];
  return list ? list[Math.floor(rnd() * list.length) % list.length] : "";
}

/** Cleans the caption (or wish) for drawing: one line, no links, at most max characters. */
export function cleanCaption(c, max = 40) {
  let t = typeof c === "string" ? c : "";
  t = t.replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/\s+/g, " ").trim();
  t = t.replace(/^["'\u201c\u201d]+|["'\u201c\u201d]+$/g, "").trim();
  if (/https?:|www\.|\.(com|app|io|org|net|in)\b/i.test(t)) return "";
  if (typeof Intl !== "undefined" && Intl.Segmenter) {
    const parts = Array.from(new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(t), (x) => x.segment);
    return parts.length > max ? parts.slice(0, max).join("").trim() : t;
  }
  return Array.from(t).slice(0, max).join("").trim();
}

/**
 * Reads the guard's reply. Returns { prompt, caption, wish }, { refused, reason }
 * or { bad: true } when the reply cannot be used. `given` is the text the
 * member asked for; it is used when the guard leaves the caption empty.
 * `original` (the member's words) picks Marathi or Hindi for a fallback wish.
 */
export function readPlan(txt, given, original, rnd) {
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
  const caption = cleanCaption(plan.caption) || cleanCaption(given);
  let wish = caption ? cleanCaption(plan.wish, 90) : "";
  // A wish cut at 90 ends on a whole word, never half a word.
  if (wish && wish !== cleanCaption(plan.wish, 1000) && wish.lastIndexOf(" ") > 0) wish = wish.slice(0, wish.lastIndexOf(" ")).replace(/[,;:\s—-]+$/, "");
  if (MONEY_WORDS.test(wish)) wish = "";
  if (caption && !wish) wish = pickFallbackWish(caption, original, rnd);
  return { prompt, caption, wish };
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
    const wanted = typeof body.text === "string" ? body.text.trim().slice(0, 60) : "";
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
    const wdKey = "img:d:" + w + ":" + day;
    const dKey = "img:all:" + day;
    let used = 0;
    let usedMine = 0;
    let usedDay = 0;
    try {
      used = Number(await redis(["GET", wKey])) || 0;
      usedMine = Number(await redis(["GET", wdKey])) || 0;
      usedDay = Number(await redis(["GET", dKey])) || 0;
    } catch (e) {
      return res.status(503).json({ error: "Limit check is unavailable, please try again." });
    }
    if (usedMine >= WALLET_DAILY) {
      return res.status(429).json({ error: DAILY_MSG });
    }
    if (used >= WALLET_HOURLY) {
      return res.status(429).json({ error: HOURLY_MSG() });
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
          { role: "user", content: "Idea (English): " + idea + "\nMember's own words: " + (original || "same") + "\nText the member wants on the picture: " + (wanted || "none given") },
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
    const plan = readPlan(txt, wanted, original);
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
        return res.status(429).json({ error: HOURLY_MSG() });
      }
      const m = Number(await redis(["INCR", wdKey]));
      if (m === 1) await redis(["EXPIRE", wdKey, 86400]);
      if (m > WALLET_DAILY) {
        await redis(["DECR", wdKey]);
        await redis(["DECR", wKey]);
        return res.status(429).json({ error: DAILY_MSG });
      }
      const d = Number(await redis(["INCR", dKey]));
      if (d === 1) await redis(["EXPIRE", dKey, 86400]);
    } catch (e) {
      return res.status(503).json({ error: "Limit check is unavailable, please try again." });
    }

    const cf = await fetch("https://api.cloudflare.com/client/v4/accounts/" + acct + "/ai/run/" + MODEL, {
      method: "POST",
      headers: { Authorization: "Bearer " + cfToken, "Content-Type": "application/json" },
      body: JSON.stringify({ prompt: prompt + NO_TEXT, steps: STEPS }),
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
    return res.status(200).json({ image: "data:image/jpeg;base64," + b64, caption: plan.caption, wish: plan.wish });
  } catch (e) {
    console.error("ai-image:", e?.message || e);
    return res.status(500).json({ error: "Something went wrong, please try again." });
  }
}
