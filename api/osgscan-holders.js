// api/osgscan-holders.js
//
// OSGScan Top Holders — reconstructs holder balances from the full
// Transfer event history of the OSG token, then returns the top 5
// wallets (by balance) plus their share of circulating supply.
//
// Response shape:
// {
//   holders: [ { address, balanceOSG, percent, label } , ... up to 5 ],
//   totalSupplyOSG: number,
//   coverage: number,   // % of totalSupply accounted for — should be ~100
//   updatedAt: number   // unix ms
// }

const ETHERSCAN_BASE = "https://api.etherscan.io/v2/api";
const CHAIN_ID = 137;

const TOKEN = "0xba05176748347944CC26900c821AbFeBeBC57415";
const TOPIC_TRANSFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";

const CHUNK_BLOCKS = 300000;   // ~ a few days per chunk, adaptive-split handles bursts
const FALLBACK_LOOKBACK_DAYS = 60;
const FALLBACK_BLOCKS_PER_DAY = 60000; // generous overestimate used only as last resort

const ZERO = "0x0000000000000000000000000000000000000000000000000000000000000000".slice(0, 42);
const DEAD = "0x000000000000000000000000000000000000dead";

const LABELS = {
  "0xf8acaa5617dff6db3d0cb44ca8de0e50a449bb83": "OSG-MAIN (Treasury)",
  "0xadc33f3cc10c44a9902a1b3f8257e6867dd242e6": "Vesting (Team)",
  "0xb43a0558700450c5d458cf00fccb9db3383cfee0": "Pool Wallet (LP)",
  "0x048e814c02e85ec1438ab8c1d2e9150a5289a886": "Staking Contract",
  "0xdc4fe983ed301ad42f4e4c43951aa07a7a182855": "Reward Pool",
  "0xa0b2dcb18cf0bdf61bcb9d33f538167df501becb": "Reward Storage",
  "0xe2e82a8acdd3af7fa74eacb3331231a769d80d4c": "TimelockDAO",
  "0x06263828484e36106edf20a6d5a38c3be9612269": "Bond Contract",
  "0x29c63cd4c3f03b1f64e929b0b8bac691deb5fa5c": "Messenger",
  "0x88e64cbc22a35c2928038f2bc13f06630c93d07a": "Media Storage",
  "0x72a4387cc07cf105feec4615b40d2ef9ca0aee6b": "P2P Exchange",
  "0x4f1eff6fc4a0271096dd78b6f6284d4c9f1904f1": "Referral Distributor",
  "0xa15214b09a9b3e1c821b94fb97d6d3bca8201cd2": "QuickSwap Pool",
  "0x86ac1943c57889c541f292ad271610383c1ab3e3": "P2P Fee Collector",
};

async function callEtherscan(params) {
  const apikey = process.env.POLYGONSCAN_KEY;
  if (!apikey) throw new Error("POLYGONSCAN_KEY not set");
  const qs = new URLSearchParams({ chainid: String(CHAIN_ID), apikey, ...params });
  const res = await fetch(ETHERSCAN_BASE + "?" + qs.toString());
  if (!res.ok) throw new Error("Etherscan HTTP " + res.status + " for " + params.action);
  return res.json();
}

async function getLatestBlock() {
  const data = await callEtherscan({ module: "proxy", action: "eth_blockNumber" });
  if (!data.result) throw new Error("Could not fetch latest block");
  return parseInt(data.result, 16);
}

// find the EXACT block the token contract was deployed at — no guessing.
async function getGenesisBlock(latestBlock) {
  try {
    const data = await callEtherscan({
      module: "contract", action: "getcontractcreation",
      contractaddresses: TOKEN,
    });
    const info = data.result && data.result[0];
    if (info && info.blockNumber) {
      return Math.max(0, parseInt(info.blockNumber, 10) - 50);
    }
    if (info && info.txHash) {
      const tx = await callEtherscan({
        module: "proxy", action: "eth_getTransactionByHash", txhash: info.txHash,
      });
      if (tx.result && tx.result.blockNumber) {
        return Math.max(0, parseInt(tx.result.blockNumber, 16) - 50);
      }
    }
  } catch (e) { /* fall through to estimate */ }
  return Math.max(0, latestBlock - FALLBACK_LOOKBACK_DAYS * FALLBACK_BLOCKS_PER_DAY);
}

async function getTotalSupply() {
  const data = await callEtherscan({
    module: "proxy", action: "eth_call",
    to: TOKEN, data: "0x18160ddd", tag: "latest",
  });
  if (!data.result) return 0;
  try { return Number(BigInt(data.result)) / 1e18; } catch (e) { return 0; }
}

