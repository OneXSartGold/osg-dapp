// ======================================================================
//  OSG Contract Config -- Polygon Mainnet
//  Updated 11 August 2026: Treasury, TermStaking v2, LPMining v7,
//  Referral v4.1 deployed and wired.
//  Updated 26 August 2026: P2P Exchange v3 is live on mainnet with two
//  pairs (1 = OSG/POL, 2 = OSG/USDT). p2pExchange now points at v3 and
//  P2P_ABI has been replaced wholesale -- see the note above it.
//
//  WHAT CHANGED FROM THE PREVIOUS FILE
//  -----------------------------------
//  - ADDRESSES: four new entries (treasury, termStakingV2, lpMiningV7,
//    referralV4). The old termStaking v1, lpMining v6 and referralV3
//    are kept ONLY as commented-out reference; nothing lives in them.
//  - TERM_STAKING_ABI is now v2. Same accumulator as v1, plus:
//    capacity (up-only), LOCK_PERIOD, stakedOf, capacityLeft,
//    lockRemaining, claimRange, withdrawRange, getPositions.
//  - LP_MINING_ABI is now v7. This is a DIFFERENT SHAPE from v6:
//    v6 tracked one total per wallet per tier; v7 tracks one record
//    per deposit. deposit() takes only lpAmount (no tierId), and every
//    read/write that used to take a tierId now takes a posId.
//  - LP_REFERRAL_ABI is retired. v7's referral hook points at
//    Referral v4.1, not at the old LPReferral v1 (which was never
//    wired to anything and holds nothing).
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
  p2pExchange: "0x269EcA6aDb7c9c1beFDc6c0be48a545b1920E1bb",
  // Polygon USDT is the quote token of P2P pair 2. It is a proxy and
  // has 6 decimals, not 18. Use TOKEN_ABI for approve/allowance.
  usdt: "0xc2132D05D31c914a87C6611C10748AEb04B58e8F",

  // -- QuickSwap (for in-app Add Liquidity) --
  quickswapRouter: "0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff",
  wpol: "0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270",
  lpPair: "0xA15214B09a9b3E1c821B94fB97d6d3BcA8201Cd2",

  // -- Live programme contracts (deployed 11 Aug 2026) --
  treasury: "0x4669b2d38098Ae28D0332F03D1630B334aDDDF50",
  termStaking: "0xb3DE3956DF62a069c9AC428Ec58120b3d9CD7cCc",
  lpMining: "0x4bFad548efD22e2fE75bBC77B6114380f8EF1bA3",
  referralV4: "0x82cfA8CB35176BAC5d9d2Ec791Aa22B33AbAA381",

  // -- Referral v4.2 set (deployed 17 Aug 2026) --
  // The ledger holds the money and the rules; the two lenses hold the
  // views and can be redeployed without touching a single balance.
  // referralV4 above stays live until Term and LP are pointed here.
  referralV42:    "0xeaB8a38660EB1556d5F7e52f48E407589B11437c",
  referralLens:   "0xa3Aa3d82a7aD78D9421934d740466F66600343A3",
  referralHealth: "0x909987447758C300C537d5a5CB25b1Ec2b7146cb",

  // -- Retired. Empty, unwired, kept only so old links resolve. --
  // termStakingV1: "0x9432B8C2B67C4c86c26EdB98893611013FAdF562",
  // lpMiningV6:    "0xb0510d6f707dF47fE7427732D5507290D847b736",
  // lpReferralV1:  "0xFa1CC9D7a9643156d797142D47e3930895401565",
  // referralV3:    "0x0A7a88B23076F35ee2c0B41E85a892C17ae2aC92",
  // p2pExchangeV2: "0xDc172cbbB940C8AF717De1cB46a89a6d91aFa567",
  //   Still unpaused as of 26 Aug 2026 and its book is empty. Pause it
  //   from Polygonscan only AFTER v3 has taken a real trade from the
  //   DApp, otherwise a problem in v3 leaves P2P with no venue at all.
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
 "https://polygon-bor-rpc.publicnode.com",
  "https://polygon.drpc.org",
  "https://1rpc.io/matic",
];

