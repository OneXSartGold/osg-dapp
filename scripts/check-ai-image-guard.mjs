// Offline check of the picture guard's reply parsing (no network, no keys).
// Feeds sample guard replies (with an optional member text) through readPlan
// from api/ai-image.js and prints what the handler would do with each one.
// Run: node scripts/check-ai-image-guard.mjs

import { readPlan } from "../api/ai-image.js";

// Fixed "random" so the fallback lines are the same on every run.
const FIRST = function () {
  return 0;
};

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
  ["caption + wish, Marathi", '{"ok":true,"prompt":"Warm sunset over a calm lake","caption":"शुभ संध्याकाळ","wish":"तुमची संध्याकाळ आनंदी आणि शांत जावो"}'],
  ["wish too long", '{"ok":true,"prompt":"Diyas on a courtyard","caption":"Happy Diwali","wish":"May this festival of lights fill your home with joy, peace, health and many bright days ahead"}'],
  ["wish with a link", '{"ok":true,"prompt":"Birthday cake","caption":"Happy Birthday","wish":"Celebrate at osg-dapp.vercel.app"}'],
  ["wish without caption", '{"ok":true,"prompt":"Misty mountains at dawn","caption":"","wish":"Have a calm day"}'],
  ["wish with money words", '{"ok":true,"prompt":"Golden sunrise","caption":"Good Morning","wish":"Start the day with profit"}'],
  ["empty caption, text given", '{"ok":true,"prompt":"Evening sky over a village","caption":"","wish":""}', "Good Evening"],
  ["wish 'learning' kept", '{"ok":true,"prompt":"Books by a window","caption":"Good Morning","wish":"Keep learning and keep shining"}'],
  ["wish 'Earn more' dropped", '{"ok":true,"prompt":"Golden sunrise","caption":"Good Morning","wish":"Earn more every day"}'],
  ["wish 'Hearts' kept", '{"ok":true,"prompt":"Diyas at night","caption":"Happy Diwali","wish":"Hearts full of light"}'],
  ["fallback, Marathi", '{"ok":true,"prompt":"Sunset over hills","caption":"शुभ संध्याकाळ","wish":""}', "", "Good evening ची इमेज बनवुन दे"],
  ["fallback, English", '{"ok":true,"prompt":"Sunset over a lake","caption":"Good Evening","wish":"Big profit tonight"}', "", "good evening picture"],
  ["caption with new domain", '{"ok":true,"prompt":"Golden light over a dark background","caption":"Visit app.onexsmartgold.com","wish":"Have a bright day"}'],
];

function len(t) {
  return [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(t)].length;
}

CASES.forEach(function (c, i) {
  const r = readPlan(c[1], c[2], c[3], FIRST);
  let out;
  if (r.bad) out = "502 Could not prepare the picture";
  else if (r.refused) out = "refused -> " + JSON.stringify(r.reason);
  else out = "make -> caption " + JSON.stringify(r.caption) + " (" + len(r.caption) + "), wish " + JSON.stringify(r.wish) + " (" + len(r.wish) + ")";
  console.log(String(i + 1).padStart(2) + ". " + c[0].padEnd(27) + " " + out);
});
