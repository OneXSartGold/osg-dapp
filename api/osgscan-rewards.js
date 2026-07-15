import { Interface, formatUnits, getAddress } from "ethers";

const POOL = "0xDc4fE983ed301AD42F4E4C43951aa07A7a182855";
const DEPLOY_BLOCK = 88008677;
const ETHERSCAN_API_KEY = process.env.POLYGONSCAN_KEY;
const CHAIN_ID = 137;
const HARD_DEADLINE_MS = 45000;
const REQUEST_TIMEOUT_MS = 15000;
const PAGE_SIZE = 1000;
const MAX_PAGES = 10;

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

function timeLeft(deadlineAt) {
  return deadlineAt - Date.now();
}

function withTimeout(promise, ms) {
  return Promise.race([
    promise,
    new Promise(function (_, reject) {
      setTimeout(function () {
        reject(new Error("Request timed out after " + ms + "ms"));
      }, ms);
    }),
  ]);
}

// Etherscan's getLogs endpoint only matches one topic0 value at a time
// (no OR array like raw eth_getLogs), so Distributed and Claimed are
// fetched as two separate calls and merged.
async function fetchLogsForTopic(topic0, userTopic, deadlineAt) {
  const allItems = [];
  for (let page = 1; page <= MAX_PAGES; page++) {
    const remaining = timeLeft(deadlineAt);
    if (remaining <= 1000) break;

    const url =
      "https://api.etherscan.io/v2/api" +
      "?chainid=" + CHAIN_ID +
      "&module=logs&action=getLogs" +
      "&address=" + POOL +
      "&fromBlock=" + DEPLOY_BLOCK +
      "&toBlock=latest" +
      "&topic0=" + topic0 +
      "&topic1=" + userTopic +
      "&topic0_1_opr=and" +
      "&page=" + page +
      "&offset=" + PAGE_SIZE +
      "&apikey=" + ETHERSCAN_API_KEY;

    const callTimeout = Math.min(REQUEST_TIMEOUT_MS, remaining);
    let json;
    try {
      const resp = await withTimeout(fetch(url), callTimeout);
      json = await resp.json();
    } catch (e) {
      throw new Error("Etherscan request failed: " + ((e && e.message) || e));
    }

    if (json.status === "0") {
      if (json.message === "No records found") break;
      throw new Error("Etherscan error: " + json.message + " - " + (json.result || ""));
    }

    const items = json.result || [];
    for (const it of items) allItems.push(it);

    if (items.length < PAGE_SIZE) break;
  }
  return allItems;
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

    const userTopic = "0x000000000000000000000000" + wallet.slice(2).toLowerCase();
    const distributedTopic = IFACE.getEvent("Distributed").topicHash;
    const claimedTopic = IFACE.getEvent("Claimed").topicHash;

    let distributedItems = [];
    let claimedItems = [];
    let errorMsg = null;

    try {
      distributedItems = await fetchLogsForTopic(distributedTopic, userTopic, deadlineAt);
    } catch (e) {
      errorMsg = (e && e.message) || String(e);
    }
    try {
      claimedItems = await fetchLogsForTopic(claimedTopic, userTopic, deadlineAt);
    } catch (e) {
      errorMsg = errorMsg || (e && e.message) || String(e);
    }

    const allItems = distributedItems.concat(claimedItems);

    const entries = [];
    for (const it of allItems) {
      let parsed;
      try {
        parsed = IFACE.parseLog({ topics: it.topics, data: it.data });
      } catch (e) {
        continue;
      }
      if (!parsed) continue;

      const ts = parseInt(it.timeStamp, 16) || 0;

      if (parsed.name === "Distributed") {
        entries.push({
          type: categoryLabel(Number(parsed.args.category)),
          amount: formatUnits(parsed.args.amount, 18),
          ts: ts,
          txHash: it.transactionHash,
        });
      } else if (parsed.name === "Claimed") {
        entries.push({
          type: "claimed",
          amount: formatUnits(parsed.args.amount, 18),
          ts: ts,
          txHash: it.transactionHash,
        });
      }
    }

    entries.sort(function (a, b) {
      return b.ts - a.ts;
    });

    res.setHeader("Cache-Control", "s-maxage=60, stale-while-revalidate=180");
    res.status(200).json({
      wallet: wallet,
      entries: entries,
      partial: !!errorMsg,
      error: errorMsg,
      scannedFrom: DEPLOY_BLOCK,
      source: "etherscan-v2-api",
    });
  } catch (e) {
    res.status(500).json({ error: (e && e.message) || "Server error" });
  }
}