// -- ERC20 (OSG Token) --
export const TOKEN_ABI = [
  "function balanceOf(address owner) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
  "function mintedThisHour() view returns (uint256)",
  "function hourStart() view returns (uint256)",
  "function dailyMinted() view returns (uint256)",
  "function mintDay() view returns (uint256)",
  "function HARD_HOURLY_CAP() view returns (uint256)",
  "function HARD_DAILY_CAP() view returns (uint256)",
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
//  The DApp claim does TWO steps:
//   1. Staking.claimReward()  -> moves pending into RewardStorage
//   2. RewardPool.claim()     -> mints up to 500 OSG/call to wallet
export const POOL_ABI = [
  "function claim()",
  "function claimChunk() view returns (uint256)",
  "function getUserReward(address user) view returns (uint256)",
  "function paused() view returns (bool)",
  // owner-only, listed here so the admin page can read/plan around it
  "function miningPercent() view returns (uint256)",
  "function emissionEndTime() view returns (uint256)",

  /* ---- lifetime emission, read straight off the pool ----
   * Home used to show OSGStaking.getPoolInfo()'s figure as the ecosystem
   * total. It is the OLD POOL ALONE: Term, LP and referral are all missing
   * from it, so the number on screen was smaller than the truth.
   *
   * totalAllocated  every OSG the pool has ever handed out
   * totalMinted     the part of that which has actually reached a wallet;
   *                 the gap is reward that has accrued and not been claimed
   * *All            the same split by programme
   */
  "function totalAllocated() view returns (uint256)",
  "function totalMinted() view returns (uint256)",
  "function totalStakingAll() view returns (uint256)",
  "function totalMiningAll() view returns (uint256)",
  "function totalReferralAll() view returns (uint256)",

  /* ---- supply and the day's budget ----
   * BASE_DAILY is 5,881 but getDailyBase() is BASE_DAILY >> getHalving(),
   * so it falls by half at every halving. Never hardcode the 5,881.
   */
  "function MAX_SUPPLY() view returns (uint256)",
  "function TEAM_SUPPLY() view returns (uint256)",
  "function EMISSION_SUPPLY() view returns (uint256)",
  "function BASE_DAILY() view returns (uint256)",
  "function getDailyBase() view returns (uint256)",
  "function getHalving() view returns (uint256)",

  /* ---- today's caps ----
   * getLimits() is what a claim is actually tested against. canClaimNow()
   * on OSGStaking does NOT check it, which is why the Claim button can look
   * available and then revert with "Staking cap exceeded".
   */
  "function getTodayStats() view returns (uint256 stakingUsedAmt, uint256 miningUsedAmt, uint256 referralUsedAmt, uint256 stakingAvail, uint256 miningAvail, uint256 referralAvail, uint256 dailyBase)",
  "function getLimits() view returns (uint256 sl, uint256 ml, uint256 rl)",
];

/* -- OSGRewardStorage --
 *
 * The only ledger that spans every pool. RewardPool has been deployed twice;
 * v2's counters start from 6 June 2026, so its totalAllocated is 23,885.82
 * short of what people have actually earned. RewardStorage was never
 * replaced — both pools were authorised against the same one — so its
 * figures are the whole history.
 *
 * getStats() returns all of it in a single call:
 *   rewarded          everything ever credited, across both pools
 *   claimed           the part that has been minted into wallets
 *   pendingTotal      the difference -- reward sitting here, unclaimed
 *   emergencyCleared  owner-cleared balances
 *   restored          put back after a mint failed; nothing was lost
 *   pools             authorised pools, currently 2
 */
export const STORAGE_ABI = [
  "function getStats() view returns (uint256 rewarded, uint256 claimed, uint256 pendingTotal, uint256 emergencyCleared, uint256 restored, uint256 pools, bool isPaused)",
  "function pendingReward(address user) view returns (uint256)",
  "function totalRewarded() view returns (uint256)",
  "function totalClaimed() view returns (uint256)",
];

/* ======================================================================
   P2P_ABI  --  OSGP2PExchangeV3
   0x269EcA6aDb7c9c1beFDc6c0be48a545b1920E1bb  (deployed 25 Aug 2026)

   THIS IS NOT v2. Read the rename table before touching P2PPanel.

     v2                          v3
     ------------------------    ----------------------------------
     PRICE_SCALE()               gone -- the divisor is 10**baseDec
     placeBuyOrder(...)          placeOrder(pairId, true,  ...)
     placeSellOrder(...)         placeOrder(pairId, false, ...)
     cancelExpiredOrder(id)      cancelExpired(id)
     pairBuyOrderIdsLength(p)    buyOrderIdsLength(p)
     pairSellOrderIdsLength(p)   sellOrderIdsLength(p)
     pairBuyOrderIds(p, i)       buyOrderIdAt(p, i)
     pairSellOrderIds(p, i)      sellOrderIdAt(p, i)
     order.user                  order.maker
     order.amount                order.baseAmount
     order.timestamp             order.createdAt
     order.expiryTime            order.expiry
     --                          bookSlice()   one call, whole side
     --                          sweepExpired()
     --                          quoteFor()    on-chain price maths
     --                          withdrawNative() / withdrawToken()

   cancelOrder(uint256) and acceptOrder(...) keep the exact v2 signature
   and therefore the exact v2 selector. Do not rewrite those two.

   PRICING. price is quote smallest units per ONE WHOLE base token, and
   quoteAmount = mulDiv(baseAmount, price, 10**baseDec). baseDec is OSG's
   18 on BOTH pairs, so pair 1's divisor is the same 1e18 that v2's
   PRICE_SCALE was: nothing in the POL maths changes. Pair 2 divides by
   1e18 too, but its price is denominated in 6-decimal USDT, so only the
   UI's formatting of price and quote differs. When in doubt, call
   quoteFor() and show what the contract itself would charge.

   TWO THINGS THE APP MUST DO
   1. sweepExpired(pairId, side, 50) before a trade. SWEEP_ON_PLACE = 6
      runs automatically, which is not enough if 50 orders have expired.
   2. Never treat an index as a stable cursor. _close does swap-and-pop,
      so closing an order moves a different one into its slot. Read the
      book with bookSlice() and drive acceptOrder off PRICE, not index.

   Owner-only setters (addPair, setPairActive, setMinBase, setFee,
   setFeeCollector, pause, unpause, rescueNative, rescueToken) are left
   out on purpose -- they are done from Polygonscan by OSG-MAIN.
   ====================================================================== */
export const P2P_ABI = [
  /* ---- errors: listed so a revert shows a name, not a hex blob ---- */
  "error EnforcedPause()",
  "error ExpectedPause()",
  "error OwnableInvalidOwner(address owner)",
  "error OwnableUnauthorizedAccount(address account)",
  "error ReentrancyGuardReentrantCall()",
  "error SafeERC20FailedOperation(address token)",
  "error NotAContract()",
  "error InvalidPair()",
  "error PairNotActive()",
  "error PairExists()",
  "error InvalidPrice()",
  "error InvalidAmount()",
  "error BelowMinimum()",
  "error BadExpiry()",
  "error TooManyOpenOrders()",
  "error InsufficientPayment()",
  "error NativeNotAccepted()",
  "error NotOrderOwner()",
  "error OrderNotOpen()",
  "error NotExpired()",
  "error NothingPending()",
  "error NothingToRescue()",
  "error ZeroAddress()",
  "error FeeTooHigh()",
  "error RenounceDisabled()",

  /* ---- writes ----
   * placeOrder is payable ONLY for a buy on a native-quote pair (pair 1).
   * Send 0 value for a sell, and 0 value for any ERC20-quote pair, or it
   * reverts NativeNotAccepted.
   */
  "function placeOrder(uint256 pairId, bool isBuy, uint128 price, uint128 baseAmount, uint40 expiry) payable returns (uint256 orderId)",
  "function acceptOrder(uint256 pairId, bool wantBuy, uint128 baseAmount, uint128 priceLimit, uint256 startFrom, uint256 maxScan) payable returns (uint256 filledBase, uint256 nextIndex)",
  "function cancelOrder(uint256 orderId)",
  "function cancelExpired(uint256 orderId)",
  "function sweepExpired(uint256 pairId, bool isBuy, uint256 maxSweep) returns (uint256 swept)",
  // pull payments: only reachable if a payout transfer failed
  "function withdrawNative()",
  "function withdrawToken(address token)",

  /* ---- reads: the book ----
   * bookSlice replaces the per-order RPC loop. One call returns a whole
   * side; 50 orders cost 1 round trip instead of 52.
   */
  "function bookSlice(uint256 pairId, bool isBuy, uint256 start, uint256 count) view returns (uint256[] ids, address[] makers, uint256[] prices, uint256[] amounts, uint256[] expiries)",
  "function buyOrderIdsLength(uint256 pairId) view returns (uint256)",
  "function sellOrderIdsLength(uint256 pairId) view returns (uint256)",
  "function buyOrderIdAt(uint256 pairId, uint256 i) view returns (uint256)",
  "function sellOrderIdAt(uint256 pairId, uint256 i) view returns (uint256)",
  "function orders(uint256) view returns (address maker, uint64 pairId, bool isBuy, uint128 price, uint128 baseAmount, uint40 createdAt, uint40 expiry, uint32 index, uint8 status)",
  "function orderCounter() view returns (uint256)",
  "function openOrderCount(address user) view returns (uint256)",

  /* ---- reads: pairs and maths ---- */
  "function pairs(uint256) view returns (address base, address quote, uint8 baseDec, uint8 quoteDec, uint256 minBase, bool active)",
  "function pairCounter() view returns (uint256)",
  "function quoteFor(uint256 pairId, uint256 baseAmount, uint256 price) view returns (uint256)",

  /* ---- reads: fee, state, owed balances ---- */
  "function feeBps() view returns (uint256)",
  "function feeCollector() view returns (address)",
  "function paused() view returns (bool)",
  "function owner() view returns (address)",
  "function pendingNative(address user) view returns (uint256)",
  "function pendingToken(address user, address token) view returns (uint256)",
  "function liabilityNative() view returns (uint256)",
  "function liabilityToken(address token) view returns (uint256)",

  /* ---- reads: limits ----
   * MAX_OPEN_PER_USER counts every open order a wallet holds across all
   * pairs and both sides. It only falls when an order closes.
   */
  "function MAX_FEE_BPS() view returns (uint256)",
  "function MAX_SCAN() view returns (uint256)",
  "function MAX_MATCH() view returns (uint256)",
  "function AUTO_MATCH_SCAN() view returns (uint256)",
  "function MAX_EXPIRY() view returns (uint256)",
  "function MAX_OPEN_PER_USER() view returns (uint256)",
  "function SWEEP_ON_PLACE() view returns (uint256)",
  "function OPEN() view returns (uint8)",
  "function FILLED() view returns (uint8)",
  "function CANCELLED() view returns (uint8)",

  /* ---- events ----
   * OrderFilled now carries maker, taker, both amounts and the fee, so a
   * "last trade" ticker can be built from this event alone.
   */
  "event OrderPlaced(uint256 indexed orderId, address indexed maker, uint256 indexed pairId, bool isBuy, uint256 price, uint256 baseAmount, uint256 expiry)",
  "event OrderFilled(uint256 indexed orderId, address indexed maker, address indexed taker, uint256 pairId, bool makerWasBuying, uint256 price, uint256 filledBase, uint256 quoteAmount, uint256 fee, uint256 remainingBase)",
  "event OrderCancelled(uint256 indexed orderId, address indexed maker, uint256 refundedBase, uint256 refundedQuote)",
  "event PairAdded(uint256 indexed pairId, address indexed base, address indexed quote, uint256 minBase)",
  "event PayoutDeferred(address indexed to, address indexed asset, uint256 amount)",
  "event Withdrawn(address indexed to, address indexed asset, uint256 amount)",
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
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address owner) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
];

