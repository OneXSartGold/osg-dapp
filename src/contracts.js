// ======================================================================
//  OSG Contract Config -- Polygon Mainnet (LIVE, June 2026)
//  Fresh 8-contract deployment. Referral is built into Staking.
// ======================================================================

export const ADDRESSES = {
  timelock: "0xE2E82A8ACdd3Af7FA74Eacb3331231A769d80D4c",
  rewardStorage: "0xa0b2DcB18Cf0BdF61bcB9D33F538167dF501BEcB",
  token: "0xba05176748347944CC26900c821AbFeBeBC57415",
  pool: "0xDc4fE983ed301AD42F4E4C43951aa07A7a182855",
  staking: "0x048E814C02e85ec1438Ab8C1d2e9150A5289A886",
  bond: "0x06263828484e36106eDF20A6D5A38c3bE9612269",
  messenger: "0x29c63cd4C3F03B1f64e929b0b8baC691DEB5FA5c",
  mediaStorage: "0x88E64Cbc22a35c2928038f2bc13F06630C93D07A",
  // referral is built into staking (no separate contract)
  referral: "0x048E814C02e85ec1438Ab8C1d2e9150A5289A886",
  referralDistributor: "0x4f1eFf6Fc4A0271096dD78B6F6284D4c9f1904F1",
  p2pExchange: "0xDc172cbbB940C8AF717De1cB46a89a6d91aFa567",
  // -- QuickSwap (for in-app Add Liquidity) --
  quickswapRouter: "0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff",
  wpol: "0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270",
  lpPair: "0xA15214B09a9b3E1c821B94fB97d6d3BcA8201Cd2",
  // -- LP Mining (Stage 1, live) --
  lpMining: "0xF534adff723b5c89AD86343B9E4b1E64E6c82aba",
  lpReferral: "0xFa1CC9D7a9643156d797142D47e3930895401565",
};

export const ZERO = "0x0000000000000000000000000000000000000000";

export const POLYGON_CHAIN_ID = "0x89"; // 137
export const POLYGON_PARAMS = {
  chainId: "0x89",
  chainName: "Polygon Mainnet",
  nativeCurrency: { name: "POL", symbol: "POL", decimals: 18 },
  rpcUrls: ["https://polygon-rpc.com"],
  blockExplorerUrls: ["https://polygonscan.com"],
};
// -- Read RPCs (fallback order: first that responds wins) --
export const RPC_URLS = [
  "https://polygon-mainnet.g.alchemy.com/v2/ZyChInaPXbkZQdhA0Ep_V",
  "https://polygon-bor-rpc.publicnode.com",
  "https://rpc.ankr.com/polygon",
  "https://polygon-rpc.com",
];
// -- ERC20 (OSG Token) --
export const TOKEN_ABI = [
  "function balanceOf(address owner) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
];

// -- OSGStaking (referral built-in) --
export const STAKING_ABI = [
  // writes
  "function stake(uint256 amount, address referrer)",
  "function addToStake(uint256 amount)",
  "function requestUnstake()",
  "function unstake()",
  "function cancelUnstake()",
  "function claimReward()",
  // reads
  "function getUserStakingInfo(address _user) view returns (uint256 staked, uint256 pendingStaking, uint256 nextClaimChunk, uint256 rewardPoolPending, uint256 unstakeRequestAt, uint256 unstakeAvailableAt, bool canUnstakeNow, bool unstakePending, uint256 totalEarned, uint256 stakedAt, uint256 sharePercent)",
  "function getUserReferralInfo(address _user) view returns (address referrer, uint256 totalReferrals, uint256 totalReferralEarned, uint256 pendingReferral, uint256 teamBonusEarned, uint256 totalTeamVolume)",
  "function getReferralChain(address _user) view returns (address l1, address l2, address l3, address l4, address l5)",
  "function getDirectReferrals(address _user) view returns (address[])",
  "function getPoolInfo() view returns (uint256 staked, uint256 totalUsersEver, uint256 currentActiveStakers, uint256 accRPS, uint256 dailyStakingEmission, uint256 rewardDistributed, uint256 referralAccrued, uint256 pendingReferralTotal, uint256 referralReserveAmt, uint256 teamBonusReserveAmt, uint256 teamBonusAmt, bool isPaused, bool emissionActive)",
  "function getEmissionSchedule() view returns (uint256 currentDailyBase, uint256 stakingDailyEmission, uint256 halvingNumber, uint256 emissionEndsAt, uint256 emissionEndsIn, uint256 timeToNextHalving, bool emissionStopped, bool emissionEnded)",
  "function pendingReward(address _user) view returns (uint256)",
  "function canClaimNow(address user) view returns (bool canClaim, uint256 amount, uint256 total, string reason)",
  "function totalStaked() view returns (uint256)",
  "function MIN_STAKE() view returns (uint256)",
  "function MIN_CLAIM() view returns (uint256)",
  "function UNSTAKE_COOLDOWN() view returns (uint256)",
  "function referralEnabled() view returns (bool)",
  "function paused() view returns (bool)",
  "function checkReferrerEligibility(address referrer) view returns (bool eligible, uint8 reasonCode)",
];

