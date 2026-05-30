import { useState, useEffect, useCallback, useRef } from "react";
import { BrowserProvider, Contract, formatUnits, parseUnits, isAddress } from "ethers";
import {
  ADDRESSES, ZERO, POLYGON_CHAIN_ID, POLYGON_PARAMS,
  TOKEN_ABI, STAKING_ABI, QUICKSWAP_URL,
} from "./contracts.js";

// ── theme ────────────────────────────────────────────────
const gold = "#F5B800", goldDark = "#C9930A";
const bg = "#0B0F1A", bgDeep = "#070A12", card = "#141A28", cardSoft = "#10151F", border = "#212a3d";

const short = (a) => (a ? `${a.slice(0,6)}...${a.slice(-4)}` : "");
const fmt = (v, d = 2) =>
  Number(v).toLocaleString("en-IN", { maximumFractionDigits: d });
const f18 = (bn) => { try { return formatUnits(bn ?? 0n, 18); } catch { return "0"; } };

const styles = `
  @import url('https://fonts.googleapis.com/css2?family=Sora:wght@400;500;600;700;800&family=Plus+Jakarta+Sans:wght@400;500;600;700&family=Space+Mono:wght@400;700&display=swap');
  * { box-sizing:border-box; margin:0; padding:0; }
  body { background:${bg}; color:#cdd5e3; font-family:'Plus Jakarta Sans',sans-serif; min-height:100vh; }
  ::-webkit-scrollbar { width:4px; } ::-webkit-scrollbar-thumb { background:${gold}44; border-radius:2px; }
  a { color:${gold}; }
  .btn-gold { background:linear-gradient(135deg,${gold},${goldDark}); color:#0B0F1A; font-family:'Sora',sans-serif; font-weight:700; font-size:14px; letter-spacing:.5px; border:none; border-radius:8px; padding:12px 24px; cursor:pointer; transition:all .2s; box-shadow:0 4px 16px ${gold}22; }
  .btn-gold:hover { filter:brightness(1.1); transform:translateY(-1px); box-shadow:0 6px 20px ${gold}33; }
  .btn-gold:disabled { opacity:.45; cursor:not-allowed; transform:none; filter:none; box-shadow:none; }
  .btn-danger { background:transparent; color:#ff6b6b; font-family:'Sora',sans-serif; font-weight:700; font-size:14px; border:1px solid #ff6b6b55; border-radius:8px; padding:11px 20px; cursor:pointer; transition:all .2s; }
  .btn-danger:hover { border-color:#ff6b6b; background:#ff6b6b11; }
  .btn-danger:disabled { opacity:.4; cursor:not-allowed; }
  .btn-ghost { background:transparent; color:#7b8699; border:1px solid ${border}; border-radius:8px; padding:11px 20px; cursor:pointer; font-family:'Sora',sans-serif; font-weight:600; font-size:14px; transition:all .2s; }
  .btn-ghost:hover { border-color:${gold}66; color:${gold}; }
  .btn-ghost:disabled { opacity:.4; cursor:not-allowed; }
  .inp { background:${bgDeep}; border:1px solid ${border}; border-radius:8px; color:#fff; font-family:'Space Mono',monospace; font-size:14px; padding:12px 14px; width:100%; outline:none; transition:border-color .2s; }
  .inp:focus { border-color:${gold}88; }
  .inp::placeholder { color:#3a4458; }
  .tab-nav { display:flex; gap:3px; background:${cardSoft}; border-radius:10px; padding:4px; border:1px solid ${border}; }
  .tab-btn { flex:1; padding:10px 4px; font-family:'Sora',sans-serif; font-weight:600; font-size:12px; letter-spacing:.2px; border:none; border-radius:7px; cursor:pointer; transition:all .2s; background:transparent; color:#5a657a; }
  .tab-btn.active { background:${gold}1a; color:${gold}; border:1px solid ${gold}44; }
  .tab-btn:hover:not(.active){ color:#8a96ab; }
  .stat-card { background:${card}; border:1px solid ${border}; border-radius:12px; padding:15px; position:relative; overflow:hidden; }
  .level-row { display:flex; align-items:center; gap:10px; padding:9px 0; border-bottom:1px solid ${border}; }
  .level-row:last-child { border-bottom:none; }
  .toast { position:fixed; bottom:24px; left:50%; transform:translateX(-50%); background:${card}; border:1px solid ${gold}66; border-radius:10px; padding:13px 24px; font-size:14px; color:${gold}; z-index:9999; animation:su .3s ease; font-family:'Sora',sans-serif; font-weight:600; max-width:90%; text-align:center; box-shadow:0 8px 30px #0006; }
  @keyframes su { from{transform:translate(-50%,20px);opacity:0} to{transform:translate(-50%,0);opacity:1} }
  .spin { display:inline-block; width:14px; height:14px; border:2px solid #0003; border-top-color:#0B0F1A; border-radius:50%; animation:sp .7s linear infinite; vertical-align:middle; }
  @keyframes sp { to{transform:rotate(360deg)} }
  .msg-container { position:relative; overflow:hidden; border-radius:16px; min-height:420px; background:${bgDeep}; border:1px solid ${gold}22; }
  .msg-grid { position:absolute; inset:0; background-image:linear-gradient(${gold}08 1px,transparent 1px),linear-gradient(90deg,${gold}08 1px,transparent 1px); background-size:40px 40px; animation:gm 20s linear infinite; }
  @keyframes gm { 0%{background-position:0 0} 100%{background-position:40px 40px} }
  .cs-badge { display:inline-flex; align-items:center; gap:6px; background:linear-gradient(135deg,${gold}22,${gold}0a); border:1px solid ${gold}55; border-radius:20px; padding:6px 16px; font-size:11px; font-weight:700; color:${gold}; letter-spacing:1.5px; }
  .feat-pill { display:inline-flex; align-items:center; gap:6px; background:${gold}0d; border:1px solid ${gold}22; border-radius:20px; padding:7px 14px; font-size:12px; color:#8a96ab; font-family:'Plus Jakarta Sans',sans-serif; font-weight:600; }
  .link-row:hover { color:${gold} !important; }
`;