// ======================================================================
//  OSGTermStaking v2  --  stake OSG, earn OSG to a 2x cap (category-2)
//
//  READING A WALLET'S POSITIONS
//  ----------------------------
//  getPositions(user) returns the WHOLE array in one call, including
//  closed ones. Index in that array IS the posId. Prefer it over
//  looping positionCount + positions(user, i).
//
//  EXITS
//  -----
//  withdraw(posId)           needs cap reached AND 180 days elapsed
//  forfeitAndWithdraw(posId) works any time, returns principal in full,
//                            gives up whatever reward was still pending
// ======================================================================
export const TERM_STAKING_ABI = [
  // writes -- user
  "function deposit(uint256 amount)",
  "function claim(uint256 posId)",
  "function claimAll()",
  "function claimRange(uint256 start, uint256 end)",
  "function withdraw(uint256 posId)",
  "function withdrawAll()",
  "function withdrawRange(uint256 start, uint256 end)",
  "function forfeitAndWithdraw(uint256 posId)",
  "function settle()",
  "function poke(address user, uint256 posId)",

  // reads -- positions
  "function getPositions(address user) view returns (tuple(uint256 amount, uint256 cap, uint256 rewardDebt, uint256 rewardPaid, uint256 unpaid, uint256 startTime, bool capped, bool closed)[])",
  "function positions(address, uint256) view returns (uint256 amount, uint256 cap, uint256 rewardDebt, uint256 rewardPaid, uint256 unpaid, uint256 startTime, bool capped, bool closed)",
  "function positionCount(address user) view returns (uint256)",
  "function positionsLength(address user) view returns (uint256)",
  "function openPositions(address user) view returns (uint256)",
  "function pendingReward(address user, uint256 posId) view returns (uint256)",
  "function remainingCap(address user, uint256 posId) view returns (uint256)",
  "function lockRemaining(address user, uint256 posId) view returns (uint256)",
  "function estimatedDaysToCap(address user, uint256 posId) view returns (uint256)",
  "function stakedOf(address user) view returns (uint256 total)",

  // reads -- pool
  "function totalStaked() view returns (uint256)",
  "function totalPrincipal() view returns (uint256)",
  "function capacity() view returns (uint256)",
  "function capacityLeft() view returns (uint256)",
  "function effectiveRateBps() view returns (uint256)",
  "function maxRateBps() view returns (uint256)",
  "function minDeposit() view returns (uint256)",
  "function minDepositFor() view returns (uint256)",
  "function getTermStakingDailyBudget() view returns (uint256)",
  "function miningShareBps() view returns (uint256)",
  "function maxShareBps() view returns (uint256)",
  "function depositDeadline() view returns (uint256)",
  "function isEmissionOver() view returns (bool)",
  "function isWiredForMining() view returns (bool)",
  "function LOCK_PERIOD() view returns (uint256)",
  "function CAP_MULTIPLIER() view returns (uint256)",
  "function MAX_POSITIONS() view returns (uint256)",
  "function referralContract() view returns (address)",
  "function paused() view returns (bool)",
  "function payoutHealth() view returns (bool canPayNow, string reason)",
  "function version() view returns (string)",

  // events
  "event Deposited(address indexed user, uint256 indexed posId, uint256 amount, uint256 cap)",
  "event Claimed(address indexed user, uint256 indexed posId, uint256 amount)",
  "event Withdrawn(address indexed user, uint256 indexed posId, uint256 principal)",
  "event ForfeitWithdrawn(address indexed user, uint256 indexed posId, uint256 principal, uint256 forfeited)",
  "event CapReached(address indexed user, uint256 indexed posId)",
  "event PayoutCapped(address indexed user, uint256 indexed posId, uint256 paidNow, uint256 remaining)",
];

