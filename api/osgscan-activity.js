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

async function callEtherscan(params) {
  const apikey = process.env.POLYGONSCAN_KEY;
  if (!apikey) throw new Error("POLYGONSCAN_KEY not set in environment variables");
  const qs = new URLSearchParams({ chainid: String(CHAIN_ID), apikey, ...params });
  const url = ETHERSCAN_BASE + "?" + qs.toString();
  const res = await fetch(url);
  if (!res.ok) throw new Error("Etherscan HTTP error " + res.status + " for " + params.action);
  return res.json();
}

async function getLatestBlock() {
  const data = await callEtherscan({ module: "proxy", action: "eth_blockNumber" });
  if (!data.result) throw new Error("Could not fetch latest block number");
  return parseInt(data.result, 16);
}

async function getLogs(address, fromBlock, toBlock) {
  const data = await callEtherscan({
    module: "logs",
    action: "getLogs",
    address,
    fromBlock: String(fromBlock),
    toBlock: String(toBlock),
  });
  if (!Array.isArray(data.result)) return [];
  return data.result;
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
    const fromBlock = Math.max(0, latestBlock - 2 * BLOCKS_PER_DAY_APPROX); // 2 days buffer, filtered to today below

    const [tokenLogs, poolLogs] = await Promise.all([
      getLogs(ADDR.token, fromBlock, latestBlock),
      getLogs(ADDR.pool, fromBlock, latestBlock),
    ]);

    // ── Today's Transfers ──
    const transfers = [];
    for (const log of tokenLogs) {
      if (!log.topics || log.topics[0] !== TOPIC_TRANSFER) continue;
      if (!isToday(log.timeStamp)) continue;
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

    // ── Today's Swappers (grouped by sender) ──
    const swapperMap = {};
    for (const log of poolLogs) {
      if (!log.topics || log.topics[0] !== TOPIC_SWAP_V2) continue;
      if (!isToday(log.timeStamp)) continue;
      const sender = topicToAddress(log.topics[1]);
      const words = decodeSwapWords(log.data);
      const totalRaw = words[0] + words[1] + words[2] + words[3];
      const volume = Number(totalRaw) / 1e18;
      if (!swapperMap[sender]) swapperMap[sender] = { address: sender, swaps: 0, volumeOSG: 0 };
      swapperMap[sender].swaps += 1;
      swapperMap[sender].volumeOSG += volume;
    }
    const swappers = Object.values(swapperMap).sort((a, b) => b.volumeOSG - a.volumeOSG);

    res.setHeader("Cache-Control", "s-maxage=60, stale-while-revalidate=180");
    res.status(200).json({ transfers: transfersOut, swappers });
  } catch (err) {
    res.status(500).json({ error: err.message || "Unknown error in osgscan-activity" });
  }
}
