import { useState, useEffect } from "react";

// ──────────────────────────────────────────────
//  OSG News Popup — branded, news sources only (compact)
//  - Shows once per browser session (sessionStorage)
//  - OSG logo header (logo passed in as prop)
//  - 3 independent crypto news/data sources (new tab)
//  BUDS-safe: factual, no price/return/moon language, DYOR.
// ──────────────────────────────────────────────

var GOLD = "#d4af37";
var BG = "#0a0e14";
var PANEL = "#111722";
var EDGE = "#1d2733";
var TXT = "#e6edf3";
var TXT3 = "#7d8896";
var GREEN = "#3fb950";
var CYAN = "#39d0d8";

var SOURCES = [
  {
    name: "CoinDesk",
    tag: "NEWS",
    desc: "Breaking crypto headlines & analysis",
    url: "https://www.coindesk.com",
    accent: CYAN,
  },
  {
    name: "Cointelegraph",
    tag: "MARKETS",
    desc: "Market coverage & industry updates",
    url: "https://cointelegraph.com",
    accent: GREEN,
  },
  {
    name: "CoinGecko",
    tag: "DATA",
    desc: "Prices, charts & on-chain data",
    url: "https://www.coingecko.com",
    accent: GOLD,
  },
];

export default function NewsPopup(props) {
  var logo = props.logo;
  var [open, setOpen] = useState(false);

  // show once per session
  useEffect(function () {
    var seen = null;
    try {
      seen = sessionStorage.getItem("osg_news_seen");
    } catch (e) {}
    if (!seen) setOpen(true);
  }, []);

  function close() {
    try {
      sessionStorage.setItem("osg_news_seen", "1");
    } catch (e) {}
    setOpen(false);
  }

  if (!open) return null;

  return (
    <div className="osgnews-overlay" onClick={close}>
      <div className="osgnews-modal" onClick={function (e) { e.stopPropagation(); }}>
        <div className="osgnews-grid" />
        <div className="osgnews-glow" />

        <button className="osgnews-x" onClick={close}>✕</button>

        {/* brand header */}
        <div className="osgnews-brand">
          <div className="osgnews-logowrap">
            {logo ? <img className="osgnews-logo" src={logo} alt="OSG" /> : null}
          </div>
          <div className="osgnews-brandname">OSG</div>
          <div className="osgnews-brandsub">ONEX SMART GOLD</div>
        </div>

        {/* section title */}
        <div className="osgnews-head">Market News</div>
        <div className="osgnews-subhead">
          Stay informed with trusted, independent crypto sources.
        </div>

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
                <div className="osgnews-srcmain">
                  <div className="osgnews-srctop">
                    <span className="osgnews-srcname">{s.name}</span>
                    <span
                      className="osgnews-srctag"
                      style={{ color: s.accent, borderColor: s.accent }}
                    >
                      {s.tag}
                    </span>
                  </div>
                  <div className="osgnews-srcdesc">{s.desc}</div>
                </div>
                <span className="osgnews-arrow" style={{ color: s.accent }}>↗️</span>
              </a>
            );
          })}
        </div>

        {/* disclaimer */}
        <div className="osgnews-disc">
          These are independent third-party sources. OSG does not own or endorse
          them, and their content is not financial advice. Always do your own
          research (DYOR).
        </div>

        {/* enter */}
        <button className="osgnews-enter" onClick={close}>
          Enter OSG →
        </button>
      </div>

      <style>{`
        .osgnews-overlay {
          position: fixed; inset: 0; z-index: 9999;
          background: rgba(3,6,10,0.85);
          display: flex; align-items: center; justify-content: center;
          padding: 14px; backdrop-filter: blur(4px);
        }
        .osgnews-modal {
          position: relative; width: 100%; max-width: 400px;
          background: ${BG};
          border: 1px solid ${EDGE};
          border-radius: 18px;
          padding: 22px 16px 16px;
          overflow: hidden;
          box-shadow: 0 24px 70px rgba(0,0,0,0.65);
          color: ${TXT};
          font-family: ui-sans-serif, system-ui, sans-serif;
        }
        .osgnews-grid {
          position: absolute; inset: 0; pointer-events: none; opacity: 0.28;
          background-image:
            linear-gradient(${EDGE} 1px, transparent 1px),
            linear-gradient(90deg, ${EDGE} 1px, transparent 1px);
          background-size: 28px 28px;
          mask-image: radial-gradient(circle at 50% 0%, #000 0%, transparent 70%);
        }
        .osgnews-glow {
          position: absolute; top: -60px; left: 50%; transform: translateX(-50%);
          width: 190px; height: 190px; pointer-events: none;
          background: radial-gradient(circle, rgba(212,175,55,0.28) 0%, transparent 65%);
        }
        .osgnews-x {
          position: absolute; top: 10px; left: 50%; transform: translateX(-50%);
          z-index: 4;
          background: ${PANEL}; border: 1px solid ${EDGE}; border-radius: 999px;
          color: ${TXT}; font-size: 15px; line-height: 1;
          cursor: pointer; padding: 5px 12px; font-weight: 700;
        }
        .osgnews-brand {
          position: relative; z-index: 1;
          display: flex; flex-direction: column; align-items: center;
          text-align: center; margin: 8px 0 14px;
        }
        .osgnews-logowrap {
          width: 74px; height: 74px; border-radius: 18px;
          display: flex; align-items: center; justify-content: center;
          background: radial-gradient(circle, rgba(212,175,55,0.15), transparent 70%);
          box-shadow: 0 0 28px rgba(212,175,55,0.32);
          margin-bottom: 8px;
        }
        .osgnews-logo {
          width: 66px; height: 66px; object-fit: contain;
          border-radius: 15px;
        }
        .osgnews-brandname {
          font-size: 22px; font-weight: 900; letter-spacing: 3px; color: ${GOLD};
          line-height: 1;
        }
        .osgnews-brandsub {
          font-size: 10px; font-weight: 700; letter-spacing: 2.5px;
          color: ${GREEN}; margin-top: 5px;
        }
        .osgnews-head {
          position: relative; z-index: 1;
          font-size: 18px; font-weight: 800; color: ${TXT}; margin-bottom: 3px;
        }
        .osgnews-subhead {
          position: relative; z-index: 1;
          font-size: 12px; color: ${TXT3}; margin-bottom: 14px; line-height: 1.45;
        }
        .osgnews-sources {
          position: relative; z-index: 1;
          display: flex; flex-direction: column; gap: 8px; margin-bottom: 14px;
        }
        .osgnews-src {
          display: flex; align-items: center; justify-content: space-between;
          gap: 10px;
          background: ${PANEL}; border: 1px solid ${EDGE};
          border-left: 3px solid ${GOLD};
          border-radius: 11px; padding: 11px 13px;
          text-decoration: none; color: ${TXT};
          transition: transform 0.12s ease;
        }
        .osgnews-src:hover { transform: translateY(-2px); }
        .osgnews-srcmain { display: flex; flex-direction: column; gap: 4px; }
        .osgnews-srctop { display: flex; align-items: center; gap: 8px; }
        .osgnews-srcname { font-size: 14.5px; font-weight: 800; }
        .osgnews-srctag {
          font-size: 8.5px; font-weight: 800; letter-spacing: 0.6px;
          border: 1px solid; border-radius: 5px; padding: 2px 6px;
        }
        .osgnews-srcdesc { font-size: 11px; color: ${TXT3}; }
        .osgnews-arrow { font-size: 19px; font-weight: 700; }
        .osgnews-disc {
          position: relative; z-index: 1;
          font-size: 10px; line-height: 1.5; color: ${TXT3};
          border-top: 1px solid ${EDGE}; padding-top: 10px; margin-bottom: 12px;
        }
        .osgnews-enter {
          position: relative; z-index: 1;
          width: 100%; padding: 12px; border: none; border-radius: 11px;
          background: linear-gradient(90deg, ${GOLD}, #b8902a);
          color: #1a1206; font-size: 14px; font-weight: 800; cursor: pointer;
          letter-spacing: 0.4px;
        }
      `}</style>
    </div>
  );
}