// ======================================================================
//  OSGLPMining v7  --  stake OSG/WPOL LP, earn OSG (category-2)
//
//  THIS IS NOT v6. Do not carry v6 call shapes over.
//    v6: deposit(tierId, lpAmount)   userTier(user, tierId)
//    v7: deposit(lpAmount)           positions(user, posId)
//
//  There is no getPositions() here -- read positionCount(user) and
//  then loop positions(user, i). Index i IS the posId.
//
//  osgValue is frozen at deposit time from lpWeight; it does not move
//  when the pool price moves. lpWeight is owner-set, never read from
//  pair reserves.
//
//  LOCK_PERIOD (365 days) binds BOTH exits. forfeitAndWithdraw is NOT
//  an escape hatch here the way it is in TermStaking -- it also waits
//  out the term. liftTerm() is the one-way owner release valve; once
//  called it cannot be undone.
// ======================================================================
export const LP_MINING_ABI = [
  // writes -- user
  "function deposit(uint256 lpAmount)",
  "function claim(uint256 posId)",
  "function claimAll()",
  "function claimRange(uint256 start, uint256 end)",
  "function withdraw(uint256 posId)",
  "function forfeitAndWithdraw(uint256 posId)",
  "function settle()",

  // reads -- positions
  "function positions(address, uint256) view returns (uint256 lpAmount, uint256 osgValue, uint256 rewardDebt, uint256 rewardPaid, uint256 unpaid, uint256 startTime, bool closed)",
  "function positionCount(address user) view returns (uint256)",
  "function openPositions(address user) view returns (uint256)",
  "function pendingReward(address user, uint256 posId) view returns (uint256)",
  "function lockRemaining(address user, uint256 posId) view returns (uint256)",
  "function nextPayoutChunk(address user, uint256 posId) view returns (uint256)",
  "function stakedLpOf(address user) view returns (uint256 total)",
  "function stakedValueOf(address user) view returns (uint256 total)",

  // reads -- pool
  "function totalLp() view returns (uint256)",
  "function totalStakeValue() view returns (uint256)",
  "function capacityLp() view returns (uint256)",
  "function capacityLeft() view returns (uint256)",
  "function lpWeight() view returns (uint256)",
  "function lpToken() view returns (address)",
  "function effectiveRateBps() view returns (uint256)",
  "function maxRateBps() view returns (uint256)",
  "function minDeposit() view returns (uint256)",
  "function getLpMiningDailyBudget() view returns (uint256)",
  "function miningShareBps() view returns (uint256)",
  "function maxShareBps() view returns (uint256)",
  "function depositDeadline() view returns (uint256)",
  "function termLifted() view returns (bool)",
  "function isWiredForMining() view returns (bool)",
  "function LOCK_PERIOD() view returns (uint256)",
  "function MAX_POSITIONS() view returns (uint256)",
  "function referralContract() view returns (address)",
  "function paused() view returns (bool)",
  "function payoutHealth() view returns (bool canPayNow, string reason)",
  "function version() view returns (string)",

  // events
  "event Deposited(address indexed user, uint256 indexed posId, uint256 lpAmount, uint256 osgValue)",
  "event Claimed(address indexed user, uint256 indexed posId, uint256 amount)",
  "event Withdrawn(address indexed user, uint256 indexed posId, uint256 lpAmount)",
  "event ForfeitWithdrawn(address indexed user, uint256 indexed posId, uint256 lpAmount, uint256 forfeited)",
  "event PayoutCapped(address indexed user, uint256 indexed posId, uint256 paid, uint256 remaining)",
  "event TermLifted(uint256 at)",
];

