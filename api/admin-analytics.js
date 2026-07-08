// api/admin-analytics.js
//
// OSG Admin Analytics — aggregates on-chain activity for the last 8 days
// (today + 7-day trend) across 4 contracts:
//   - Token (Transfer events)
//   - QuickSwap OSG/WPOL Pool (Swap events)
//   - Staking contract (all events — exact names TBD, counted generically)
//   - P2P Exchange (all events — exact names TBD, counted generically)
//
// Uses Etherscan V2 Unified API (same key works for Polygon via chainid=137).
// Reads POLYGONSCAN_KEY from Vercel Environment Variables.
//
// Response shape:
// {
//   today:  { transfers, transferVolume, swaps, swapVolumeOSG, stakingActivity, p2pActivity },
//   days:   [ { date:"YYYY-MM-DD", transfers, transferVolume, swaps, swapVolumeOSG, stakingActivity, p2pActivity }, ... ] // oldest -> newest, 8 entries
// }

const ETHERSCAN_BASE = "https://api.etherscan.io/v2/api";
const CHAIN_ID = 137; // Polygon PoS

const ADDR = {
  token:   "0xba05176748347944CC26900c821AbFeBeBC57415",
  pool:    "0xA15214B09a9b3E1c821B94fB97d6d3BcA8201Cd2",
  staking: "0x048E814C02e85ec1438Ab8C1d2e9150A5289A886",
  p2p:     "0x72A4387cC07cF105fEec4615b40d2EF9ca0AEE6B",
};

// Standard event topic0 hashes (these never change, well-known signatures)
const TOPIC_TRANSFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
const TOPIC_SWAP_V2   = "0xd78ad95fa46c994b6551d0da85fc275fe613ce37657fb8d5e3d130840159d82";

const DAYS_BACK = 8; // today + 7 previous days
const BLOCKS_PER_DAY_APPROX = 43200; // Polygon ~2s block time

async function callEtherscan(params) {
  const apikey = process.env.POLYGONSCAN_KEY;
  if (!apikey) {
    throw new Error("POLYGONSCAN_KEY not set in environment variables");
  }
  const qs = new URLSearchParams({ chainid: String(CHAIN_ID), apikey, ...params });
  const url = ${ETHERSCAN_BASE}?${qs.toString()};
  const res = await fetch(url);
  if (!res.ok) {
    throw new Error(Etherscan HTTP error ${res.status} for ${params.action});
  }
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
  // Etherscan returns status "0" with message "No records found" when empty — not a real error
  if (!Array.isArray(data.result)) return [];
  return data.result;
}

function hexToDateKey(hexTimestamp) {
  const ms = parseInt(hexTimestamp, 16) * 1000;
  const d = new Date(ms);
  return d.toISOString().slice(0, 10); // "YYYY-MM-DD" (UTC)
}

function hexToTokenAmount(hexData, decimals) {
  // hexData like "0x0000...<32 bytes>" for a single uint256 value
  try {
    const raw = BigInt(hexData);
    const divisor = BigInt(10) ** BigInt(decimals);
    return Number(raw) / Number(divisor);
  } catch (e) {
    return 0;
  }
}

function decodeSwapAmounts(hexData) {
  // Swap(address indexed sender, uint amount0In, uint amount1In, uint amount0Out, uint amount1Out, address indexed to)
  // data = 4 x 32-byte words: amount0In, amount1In, amount0Out, amount1Out
  try {
    const clean = hexData.startsWith("0x") ? hexData.slice(2) : hexData;
    const words = [];
    for (let i = 0; i < 4; i++) {
      const word = clean.slice(i * 64, (i + 1) * 64);
      words.push(BigInt("0x" + word));
    }
    const [amount0In, amount1In, amount0Out, amount1Out] = words;
    // OSG could be token0 or token1 depending on pair sort order — we don't know which
    // without querying token0()/token1(); as a v1 approximation we sum in+out on both
    // sides and let the frontend label it as "pool volume" rather than exact OSG amount.
    const totalRaw = amount0In + amount1In + amount0Out + amount1Out;
    return Number(totalRaw) / 1e18; // approximate, assumes 18 decimals both sides
  } catch (e) {
    return 0;
  }
}

function emptyDayBucket() {
  return {
    transfers: 0,
    transferVolume: 0,
    swaps: 0,
    swapVolumeOSG: 0,
    stakingActivity: 0,
    p2pActivity: 0,
  };
}

module.exports = async (req, res) => {
  try {
    const latestBlock = await getLatestBlock();
    const fromBlock = Math.max(0, latestBlock - DAYS_BACK * BLOCKS_PER_DAY_APPROX);

    // Fetch logs for all 4 contracts in parallel
    const [tokenLogs, poolLogs, stakingLogs, p2pLogs] = await Promise.all([
      getLogs(ADDR.token, fromBlock, latestBlock),
      getLogs(ADDR.pool, fromBlock, latestBlock),
      getLogs(ADDR.staking, fromBlock, latestBlock),
      getLogs(ADDR.p2p, fromBlock, latestBlock),
    ]);

    // Build a map of date -> bucket
    const buckets = {};
    function bucketFor(dateKey) {
      if (!buckets[dateKey]) buckets[dateKey] = emptyDayBucket();
      return buckets[dateKey];
    }

    // Token Transfer events
    for (const log of tokenLogs) {
      if (!log.topics || log.topics[0] !== TOPIC_TRANSFER) continue;
      const dateKey = hexToDateKey(log.timeStamp);
      const bucket = bucketFor(dateKey);
      bucket.transfers += 1;
      bucket.transferVolume += hexToTokenAmount(log.data, 18);
    }

    // QuickSwap Pool Swap events
    for (const log of poolLogs) {
      if (!log.topics || log.topics[0] !== TOPIC_SWAP_V2) continue;
      const dateKey = hexToDateKey(log.timeStamp);
      const bucket = bucketFor(dateKey);
      bucket.swaps += 1;
      bucket.swapVolumeOSG += decodeSwapAmounts(log.data);
    }

    // Staking contract — ALL events counted generically (exact event names not yet mapped)
    for (const log of stakingLogs) {
      if (!log.timeStamp) continue;
      const dateKey = hexToDateKey(log.timeStamp);
      const bucket = bucketFor(dateKey);
      bucket.stakingActivity += 1;
    }

    // P2P Exchange — ALL events counted generically (exact event names not yet mapped)
    for (const log of p2pLogs) {
      if (!log.timeStamp) continue;
      const dateKey = hexToDateKey(log.timeStamp);
      const bucket = bucketFor(dateKey);
      bucket.p2pActivity += 1;
    }

    // Build ordered array of last DAYS_BACK days (oldest -> newest), filling zeros for empty days
    const days = [];
    const now = new Date();
    for (let i = DAYS_BACK - 1; i >= 0; i--) {
      const d = new Date(now);
      d.setUTCDate(d.getUTCDate() - i);
      const dateKey = d.toISOString().slice(0, 10);
      const bucket = buckets[dateKey] || emptyDayBucket();
      days.push({ date: dateKey, ...bucket });
    }

    const today = days[days.length - 1];

    res.setHeader("Cache-Control", "s-maxage=120, stale-while-revalidate=300");
    res.status(200).json({ today, days });
  } catch (err) {
    res.status(500).json({ error: err.message || "Unknown error in admin-analytics" });
  }
};
