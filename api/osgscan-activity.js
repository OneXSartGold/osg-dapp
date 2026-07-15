// api/osgscan-activity.js
//
// OSGScan public activity data — today's Transfers and today's Swappers.
// Uses Etherscan V2 Unified API (POLYGONSCAN_KEY from Vercel env).
//
// Response shape:
// {
//   transfers: [ { from, to, amount, txHash, timestamp }, ... ]  // today, newest first, max 50
//   swappers:  [ { address, swaps, volumeOSG }, ... ]            // today, sorted by volume desc
// }

const ETHERSCAN_BASE = "https://api.etherscan.io/v2/api";
const CHAIN_ID = 137;

const ADDR = {
  token: "0xba05176748347944CC26900c821AbFeBeBC57415",
  pool:  "0xA15214B09a9b3E1c821B94fB97d6d3BcA8201Cd2",
};

const TOPIC_TRANSFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
const TOPIC_SWAP_V2  = "0xd78ad95fa46c994b6551d0da85fc275fe613ce37657fb8d5e3d130840159d822";

const BLOCKS_PER_DAY_APPROX = 43200; // Polygon ~2s block time
const MAX_TRANSFERS_RETURNED = 50;
const MAX_SWAP_TX_LOOKUPS = 30; // cap how many tx.from lookups we do, for speed
const TX_LOOKUP_CONCURRENCY = 1; // stay safely under Etherscan free-tier's 5 req/sec
const CALL_RETRIES = 3;

function sleep(ms) {
  return new Promise(function (r) { setTimeout(r, ms); });
}

// Retries on rate-limit / transient errors instead of silently treating
// a failed call as "no data" — this was the root cause of Swappers
// sometimes showing 0 when swaps actually happened (many more Etherscan
// calls are needed for Swappers than for Transfers, so it hit the
// free-tier 5 req/sec limit far more often).
async function callEtherscan(params) {
  const apikey = process.env.POLYGONSCAN_KEY;
  if (!apikey) throw new Error("POLYGONSCAN_KEY not set in environment variables");
  const qs = new URLSearchParams({ chainid: String(CHAIN_ID), apikey, ...params });
  const url = ETHERSCAN_BASE + "?" + qs.toString();

  let lastErr = null;
  for (let attempt = 0; attempt < CALL_RETRIES; attempt++) {
    try {
      const res = await fetch(url);
      if (!res.ok) {
        if (res.status === 429 || res.status >= 500) {
          lastErr = new Error("Etherscan HTTP " + res.status + " for " + params.action);
          await sleep(300 * (attempt + 1));
          continue;
        }
        throw new Error("Etherscan HTTP error " + res.status + " for " + params.action);
      }
      const json = await res.json();
      // Etherscan reports rate limiting via status:"0" + a message, not always HTTP 429
      if (json && json.status === "0" && json.message && /rate limit|max calls/i.test(json.message)) {
        lastErr = new Error("Etherscan rate limited: " + json.message);
        console.warn("osgscan-activity: rate limited on", params.action, "attempt", attempt + 1);
        await sleep(300 * (attempt + 1));
        continue;
      }
      return json;
    } catch (e) {
      lastErr = e;
      await sleep(300 * (attempt + 1));
    }
  }
  console.warn("osgscan-activity: call failed after retries:", params.action, (lastErr && lastErr.message) || lastErr);
  throw lastErr || new Error("Etherscan call failed after retries");
}

async function getLatestBlock() {
  const data = await callEtherscan({ module: "proxy", action: "eth_blockNumber" });
  if (!data.result) throw new Error("Could not fetch latest block number");
  return parseInt(data.result, 16);
}

// Filters by topic0 SERVER-SIDE (on Etherscan's end) instead of fetching
// every event type and filtering in JS. This avoids the 1000-record
// response cap silently truncating away the events we actually want
// (e.g. Swap events getting crowded out by Sync/Mint/Burn events).
async function getLogs(address, fromBlock, toBlock, topic0) {
  const params = {
    module: "logs",
    action: "getLogs",
    address,
    fromBlock: String(fromBlock),
    toBlock: String(toBlock),
  };
  if (topic0) params.topic0 = topic0;
  try {
    const data = await callEtherscan(params);
    if (!Array.isArray(data.result)) {
      console.warn("osgscan-activity: getLogs non-array result for", address, data && data.message);
      return [];
    }
    return data.result;
  } catch (e) {
    console.warn("osgscan-activity: getLogs failed for", address, (e && e.message) || e);
    return [];
  }
}

async function getTxFrom(txHash) {
  // This call uses module=proxy, which replies in raw JSON-RPC format
  // (no "status" field), so callEtherscan's status:"0" rate-limit check
  // never fires for it. Retry here directly on any missing/invalid result,
  // regardless of what shape the failure took.
  for (let attempt = 0; attempt < CALL_RETRIES; attempt++) {
    try {
      const data = await callEtherscan({ module: "proxy", action: "eth_getTransactionByHash", txhash: txHash });
      if (data && data.result && data.result.from) return data.result.from.toLowerCase();
      if (data && data.error) {
        console.warn("osgscan-activity: getTxFrom JSON-RPC error for", txHash, data.error.message || data.error);
      }
    } catch (e) {
      console.warn("osgscan-activity: getTxFrom threw for", txHash, (e && e.message) || e);
    }
    if (attempt < CALL_RETRIES - 1) await sleep(350 * (attempt + 1));
  }
  console.warn("osgscan-activity: getTxFrom gave up for", txHash);
  return null;
}