// QuickSwap swap link
export const QUICKSWAP_URL =
  "https://quickswap.exchange/#/swap?outputCurrency=" + ADDRESSES.token;
/* ======================================================================
   REFERRAL_V4_ABI  --  OSGReferral v4.1
   0x82cfA8CB35176BAC5d9d2Ec791Aa22B33AbAA381  (deployed 11 Aug 2026)

   Human-readable subset. Only what the DApp actually calls.
   Full 15-level structure; getLevelTable returns two fixed uint256[15]
   arrays (bps, conditions).

   Renamed from v3: totalVolume(address) is now volume(address).
   New in v4.1: rank / team-bonus views, previewRank, claimTeamBonus,
   refreshRank, stakeWiringHealthy.
   ====================================================================== */
export const REFERRAL_V4_ABI = [
  /* ---- budget & health ---- */
  "function referralDailyBudget() view returns (uint256)",
  "function payoutHealth() view returns (bool canPayNow, string reason)",
  "function bonusHealth() view returns (bool canPayNow, string reason)",
  "function isWiredForReferral() view returns (bool)",
  "function stakeWiringHealthy() view returns (bool termOk, bool lpOk)",
  "function paused() view returns (bool)",
  "function version() pure returns (string)",

  /* ---- level structure ---- */
  "function getLevelTable() view returns (uint256[15] bps, uint256[15] conditions)",
  "function totalLevelBps() view returns (uint256)",
  "function LEVELS() view returns (uint256)",

  /* ---- per-user level commission ---- */
  "function directReferrals(address user) view returns (uint256)",
  "function unlockedLevels(address user) view returns (uint256 n)",
  "function activeBps(address user) view returns (uint256 total)",
  "function owed(address) view returns (uint256)",
  "function paid(address) view returns (uint256)",
  "function volume(address) view returns (uint256)",
  "function stakeOf(address user) view returns (uint256 total)",

  /* ---- rank & team bonus ---- */
  "function rankOf(address) view returns (uint8)",
  "function rankSince(address) view returns (uint256)",
  "function rankHoldRemaining(address user) view returns (uint256)",
  "function bonusPaidTotal(address) view returns (uint256)",
  "function lastBonusAt(address) view returns (uint256)",
  "function bonusCooldownRemaining(address user) view returns (uint256)",
  "function tiers(uint256) view returns (uint256 directsNeeded, uint256 stakeNeeded, uint256 monthlyPayout)",
  "function previewRank(address user, address[] directs) view returns (uint8 rank, uint256 count, uint256 stakeTotal)",
  "function BONUS_PERIOD() view returns (uint256)",
  "function RANK_HOLD() view returns (uint256)",

  /* ---- writes ---- */
  "function claimMyReferral()",
  "function claimTeamBonus(address[] directs)",
  "function refreshRank(address user, address[] directs)",

  /* ---- events ---- */
  "event CommissionAccrued(address indexed earner, address indexed from, uint8 level, uint256 amount)",
  "event CommissionPaid(address indexed earner, uint256 amount, uint256 remainingOwed)",
  "event PayoutCapped(address indexed earner, uint256 paidNow, uint256 remaining)",
  "event RankUpdated(address indexed user, uint8 oldRank, uint8 newRank, uint256 directVolume)",
  "event BonusPaid(address indexed user, uint8 rank, uint256 requested, uint256 received)",
  "event BonusShort(address indexed user, uint256 requested, uint256 received)",
];

