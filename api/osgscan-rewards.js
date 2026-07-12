import { JsonRpcProvider, Interface, formatUnits, getAddress } from "ethers";

const RPC_LIST = [
  { name: "alchemy", url: "https://polygon-mainnet.g.alchemy.com/v2/ZyChInaPXbkZQdhA0Ep_V" },
  { name: "ankr", url: "https://rpc.ankr.com/polygon" },
  { name: "polygon-rpc", url: "https://polygon-rpc.com" },
  { name: "publicnode", url: "https://polygon-bor-rpc.publicnode.com" },
];

const POOL = "0xDc4fE983ed301AD42F4E4C43951aa07A7a182855";
const DEPLOY_BLOCK = 88008677;
const CHUNK = 3000;
const CONCURRENCY = 8;
const SCAN_BUDGET_MS = 28000; // budget for the log-scanning phase
const HARD_DEADLINE_MS = 50000; // overall hard deadline for the whole function
const CHUNK_RETRIES = 3;

const IFACE = new Interface([
  "event Distributed(address indexed user, uint256 amount, uint8 indexed category)",
  "event Claimed(address indexed user, uint256 amount)",
]);

function categoryLabel(cat) {
  if (cat === 1) return "staking";
  if (cat === 2) return "mining";
  if (cat === 3) return "referral";
  return "other";
}

const providerCache = {};
function getProviderFor(url) {
  if (!providerCache[url]) {
    providerCache[url] = new JsonRpcProvider(url, 137, { batchMaxCount: 1 });
  }
  return providerCache[url];
}

function sleep(ms) {
  return new Promise(function (r) {
    setTimeout(r, ms);
  });
}

const providerStats = {};
for (const rpc of RPC_LIST) providerStats[rpc.name] = { success: 0, fail: 0 };

async function getLogsOnePass(params) {
  let lastErr = null;
  for (const rpc of RPC_LIST) {
    try {
      const p = getProviderFor(rpc.url);
      const logs = await p.getLogs(params);
      providerStats[rpc.name].success++;
      return { logs: logs, provider: rpc.name };
    } catch (e) {
      providerStats[rpc.name].fail++;
      lastErr = e;
      continue;
    }
  }
  throw lastErr || new Error("All RPCs failed for getLogs");
}

async function getLogsWithRetry(params) {
  let lastErr = null;
  for (let attempt = 0; attempt < CHUNK_RETRIES; attempt++) {
    try {
      return await getLogsOnePass(params);
    } catch (e) {
      lastErr = e;
      if (attempt < CHUNK_RETRIES - 1) await sleep(300 * (attempt + 1));
    }
  }
  throw lastErr || new Error("getLogs failed after retries");
}

async function getBlockNumberAnyRpc() {
  let lastErr = null;
  for (const rpc of RPC_LIST) {
    try {
      const p = getProviderFor(rpc.url);
      const n = await p.getBlockNumber();
      return n;
    } catch (e) {
      lastErr = e;
      continue;
    }
  }
  throw lastErr || new Error("All RPCs failed for getBlockNumber");
}

async function getBlockAnyRpc(blockNumber) {
  let lastErr = null;
  for (const rpc of RPC_LIST) {
    try {
      const p = getProviderFor(rpc.url);
      const b = await p.getBlock(blockNumber);
      if (b) return b;
    } catch (e) {
      lastErr = e;
      continue;
    }
  }
  throw lastErr || new Error("All RPCs failed for getBlock");
}

async function runPool(items, worker, concurrency) {
  const results = new Array(items.length);
  let idx = 0;
  async function runner() {
    while (idx < items.length) {
      const my = idx++;
      try {
        results[my] = await worker(items[my], my);
      } catch (e) {
        results[my] = null;
      }
    }
  }
  const runners = [];
  for (let i = 0; i < concurrency; i++) runners.push(runner());
  await Promise.all(runners);
  return results;
}

