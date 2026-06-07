// ══════════════════════════════════════════════════════════
//  OSG Messenger — End-to-End Encryption  (Mārg 1: ECDH)
//  ----------------------------------------------------------
//  • Pure off-chain. NO contract changes.
//  • Each user's encryption key is derived DETERMINISTICALLY
//    from a MetaMask signature (personal_sign) — nothing is
//    ever stored on any server, and the same wallet always
//    re-derives the same key.
//  • Scheme: X25519 ECDH  →  shared secret  →  AES-256-GCM.
//    Only the real sender + receiver can read a message.
//  • Ciphertext is stored inline in the message `cid` field.
//
//  npm install @noble/curves@1.6.0 @noble/hashes@1.5.0 @noble/ciphers@1.0.0
// ══════════════════════════════════════════════════════════

import { x25519 } from "@noble/curves/ed25519";
import { sha256 } from "@noble/hashes/sha256";
import { gcm } from "@noble/ciphers/aes";
import { randomBytes, bytesToHex, hexToBytes, utf8ToBytes } from "@noble/hashes/utils";

// Marks an OSG-encrypted v1 message so we can tell it apart from
// old plaintext messages (which stay readable as-is).
const PREFIX = "e1:";

// The exact text the user signs to derive their key. MUST stay
// identical forever — changing it would change everyone's keys.
const SIGN_MESSAGE =
  "OSG Messenger — encryption key\n\n" +
  "Sign this message to create your private end-to-end encryption key.\n" +
  "This is FREE and does NOT send a transaction.\n" +
  "Only sign on the official OSG dApp.  (v1)";

// Contract caps `cid` at 128 chars. With prefix(3) + nonce(12) +
// GCM tag(16), that leaves ~65 bytes of plaintext per message.
export const MAX_PLAINTEXT_CHARS = 65;

// ── base64 helpers (byte-safe) ────────────────────────────
function b64encode(bytes) {
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}
function b64decode(str) {
  const bin = atob(str);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// ── derive a deterministic keypair from a wallet signature ──
//  signer: an ethers Signer.  Returns { priv:Uint8Array(32), pubHex:"0x.." }
export async function deriveKeypair(signer) {
  const signature = await signer.signMessage(SIGN_MESSAGE); // "0x" + 130 hex
  const sigBytes = hexToBytes(signature.slice(2));
  const priv = sha256(sigBytes);             // 32-byte seed → X25519 private
  const pub = x25519.getPublicKey(priv);     // 32-byte public
  return { priv, pubHex: "0x" + bytesToHex(pub) };
}

// ── ECDH shared secret → AES-256 key ──────────────────────
//  Same key in BOTH directions: x25519(myPriv,theirPub) === x25519(theirPriv,myPub)
function deriveAesKey(myPriv, theirPubHex) {
  const theirPub = hexToBytes(String(theirPubHex).replace(/^0x/, ""));
  const shared = x25519.getSharedSecret(myPriv, theirPub); // 32 bytes
  const info = utf8ToBytes("OSG-MSG-v1");
  const buf = new Uint8Array(shared.length + info.length);
  buf.set(shared, 0);
  buf.set(info, shared.length);
  return sha256(buf); // 32-byte AES-256 key (KDF = sha256(shared || info))
}

// ── encrypt → string for the `cid` field ──────────────────
export function encryptMessage(plaintext, myPriv, theirPubHex) {
  const key = deriveAesKey(myPriv, theirPubHex);
  const nonce = randomBytes(12);
  const ct = gcm(key, nonce).encrypt(utf8ToBytes(plaintext)); // includes 16-byte tag
  const blob = new Uint8Array(nonce.length + ct.length);
  blob.set(nonce, 0);
  blob.set(ct, nonce.length);
  return PREFIX + b64encode(blob);
}

// ── decrypt → { text, encrypted } ─────────────────────────
//  Legacy plaintext messages (no prefix) are returned unchanged.
export function decryptMessage(cid, myPriv, theirPubHex) {
  if (!cid || !cid.startsWith(PREFIX)) {
    return { text: cid, encrypted: false };          // old plaintext message
  }
  if (!theirPubHex || String(theirPubHex).length < 4) {
    return { text: "🔒 (encrypted — sender has no key)", encrypted: true };
  }
  try {
    const key = deriveAesKey(myPriv, theirPubHex);
    const blob = b64decode(cid.slice(PREFIX.length));
    const nonce = blob.slice(0, 12);
    const ct = blob.slice(12);
    const pt = gcm(key, nonce).decrypt(ct);
    return { text: new TextDecoder().decode(pt), encrypted: true };
  } catch {
    return { text: "🔒 (unable to decrypt)", encrypted: true };
  }
}

export function isEncrypted(cid) {
  return typeof cid === "string" && cid.startsWith(PREFIX);
}