/* =====================================================================
 *  REFERRAL v4.2 — three contracts
 * =====================================================================
 *  Do NOT point REFERRAL_V4_ABI at referralV42. Seven of its entries no
 *  longer exist on the ledger: stakeWiringHealthy, getLevelTable,
 *  unlockedLevels, activeBps, payoutHealth, bonusHealth, previewRank and
 *  referralDailyBudget all moved to the lens contracts, several with
 *  different arguments. Calling them on the ledger reverts.
 *
 *  Which contract to ask:
 *    ledger  -> writes, balances, the tree
 *    lens    -> team screens: upline, downline, per-level detail
 *    health  -> why a button would fail, rank previews, wiring
 * ===================================================================== */

export const REFERRAL_V42_ABI = [
  /* ---- the tree ---- */
  "function referrerOf(address user) view returns (address)",
  "function nativeReferrer(address) view returns (address)",
  "function registeredAt(address) view returns (uint256)",
  "function directReferrals(address user) view returns (uint256)",
  "function registeredDirects(address) view returns (uint256)",
  "function nativeDirects(address) view returns (uint256)",
  "function directCounted(address) view returns (bool)",
  "function childrenOf(address user) view returns (address[])",
  "function childrenCount(address user) view returns (uint256)",
  "function childrenSlice(address user, uint256 offset, uint256 limit) view returns (address[] page, uint256 total)",

  /* ---- stake ---- */
  "function stakeOf(address user) view returns (uint256 total)",
  "function qualifyingStakeOf(address user) view returns (uint256 total)",
  "function minDirectStake() view returns (uint256)",
  "function minReferrerStake() view returns (uint256)",

  /* ---- level commission ---- */
  "function owed(address) view returns (uint256)",
  "function paid(address) view returns (uint256)",
  "function volume(address) view returns (uint256)",
  "function levelBps(uint256) view returns (uint256)",
  "function levelConditions(uint256) view returns (uint256)",
  "function totalLevelBps() view returns (uint256)",
  "function LEVELS() view returns (uint256)",

  /* ---- rank & bonus ---- */
  "function rankOf(address) view returns (uint8)",
  "function rankSince(address) view returns (uint256)",
  "function lastBonusAt(address) view returns (uint256)",
  "function bonusPaidTotal(address) view returns (uint256)",
  "function tiers(uint256) view returns (uint256 directsNeeded, uint256 stakeNeeded, uint256 monthlyPayout)",
  "function RANK_HOLD() view returns (uint256)",
  "function BONUS_PERIOD() view returns (uint256)",

  /* ---- wiring ---- */
  "function isWiredForReferral() view returns (bool)",
  "function stakeSourceCount() view returns (uint256)",
  "function paused() view returns (bool)",
  "function version() pure returns (string)",

  /* ---- writes ---- */
  "function register(address referrer)",
  "function claimMyReferral()",
  "function claimTeamBonus(address[] directs)",
  "function refreshRank(address user, address[] directs)",
  "function syncDirect(address user)",

  /* ---- events ---- */
  "event Registered(address indexed user, address indexed referrer)",
  "event DirectQualified(address indexed user, address indexed referrer, uint256 referrerDirects)",
  "event DirectDropped(address indexed user, address indexed referrer, uint256 referrerDirects)",
  "event CommissionAccrued(address indexed earner, address indexed from, uint8 level, uint256 amount)",
  "event CommissionPaid(address indexed earner, uint256 amount, uint256 remainingOwed)",
  "event PayoutCapped(address indexed earner, uint256 paidNow, uint256 remaining)",
  "event CommissionTruncated(address indexed from, uint256 levelsCompleted)",
  "event RankUpdated(address indexed user, uint8 oldRank, uint8 newRank, uint256 directVolume)",
  "event BonusPaid(address indexed user, uint8 rank, uint256 requested, uint256 received)",
  "event BonusShort(address indexed user, uint256 requested, uint256 received)",
];

