import { useState, useEffect } from "react";

/* ══════════════════════════════════════════════════════════
   OSG News Popup — P2P v2 Auto-Match launch announcement
   - Shows once per browser session (sessionStorage)
   - OSG logo passed in as prop
   - Holographic gold / blue / violet premium design
   ══════════════════════════════════════════════════════════ */

const STORAGE_KEY = "osgnews_p2pv2_seen";

const GOLD = "#F7D27A";
const BLUE = "#38BDF8";
const PURPLE = "#A78BFA";
const GREEN = "#46D08A";
const BG = "#07070A";
const TXT = "#F4F4F5";
const TXT2 = "#9A9AA8";
const TXT3 = "#6B6B78";
const EDGE = "rgba(255,255,255,.1)";
const LOGO_FALLBACK = "data:image/jpeg;base64,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";


export default function NewsPopup(props) {
  const [open, setOpen] = useState(false);

  useEffect(function () {
    try {
      var seen = sessionStorage.getItem(STORAGE_KEY);
      if (!seen) setOpen(true);
    } catch (e) {
      setOpen(true);
    }
  }, []);

  function close() {
    setOpen(false);
    try {
      sessionStorage.setItem(STORAGE_KEY, "1");
    } catch (e) {}
  }

  if (!open) return null;

  return (
    <div className="osgnews-overlay" onClick={close}>
      <div
        className="osgnews-frame"
        onClick={function (e) {
          e.stopPropagation();
        }}
      >
        <div className="osgnews-modal">
          <div className="osgnews-mesh">
            <span className="osgnews-blob b1"></span>
            <span className="osgnews-blob b2"></span>
            <span className="osgnews-blob b3"></span>
          </div>

          <button className="osgnews-x" onClick={close}>
            ✕
          </button>

          <div className="osgnews-brand">
            <div className="osgnews-logowrap">
              <span className="osgnews-halo"></span>
              <img className="osgnews-logo" src={props.logo || LOGO_FALLBACK} alt="OSG" />
            </div>
            <div>
              <div className="osgnews-brandname">OSG</div>
              <div className="osgnews-brandsub">ONEX SMART GOLD</div>
            </div>
          </div>

          <div className="osgnews-badgewrap">
            <span className="osgnews-badge">
              <span className="osgnews-dot"></span>JUST LAUNCHED
            </span>
          </div>

          <h1 className="osgnews-head">
            P2P Exchange <span className="osgnews-v2">v2</span> — Auto-Match
            is here!
          </h1>
          <div className="osgnews-rule"></div>
          <p className="osgnews-sub">
            Place an order and it fills instantly at the best price. No more
            waiting to get matched.
          </p>

          <div className="osgnews-feats">
            <div className="osgnews-feat f1">
              <span className="osgnews-ic">⚡</span>
              <span className="osgnews-tt">Instant auto-matching</span>
            </div>
            <div className="osgnews-feat f2">
              <span className="osgnews-ic">✅</span>
              <span className="osgnews-tt">Same low 0.5% fee, on-chain</span>
            </div>
          </div>

          <button className="osgnews-enter" onClick={close}>
            🚀 Try P2P Exchange
          </button>
          <div className="osgnews-disc">
            🛡️ Trading involves risk. Always DYOR.
          </div>
        </div>
      </div>

      <style>{`
        .osgnews-overlay {
          position: fixed; inset: 0; z-index: 9999;
          background: rgba(3,6,10,0.85);
          display: flex; align-items: center; justify-content: center;
          padding: 16px; backdrop-filter: blur(4px);
        }
        .osgnews-frame {
          width: 100%; max-width: 380px; border-radius: 24px; padding: 2px;
          position: relative;
          background: conic-gradient(from 0deg, ${GOLD} 0deg, ${BLUE} 90deg, ${PURPLE} 180deg, ${GREEN} 270deg, ${GOLD} 360deg);
          box-shadow: 0 26px 80px -12px rgba(56,189,248,.25), 0 26px 70px rgba(0,0,0,.7);
        }
        .osgnews-modal {
          position: relative; border-radius: 22px; overflow: hidden;
          background: ${BG}; color: ${TXT};
          padding: 22px 20px 18px;
        }
        .osgnews-mesh { position: absolute; inset: 0; pointer-events: none; overflow: hidden; }
        .osgnews-blob { position: absolute; border-radius: 50%; filter: blur(40px); opacity: .5; }
        .osgnews-blob.b1 { width: 200px; height: 200px; top: -80px; left: -60px; background: radial-gradient(circle, ${GOLD}, transparent 70%); }
        .osgnews-blob.b2 { width: 180px; height: 180px; top: -60px; right: -70px; background: radial-gradient(circle, ${BLUE}, transparent 70%); opacity: .35; }
        .osgnews-blob.b3 { width: 160px; height: 160px; bottom: -80px; left: 40%; background: radial-gradient(circle, ${PURPLE}, transparent 70%); opacity: .28; }
        .osgnews-x {
          position: absolute; top: 12px; right: 12px; z-index: 4;
          width: 28px; height: 28px; border-radius: 50%;
          background: rgba(255,255,255,.08); border: 1px solid ${EDGE};
          color: ${TXT}; font-size: 13px; cursor: pointer;
        }
        .osgnews-brand { position: relative; z-index: 1; display: flex; align-items: center; gap: 10px; margin-top: 2px; }
        .osgnews-logowrap { position: relative; width: 46px; height: 46px; flex: none; }
        .osgnews-halo {
          position: absolute; inset: -8px; border-radius: 50%;
          background: conic-gradient(from 0deg, ${GOLD}, ${BLUE}, ${PURPLE}, ${GOLD});
          filter: blur(7px); opacity: .6; z-index: 0;
        }
        .osgnews-logo { width: 46px; height: 46px; object-fit: contain; position: relative; z-index: 1; border-radius: 50%; background: ${BG}; box-shadow: 0 0 0 3px ${BG}; display: block; }
        .osgnews-brandname {
          font-size: 21px; font-weight: 900; letter-spacing: .5px; line-height: 1;
          background: linear-gradient(120deg, #FCEAB0, ${GOLD} 40%, ${BLUE} 75%, ${PURPLE} 100%);
          -webkit-background-clip: text; background-clip: text; -webkit-text-fill-color: transparent;
        }
        .osgnews-brandsub { font-size: 9.5px; letter-spacing: 2px; color: ${GREEN}; font-weight: 700; margin-top: 3px; }
        .osgnews-badgewrap { position: relative; z-index: 1; margin-top: 16px; }
        .osgnews-badge {
          display: inline-flex; align-items: center; gap: 7px;
          font-size: 11px; font-weight: 800; letter-spacing: .5px; color: ${BG};
          background: linear-gradient(120deg, ${GOLD}, ${BLUE} 90%);
          border-radius: 999px; padding: 6px 13px 6px 9px;
          box-shadow: 0 6px 18px -4px rgba(56,189,248,.5);
        }
        .osgnews-dot { width: 6px; height: 6px; border-radius: 50%; background: ${BG}; animation: osgblink 1.3s ease-in-out infinite; }
        @keyframes osgblink { 0%, 100% { opacity: 1; } 50% { opacity: .25; } }
        .osgnews-head {
          position: relative; z-index: 1;
          font-size: 21px; font-weight: 900; line-height: 1.18; color: ${TXT};
          margin-top: 12px; letter-spacing: -.3px;
        }
        .osgnews-v2 {
          background: linear-gradient(100deg, ${GOLD}, ${BLUE} 60%, ${PURPLE});
          -webkit-background-clip: text; background-clip: text; -webkit-text-fill-color: transparent;
        }
        .osgnews-rule { width: 34px; height: 3px; border-radius: 99px; margin-top: 9px; background: linear-gradient(90deg, ${GOLD}, ${BLUE}); position: relative; z-index: 1; }
        .osgnews-sub { position: relative; z-index: 1; font-size: 12.5px; color: ${TXT2}; line-height: 1.5; margin-top: 9px; }
        .osgnews-feats { position: relative; z-index: 1; margin-top: 14px; display: flex; flex-direction: column; gap: 8px; }
        .osgnews-feat {
          display: flex; align-items: center; gap: 11px;
          background: rgba(255,255,255,.035); border-radius: 12px; padding: 9px 12px;
          border: 1px solid ${EDGE};
        }
        .osgnews-feat.f1 { border-color: rgba(233,185,73,.35); }
        .osgnews-feat.f2 { border-color: rgba(56,189,248,.35); }
        .osgnews-ic {
          flex: none; width: 28px; height: 28px; border-radius: 9px;
          display: flex; align-items: center; justify-content: center; font-size: 13px;
        }
        .osgnews-feat.f1 .osgnews-ic { background: rgba(233,185,73,.16); color: ${GOLD}; }
        .osgnews-feat.f2 .osgnews-ic { background: rgba(56,189,248,.16); color: ${BLUE}; }
        .osgnews-tt { font-size: 12.5px; font-weight: 800; color: ${TXT}; }
        .osgnews-enter {
          position: relative; z-index: 1; margin-top: 16px; width: 100%; border: none; cursor: pointer;
          font-size: 14.5px; font-weight: 800; color: ${BG};
          background: linear-gradient(100deg, ${GOLD} 0%, ${BLUE} 55%, ${PURPLE} 100%);
          border-radius: 13px; padding: 13px;
          box-shadow: 0 14px 30px -8px rgba(56,189,248,.45), inset 0 1px 0 rgba(255,255,255,.5);
        }
        .osgnews-disc { position: relative; z-index: 1; text-align: center; font-size: 9.5px; color: ${TXT3}; margin-top: 10px; }
      `}</style>
    </div>
  );
}