// Runs async work over items with a limited number of parallel workers,
// instead of one-at-a-time with artificial delays.
async function runPool(items, worker, concurrency) {
  let idx = 0;
  async function runner() {
    while (idx < items.length) {
      const my = idx++;
      try {
        await worker(items[my]);
      } catch (e) {
        // ignore individual failures, they just won't appear in results
      }
    }
  }
  const runners = [];
  for (let i = 0; i < concurrency; i++) runners.push(runner());
  await Promise.all(runners);
}

function topicToAddress(topic) {
  // topic is 32-byte hex; address is the last 20 bytes
  return "0x" + topic.slice(-40);
}

function hexToTokenAmount(hexData, decimals) {
  try {
    const raw = BigInt(hexData);
    const divisor = BigInt(10) ** BigInt(decimals);
    return Number(raw) / Number(divisor);
  } catch (e) {
    return 0;
  }
}

function matchesRange(hexTimestamp, range) {
  const ms = parseInt(hexTimestamp, 16) * 1000;
  const d = new Date(ms);
  const now = new Date();
  if (range === "yesterday") {
    const y = new Date(now.getTime() - 86400000);
    return d.toISOString().slice(0, 10) === y.toISOString().slice(0, 10);
  }
  if (range === "7d") {
    const cutoff = new Date(now.getTime() - 7 * 86400000);
    return d >= cutoff;
  }
  return isToday(hexTimestamp);
}

function isToday(hexTimestamp) {
  const ms = parseInt(hexTimestamp, 16) * 1000;
  const d = new Date(ms);
  const now = new Date();
  return d.toISOString().slice(0, 10) === now.toISOString().slice(0, 10);
}

function decodeSwapWords(hexData) {
  const clean = hexData.startsWith("0x") ? hexData.slice(2) : hexData;
  const words = [];
  for (let i = 0; i < 4; i++) {
    const word = clean.slice(i * 64, (i + 1) * 64);
    words.push(BigInt("0x" + word));
  }
  return words; // [amount0In, amount1In, amount0Out, amount1Out]
}

export default async function handler(req, res) {
  try {
    const latestBlock = await getLatestBlock();
    const range = (req.query && req.query.range) || "today";
    const rangeDays = range === "7d" ? 8 : (range === "yesterday" ? 3 : 2);
    const fromBlock = Math.max(0, latestBlock - rangeDays * BLOCKS_PER_DAY_APPROX); // buffer, filtered below

    const [tokenLogs, poolLogs] = await Promise.all([
      getLogs(ADDR.token, fromBlock, latestBlock, TOPIC_TRANSFER),
      getLogs(ADDR.pool, fromBlock, latestBlock, TOPIC_SWAP_V2),
    ]);

    // ── Today's Transfers ──
    const transfers = [];
    for (const log of tokenLogs) {
      if (!log.topics || log.topics[0] !== TOPIC_TRANSFER) continue;
      if (!matchesRange(log.timeStamp, range)) continue;
      transfers.push({
        from: topicToAddress(log.topics[1]),
        to: topicToAddress(log.topics[2]),
        amount: hexToTokenAmount(log.data, 18),
        txHash: log.transactionHash,
        timestamp: parseInt(log.timeStamp, 16) * 1000,
      });
    }
    transfers.sort((a, b) => b.timestamp - a.timestamp);
    const transfersOut = transfers.slice(0, MAX_TRANSFERS_RETURNED);

    // ── Swappers (grouped by sender) ──
    const rangeSwapLogs = poolLogs.filter(function (log) {
      return log.topics && log.topics[0] === TOPIC_SWAP_V2 && matchesRange(log.timeStamp, range);
    });

    // Keep only the most recent swap logs (by timestamp) before doing the
    // expensive tx.from lookups, so a busy "Last 7 Days" range stays fast.
    rangeSwapLogs.sort(function (a, b) {
      return parseInt(b.timeStamp, 16) - parseInt(a.timeStamp, 16);
    });

    const uniqueTxHashesAll = [...new Set(rangeSwapLogs.map(function (log) { return log.transactionHash; }))];
    const uniqueTxHashes = uniqueTxHashesAll.slice(0, MAX_SWAP_TX_LOOKUPS);

    const txFromMap = {};
    await runPool(
      uniqueTxHashes,
      async function (hash) {
        const from = await getTxFrom(hash);
        txFromMap[hash] = from;
      },
      TX_LOOKUP_CONCURRENCY,
    );

    const swapperMap = {};
    for (const log of rangeSwapLogs) {
      if (!(log.transactionHash in txFromMap)) continue; // skip logs we didn't look up (capped)
      const realUser = txFromMap[log.transactionHash];
      if (!realUser) continue;
      const words = decodeSwapWords(log.data);
      const osgRaw = words[1] + words[3];
      const volume = Number(osgRaw) / 1e18;
      if (!swapperMap[realUser]) swapperMap[realUser] = { address: realUser, swaps: 0, volumeOSG: 0 };
      swapperMap[realUser].swaps += 1;
      swapperMap[realUser].volumeOSG += volume;
    }
    const swappers = Object.values(swapperMap).sort((a, b) => b.volumeOSG - a.volumeOSG);

    res.setHeader("Cache-Control", "s-maxage=90, stale-while-revalidate=240");
    res.status(200).json({ transfers: transfersOut, swappers });
  } catch (err) {
    res.status(500).json({ error: err.message || "Unknown error in osgscan-activity" });
  }
}
