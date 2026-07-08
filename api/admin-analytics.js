export default async function handler(req, res) {
  const ETHERSCAN_BASE = "https://api.etherscan.io/v2/api";
  const CHAIN_ID = 137;
  const ADDR = {
    token:   "0xba05176748347944CC26900c821AbFeBeBC57415",
    pool:    "0xA15214B09a9b3E1c821B94fB97d6d3BcA8201Cd2",
    staking: "0x048E814C02e85ec1438Ab8C1d2e9150A5289A886",
    p2p:     "0x72A4387cC07cF105fEec4615b40d2EF9ca0AEE6B",
  };
  const BLOCKS_PER_DAY_APPROX = 43200;
  const DAYS_BACK = 8;

  async function callEtherscan(params) {
    const apikey = process.env.POLYGONSCAN_KEY;
    const qs = new URLSearchParams({ chainid: String(CHAIN_ID), apikey, ...params });
    const url = ETHERSCAN_BASE + "?" + qs.toString();
    const r = await fetch(url);
    const j = await r.json();
    return j;
  }

  try {
    const bn = await callEtherscan({ module: "proxy", action: "eth_blockNumber" });
    const latestBlock = parseInt(bn.result, 16);
    const fromBlock = Math.max(0, latestBlock - DAYS_BACK * BLOCKS_PER_DAY_APPROX);

    const debug = {};
    async function debugLogs(name, address) {
      const j = await callEtherscan({
        module: "logs", action: "getLogs", address,
        fromBlock: String(fromBlock), toBlock: String(latestBlock),
      });
      debug[name] = {
        status: j.status,
        message: j.message,
        resultIsArray: Array.isArray(j.result),
        resultCount: Array.isArray(j.result) ? j.result.length : null,
        resultIfNotArray: Array.isArray(j.result) ? undefined : j.result,
      };
    }

    await debugLogs("token", ADDR.token);
    await debugLogs("pool", ADDR.pool);
    await debugLogs("staking", ADDR.staking);
    await debugLogs("p2p", ADDR.p2p);

    res.status(200).json({ latestBlock, fromBlock, debug });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
}
