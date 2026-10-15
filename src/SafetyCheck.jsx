import { useState, useEffect } from "react";
import { Contract } from "ethers";

/* ══════════════════════════════════════════════════════════
   Wallet Safety Check (member tool #1) — read-only view.
   Lists the token permissions (ERC-20 approvals) a wallet has
   given on Polygon, with a risk label for each one.
   Data: /api/osg-wallet-flow?mode=approvals&address=0x...
   (lib/wallet-approvals.js).
   Remove = approve(spender, 0) on the token contract, sent from the
   member's own connected wallet after a staticCall simulation.
   Shown only when the connected wallet is the checked address.
   ══════════════════════════════════════════════════════════ */

const GOLD = "#F7D27A";
const GREEN = "#46D08A";
const RED = "#F2675C";
const ORANGE = "#F59E0B";
const BLUE = "#38BDF8";
const TXT = "#F4F4F5";
const TXT2 = "#9A9AA8";
const TXT3 = "#5E5E6E";
const EDGE = "rgba(255,255,255,.08)";

const RISK = {
  high: { label: "High risk", color: RED },
  medium: { label: "Medium risk", color: ORANGE },
  low: { label: "Low risk", color: GOLD },
  none: { label: "Safe", color: GREEN },
};

const REASON_TEXT = {
  unlimited: "Can spend an unlimited amount of this coin.",
  unknown_spender: "Not an OSG contract and not a well-known app.",
  not_verified: "The contract code is not verified on Polygonscan.",
  not_a_contract: "Permission was given to a plain wallet, not an app.",
  old_osg_contract: "Old OSG contract that is no longer used.",
};

const CATEGORY_TEXT = {
  official: "OSG official",
  official_old: "OSG (old)",
  known: "Known app",
  unknown: "Unknown",
};

function isAddress(a) {
  return /^0x[0-9a-fA-F]{40}$/.test(String(a || "").trim());
}

function short(a) {
  return a ? a.slice(0, 6) + "…" + a.slice(-4) : "";
}

function fmtDate(sec) {
  if (!sec) return "";
  try {
    return new Date(sec * 1000).toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" });
  } catch (e) {
    return "";
  }
}

function fmtAmount(a) {
  if (a === "unlimited") return "Unlimited";
  if (a === null || a === undefined) return "Unknown";
  const n = Number(a);
  if (!isFinite(n)) return a;
  return n.toLocaleString("en-US", { maximumFractionDigits: 6 });
}

const APPROVE_ABI = ["function approve(address spender, uint256 amount) returns (bool)"];

function errText(e) {
  const m = String((e && (e.shortMessage || e.reason || e.message)) || "");
  if (/user rejected|denied|ACTION_REJECTED/i.test(m) || (e && e.code === 4001)) return "Cancelled in the wallet.";
  return m ? m.slice(0, 140) : "Failed.";
}

