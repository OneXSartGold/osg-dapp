// ══════════════════════════════════════════════════════════
//  OSG Contract Config — Polygon Mainnet (LIVE, June 2026)
//  Fresh 8-contract deployment. Referral is built into Staking.
// ══════════════════════════════════════════════════════════

export const ADDRESSES = {
  timelock: "0xE2E82A8ACdd3Af7FA74Eacb3331231A769d80D4c",
  rewardStorage: "0xa0b2DcB18Cf0BdF61bcB9D33F538167dF501BEcB",
  token: "0xba05176748347944CC26900c821AbFeBeBC57415",
  pool: "0x2633053377c49898341f8dC813B4A8c7c05668d8",
  staking: "0x048E814C02e85ec1438Ab8C1d2e9150A5289A886",
  bond: "0x06263828484e36106eDF20A6D5A38c3bE9612269",
  messenger: "0x29c63cd4C3F03B1f64e929b0b8baC691DEB5FA5c",
  mediaStorage: "0x88E64Cbc22a35c2928038f2bc13F06630C93D07A",
  // referral is built into staking (no separate contract)
  referral: "0x048E814C02e85ec1438Ab8C1d2e9150A5289A886",
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

// ── ERC20 (OSG Token) ─────────────────────────────────────
export const TOKEN_ABI = [
  "function balanceOf(address owner) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
];

// ── OSGStaking (referral built-in) ────────────────────────
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

// QuickSwap swap link (until liquidity pool exists)
export const QUICKSWAP_URL =
  "https://quickswap.exchange/#/swap?outputCurrency=" + ADDRESSES.token;
