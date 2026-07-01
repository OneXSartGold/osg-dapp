import { useState, useEffect } from "react";

// ──────────────────────────────────────────────
//  OSG News / Markets Popup  (terminal style)
//  - Shows once per browser session (sessionStorage)
//  - OSG price comes IN as a prop (single source of truth)
//  - BTC/USD fetched here from CoinGecko (no key needed)
//  - 3 third-party news/data sources (open in new tab)
//  BUDS-safe: factual only, no buy/return/moon language, DYOR.
// ──────────────────────────────────────────────

var GOLD = "#d4af37";
var BG = "#0a0e14";
var PANEL = "#111722";
var EDGE = "#1d2733";
var TXT = "#e6edf3";
var TXT3 = "#7d8896";
var GREEN = "#3fb950";
var RED = "#f85149";
var CYAN = "#39d0d8";

var SOURCES = [
  {
    name: "CoinDesk",
    tag: "NEWS",
    url: "https://www.coindesk.com",
    accent: CYAN,
    spark: [4, 6, 5, 8, 7, 10, 9, 12],
  },
  {
    name: "Cointelegraph",
    tag: "MARKETS",
    url: "https://cointelegraph.com",
    accent: GREEN,
    spark: [8, 7, 9, 6, 8, 11, 10, 13],
  },
  {
    name: "CoinGecko",
    tag: "DATA",
    url: "https://www.coingecko.com",
    accent: GOLD,
    spark: [5, 6, 6, 7, 9, 8, 11, 12],
  },
];

// tiny inline sparkline (no library)
function Spark(props) {
  var pts = props.data;
  var w = 64;
  var h = 22;
  var max = Math.max.apply(null, pts);
  var min = Math.min.apply(null, pts);
  var span = max - min || 1;
  var step = w / (pts.length - 1);
  var d = "";
  for (var i = 0; i < pts.length; i++) {
    var x = i * step;
    var y = h - ((pts[i] - min) / span) * h;
    d += (i === 0 ? "M" : "L") + x.toFixed(1) + " " + y.toFixed(1) + " ";
  }
  return (
    <svg width={w} height={h} style={{ display: "block" }}>
      <polyline
        points=""
        fill="none"
        stroke={props.color}
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
        d={d}
        style={{ fill: "none", stroke: props.color }}
      />
      <path d={d} fill="none" stroke={props.color} strokeWidth="1.5" />
    </svg>
  );
}

