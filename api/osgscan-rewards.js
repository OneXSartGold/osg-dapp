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
const SCAN_BUDGET_MS = 28000;
const HARD_DEADLINE_MS = 50000;
const CHUNK_RETRIES = 3;
const RPC_CALL_TIMEOUT_MS = 8000; // any single RPC call gets killed after this
const MAX_BLOCKS_PER_REQUEST = 500000; // only scan recent ~500k blocks per request

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

// Wraps any promise so it never blocks execution longer than ms
function withTimeout(promise, ms) {
  return Promise.race([
    promise,
    new Promise(function (_, reject) {
      setTimeout(function () {
        reject(new Error("RPC call timed out after " + ms + "ms"));
      }, ms);
    }),
  ]);
}

const providerStats = {};
for (const rpc of RPC_LIST) providerStats[rpc.name] = { success: 0, fail: 0 };

async function getLogsOnePass(params) {
  let lastErr = null;
  for (const rpc of RPC_LIST) {
    try {
      const p = getProviderFor(rpc.url);
      const logs = await withTimeout(p.getLogs(params), RPC_CALL_TIMEOUT_MS);
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
      const n = await withTimeout(p.getBlockNumber(), RPC_CALL_TIMEOUT_MS);
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
      const b = await withTimeout(p.getBlock(blockNumber), RPC_CALL_TIMEOUT_MS);
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

    // Only scan the most recent MAX_BLOCKS_PER_REQUEST blocks in one call.
    // Older history (before scanStartBlock) is not covered by this request.
    const scanStartBlock = Math.max(DEPLOY_BLOCK, latest - MAX_BLOCKS_PER_REQUEST);
    const olderHistoryNotScanned = scanStartBlock > DEPLOY_BLOCK;

    const ranges = [];
    let to = latest;
    while (to >= scanStartBlock) {
      const from = Math.max(to - CHUNK + 1, scanStartBlock);
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
      scannedFrom: scanStartBlock,
      olderHistoryNotScanned: olderHistoryNotScanned,
      latestBlock: latest,
      providerStats: providerStats,
      chunkDebug: chunkDebug,
    });
  } catch (e) {
    res.status(500).json({ error: (e && e.message) || "Server error" });
  }
}
