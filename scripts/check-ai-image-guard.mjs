// Offline check of the picture guard's reply parsing (no network, no keys).
// Feeds sample guard replies through readPlan from api/ai-image.js and prints
// what the handler would do with each one.
// Run: node scripts/check-ai-image-guard.mjs

import { readPlan } from "../api/ai-image.js";

const CASES = [
  ["ok, Marathi caption", '{"ok":true,"prompt":"Sunrise over green Sahyadri hills, watercolor","caption":"शुभ सकाळ"}'],
  ["ok, Kannada caption", '{"ok":true,"prompt":"Rows of glowing diyas on a courtyard at dusk","caption":"ದೀಪಾವಳಿ ಹಬ್ಬದ ಶುಭಾಶಯಗಳು"}'],
  ["ok, English caption", '{"ok":true,"prompt":"Chocolate birthday cake with candles, 3D render","caption":"Happy Birthday"}'],
  ["ok, empty caption", '{"ok":true,"prompt":"A tiger resting in tall grass, realistic","caption":""}'],
  ["ok, caption missing", '{"ok":true,"prompt":"A village farm in the rain, oil painting"}'],
  ["ok, caption too long", '{"ok":true,"prompt":"Ganesh Chaturthi pandal with marigolds","caption":"गणपती बाप्पा मोरया! मंगलमूर्ती मोरया! सर्वांना गणेश चतुर्थीच्या हार्दिक शुभेच्छा"}'],
  ["ok, caption with a link", '{"ok":true,"prompt":"Golden light over a dark background","caption":"Join osg-dapp.vercel.app"}'],
  ["ok, JSON wrapped in prose", 'Here you go: {"ok":true,"prompt":"Lotus flowers on a calm lake","caption":"शुभ प्रभात"} hope it helps'],
  ["refused, Marathi reason", '{"ok":false,"reason":"खऱ्या व्यक्तींचे चित्र बनवता येत नाही; त्याऐवजी निसर्ग किंवा सणाचे चित्र मागा."}'],
  ["refused, no reason", '{"ok":false}'],
  ["malformed JSON", '{"ok":true,"prompt":"A temple at sunrise",'],
  ["ok but empty prompt", '{"ok":true,"prompt":"","caption":"Happy Diwali"}'],
];

CASES.forEach(function (c, i) {
  const r = readPlan(c[1]);
  let out;
  if (r.bad) out = "502 Could not prepare the picture";
  else if (r.refused) out = "refused -> " + JSON.stringify(r.reason);
  else out = "make -> caption " + JSON.stringify(r.caption) + " (" + [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(r.caption)].length + " chars)";
  console.log(String(i + 1).padStart(2) + ". " + c[0].padEnd(26) + " " + out);
});