export default function SafetyCheck({ wallet, ensureReady, showToast }) {
  const [busyKey, setBusyKey] = useState("");
  const [addr, setAddr] = useState(wallet || "");
  const [state, setState] = useState({ loading: false, error: "", data: null });

  useEffect(
    function () {
      if (wallet && !addr) setAddr(wallet);
    },
    [wallet],
  );

  function run(target) {
    const a = String(target || addr || "").trim();
    if (!isAddress(a)) {
      setState({ loading: false, error: "Please enter a valid 0x wallet address.", data: null });
      return;
    }
    setState({ loading: true, error: "", data: null });
    fetch("/api/osg-wallet-flow?mode=approvals&address=" + a + "&t=" + Date.now())
      .then(function (r) {
        return r.json();
      })
      .then(function (d) {
        if (!d || !d.ok) throw new Error((d && d.error) || "scan failed");
        setState({ loading: false, error: "", data: d });
      })
      .catch(function () {
        setState({ loading: false, error: "The check could not finish. Please try again in a minute.", data: null });
      });
  }

  const d = state.data;
  const canRemove = !!(wallet && d && d.address && d.address.toLowerCase() === wallet.toLowerCase() && ensureReady);

  async function remove(x) {
    const key = x.token + x.spender;
    const toast = showToast || function () {};
    const signer = await ensureReady();
    if (!signer) return;
    setBusyKey(key);
    try {
      const c = new Contract(x.token, APPROVE_ABI, signer);
      await c.approve.staticCall(x.spender, 0n);
      const gas = await c.approve.estimateGas(x.spender, 0n);
      toast("Confirm in your wallet: remove " + (x.tokenSymbol || "coin") + " permission…");
      const tx = await c.approve(x.spender, 0n, { gasLimit: (gas * 12n) / 10n + 20000n });
      toast("Removing… waiting for Polygon");
      await tx.wait();
      toast("✓ Permission removed");
      setState(function (s) {
        if (!s.data) return s;
        const left = s.data.approvals.filter(function (y) { return y.token + y.spender !== key; });
        return Object.assign({}, s, {
          data: Object.assign({}, s.data, { approvals: left, revokedCount: (s.data.revokedCount || 0) + 1 }),
        });
      });
    } catch (e) {
      toast("⚠️ " + errText(e));
    } finally {
      setBusyKey("");
    }
  }
  const list = (d && d.approvals) || [];
  const highCount = list.filter(function (x) { return x.risk === "high"; }).length;

  const card = {
    background: "linear-gradient(165deg,#16140C 0%,#121118 60%)",
    border: "1px solid rgba(233,185,73,.2)",
    borderRadius: 20,
    padding: "18px 16px 16px",
    marginBottom: 14,
  };

  return (
    <div style={card}>
      <div style={{ fontFamily: "'Bricolage Grotesque',sans-serif", fontWeight: 800, fontSize: 18, color: TXT }}>
        🛡️ Wallet Safety Check
      </div>
      <div style={{ fontSize: 13, color: TXT2, marginTop: 4, lineHeight: 1.5 }}>
        See which apps are allowed to spend your coins. Permissions you no longer need are a common way coins
        disappear from a wallet.
      </div>

      <div style={{ display: "flex", gap: 8, marginTop: 12 }}>
        <input
          value={addr}
          onChange={function (e) { setAddr(e.target.value); }}
          placeholder="0x… wallet address"
          spellCheck={false}
          style={{
            flex: 1,
            minWidth: 0,
            background: "rgba(255,255,255,.04)",
            border: "1px solid " + EDGE,
            borderRadius: 12,
            color: TXT,
            padding: "10px 12px",
            fontSize: 13,
            fontFamily: "monospace",
          }}
        />
        <button
          onClick={function () { run(); }}
          disabled={state.loading}
          style={{
            background: "linear-gradient(135deg,#F7D27A 0%,#E9B949 45%,#C4912E 100%)",
            color: "#111",
            border: 0,
            borderRadius: 12,
            padding: "10px 16px",
            fontWeight: 700,
            fontSize: 13,
            cursor: state.loading ? "wait" : "pointer",
            opacity: state.loading ? 0.6 : 1,
          }}
        >
          {state.loading ? "Checking…" : "Check"}
        </button>
      </div>
      {wallet && addr.toLowerCase() !== wallet.toLowerCase() && (
        <button
          onClick={function () { setAddr(wallet); run(wallet); }}
          style={{ background: "none", border: 0, color: BLUE, fontSize: 12, padding: "6px 0 0", cursor: "pointer" }}
        >
          Use my connected wallet
        </button>
      )}

      {state.loading && (
        <div style={{ fontSize: 12, color: TXT2, marginTop: 12 }}>
          Scanning permissions on Polygon. This can take up to 30 seconds…
        </div>
      )}
      {state.error && <div style={{ fontSize: 13, color: RED, marginTop: 12 }}>{state.error}</div>}

      {d && (
        <div style={{ marginTop: 14 }}>
          <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginBottom: 12 }}>
            <Stat label="Open permissions" value={list.length} color={TXT} />
            <Stat label="High risk" value={highCount} color={highCount ? RED : GREEN} />
            <Stat label="Already removed" value={d.revokedCount || 0} color={TXT2} />
          </div>

          {list.length === 0 && (
            <div style={{ fontSize: 13, color: GREEN }}>No open permissions found for this wallet. ✅</div>
          )}

          {list.map(function (x) {
            const r = RISK[x.risk] || RISK.medium;
            return (
              <div
                key={x.token + x.spender}
                style={{
                  border: "1px solid " + EDGE,
                  borderLeft: "3px solid " + r.color,
                  borderRadius: 14,
                  padding: "12px 12px 10px",
                  marginBottom: 10,
                  background: "rgba(255,255,255,.02)",
                }}
              >
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8 }}>
                  <div style={{ fontWeight: 700, fontSize: 14, color: TXT }}>
                    {x.tokenSymbol || short(x.token)}
                    <span style={{ fontWeight: 400, color: TXT2, fontSize: 13 }}>
                      {" · "}
                      {fmtAmount(x.allowance)}
                    </span>
                  </div>
                  <span
                    style={{
                      fontSize: 11,
                      fontWeight: 700,
                      color: r.color,
                      border: "1px solid " + r.color,
                      borderRadius: 999,
                      padding: "2px 8px",
                      whiteSpace: "nowrap",
                    }}
                  >
                    {r.label}
                  </span>
                </div>
                <div style={{ fontSize: 12, color: TXT2, marginTop: 6 }}>
                  Allowed app:{" "}
                  <a
                    href={"https://polygonscan.com/address/" + x.spender}
                    target="_blank"
                    rel="noopener noreferrer"
                    style={{ color: BLUE, textDecoration: "none" }}
                  >
                    {x.spenderLabel || short(x.spender)}
                  </a>
                  <span style={{ color: TXT3 }}>{" · " + (CATEGORY_TEXT[x.category] || "")}</span>
                </div>
                {x.reasons && x.reasons.length > 0 && (
                  <ul style={{ margin: "6px 0 0", paddingLeft: 18, fontSize: 12, color: TXT2, lineHeight: 1.5 }}>
                    {x.reasons.map(function (k) {
                      return <li key={k}>{REASON_TEXT[k] || k}</li>;
                    })}
                  </ul>
                )}
                {canRemove && (
                  <button
                    onClick={function () { remove(x); }}
                    disabled={!!busyKey}
                    style={{
                      marginTop: 8,
                      background: "transparent",
                      color: x.risk === "none" ? TXT2 : RED,
                      border: "1px solid " + (x.risk === "none" ? EDGE : RED),
                      borderRadius: 10,
                      padding: "6px 12px",
                      fontSize: 12,
                      fontWeight: 700,
                      cursor: busyKey ? "wait" : "pointer",
                      opacity: busyKey && busyKey !== x.token + x.spender ? 0.5 : 1,
                    }}
                  >
                    {busyKey === x.token + x.spender ? "Removing…" : "Remove permission"}
                  </button>
                )}
                <div style={{ fontSize: 11, color: TXT3, marginTop: 6 }}>
                  Given {fmtDate(x.lastApprovalTime)}
                  {x.lastApprovalTx && (
                    <>
                      {" · "}
                      <a
                        href={"https://polygonscan.com/tx/" + x.lastApprovalTx}
                        target="_blank"
                        rel="noopener noreferrer"
                        style={{ color: TXT3 }}
                      >
                        view transaction
                      </a>
                    </>
                  )}
                </div>
              </div>
            );
          })}

          {d.truncated && (
            <div style={{ fontSize: 12, color: ORANGE, marginTop: 4 }}>
              This wallet has a very long history; only the first 10,000 permission events were checked.
            </div>
          )}
          {list.length > 0 && !canRemove && (
            <div style={{ fontSize: 12, color: GOLD, marginTop: 6 }}>
              To remove a permission, connect this wallet and check it again.
            </div>
          )}
          {list.length > 0 && canRemove && (
            <div style={{ fontSize: 12, color: TXT2, marginTop: 6, lineHeight: 1.5 }}>
              Removing a permission sends 0 POL; only a small network fee is paid. Your wallet will show the coin's
              own contract as "To". If you remove a permission you still need (for example an OSG app you use), the
              app will simply ask for it again next time.
            </div>
          )}
        </div>
      )}

      <div
        style={{
          fontSize: 11,
          color: TXT3,
          marginTop: 14,
          lineHeight: 1.5,
          borderTop: "1px solid " + EDGE,
          paddingTop: 10,
        }}
      >
        Checking is read-only. Removing is signed by you in your own wallet. This tool never asks for your seed phrase or keys. It can help stop future misuse, but it
        cannot bring back coins that were already taken. Anyone offering to "recover" lost crypto is a scammer.
      </div>
    </div>
  );
}

function Stat({ label, value, color }) {
  return (
    <div
      style={{
        flex: "1 1 0",
        minWidth: 0,
        border: "1px solid " + EDGE,
        borderRadius: 12,
        padding: "8px 10px",
        background: "rgba(255,255,255,.02)",
      }}
    >
      <div style={{ fontSize: 18, fontWeight: 800, color }}>{value}</div>
      <div style={{ fontSize: 11, color: TXT2 }}>{label}</div>
    </div>
  );
}