// ── small UI bits ─────────────────────────────────────────
function StatCard({ label, value, sub, accent }) {
  return (
    <div className="stat-card" style={{ borderColor: accent ? `${accent}33` : border }}>
      <div style={{ position:"absolute", top:0, left:0, right:0, height:2, background:`linear-gradient(90deg,${accent||gold},transparent)` }}/>
      <div style={{ fontSize:10, color:"#5a657a", letterSpacing:1, textTransform:"uppercase", marginBottom:6, fontFamily:"'Space Mono',monospace" }}>{label}</div>
      <div style={{ fontSize:23, fontWeight:700, color:accent||gold, lineHeight:1, wordBreak:"break-all", fontFamily:"'Sora',sans-serif" }}>{value}</div>
      {sub && <div style={{ fontSize:11, color:"#5a657a", marginTop:4 }}>{sub}</div>}
    </div>
  );
}

function Header({ wallet, network, onConnect, onSwitch, connecting }) {
  return (
    <div style={{ display:"flex", alignItems:"center", justifyContent:"space-between", padding:"14px 20px", borderBottom:`1px solid ${border}`, background:bgDeep, position:"sticky", top:0, zIndex:100, flexWrap:"wrap", gap:10 }}>
      <div style={{ display:"flex", alignItems:"center", gap:12 }}>
        <div style={{ width:34, height:34, borderRadius:8, background:`linear-gradient(135deg,${gold},${goldDark})`, display:"flex", alignItems:"center", justifyContent:"center", fontWeight:800, fontSize:16, color:"#0B0F1A" }}>X</div>
        <div>
          <div style={{ fontSize:17, fontWeight:700, color:gold, letterSpacing:.5, fontFamily:"'Sora',sans-serif" }}>OSG DApp</div>
          <div style={{ fontSize:10, color:"#4a5468", fontFamily:"'Space Mono',monospace" }}>OneX Smart Gold</div>
        </div>
      </div>
      <div style={{ display:"flex", alignItems:"center", gap:10 }}>
        {wallet && (network
          ? <span style={{ background:"#00c85315", border:"1px solid #00c85333", color:"#00c853", padding:"4px 10px", borderRadius:12, fontSize:11, fontWeight:700 }}>⬡ Polygon</span>
          : <button onClick={onSwitch} style={{ background:"#ff550015", border:"1px solid #ff550055", color:"#ff7777", padding:"4px 10px", borderRadius:12, fontSize:11, fontWeight:700, cursor:"pointer" }}>⚠ Switch Network</button>
        )}
        {wallet
          ? <div style={{ display:"flex", alignItems:"center", gap:8, background:card, border:`1px solid ${gold}33`, borderRadius:8, padding:"6px 12px" }}>
              <div style={{ width:7, height:7, borderRadius:"50%", background:network?"#00c853":"#ff5555" }}/>
              <span style={{ fontFamily:"'Space Mono',monospace", fontSize:12, color:"#aeb8c9" }}>{short(wallet)}</span>
            </div>
          : <button className="btn-gold" onClick={onConnect} disabled={connecting} style={{ padding:"9px 18px", fontSize:13 }}>{connecting ? <span className="spin"/> : "Connect Wallet"}</button>
        }
      </div>
    </div>
  );
}

