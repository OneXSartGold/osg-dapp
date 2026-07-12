import { JsonRpcProvider, Interface, formatUnits, getAddress } from "ethers";

// NOTE: ankr / polygon-rpc / publicnode now require paid API keys and
// were removed from this list since every call to them failed (401/403).
// Add a second real RPC key here later for redundancy if needed.
const RPC_LIST = [
  { name: "alchemy", url: "https://polygon-mainnet.g.alchemy.com/v2/ZyChInaPXbkZQdhA0Ep_V" },
];

const POOL = "0xDc4fE983ed301AD42F4E4C43951aa07A7a182855";
const DEPLOY_BLOCK = 88008677;
const CHUNK = 8000;
const CONCURRENCY = 2;
const HARD_DEADLINE_MS = 50000;
const RPC_CALL_TIMEOUT_MS = 12000;
const CHUNK_RETRIES = 2;
const MAX_BLOCKS_PER_REQUEST = 300000;

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

function timeLeft(deadlineAt) {
  return deadlineAt - Date.now();
}

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
for (const rpc of RPC_LIST) providerStats[rpc.name] = { success: 0, fail: 0, lastError: null };

async function getLogsOnePass(params, deadlineAt) {
  let lastErr = null;
  for (const rpc of RPC_LIST) {
    const remaining = timeLeft(deadlineAt);
    if (remaining <= 500) {
      throw new Error("Global deadline reached, skipping remaining RPCs");
    }
    try {
      const p = getProviderFor(rpc.url);
      const callTimeout = Math.min(RPC_CALL_TIMEOUT_MS, remaining);
      const logs = await withTimeout(p.getLogs(params), callTimeout);
      providerStats[rpc.name].success++;
      return { logs: logs, provider: rpc.name };
    } catch (e) {
      providerStats[rpc.name].fail++;
      providerStats[rpc.name].lastError = (e && e.message) || String(e);
      lastErr = e;
      continue;
    }
  }
  throw lastErr || new Error("All RPCs failed for getLogs");
}

async function getLogsWithRetry(params, deadlineAt) {
  let lastErr = null;
  for (let attempt = 0; attempt < CHUNK_RETRIES; attempt++) {
    if (timeLeft(deadlineAt) <= 500) {
      throw lastErr || new Error("Global deadline reached before retry");
    }
    try {
      return await getLogsOnePass(params, deadlineAt);
    } catch (e) {
      lastErr = e;
      if (attempt < CHUNK_RETRIES - 1 && timeLeft(deadlineAt) > 1000) {
        await sleep(250);
      }
    }
  }
  throw lastErr || new Error("getLogs failed after retries");
}

async function getBlockNumberAnyRpc(deadlineAt) {
  let lastErr = null;
  for (const rpc of RPC_LIST) {
    const remaining = timeLeft(deadlineAt);
    if (remaining <= 500) break;
    try {
      const p = getProviderFor(rpc.url);
      const n = await withTimeout(p.getBlockNumber(), Math.min(RPC_CALL_TIMEOUT_MS, remaining));
      return n;
    } catch (e) {
      lastErr = e;
      continue;
    }
  }
  throw lastErr || new Error("All RPCs failed for getBlockNumber");
}

async function getBlockAnyRpc(blockNumber, deadlineAt) {
  let lastErr = null;
  for (const rpc of RPC_LIST) {
    const remaining = timeLeft(deadlineAt);
    if (remaining <= 300) break;
    try {
      const p = getProviderFor(rpc.url);
      const b = await withTimeout(p.getBlock(blockNumber), Math.min(RPC_CALL_TIMEOUT_MS, remaining));
      if (b) return b;
    } catch (e) {
      lastErr = e;
      continue;
    }
  }
  throw lastErr || new Error("All RPCs failed for getBlock");
}

async function runPool(items, worker, concurrency, deadlineAt) {
  const results = new Array(items.length);
  const skipped = [];
  let idx = 0;
  async function runner() {
    while (idx < items.length) {
      if (timeLeft(deadlineAt) <= 500) {
        while (idx < items.length) {
          skipped.push(items[idx]);
          results[idx] = null;
          idx++;
        }
        return;
      }
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
  return { results: results, skipped: skipped };
}

export default async function handler(req, res) {
  const startedAt = Date.now();
  const deadlineAt = startedAt + HARD_DEADLINE_MS;
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

    const latest = await getBlockNumberAnyRpc(deadlineAt);

    const userTopic =
      "0x000000000000000000000000" + wallet.slice(2).toLowerCase();
    const distributedTopic = IFACE.getEvent("Distributed").topicHash;
    const claimedTopic = IFACE.getEvent("Claimed").topicHash;

    const scanStartBlock = Math.max(DEPLOY_BLOCK, latest - MAX_BLOCKS_PER_REQUEST);
    const olderHistoryNotScanned = scanStartBlock > DEPLOY_BLOCK;

    const ranges = [];
    let to = latest;
    while (to >= scanStartBlock) {
      const from = Math.max(to - CHUNK + 1, scanStartBlock);
      ranges.push([from, to]);
      to = from - 1;
    }

    let failedChunkCount = 0;
    const chunkDebug = [];

    const poolResult = await runPool(
      ranges,
      async function (range) {
        try {
          const result = await getLogsWithRetry(
            {
              address: POOL,
              fromBlock: range[0],
              toBlock: range[1],
              topics: [[distributedTopic, claimedTopic], userTopic],
            },
            deadlineAt,
          );
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
            "osgscan-rewards: chunk failed",
            range[0],
            range[1],
            (e && e.message) || e,
          );
          return [];
        }
      },
      CONCURRENCY,
      deadlineAt,
    );

    const chunkResults = poolResult.results;
    const timedOut = poolResult.skipped.length > 0;

    const allLogs = [];
    for (const logs of chunkResults) {
      if (logs) for (const l of logs) allLogs.push(l);
    }

    const blockTimeCache = {};
    const uniqueBlocks = Array.from(
      new Set(allLogs.map(function (l) { return l.blockNumber; })),
    );

    const tsPoolResult = await runPool(
      uniqueBlocks,
      async function (bn) {
        try {
          const b = await getBlockAnyRpc(bn, deadlineAt);
          blockTimeCache[bn] = b ? b.timestamp : 0;
        } catch (e) {
          blockTimeCache[bn] = 0;
        }
      },
      CONCURRENCY,
      deadlineAt,
    );
    const timestampsTruncated = tsPoolResult.skipped.length > 0;

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
