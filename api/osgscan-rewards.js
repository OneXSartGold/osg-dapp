import { JsonRpcProvider, Interface, formatUnits, getAddress } from "ethers";

const RPC_URLS = [
  "https://rpc.ankr.com/polygon",
  "https://polygon-rpc.com",
  "https://polygon-bor-rpc.publicnode.com",
  "https://polygon.drpc.org",
];

const POOL = "0xDc4fE983ed301AD42F4E4C43951aa07A7a182855";
const DEPLOY_BLOCK = 88008677;
const CHUNK = 3000;

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
      return { logs: logs, provider: p };
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
      return { number: n, provider: p };
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

export default async function handler(req, res) {
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

    const latestInfo = await getBlockNumberAnyRpc();
    const latest = latestInfo.number;

    const userTopic =
      "0x000000000000000000000000" + wallet.slice(2).toLowerCase();

    const distributedTopic = IFACE.getEvent("Distributed").topicHash;
    const claimedTopic = IFACE.getEvent("Claimed").topicHash;

    const blockTimeCache = {};
    const entries = [];

    let from = DEPLOY_BLOCK;
    while (from <= latest) {
      const to = Math.min(from + CHUNK - 1, latest);

      let logs = [];
      try {
        const r = await getLogsAnyRpc({
          address: POOL,
          fromBlock: from,
          toBlock: to,
          topics: [[distributedTopic, claimedTopic], userTopic],
        });
        logs = r.logs;
      } catch (chunkErr) {
        from = to + 1;
        continue;
      }

      for (const log of logs) {
        let parsed;
        try {
          parsed = IFACE.parseLog(log);
        } catch (e) {
          continue;
        }
        if (!parsed) continue;

        if (!blockTimeCache[log.blockNumber]) {
          try {
            const block = await getBlockAnyRpc(log.blockNumber);
            blockTimeCache[log.blockNumber] = block ? block.timestamp : 0;
          } catch (e) {
            blockTimeCache[log.blockNumber] = 0;
          }
        }
        const ts = blockTimeCache[log.blockNumber];

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

      from = to + 1;
    }

    entries.sort(function (a, b) {
      return b.ts - a.ts;
    });

    res.setHeader("Cache-Control", "s-maxage=60, stale-while-revalidate=180");
    res.status(200).json({ wallet: wallet, entries: entries });
  } catch (e) {
    res.status(500).json({ error: (e && e.message) || "Server error" });
  }
}