// ── Dashboard ─────────────────────────────────────────────
function Dashboard({ data, wallet }) {
  const links = [
    ["OSG Token", ADDRESSES.token],
    ["Staking", ADDRESSES.staking],
    ["Referral", ADDRESSES.referral],
    ["Reward Pool", ADDRESSES.pool],
  ];
  return (
    <div style={{ display:"flex", flexDirection:"column", gap:14 }}>
      <div style={{ display:"grid", gridTemplateColumns:"1fr 1fr", gap:10 }}>
        <StatCard label="OSG Balance" value={wallet ? fmt(data.balance) : "—"} sub="OneX Smart Gold" accent={gold}/>
        <StatCard label="Your Staked" value={wallet ? fmt(data.staked) : "—"} sub="Currently locked" accent="#00b4ff"/>
        <StatCard label="Pending Reward" value={wallet ? fmt(data.pending, 4) : "—"} sub="Claimable" accent="#00c853"/>
        <StatCard label="Pool Total Staked" value={fmt(data.totalStaked)} sub="All users" accent="#7B3FE4"/>
      </div>

      <div style={{ background:card, border:`1px solid ${border}`, borderRadius:12, padding:14 }}>
        <div style={{ fontSize:11, color:"#5a657a", textTransform:"uppercase", letterSpacing:1, marginBottom:12, fontFamily:"'Sora',sans-serif", fontWeight:600 }}>Pool &amp; Emission</div>
        <div style={{ display:"grid", gridTemplateColumns:"1fr 1fr", gap:10 }}>
          {[
            ["Active Stakers", fmt(data.activeStakers, 0)],
            ["Daily Emission", fmt(data.dailyEmission, 2) + " OSG"],
            ["Your Total Earned", fmt(data.totalEarned, 4) + " OSG"],
            ["Your Share", fmt(data.sharePercent, 4) + " %"],
            ["Halving #", fmt(data.halving, 0)],
            ["Reward Distributed", fmt(data.rewardDistributed, 2) + " OSG"],
          ].map(([k,v]) => (
            <div key={k} style={{ background:cardSoft, border:`1px solid ${border}`, borderRadius:8, padding:"10px 12px" }}>
              <div style={{ fontSize:10, color:"#5a657a", textTransform:"uppercase", letterSpacing:.5 }}>{k}</div>
              <div style={{ fontSize:15, fontWeight:700, color:"#cdd5e3", marginTop:3, fontFamily:"'Sora',sans-serif" }}>{v}</div>
            </div>
          ))}
        </div>
      </div>

      <div style={{ background:card, border:`1px solid ${border}`, borderRadius:12, padding:14 }}>
        <div style={{ fontSize:11, color:"#5a657a", textTransform:"uppercase", letterSpacing:1, marginBottom:10, fontFamily:"'Sora',sans-serif", fontWeight:600 }}>Verified Contracts (Polygonscan)</div>
        {links.map(([n,a]) => (
          <a key={n} className="link-row" href={`https://polygonscan.com/address/${a}`} target="_blank" rel="noreferrer"
             style={{ display:"flex", justifyContent:"space-between", padding:"8px 0", borderBottom:`1px solid ${border}`, textDecoration:"none", color:"inherit" }}>
            <span style={{ fontSize:13, color:"#7b8699" }}>{n}</span>
            <span style={{ fontFamily:"'Space Mono',monospace", fontSize:10, color:"#5a657a" }}>{short(a)} ↗</span>
          </a>
        ))}
      </div>
    </div>
  );
}

