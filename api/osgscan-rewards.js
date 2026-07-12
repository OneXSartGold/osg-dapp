import { JsonRpcProvider, Interface, formatUnits, getAddress } from "ethers";

const RPC_URLS = [
  "https://polygon-mainnet.g.alchemy.com/v2/ZyChInaPXbkZQdhA0Ep_V",
  "https://rpc.ankr.com/polygon",
  "https://polygon-rpc.com",
  "https://polygon-bor-rpc.publicnode.com",
];

const POOL = "0xDc4fE983ed301AD42F4E4C43951aa07A7a182855";
const DEPLOY_BLOCK = 88008677;
const CHUNK = 3000;
const CONCURRENCY = 8;
const TIME_BUDGET_MS = 50000;

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

async function getLogsAnyRpc(params) {
  let lastErr = null;
  for (const url of RPC_URLS) {
    try {
      const p = getProviderFor(url);
      const logs = await p.getLogs(params);
      return logs;
    } catch (e) {
      lastErr = e;
      continue;
    }
  }
  throw lastErr || new Error("All RPCs failed for getLogs");
}

async function getBlockNumberAnyRpc() {
  let lastErr = null;
  for (const url of RPC_URLS) {
    try {
      const p = getProviderFor(url);
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
  for (const url of RPC_URLS) {
    try {
      const p = getProviderFor(url);
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

    const ranges = [];
    let from = DEPLOY_BLOCK;
    while (from <= latest) {
      const to = Math.min(from + CHUNK - 1, latest);
      ranges.push([from, to]);
      from = to + 1;
    }

    let partial = false;
    const cutRanges = [];
    for (const r of ranges) {
      if (Date.now() - startedAt > TIME_BUDGET_MS) {
        partial = true;
        break;
      }
      cutRanges.push(r);
    }

    const chunkResults = await runPool(
      cutRanges,
      async function (range) {
        try {
          return await getLogsAnyRpc({
            address: POOL,
            fromBlock: range[0],
            toBlock: range[1],
            topics: [[distributedTopic, claimedTopic], userTopic],
          });
        } catch (e) {
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
    await runPool(
      uniqueBlocks,
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

    res.setHeader("Cache-Control", "s-maxage=60, stale-while-revalidate=180");
    res.status(200).json({ wallet: wallet, entries: entries, partial: partial });
  } catch (e) {
    res.status(500).json({ error: (e && e.message) || "Server error" });
  }
}