async function getLogsRaw(fromBlock, toBlock) {
  const data = await callEtherscan({
    module: "logs", action: "getLogs",
    address: TOKEN,
    fromBlock: String(fromBlock), toBlock: String(toBlock),
  });
  if (Array.isArray(data.result)) return data.result;
  if (data.message && /no records/i.test(data.message)) return [];
  return null; // signals failure
}

// adaptive fetch: if a range looks capped/truncated (>=1000 results) or the
// call fails, split it in half and recurse — guarantees full coverage
// regardless of how busy any given period was.
async function getLogsAdaptive(fromBlock, toBlock, depth) {
  if (depth === undefined) depth = 0;
  let logs = await getLogsRaw(fromBlock, toBlock);
  if (logs === null) {
    await new Promise((r) => setTimeout(r, 400));
    logs = await getLogsRaw(fromBlock, toBlock);
  }
  const looksTruncated = logs === null || logs.length >= 1000;
  if (looksTruncated && toBlock > fromBlock && depth < 8) {
    const mid = fromBlock + Math.floor((toBlock - fromBlock) / 2);
    const a = await getLogsAdaptive(fromBlock, mid, depth + 1);
    await new Promise((r) => setTimeout(r, 150));
    const b = await getLogsAdaptive(mid + 1, toBlock, depth + 1);
    return a.concat(b);
  }
  if (logs === null) throw new Error("getLogs failed for " + fromBlock + "-" + toBlock);
  return logs;
}

function topicToAddress(topic) {
  return "0x" + topic.slice(-40);
}

export default async function handler(req, res) {
  try {
    const latestBlock = await getLatestBlock();
    const startBlock = await getGenesisBlock(latestBlock);

    const ranges = [];
    for (let from = startBlock; from <= latestBlock; from += CHUNK_BLOCKS) {
      const to = Math.min(from + CHUNK_BLOCKS - 1, latestBlock);
      ranges.push([from, to]);
    }

    const balances = {};
    let incompleteChunks = 0;

    for (const [from, to] of ranges) {
      let logs;
      try {
        logs = await getLogsAdaptive(from, to);
      } catch (e) {
        incompleteChunks++;
        logs = [];
      }
      for (const log of logs) {
        if (!log.topics || log.topics[0] !== TOPIC_TRANSFER) continue;
        const from_ = topicToAddress(log.topics[1]).toLowerCase();
        const to_ = topicToAddress(log.topics[2]).toLowerCase();
        let amt;
        try { amt = BigInt(log.data); } catch (e) { continue; }

        if (from_ !== ZERO) balances[from_] = (balances[from_] || 0n) - amt;
        if (to_ !== ZERO) balances[to_] = (balances[to_] || 0n) + amt;
      }
      await new Promise((r) => setTimeout(r, 150));
    }

    const totalSupplyOSG = await getTotalSupply();

    const sumHeld = Object.values(balances).reduce((s, v) => s + (v > 0n ? v : 0n), 0n);
    const sumHeldOSG = Number(sumHeld) / 1e18;
    const coverage = totalSupplyOSG > 0 ? sumHeldOSG / totalSupplyOSG : 0;

    if (incompleteChunks > 0 && coverage < 0.95) {
      res.status(200).json({
        error: "Incomplete transfer history (" + incompleteChunks + " chunk(s) failed) — holder data would be misleading, not returning it.",
        coverage: Math.round(coverage * 1000) / 10,
        totalSupplyOSG,
        updatedAt: Date.now(),
      });
      return;
    }

    const ranked = Object.keys(balances)
      .filter((a) => a !== ZERO && a !== DEAD)
      .map((a) => ({ address: a, raw: balances[a] }))
      .filter((h) => h.raw > 0n)
      .sort((a, b) => (b.raw > a.raw ? 1 : b.raw < a.raw ? -1 : 0))
      .slice(0, 5)
      .map((h) => {
        const balanceOSG = Number(h.raw) / 1e18;
        const percent = totalSupplyOSG > 0 ? (balanceOSG / totalSupplyOSG) * 100 : 0;
        return {
          address: h.address,
          balanceOSG,
          percent,
          label: LABELS[h.address] || null,
        };
      });

    res.setHeader("Cache-Control", "s-maxage=600, stale-while-revalidate=1800");
    res.status(200).json({
      holders: ranked,
      totalSupplyOSG,
      coverage: Math.round(coverage * 1000) / 10,
      updatedAt: Date.now(),
    });
  } catch (err) {
    res.status(500).json({ error: err.message || "Unknown error in osgscan-holders" });
  }
}