// ── Staking ───────────────────────────────────────────────
function Staking({ wallet, data, refParam, actions, busy }) {
  const [tab, setTab] = useState("stake");
  const [amount, setAmount] = useState("");
  const [refInput, setRefInput] = useState("");

  useEffect(() => { if (refParam && isAddress(refParam)) setRefInput(refParam); }, [refParam]);

  const info = data.stakingInfo;
  const hasStake = Number(data.staked) > 0;

  return (
    <div style={{ display:"flex", flexDirection:"column", gap:14 }}>
      <div className="tab-nav">
        {["stake","unstake","claim"].map(t => (
          <button key={t} className={`tab-btn ${tab===t?"active":""}`} onClick={()=>setTab(t)}>
            {t==="stake"?"⬆ Stake":t==="unstake"?"⬇ Unstake":"💰 Claim"}
          </button>
        ))}
      </div>

      {tab==="stake" && (
        <div style={{ background:card, border:`1px solid ${border}`, borderRadius:12, padding:16 }}>
          <div style={{ display:"flex", justifyContent:"space-between", marginBottom:8 }}>
            <span style={{ fontSize:13, color:"#7b8699" }}>Amount to Stake</span>
            <span style={{ fontSize:11, color:"#5a657a" }}>Balance: {fmt(data.balance)} OSG</span>
          </div>
          <div style={{ position:"relative" }}>
            <input className="inp" placeholder="0.00" value={amount} inputMode="decimal"
              onChange={e=>setAmount(e.target.value.replace(/[^0-9.]/g,""))} style={{ paddingRight:60 }}/>
            <button onClick={()=>setAmount(String(data.balance).replace(/,/g,""))}
              style={{ position:"absolute", right:8, top:"50%", transform:"translateY(-50%)", background:`${gold}18`, border:`1px solid ${gold}33`, color:gold, borderRadius:4, padding:"2px 7px", fontSize:10, cursor:"pointer", fontWeight:700 }}>MAX</button>
          </div>

          {!hasStake && (
            <div style={{ marginTop:12 }}>
              <div style={{ fontSize:12, color:"#7b8699", marginBottom:6 }}>Referrer (optional — first stake only)</div>
              <input className="inp" placeholder="0x... referrer address" value={refInput}
                onChange={e=>setRefInput(e.target.value.trim())} style={{ fontSize:11 }}/>
            </div>
          )}

          <div style={{ background:cardSoft, borderRadius:8, padding:"11px 13px", margin:"12px 0", fontSize:12, color:"#8a96ab", lineHeight:1.5 }}>
            ⓘ Staking has two steps: first <b style={{color:gold}}>Approve</b> the token, then <b style={{color:gold}}>Stake</b>. Rewards are earned daily from emissions.
          </div>

          <button className="btn-gold" style={{ width:"100%" }} disabled={busy.stake || !wallet}
            onClick={()=>actions.stake(amount, hasStake ? null : refInput)}>
            {busy.stake ? <span className="spin"/> : hasStake ? `Add ${amount||"0"} OSG to Stake` : `Stake ${amount||"0"} OSG`}
          </button>
        </div>
      )}

      {tab==="unstake" && (
        <div style={{ background:card, border:`1px solid ${border}`, borderRadius:12, padding:16 }}>
          <div style={{ fontSize:12, color:"#7b8699", marginBottom:6 }}>Currently Staked</div>
          <div style={{ fontSize:34, fontWeight:800, color:gold, marginBottom:14, fontFamily:"'Sora',sans-serif" }}>{fmt(data.staked)} <span style={{fontSize:15,color:"#5a657a"}}>OSG</span></div>

          {!info.unstakePending ? (
            <>
              <div style={{ background:cardSoft, borderRadius:8, padding:12, fontSize:12, color:"#8a96ab", marginBottom:14, lineHeight:1.5 }}>
                To unstake, first send a <b style={{color:gold}}>Request</b> → tokens become withdrawable after the cooldown.
              </div>
              <button className="btn-danger" style={{ width:"100%" }} disabled={busy.unstake || !hasStake}
                onClick={actions.requestUnstake}>{busy.unstake ? <span className="spin"/> : "Request Unstake"}</button>
            </>
          ) : (
            <>
              <div style={{ background: info.canUnstakeNow ? "#00c85311" : "#ff550011", border:`1px solid ${info.canUnstakeNow?"#00c85333":"#ff550033"}`, borderRadius:8, padding:12, fontSize:13, color: info.canUnstakeNow?"#00c853":"#ff8888", marginBottom:14 }}>
                {info.canUnstakeNow ? "✅ Cooldown complete — you can withdraw now!" : "⏳ Cooldown in progress — please wait a little longer."}
              </div>
              <div style={{ display:"flex", gap:8 }}>
                <button className="btn-gold" style={{ flex:1 }} disabled={busy.unstake || !info.canUnstakeNow}
                  onClick={actions.unstake}>{busy.unstake ? <span className="spin"/> : "Withdraw Now"}</button>
                <button className="btn-ghost" disabled={busy.cancel} onClick={actions.cancelUnstake}>
                  {busy.cancel ? <span className="spin"/> : "Cancel"}</button>
              </div>
            </>
          )}
        </div>
      )}

      {tab==="claim" && (
        <div style={{ background:card, border:`1px solid ${border}`, borderRadius:12, padding:20, textAlign:"center" }}>
          <div style={{ fontSize:11, color:"#5a657a", textTransform:"uppercase", letterSpacing:1, marginBottom:8, fontFamily:"'Sora',sans-serif", fontWeight:600 }}>Claimable Reward</div>
          <div style={{ fontSize:42, fontWeight:800, color:"#00c853", lineHeight:1, fontFamily:"'Sora',sans-serif" }}>{fmt(data.claim.amount, 4)}</div>
          <div style={{ fontSize:14, color:"#5a657a", marginTop:4, marginBottom:8 }}>OSG (this chunk)</div>
          <div style={{ fontSize:12, color:"#7b8699", marginBottom:16 }}>Total pending: {fmt(data.pending, 4)} OSG</div>
          {!data.claim.canClaim && data.claim.reason && (
            <div style={{ background:"#ff550011", border:"1px solid #ff550033", borderRadius:8, padding:10, fontSize:12, color:"#ff8888", marginBottom:14 }}>
              ⓘ {data.claim.reason}
            </div>
          )}
          <button className="btn-gold" style={{ width:"100%" }} disabled={busy.claim || !data.claim.canClaim}
            onClick={actions.claim}>{busy.claim ? <span className="spin"/> : "Claim Reward"}</button>
        </div>
      )}
    </div>
  );
}