/* Team screens. Every call is a view; none of them costs gas.
 *
 * The downline calls take a maxNodes cap and return `truncated` when a
 * team outgrows it. A view has no gas limit of its own but the RPC node
 * answering it does, so an unbounded walk would time out and return
 * nothing at all. Start around 300 and page with downlineAtLevel rather
 * than raising the cap until the call dies.
 *
 * Downline covers BOTH trees. OSGStaking does keep a child list --
 * getDirectReferrals(address) -- and Lens v2 merges it with the v4.2 one at
 * every node, so an old team reads in full. Rows carry isLegacy: on those,
 * qualified is always true (OSGStaking's count is a latch), joinedAt is the
 * first stake there, and qualifyingStake counts Term and LP only, so it
 * reads zero for anyone who has not migrated. That zero is correct, not a
 * failure -- never render it as a pass/fail test on a legacy row. */
export const REFERRAL_LENS_ABI = [
  "function uplineOf(address user) view returns (address referrer, bool isLegacy, bool exists)",
  "function uplineView(address user) view returns (tuple(uint8 level, address wallet, uint256 stake, uint256 levelBps, bool levelOpen, bool stakeOk, bool earning)[] chain)",
  "function directsView(address user) view returns (tuple(uint8 level, address wallet, uint256 stake, uint256 qualifyingStake, bool qualified, bool isLegacy, address referrer, uint256 joinedAt)[] list)",
  "function levelSummary(address user, uint256 maxNodes) view returns (tuple(uint8 level, uint256 members, uint256 legacyMembers, uint256 qualified, uint256 totalStake, uint256 levelBps, uint256 directsNeeded, bool open)[] rows, uint256 totalMembers, bool truncated)",
  "function downlineAtLevel(address user, uint8 level, uint256 offset, uint256 limit, uint256 maxNodes) view returns (tuple(uint8 level, address wallet, uint256 stake, uint256 qualifyingStake, bool qualified, bool isLegacy, address referrer, uint256 joinedAt)[] page, uint256 totalAtLevel, bool truncated)",
  "function legacyStaking() view returns (address)",
  "function core() view returns (address)",
  "function walletCard(address user) view returns (tuple(address referrer, bool hasUpline, bool uplineIsLegacy, uint256 legacyDirects, uint256 registeredDirects, uint256 qualifiedDirects, uint256 directsForLevels, uint256 levelsOpen, uint256 activeBps, uint256 stake, uint256 qualifyingStake, bool countsAsDirect, uint256 owed, uint256 paid, uint256 volume, uint8 rank, uint256 rankHoldRemaining, uint256 bonusCooldownRemaining, uint256 bonusPaidTotal) card)",
  "function previewCommission(address from, uint256 rewardAmount) view returns (address[] earners, uint8[] levels, uint256[] amounts)",
  "function version() pure returns (string)",
];