// -- OSGMessenger v7 (text chat: cid carries the text, fileType="text") --
export const MESSENGER_ABI = [
  // writes
  "function sendMessage(address to, string cid, string fileType) payable",
  "function markAsRead(uint256 index)",
  "function deleteMessage(uint256 index)",
  "function setPublicKey(string pubKey)",
  // reads
  "function getMessages(uint256 start, uint256 limit) view returns (tuple(address from, string cid, string fileType, uint256 timestamp, bool isRead, bool isDeleted)[])",
  "function getActiveMessages(uint256 start, uint256 limit) view returns (tuple(address from, string cid, string fileType, uint256 timestamp, bool isRead, bool isDeleted)[])",
  "function getInboxLength(address user) view returns (uint256)",
  "function unreadCount(address) view returns (uint256)",
  "function getUserFee(address user) view returns (uint256)",
  "function getMaticFee() view returns (uint256)",
  "function useOSGFee() view returns (bool)",
  "function messagingFeeOSG() view returns (uint256)",
  "function cooldown() view returns (uint256)",
  "function lastSent(address) view returns (uint256)",
  "function paused() view returns (bool)",
  "function publicKeys(address) view returns (string)",
];

// -- OSGRewardPool v2 (chunked claim -- mints OSG to wallet) --
//  The DApp claim now does TWO steps:
//   1. Staking.claimReward()  -> moves pending into RewardStorage
//   2. RewardPool.claim()     -> mints up to 500 OSG/call to wallet
//  This ABI is what step 2 needs.
export const POOL_ABI = [
  // write: pulls reward from storage and mints up to claimChunk (<=500 OSG)
  "function claim()",
  // reads (handy for showing the real claimable chunk / pending)
  "function claimChunk() view returns (uint256)",
  "function getUserReward(address user) view returns (uint256)",
  "function paused() view returns (bool)",
];

// -- OSGP2PExchangeV2 (order-book based P2P trading, pairId=1 = OSG/POL) --
//  v2 keeps buy orders and sell orders in SEPARATE per-pair id lists
//  (pairBuyOrderIds / pairSellOrderIds), each indexed (pairId, index).
//  Auto-matching happens inside placeBuyOrder / placeSellOrder itself;
//  acceptOrder() is kept for the existing tap-to-trade flow.
export const P2P_ABI = [
  "error EnforcedPause()",
  "error ExpectedPause()",
  "error OwnableInvalidOwner(address owner)",
  "error OwnableUnauthorizedAccount(address account)",
  "error ReentrancyGuardReentrantCall()",
  "error SafeERC20FailedOperation(address token)",
  // writes
  "function placeBuyOrder(uint256 pairId, uint128 price, uint128 amount, uint40 expiryTime) payable returns (uint256 orderId)",
  "function placeSellOrder(uint256 pairId, uint128 price, uint128 amount, uint40 expiryTime) returns (uint256 orderId)",
  "function acceptOrder(uint256 pairId, bool wantBuy, uint128 amount, uint128 priceLimit, uint256 startFrom, uint256 maxScan) payable returns (uint256 filledAmount, uint256 nextScanIndex)",
  "function cancelOrder(uint256 orderId)",
  "function cancelExpiredOrder(uint256 orderId)",
  // reads
  "function orders(uint256) view returns (address user, uint256 pairId, bool isBuy, uint128 price, uint128 amount, uint40 timestamp, uint40 expiryTime, uint8 status)",
  "function pairs(uint256) view returns (address token, bool active, uint256 minAmount)",
  "function orderCounter() view returns (uint256)",
  "function pairCounter() view returns (uint256)",
  "function pairBuyOrderIds(uint256, uint256) view returns (uint256)",
  "function pairSellOrderIds(uint256, uint256) view returns (uint256)",
  "function pairBuyOrderIdsLength(uint256 pairId) view returns (uint256)",
  "function pairSellOrderIdsLength(uint256 pairId) view returns (uint256)",
  "function userBuyPriceOrder(address, uint256, uint256) view returns (uint256)",
  "function userSellPriceOrder(address, uint256, uint256) view returns (uint256)",
  "function feeBps() view returns (uint256)",
  "function feeCollector() view returns (address)",
  "function MAX_FEE_BPS() view returns (uint256)",
  "function MAX_SCAN() view returns (uint256)",
  "function MAX_MATCH() view returns (uint256)",
  "function AUTO_MATCH_SCAN() view returns (uint256)",
  "function PRICE_SCALE() view returns (uint256)",
  "function paused() view returns (bool)",
  "function tokenRegistered(address) view returns (bool)",
  // events (for reading order-book / history via getLogs later)
  "event OrderPlaced(uint256 indexed orderId, address indexed user, uint256 indexed pairId, bool isBuy, uint256 price, uint256 amount, uint256 expiryTime)",
  "event OrderFilled(uint256 indexed orderId, address indexed taker, uint256 filledAmount, uint256 remainingAmount)",
  "event OrderCancelled(uint256 indexed orderId, address indexed user, uint256 refundedAmount)",
  "event OrderMerged(uint256 indexed orderId, address indexed user, uint256 addedAmount, uint256 newTotalAmount, uint256 newExpiryTime)",
];