// ── Referral ──────────────────────────────────────────────
function Referral({ wallet, data, showToast }) {
  const origin = typeof window !== "undefined" ? window.location.origin : "";
  const refLink = wallet ? `${origin}/?ref=${wallet}` : "Connect wallet to generate your link";
  const [copied, setCopied] = useState(false);

  const copy = async () => {
    if (!wallet) { showToast("⚠️ Connect wallet first!"); return; }
    try { await navigator.clipboard.writeText(refLink); } catch {}
    setCopied(true); showToast("🔗 Referral link copied!");
    setTimeout(()=>setCopied(false), 1800);
  };

  const r = data.referralInfo;
  const chain = data.referralChain;
  const chainLabels = ["L1","L2","L3","L4","L5"];
  const chainColors = [gold,"#C0C0C0","#CD7F32","#00c853","#00b4ff"];

  return (
    <div style={{ display:"flex", flexDirection:"column", gap:14 }}>
      <div style={{ display:"grid", gridTemplateColumns:"1fr 1fr", gap:10 }}>
        <StatCard label="Referral Earned" value={`${fmt(r.totalReferralEarned,4)}`} sub="OSG total" accent={gold}/>
        <StatCard label="Total Referrals" value={fmt(r.totalReferrals,0)} sub="Direct + team" accent="#00c853"/>
        <StatCard label="Pending Referral" value={`${fmt(r.pendingReferral,4)}`} sub="OSG" accent="#00b4ff"/>
        <StatCard label="Team Bonus" value={`${fmt(r.teamBonusEarned,4)}`} sub="OSG" accent="#7B3FE4"/>
      </div>

      <div style={{ background:card, border:`1px solid ${gold}22`, borderRadius:12, padding:14 }}>
        <div style={{ fontSize:11, color:"#5a657a", textTransform:"uppercase", letterSpacing:1, marginBottom:10, fontFamily:"'Sora',sans-serif", fontWeight:600 }}>Your Referral Link</div>
        <div style={{ display:"flex", gap:8 }}>
          <div style={{ flex:1, background:cardSoft, border:`1px solid ${border}`, borderRadius:6, padding:"9px 12px", fontFamily:"'Space Mono',monospace", fontSize:10, color:"#7b8699", overflow:"hidden", textOverflow:"ellipsis", whiteSpace:"nowrap" }}>{refLink}</div>
          <button className="btn-gold" onClick={copy} style={{ padding:"8px 14px", fontSize:12, whiteSpace:"nowrap" }}>{copied?"✓":"🔗"} Copy</button>
        </div>
        <div style={{ fontSize:11, color:"#5a657a", marginTop:8, lineHeight:1.5 }}>Share this link — whoever stakes for the first time using it becomes your referral.</div>
      </div>

      <div style={{ background:card, border:`1px solid ${border}`, borderRadius:12, padding:14 }}>
        <div style={{ fontSize:11, color:"#5a657a", textTransform:"uppercase", letterSpacing:1, marginBottom:10, fontFamily:"'Sora',sans-serif", fontWeight:600 }}>Your Upline (5 Levels)</div>
        {chain.map((addr,i) => (
          <div key={i} className="level-row">
            <div style={{ width:26, height:26, borderRadius:6, background:`${chainColors[i]}18`, border:`1px solid ${chainColors[i]}33`, display:"flex", alignItems:"center", justifyContent:"center", fontSize:10, fontWeight:700, color:chainColors[i] }}>{chainLabels[i]}</div>
            <span style={{ flex:1, fontFamily:"'Space Mono',monospace", fontSize:12, color: addr && addr!==ZERO ? "#aeb8c9" : "#3a4458" }}>
              {addr && addr!==ZERO ? short(addr) : "— empty —"}
            </span>
          </div>
        ))}
      </div>

      <div style={{ background:card, border:`1px solid ${border}`, borderRadius:12, padding:14 }}>
        <div style={{ fontSize:11, color:"#5a657a", textTransform:"uppercase", letterSpacing:1, marginBottom:8, fontFamily:"'Sora',sans-serif", fontWeight:600 }}>Your Referrer</div>
        <div style={{ fontFamily:"'Space Mono',monospace", fontSize:13, color: r.referrer && r.referrer!==ZERO ? gold : "#5a657a" }}>
          {r.referrer && r.referrer!==ZERO ? short(r.referrer) : "No referrer set"}
        </div>
      </div>
    </div>
  );
}

// ── Swap (external until pool exists) ─────────────────────
function Swap() {
  return (
    <div style={{ background:card, border:`1px solid ${gold}18`, borderRadius:12, padding:20, textAlign:"center" }}>
      <div style={{ fontSize:40, marginBottom:10 }}>🔄</div>
      <div style={{ fontSize:18, fontWeight:700, color:gold, marginBottom:8, fontFamily:"'Sora',sans-serif" }}>Swap MATIC → OSG</div>
      <div style={{ fontSize:13, color:"#8a96ab", marginBottom:6, lineHeight:1.5 }}>
        The liquidity pool is not live yet. Once the pool is added, in-app swap will be available right here.
      </div>
      <div style={{ fontSize:12, color:"#7b8699", marginBottom:18 }}>
        In the meantime, you can swap directly on QuickSwap ↓
      </div>
      <a href={QUICKSWAP_URL} target="_blank" rel="noreferrer">
        <button className="btn-gold" style={{ width:"100%" }}>Open QuickSwap ↗</button>
      </a>
      <div style={{ fontSize:11, color:"#5a657a", marginTop:12, fontFamily:"'Space Mono',monospace" }}>
        OSG: {short(ADDRESSES.token)}
      </div>
    </div>
  );
}