export default function NewsPopup(props) {
  // OSG/USD = osgPerPol * polUsd  (both passed in)
  var osgPerPol = props.osgPerPol;
  var polUsd = props.polUsd;
  var _op = Number(osgPerPol);
  var _pu = Number(polUsd);
  var osgUsd = (_op > 0 && _pu > 0) ? _op * _pu : null;

  var chg24 = typeof props.chg24 === "number" ? props.chg24 : null;

  var [open, setOpen] = useState(false);
  var [btc, setBtc] = useState(null);

  // show once per session
  useEffect(function () {
    var seen = null;
    try {
      seen = sessionStorage.getItem("osg_news_seen");
    } catch (e) {}
    if (!seen) setOpen(true);
  }, []);

  // BTC/USD live from CoinGecko
  useEffect(function () {
    if (!open) return;
    var go = function () {
      fetch(
        "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd"
      )
        .then(function (r) {
          return r.json();
        })
        .then(function (d) {
          var p = d && d.bitcoin && d.bitcoin.usd;
          if (p > 0) setBtc(p);
        })
        .catch(function () {});
    };
    go();
    var id = setInterval(go, 30000);
    return function () {
      clearInterval(id);
    };
  }, [open]);

  function close() {
    try {
      sessionStorage.setItem("osg_news_seen", "1");
    } catch (e) {}
    setOpen(false);
  }

  if (!open) return null;

  var osgStr =
    osgUsd !== null
      ? "$" + osgUsd.toLocaleString("en-US", { maximumFractionDigits: 6 })
      : "—";
  var btcStr =
    btc !== null
      ? "$" + btc.toLocaleString("en-US", { maximumFractionDigits: 0 })
      : "…";

  // ticker row: OSG first (gold), then majors (static labels — factual placeholders)
  var ticker = [
    { s: "OSG", v: osgStr, gold: true },
    { s: "BTC", v: btcStr, gold: false },
    { s: "ETH", v: "", gold: false },
    { s: "POL", v: polUsd ? "$" + Number(polUsd).toFixed(4) : "", gold: false },
    { s: "SOL", v: "", gold: false },
    { s: "BNB", v: "", gold: false },
  ];

  return (
    <div className="osgnews-overlay" onClick={close}>
      <div className="osgnews-modal" onClick={function (e) { e.stopPropagation(); }}>
        <div className="osgnews-grid" />

        {/* close */}
        <button className="osgnews-x" onClick={close}>✕</button>

        {/* ticker strip */}
        <div className="osgnews-ticker">
          {ticker.map(function (it, i) {
            return (
              <span
                className="osgnews-tick"
                key={i}
                style={{ color: it.gold ? GOLD : TXT3 }}
              >
                <b style={{ color: it.gold ? GOLD : TXT }}>{it.s}</b>{" "}
                {it.v}
              </span>
            );
          })}
        </div>

        {/* price cards */}
        <div className="osgnews-prices">
          <div className="osgnews-pcard" style={{ borderColor: GOLD }}>
            <div className="osgnews-plabel" style={{ color: GOLD }}>OSG / USD</div>
            <div className="osgnews-pbig" style={{ color: GOLD }}>{osgStr}</div>
            <div className="osgnews-psub">
              {chg24 !== null ? (
                <span style={{ color: chg24 >= 0 ? GREEN : RED }}>
                  {(chg24 >= 0 ? "▲ " : "▼ ") + Math.abs(chg24).toFixed(2) + "% 24h"}
                </span>
              ) : (
                <span style={{ color: TXT3 }}>live rate</span>
              )}
            </div>
          </div>
          <div className="osgnews-pcard" style={{ borderColor: CYAN }}>
            <div className="osgnews-plabel" style={{ color: CYAN }}>BTC / USD</div>
            <div className="osgnews-pbig" style={{ color: TXT }}>{btcStr}</div>
            <div className="osgnews-psub"><span style={{ color: TXT3 }}>via CoinGecko</span></div>
          </div>
        </div>

        {/* header */}
        <div className="osgnews-head">MARKET TERMINAL</div>
        <div className="osgnews-subhead">Independent crypto news &amp; data</div>

        {/* source cards */}
        <div className="osgnews-sources">
          {SOURCES.map(function (s, i) {
            return (
              <a
                className="osgnews-src"
                key={i}
                href={s.url}
                target="_blank"
                rel="noreferrer"
                style={{ borderLeftColor: s.accent }}
              >
                <div className="osgnews-srctop">
                  <span className="osgnews-srcname">{s.name}</span>
                  <span className="osgnews-srctag" style={{ color: s.accent, borderColor: s.accent }}>{s.tag}</span>
                </div>
                <Spark data={s.spark} color={s.accent} />
              </a>
            );
          })}
        </div>

        {/* disclaimer */}
        <div className="osgnews-disc">
          Independent third-party sources. OSG does not own or endorse them.
          Prices are factual on-chain / market data, not financial advice. DYOR.
        </div>

        {/* enter */}
        <button className="osgnews-enter" onClick={close}>
          Enter OSG Terminal →
        </button>
      </div>

      <style>{`
        .osgnews-overlay {
          position: fixed; inset: 0; z-index: 9999;
          background: rgba(3,6,10,0.82);
          display: flex; align-items: center; justify-content: center;
          padding: 16px; backdrop-filter: blur(3px);
        }
        .osgnews-modal {
          position: relative; width: 100%; max-width: 440px;
          background: ${BG};
          border: 1px solid ${EDGE};
          border-radius: 16px;
          padding: 18px 18px 20px;
          overflow: hidden;
          box-shadow: 0 20px 60px rgba(0,0,0,0.6);
          color: ${TXT};
          font-family: ui-sans-serif, system-ui, sans-serif;
        }
        .osgnews-grid {
          position: absolute; inset: 0; pointer-events: none; opacity: 0.35;
          background-image:
            linear-gradient(${EDGE} 1px, transparent 1px),
            linear-gradient(90deg, ${EDGE} 1px, transparent 1px);
          background-size: 26px 26px;
          mask-image: radial-gradient(circle at 50% 0%, #000 0%, transparent 70%);
        }
        .osgnews-x {
          position: absolute; top: 8px; left: 50%; transform: translateX(-50%); z-index: 3;
background: #111722; border: 1px solid #1d2733; border-radius: 999px;
color: #e6edf3; font-size: 18px; line-height: 1; cursor: pointer; padding: 6px 14px; font-weight: 700;
        }
        .osgnews-ticker {
          position: relative; z-index: 1;
          display: flex; flex-wrap: wrap; gap: 10px 16px;
          font-size: 12px; padding: 4px 2px 12px;
          border-bottom: 1px solid ${EDGE}; margin-bottom: 14px;
        }
        .osgnews-tick b { font-weight: 700; }
        .osgnews-prices {
          position: relative; z-index: 1;
          display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-bottom: 16px;
        }
        .osgnews-pcard {
          background: ${PANEL}; border: 1px solid ${EDGE};
          border-radius: 10px; padding: 10px 12px;
        }
        .osgnews-plabel { font-size: 11px; letter-spacing: 0.5px; font-weight: 600; }
        .osgnews-pbig { font-size: 19px; font-weight: 800; margin-top: 4px; }
        .osgnews-psub { font-size: 11px; margin-top: 3px; }
        .osgnews-head {
          position: relative; z-index: 1;
          font-size: 15px; font-weight: 800; letter-spacing: 1px; color: ${TXT};
        }
        .osgnews-subhead {
          position: relative; z-index: 1;
          font-size: 12px; color: ${TXT3}; margin: 2px 0 14px;
        }
        .osgnews-sources {
          position: relative; z-index: 1;
          display: flex; flex-direction: column; gap: 8px; margin-bottom: 14px;
        }
        .osgnews-src {
          display: flex; align-items: center; justify-content: space-between;
          background: ${PANEL}; border: 1px solid ${EDGE};
          border-left: 3px solid ${GOLD};
          border-radius: 8px; padding: 10px 12px;
          text-decoration: none; color: ${TXT};
        }
        .osgnews-srctop { display: flex; flex-direction: column; gap: 4px; }
        .osgnews-srcname { font-size: 13px; font-weight: 700; }
        .osgnews-srctag {
          font-size: 9px; font-weight: 700; letter-spacing: 0.5px;
          border: 1px solid; border-radius: 4px; padding: 1px 5px;
          width: fit-content;
        }
        .osgnews-disc {
          position: relative; z-index: 1;
          font-size: 10.5px; line-height: 1.5; color: ${TXT3};
          border-top: 1px solid ${EDGE}; padding-top: 10px; margin-bottom: 14px;
        }
        .osgnews-enter {
          position: relative; z-index: 1;
          width: 100%; padding: 12px; border: none; border-radius: 10px;
          background: linear-gradient(90deg, ${GOLD}, #b8902a);
          color: #1a1206; font-size: 14px; font-weight: 800; cursor: pointer;
          letter-spacing: 0.3px;
        }
      `}</style>
    </div>
  );
}