// -- Router (for in-app Add Liquidity via addLiquidityETH) --
export const ROUTER_ABI = [
  "function addLiquidityETH(address token, uint amountTokenDesired, uint amountTokenMin, uint amountETHMin, address to, uint deadline) external payable returns (uint amountToken, uint amountETH, uint liquidity)",
  "function getAmountsOut(uint amountIn, address[] memory path) public view returns (uint[] memory amounts)",
];

// -- OSG/WPOL LP Pair (for reading live reserves/ratio) --
export const PAIR_ABI = [
  "function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)",
  "function token0() external view returns (address)",
  "function token1() external view returns (address)",
];

// -- LP Token (ERC20-style, same shape as TOKEN_ABI) --
export const LP_TOKEN_ABI = [
  "function balanceOf(address owner) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
];

// -- OSGLPMining v5 (LP Mining, category-2 distributor) --
export const LP_MINING_ABI = [
  // writes
  "function deposit(uint8 tierId, uint256 lpAmount)",
  "function withdraw(uint8 tierId, uint256 lpAmount)",
  "function claim(uint8 tierId)",
  // reads
  "function pendingMiningReward(address user, uint8 tierId) view returns (uint256)",
  "function tiers(uint8) view returns (uint256 minDeposit, uint256 capacityLp, uint256 totalDepositedLp, bool active, uint256 tierWeightBps, uint256 accRewardPerShare, uint256 lastRewardTime)",
  "function userTier(address, uint8) view returns (uint256 lpAmount, uint256 rewardDebt)",
  "function firstDepositTime(address) view returns (uint256)",
  "function isWiredForMining() view returns (bool)",
  "function getLpMiningDailyBudget() view returns (uint256)",
  "function getTierDailyBudget(uint8 tierId) view returns (uint256)",
  "function tierCapacityLp(uint8 tierId) view returns (uint256)",
  "function referralContract() view returns (address)",
  "function paused() view returns (bool)",
  "function miningShareBps() view returns (uint256)",
  "function FIRST_WITHDRAW_LOCK() view returns (uint256)",
  // events
  "event Deposited(address indexed user, uint8 tier, uint256 lpAmount)",
  "event Withdrawn(address indexed user, uint8 tier, uint256 lpAmount)",
  "event MiningClaimed(address indexed user, uint8 tier, uint256 amount)",
];

// -- OSGLPReferral v1 (LP Mining Referral, category-3 distributor) --
export const LP_REFERRAL_ABI = [
  // reads
  "function getCurrentRank(address user) view returns (uint8)",
  "function teamLiquidityLp(address) view returns (uint256)",
  "function qualifiedSince(address) view returns (uint256)",
  "function highestRankPaid(address) view returns (uint8)",
  "function poolCapacityLp() view returns (uint256)",
  "function owed(address user) view returns (uint256)",
  "function levelCommissionOwed(address) view returns (uint256)",
  "function levelCommissionPaid(address) view returns (uint256)",
  "function milestoneBonusOwed(address) view returns (uint256)",
  "function milestoneBonusPaid(address) view returns (uint256)",
  "function rankThresholdBps(uint256) view returns (uint256)",
  "function rankBonusBps(uint256) view returns (uint256)",
  "function getRecurringBonusBps(address user) view returns (uint256)",
  "function isWiredForReferral() view returns (bool)",
  "function MAINTAIN_PERIOD() view returns (uint256)",
  "function lpMining() view returns (address)",
  // events
  "event LevelCommissionAccrued(address indexed referrer, address indexed from, uint256 amount, uint8 level)",
  "event MilestoneBonusAccrued(address indexed user, uint8 rank, uint256 amount)",
  "event RecurringBonusPaid(address indexed user, uint256 amount, uint256 bps)",
];
// QuickSwap swap link (until liquidity pool exists)
export const QUICKSWAP_URL =
  "https://quickswap.exchange/#/swap?outputCurrency=" + ADDRESSES.token;