// ── Messenger (coming soon) ───────────────────────────────
function Messenger() {
  const [d,setD]=useState(31),[h,setH]=useState(14),[m,setM]=useState(37),[s,setS]=useState(42);
  useEffect(()=>{ const t=setInterval(()=>{ setS(x=>{ if(x>0)return x-1; setM(y=>{ if(y>0)return y-1; setH(z=>{ if(z>0)return z-1; setD(w=>w>0?w-1:0); return 23; }); return 59; }); return 59; }); },1000); return ()=>clearInterval(t); },[]);
  const pad=n=>String(n).padStart(2,"0");
  const feats=[["🔐","AES-256 Encrypted"],["🌐","IPFS Storage"],["👛","Wallet-to-Wallet"],["👥","Group Chats"],["📸","Photo & Video"],["⛓️","On-Chain Hash"]];
  return (
    <div style={{ display:"flex", flexDirection:"column", gap:16 }}>
      <div className="msg-container">
        <div className="msg-grid"/>
        <div style={{ position:"relative", zIndex:2, display:"flex", flexDirection:"column", alignItems:"center", justifyContent:"center", minHeight:420, padding:24, textAlign:"center" }}>
          <div className="cs-badge" style={{ marginBottom:18 }}>● Coming Soon</div>
          <div style={{ fontSize:48, marginBottom:10 }}>💬</div>
          <div style={{ fontSize:26, fontWeight:800, color:gold, letterSpacing:2, marginBottom:6, fontFamily:"'Sora',sans-serif" }}>OSG MESSENGER</div>
          <div style={{ fontSize:12, color:"#7b8699", letterSpacing:1, marginBottom:18, fontFamily:"'Space Mono',monospace" }}>AES-256 · X25519 · IPFS · Polygon</div>
          <div style={{ display:"grid", gridTemplateColumns:"repeat(4,1fr)", gap:8, marginBottom:20, width:"100%", maxWidth:320 }}>
            {[["Days",d],["Hrs",h],["Min",m],["Sec",s]].map(([l,v])=>(
              <div key={l} style={{ background:cardSoft, border:`1px solid ${gold}22`, borderRadius:10, padding:"12px 6px" }}>
                <div style={{ fontSize:26, fontWeight:800, color:gold, fontFamily:"'Space Mono',monospace" }}>{pad(v)}</div>
                <div style={{ fontSize:9, color:"#5a657a", marginTop:4, textTransform:"uppercase", letterSpacing:1 }}>{l}</div>
              </div>
            ))}
          </div>
          <div style={{ display:"flex", flexWrap:"wrap", gap:6, justifyContent:"center" }}>
            {feats.map(([i,l])=> <div key={l} className="feat-pill">{i} {l}</div>)}
          </div>
          <div style={{ fontSize:12, color:"#5a657a", marginTop:20 }}>Target launch: Q3 2026</div>
        </div>
      </div>
    </div>
  );
}

// ── Main App ──────────────────────────────────────────────
const EMPTY = {
  balance:"0", staked:"0", pending:"0", totalStaked:"0",
  activeStakers:"0", dailyEmission:"0", totalEarned:"0", sharePercent:"0",
  halving:"0", rewardDistributed:"0",
  stakingInfo:{ unstakePending:false, canUnstakeNow:false },
  referralInfo:{ referrer:ZERO, totalReferrals:"0", totalReferralEarned:"0", pendingReferral:"0", teamBonusEarned:"0", totalTeamVolume:"0" },
  referralChain:[ZERO,ZERO,ZERO,ZERO,ZERO],
  claim:{ canClaim:false, amount:"0", total:"0", reason:"" },
};