export default async function handler(req, res) {
  const startedAt = Date.now();
  try {
    const rawWallet = req.query.wallet;
    if (!rawWallet) {
      res.status(400).json({ error: "wallet query param required" });
      return;
    }
    let wallet;
    try {
      wallet = getAddress(rawWallet);
    } catch (e) {
      res.status(400).json({ error: "Invalid wallet address" });
      return;
    }

    const latest = await getBlockNumberAnyRpc();

    const userTopic =
      "0x000000000000000000000000" + wallet.slice(2).toLowerCase();
    const distributedTopic = IFACE.getEvent("Distributed").topicHash;
    const claimedTopic = IFACE.getEvent("Claimed").topicHash;

    // Scan latest -> oldest so recent history is covered first, even if we run out of time
    const ranges = [];
    let to = latest;
    while (to >= DEPLOY_BLOCK) {
      const from = Math.max(to - CHUNK + 1, DEPLOY_BLOCK);
      ranges.push([from, to]);
      to = from - 1;
    }

    let timedOut = false;
    const cutRanges = [];
    for (const r of ranges) {
      if (Date.now() - startedAt > SCAN_BUDGET_MS) {
        timedOut = true;
        break;
      }
      cutRanges.push(r);
    }

    let failedChunkCount = 0;
    const chunkDebug = [];

    const chunkResults = await runPool(
      cutRanges,
      async function (range) {
        try {
          const result = await getLogsWithRetry({
            address: POOL,
            fromBlock: range[0],
            toBlock: range[1],
            topics: [[distributedTopic, claimedTopic], userTopic],
          });
          if (result.logs.length > 0) {
            chunkDebug.push({
              from: range[0],
              to: range[1],
              count: result.logs.length,
              provider: result.provider,
            });
          }
          return result.logs;
        } catch (e) {
          failedChunkCount++;
          console.warn(
            "osgscan-rewards: chunk permanently failed",
            range[0],
            range[1],
            (e && e.message) || e,
          );
          return [];
        }
      },
      CONCURRENCY,
    );

    const allLogs = [];
    for (const logs of chunkResults) {
      if (logs) for (const l of logs) allLogs.push(l);
    }

    // Second phase: fetch block timestamps, but respect a hard deadline.
    // Any block whose timestamp we don't have time to fetch gets ts=0
    // (entry is NOT dropped, only its timestamp/sort position is approximate).
    const blockTimeCache = {};
    const uniqueBlocks = Array.from(
      new Set(allLogs.map(function (l) { return l.blockNumber; })),
    );

    let timestampsTruncated = false;
    const blocksInTime = [];
    for (const bn of uniqueBlocks) {
      if (Date.now() - startedAt > HARD_DEADLINE_MS - 5000) {
        timestampsTruncated = true;
        break;
      }
      blocksInTime.push(bn);
    }

    await runPool(
      blocksInTime,
      async function (bn) {
        try {
          const b = await getBlockAnyRpc(bn);
          blockTimeCache[bn] = b ? b.timestamp : 0;
        } catch (e) {
          blockTimeCache[bn] = 0;
        }
      },
      CONCURRENCY,
    );

    const entries = [];
    for (const log of allLogs) {
      let parsed;
      try {
        parsed = IFACE.parseLog(log);
      } catch (e) {
        continue;
      }
      if (!parsed) continue;
      const ts = blockTimeCache[log.blockNumber] || 0;

      if (parsed.name === "Distributed") {
        entries.push({
          type: categoryLabel(Number(parsed.args.category)),
          amount: formatUnits(parsed.args.amount, 18),
          ts: ts,
          txHash: log.transactionHash,
        });
      } else if (parsed.name === "Claimed") {
        entries.push({
          type: "claimed",
          amount: formatUnits(parsed.args.amount, 18),
          ts: ts,
          txHash: log.transactionHash,
        });
      }
    }

    entries.sort(function (a, b) {
      return b.ts - a.ts;
    });

    const partial = timedOut || failedChunkCount > 0 || timestampsTruncated;

    res.setHeader("Cache-Control", "s-maxage=60, stale-while-revalidate=180");
    res.status(200).json({
      wallet: wallet,
      entries: entries,
      partial: partial,
      timedOut: timedOut,
      timestampsTruncated: timestampsTruncated,
      failedChunkCount: failedChunkCount,
      scannedFrom: DEPLOY_BLOCK,
      latestBlock: latest,
      providerStats: providerStats,
      chunkDebug: chunkDebug,
    });
  } catch (e) {
    res.status(500).json({ error: (e && e.message) || "Server error" });
  }
}