/* Diagnostics. Each *Health call returns a plain reason string meant to
 * be shown to the user as-is, so a disabled button can always say why.
 * Note these take a user argument -- the v4.1 versions did not. */
export const REFERRAL_HEALTH_ABI = [
  "function registerHealth(address user, address referrer) view returns (bool ok, string reason)",
  "function earningHealth(address user) view returns (bool ok, string reason)",
  "function payoutHealth(address user) view returns (bool ok, string reason)",
  "function bonusHealth(address user) view returns (bool ok, string reason)",
  "function qualificationStatus(address user) view returns (bool counted, uint256 qualifyingStake, uint256 required, uint256 shortfall, address referrer)",
  "function previewRank(address user, address[] directs) view returns (uint8 rank, uint256 count, uint256 stakeTotal, string problem)",
  "function rankProgress(address user, address[] directs) view returns (uint256[3] directsNeeded, uint256[3] stakeNeeded, uint256[3] monthlyPayout, uint256 haveDirects, uint256 haveStake)",
  "function stakeSourceHealth() view returns (address[] addrs, bytes4[] selectors, bool[] ok, bool[] isCommissionSource)",
  "function programmeStats() view returns (uint256 totalLevelBps, uint256 referralBudgetToday, uint256 minDirectStake, uint256 minReferrerStake, uint256 sourceCount, bool wired, bool paused, bool seedOpen)",
  "function selectorFor(string signature) pure returns (bytes4)",
  "function version() pure returns (string)",
];