export default function App() {
  const [tab, setTab] = useState("dashboard");
  const [wallet, setWallet] = useState(null);
  const [network, setNetwork] = useState(false);
  const [toast, setToast] = useState(null);
  const [connecting, setConnecting] = useState(false);
  const [data, setData] = useState(EMPTY);
  const [busy, setBusy] = useState({});
  const [refParam, setRefParam] = useState(null);
  const providerRef = useRef(null);

  const showToast = useCallback((msg) => { setToast(msg); setTimeout(()=>setToast(null), 3000); }, []);
  const setBusyKey = (k,v) => setBusy(b => ({ ...b, [k]:v }));

  // read ?ref= from URL
  useEffect(() => {
    try { const p = new URLSearchParams(window.location.search).get("ref"); if (p && isAddress(p)) setRefParam(p); } catch {}
  }, []);

  const getProvider = () => {
    if (!window.ethereum) { showToast("⚠️ Please install MetaMask!"); return null; }
    if (!providerRef.current) providerRef.current = new BrowserProvider(window.ethereum);
    return providerRef.current;
  };

  const ensureReady = async () => {
    if (!wallet) { showToast("⚠️ Connect wallet first!"); return null; }
    if (!network) { showToast("⚠️ Switch to Polygon!"); await switchNetwork(); return null; }
    const p = getProvider(); if (!p) return null;
    return await p.getSigner();
  };

  const loadData = useCallback(async (account) => {
    try {
      const p = getProvider(); if (!p) return;
      const token = new Contract(ADDRESSES.token, TOKEN_ABI, p);
      const stk = new Contract(ADDRESSES.staking, STAKING_ABI, p);

      const [bal, si, ri, chain, totStk, pend, claimNow, pool, emis] = await Promise.all([
        account ? token.balanceOf(account) : Promise.resolve(0n),
        account ? stk.getUserStakingInfo(account) : Promise.resolve(null),
        account ? stk.getUserReferralInfo(account) : Promise.resolve(null),
        account ? stk.getReferralChain(account) : Promise.resolve([ZERO,ZERO,ZERO,ZERO,ZERO]),
        stk.totalStaked(),
        account ? stk.pendingReward(account) : Promise.resolve(0n),
        account ? stk.canClaimNow(account) : Promise.resolve([false,0n,0n,""]),
        stk.getPoolInfo(),
        stk.getEmissionSchedule(),
      ]);

      setData({
        balance: f18(bal),
        staked: si ? f18(si.staked) : "0",
        pending: f18(pend),
        totalStaked: f18(totStk),
        activeStakers: pool ? String(pool.currentActiveStakers) : "0",
        dailyEmission: pool ? f18(pool.dailyStakingEmission) : "0",
        rewardDistributed: pool ? f18(pool.rewardDistributed) : "0",
        totalEarned: si ? f18(si.totalEarned) : "0",
        sharePercent: si ? (Number(si.sharePercent)/100).toString() : "0",
        halving: emis ? String(emis.halvingNumber) : "0",
        stakingInfo: si ? {
          unstakePending: si.unstakePending,
          canUnstakeNow: si.canUnstakeNow,
          unstakeAvailableAt: Number(si.unstakeAvailableAt),
        } : EMPTY.stakingInfo,
        referralInfo: ri ? {
          referrer: ri.referrer,
          totalReferrals: String(ri.totalReferrals),
          totalReferralEarned: f18(ri.totalReferralEarned),
          pendingReferral: f18(ri.pendingReferral),
          teamBonusEarned: f18(ri.teamBonusEarned),
          totalTeamVolume: f18(ri.totalTeamVolume),
        } : EMPTY.referralInfo,
        referralChain: chain ? [chain.l1,chain.l2,chain.l3,chain.l4,chain.l5] : EMPTY.referralChain,
        claim: claimNow ? { canClaim: claimNow.canClaim, amount: f18(claimNow.amount), total: f18(claimNow.total), reason: claimNow.reason } : EMPTY.claim,
      });
    } catch (e) {
      console.error("loadData error:", e);
    }
  }, []);

  const switchNetwork = async () => {
    try {
      await window.ethereum.request({ method:"wallet_switchEthereumChain", params:[{ chainId: POLYGON_CHAIN_ID }] });
      setNetwork(true);
    } catch (e) {
      if (e.code === 4902) {
        try { await window.ethereum.request({ method:"wallet_addEthereumChain", params:[POLYGON_PARAMS] }); setNetwork(true); }
        catch { showToast("❌ Network add failed"); }
      } else { showToast("❌ Switch failed"); }
    }
  };

  const connect = async () => {
    if (!window.ethereum) { showToast("⚠️ Please install MetaMask!"); return; }
    setConnecting(true);
    try {
      const accs = await window.ethereum.request({ method:"eth_requestAccounts" });
      const cid = await window.ethereum.request({ method:"eth_chainId" });
      setWallet(accs[0]);
      const onPoly = cid === POLYGON_CHAIN_ID;
      setNetwork(onPoly);
      if (!onPoly) await switchNetwork();
      else showToast("✅ Wallet connected!");
      await loadData(accs[0]);
    } catch { showToast("❌ Connection failed"); }
    finally { setConnecting(false); }
  };

  // wallet event listeners
  useEffect(() => {
    if (!window.ethereum) return;
    const onAcc = (accs) => { if (accs.length) { setWallet(accs[0]); loadData(accs[0]); } else { setWallet(null); setData(EMPTY); } };
    const onChain = (cid) => { setNetwork(cid === POLYGON_CHAIN_ID); providerRef.current = null; if (wallet) loadData(wallet); };
    window.ethereum.on("accountsChanged", onAcc);
    window.ethereum.on("chainChanged", onChain);
    return () => { window.ethereum.removeListener("accountsChanged", onAcc); window.ethereum.removeListener("chainChanged", onChain); };
  }, [wallet, loadData]);

  // auto refresh every 20s
  useEffect(() => {
    if (!wallet) return;
    const t = setInterval(() => loadData(wallet), 20000);
    return () => clearInterval(t);
  }, [wallet, loadData]);

  // ── write actions ──────────────────────────────────────
  const actions = {
    stake: async (amount, referrer) => {
      if (!amount || Number(amount) <= 0) { showToast("⚠️ Enter an amount!"); return; }
      const signer = await ensureReady(); if (!signer) return;
      setBusyKey("stake", true);
      try {
        const amt = parseUnits(String(amount), 18);
        const token = new Contract(ADDRESSES.token, TOKEN_ABI, signer);
        const allowance = await token.allowance(wallet, ADDRESSES.staking);
        if (allowance < amt) {
          showToast("1/2 — Approving...");
          const txA = await token.approve(ADDRESSES.staking, amt);
          await txA.wait();
        }
        const stk = new Contract(ADDRESSES.staking, STAKING_ABI, signer);
        showToast("2/2 — Staking...");
        let tx;
        const ref = referrer && isAddress(referrer) ? referrer : ZERO;
        if (referrer === null) tx = await stk.addToStake(amt);
        else tx = await stk.stake(amt, ref);
        await tx.wait();
        showToast("✅ Stake successful!");
        await loadData(wallet);
      } catch (e) { console.error(e); showToast("❌ " + (e?.shortMessage || e?.reason || "Stake failed")); }
      finally { setBusyKey("stake", false); }
    },
    requestUnstake: async () => {
      const signer = await ensureReady(); if (!signer) return;
      setBusyKey("unstake", true);
      try {
        const stk = new Contract(ADDRESSES.staking, STAKING_ABI, signer);
        const tx = await stk.requestUnstake(); await tx.wait();
        showToast("⏳ Unstake requested — cooldown started!"); await loadData(wallet);
      } catch (e) { showToast("❌ " + (e?.shortMessage || e?.reason || "Failed")); }
      finally { setBusyKey("unstake", false); }
    },
    unstake: async () => {
      const signer = await ensureReady(); if (!signer) return;
      setBusyKey("unstake", true);
      try {
        const stk = new Contract(ADDRESSES.staking, STAKING_ABI, signer);
        const tx = await stk.unstake(); await tx.wait();
        showToast("✅ Unstaked — tokens returned!"); await loadData(wallet);
      } catch (e) { showToast("❌ " + (e?.shortMessage || e?.reason || "Failed")); }
      finally { setBusyKey("unstake", false); }
    },
    cancelUnstake: async () => {
      const signer = await ensureReady(); if (!signer) return;
      setBusyKey("cancel", true);
      try {
        const stk = new Contract(ADDRESSES.staking, STAKING_ABI, signer);
        const tx = await stk.cancelUnstake(); await tx.wait();
        showToast("↩️ Unstake cancelled"); await loadData(wallet);
      } catch (e) { showToast("❌ " + (e?.shortMessage || e?.reason || "Failed")); }
      finally { setBusyKey("cancel", false); }
    },
    claim: async () => {
      const signer = await ensureReady(); if (!signer) return;
      setBusyKey("claim", true);
      try {
        const stk = new Contract(ADDRESSES.staking, STAKING_ABI, signer);
        const tx = await stk.claimReward(); await tx.wait();
        showToast("💰 Reward claimed!"); await loadData(wallet);
      } catch (e) { showToast("❌ " + (e?.shortMessage || e?.reason || "Claim failed")); }
      finally { setBusyKey("claim", false); }
    },
  };

  const tabs = [
    { id:"dashboard", label:"📊 Dash" },
    { id:"staking",   label:"⚡ Stake" },
    { id:"referral",  label:"👥 Refer" },
    { id:"swap",      label:"🔄 Swap" },
    { id:"messenger", label:"💬 Msg" },
  ];

  return (
    <>
      <style>{styles}</style>
      <div style={{ minHeight:"100vh", background:bg }}>
        <Header wallet={wallet} network={network} onConnect={connect} onSwitch={switchNetwork} connecting={connecting}/>
        <div style={{ maxWidth:560, margin:"0 auto", padding:"16px 14px" }}>
          <div className="tab-nav" style={{ marginBottom:16 }}>
            {tabs.map(t => (
              <button key={t.id} className={`tab-btn ${tab===t.id?"active":""}`} onClick={()=>setTab(t.id)}>{t.label}</button>
            ))}
          </div>

          {tab==="dashboard" && <Dashboard data={data} wallet={wallet}/>}
          {tab==="staking"   && <Staking wallet={wallet} data={data} refParam={refParam} actions={actions} busy={busy}/>}
          {tab==="referral"  && <Referral wallet={wallet} data={data} showToast={showToast}/>}
          {tab==="swap"      && <Swap/>}
          {tab==="messenger" && <Messenger/>}

          {!wallet && (
            <div style={{ textAlign:"center", marginTop:20, fontSize:13, color:"#7b8699" }}>
              👆 Connect your wallet to see real data
            </div>
          )}
        </div>
        <div style={{ textAlign:"center", padding:16, borderTop:`1px solid ${border}`, marginTop:16 }}>
          <div style={{ fontSize:10, color:"#3a4458", fontFamily:"'Space Mono',monospace" }}>OSG · Polygon Mainnet · {short(ADDRESSES.token)}</div>
        </div>
      </div>
      {toast && <div className="toast">{toast}</div>}
    </>
  );
}
