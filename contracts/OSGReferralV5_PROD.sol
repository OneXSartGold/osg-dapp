// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/*
 * ======================================================================
 *  OSGReferral v5
 *  Category-3 (Referral) distributor.
 * ======================================================================
 *
 *  WHAT CHANGED FROM v4.1, AND WHY
 *  -------------------------------
 *  v4.1 read the whole tree out of OSGStaking and stored none of it. That
 *  was the right call while OSGStaking was the only way in. It is the
 *  wrong call now: `staking` is immutable, TermStaking.deposit() takes no
 *  referrer, and so a wallet that joins straight into Term v2 has no
 *  upline at all. Its referrer earns nothing on it, forever, and no later
 *  transaction can repair that -- OSGStaking writes a referrer once, on a
 *  wallet's first stake there, and never again.
 *
 *  The practical effect was that every new member had to be routed
 *  through the contract we are trying to empty, purely to register a
 *  relationship. This version ends that.
 *
 *  1. register(referrer) writes the bond here. One time, permanent.
 *
 *  2. _referrerOf() prefers the local bond and falls back to OSGStaking.
 *     Every existing team therefore keeps working untouched -- nobody
 *     re-registers, and a chain built last year reads the same today.
 *
 *  3. register() refuses any wallet that already has an OSGStaking
 *     referrer. The two trees can never disagree about the same wallet,
 *     so no commission is ever paid twice for one claim.
 *
 *  4. NOTHING COUNTS WITHOUT STAKE, IN EITHER DIRECTION.
 *     A direct is counted once its own stake reaches minDirectStake and
 *     UNCOUNTED again if it falls back below -- syncDirect() moves the
 *     figure both ways and anyone may call it. An upline also has to hold
 *     minReferrerStake of its own at the moment a downline claims, or the
 *     commission does not accrue.
 *     A one-way latch would have been cheaper to write and much cheaper
 *     to abuse: one 100 OSG float walked from wallet to wallet, staking
 *     and withdrawing, opens all fifteen levels for the price of one
 *     stake and a week of cooldowns. Reading live in both directions is
 *     the only thing that actually closes that, and it is why syncDirect
 *     has to be open to everyone -- it writes what the chain already
 *     says, so a hostile caller can only make the count correct.
 *
 *  5. onLiquidityChange() now exists. TermStaking and LPMining have been
 *     calling it since they were deployed; v4.1 never implemented it, so
 *     every deposit quietly emitted ReferralHookFailed. Here it is what
 *     marks a direct as qualified, at the moment the deposit lands.
 *
 *  6. qualify(user) is open to anyone, as a fallback for when the hook
 *     was swallowed or the deposit came before the registration. It is
 *     idempotent and only ever reads live state, so an open door costs
 *     nothing.
 *
 *  7. Stake sources are a LIST, not three fixed slots. v4.1 named
 *     TermStaking and LPMining in storage and typed them in interfaces,
 *     so a fourth programme could not be counted without another
 *     deployment -- which is most of why this one exists. Each entry is
 *     an address plus the selector of a f(address) view returning
 *     uint256, so a new programme is one owner call whatever it decides
 *     to call its getter.
 *
 *  8. seedLedger()/seedBonus() carry balances over from v4.1, and
 *     lockSeeding() shuts that door permanently. Redeploying without
 *     them would zero bonusPaidTotal and lastBonusAt, which would let a
 *     wallet collect a monthly bonus it had already been paid.
 *
 *  KNOWN, ACCEPTED
 *  ---------------
 *  A wallet registered here could still go and stake in OSGStaking naming
 *  a different referrer. Commission would follow the local bond; the
 *  OSGStaking referrer would gain a direct on their count without
 *  earning on that wallet. It costs a real stake in the contract we are
 *  winding down to achieve very little, so it is documented rather than
 *  defended against.
 *
 *  Legacy directs, counted inside OSGStaking, do NOT fall when those
 *  wallets withdraw -- that contract latches and cannot be changed. Only
 *  locally-registered directs move both ways. The two are added together,
 *  so a wallet with an old team keeps whatever OSGStaking already granted
 *  it.
 *
 *  Active Staking is not a qualifying source at all -- see
 *  qualifyingStakeOf(). It calls no hooks, so anything qualified on it
 *  could outlive its own stake indefinitely. Every qualifying source
 *  reports both deposits and withdrawals, which is what makes the count
 *  self-maintaining rather than dependent on somebody remembering to
 *  sweep.
 *
 *  OSGStaking also runs no referral hook of its own: the fifteen-level
 *  programme does not reach claims made there, and cannot be made to.
 *  Those claims still pay the old five-level 11.5% through the original
 *  distributor. It is one more reason the migration into Term matters.
 *
 *  WHICH PROGRAMME COUNTS WHERE -- THE AUTHORITATIVE TABLE
 *  ------------------------------------------------------
 *  Three programmes, six questions, and the answer is not the same for
 *  all six. This table is the rule; anything that disagrees with it,
 *  including a comment elsewhere in this file, is wrong.
 *
 *                                    Active   Term   LP   (future)
 *    Who your upline is (the tree)     yes*     --    --      --
 *    Directs counted toward levels     yes*    yes   yes     yes
 *    Qualifying a NEW direct            NO     yes   yes     yes
 *    Eligibility to be a referrer      yes     yes   yes     yes
 *    Your own stake to earn            yes     yes   yes     yes
 *    Team stake for A1/A2/A3           yes     yes   yes     yes
 *    Generates commission at all        NO     yes   yes    if hooked
 *
 *    * Active Staking is the FALLBACK tree and keeps whatever directs it
 *      already counted. It cannot gain new ones through this contract.
 *
 *  Two answers in that table are deliberate and easy to misread:
 *
 *  Qualifying a NEW direct excludes Active Staking because OSGStaking
 *  fires no hooks, so anything qualified there could outlive its own
 *  stake. Every qualifying source reports withdrawals as well as
 *  deposits, which is what makes the count self-maintaining.
 *
 *  Eligibility and earning DO include Active Staking, because a member
 *  who has not migrated yet still has real money in the system and
 *  should not lose their team for being slow.
 *
 *  OSGStaking also runs no referral hook of its own. The fifteen-level
 *  programme does not reach claims made there and cannot be made to;
 *  those still pay the older five-level 11.5% through the original
 *  distributor. Migration into Term is what moves a downline from 11.5%
 *  to 45%.
 *
 *  ----------------------------------------------------------------------
 *  EVERYTHING BELOW THIS LINE IS v4.1 BEHAVIOUR, UNCHANGED IN INTENT
 *  ----------------------------------------------------------------------
 *
 *  TWO SEPARATE PROGRAMMES, TWO SEPARATE PURSES
 *
 *  1. LEVEL COMMISSION -- 45% across fifteen levels, paid out of the
 *     Referral share of emission. Accrues whenever someone downline
 *     claims a staking or mining reward.
 *
 *  2. ACHIEVEMENT BONUS -- A1/A2/A3, a flat monthly figure paid out of
 *     OSGTreasury. Not emission. It has an end date and the treasury has
 *     a monthly ceiling of its own, so this programme cannot eat into
 *     what the level commission needs.
 *
 *  HOW A RANK IS PROVEN
 *
 *  The caller supplies their own directs list and the contract checks
 *  every entry names the caller as its referrer, and that the list
 *  strictly ascends so a duplicate cannot be slipped in. Walking an
 *  unbounded list on-chain is how a contract becomes unusable for
 *  exactly the people it was meant to reward.
 *
 *  STAKE MEANS ALL THREE PLACES
 *
 *  Active Staking + TermStaking + LP Mining, with LP counted at the OSG
 *  valuation LPMining froze in at deposit -- deliberately not a live
 *  price, because a shallow pool makes a live price something an
 *  attacker can move for the length of one transaction.
 * ======================================================================
 */

interface IOSGStaking {
    /// 11 fields; referrer at index 6, totalReferrals at index 7.
    function users(address user) external view returns (
        uint256 staked,
        uint256 rewardDebt,
        uint256 pendingHarvest,
        uint256 unstakeRequestAt,
        uint256 totalEarned,
        uint256 stakedAt,
        address referrer,
        uint256 totalReferrals,
        uint256 totalReferralEarned,
        uint256 totalTeamVolume,
        uint256 teamBonusEarned
    );
}

interface IOSGRewardPool {
    function distribute(address user, uint256 amount, uint8 category) external;
    function distributorType(address) external view returns (uint8);
    function distributorActive(address) external view returns (bool);
    function paused() external view returns (bool);
    function emissionStopped() external view returns (bool);
    function getTodayStats() external view returns (
        uint256 stakingUsedAmt, uint256 miningUsedAmt, uint256 referralUsedAmt,
        uint256 stakingAvail, uint256 miningAvail, uint256 referralAvail,
        uint256 dailyBase
    );
    function startTime() external view returns (uint256);
}

/// Whatever posts the OSG price later -- a TWAP reader, a Chainlink
/// consumer, a keeper. Eight decimals, same as Chainlink USD feeds.
interface IOSGPriceOracle {
    function osgUsdPrice() external view returns (uint256);
}

interface IOSGTreasury {
    /// Returns what was actually sent -- may be less than asked, may be
    /// zero, and never reverts on a shortfall.
    function spendTeamBonus(address to, uint256 amount) external returns (uint256 paid);
    function spendAirdrop(address to, uint256 amount) external returns (uint256 paid);
    function teamBonusAvailable() external view returns (uint256);
    function airdropPool() external view returns (uint256);
    function endsAt() external view returns (uint256);
}

/*
 *  Stake sources are not typed here on purpose. TermStaking answers to
 *  stakedOf(address) and LPMining to stakedValueOf(address), and the next
 *  programme will pick its own name again. Holding an interface per
 *  contract is what forced a redeploy last time; holding a selector does
 *  not.
 */

contract OSGReferral is Ownable, Pausable, ReentrancyGuard {
    error NothingAccruedYet();
    error MinReferrerStakeMustBePositive();
    error ThresholdIsZero();
    error PriceOutOfBand();
    error BadBand();

    // Custom errors: same meaning as the old strings, a fraction of
    // the bytecode. The name is the message.
    error AirdropPaused();
    error AlreadyASource();
    error AlreadyCountedAsADirect();
    error AlreadyRegistered();
    error AmountIsZero();
    error BadBatchSize();
    error BadPermission();
    error BadRankCount();
    error BatchOutOfRange();
    error CannotReferItself();
    error CannotReferYourself();
    error CommissionPaused();
    error ConditionsMustNotFall();
    error CorrectionWindowClosed();
    error IndexOutOfRange();
    error LengthMismatch();
    error Level1NeedsADirect();
    error LevelGasBelowFloor();
    error LevelTableTooRich();
    error ListMustAscendNoDuplicates();
    error MinDirectStakeMustBePositive();
    error NoAirdropBudgetToday();
    error NoRankBudgetToday();
    error NoRankRefreshRankFirst();
    error NoReferralBudgetAvailableToday();
    error NotASource();
    error NotPermitted();
    error NotRegisteredHere();
    error NotYourDirect();
    error NothingOwed();
    error PoolNotContract();
    error RankBonusPaused();
    error RankHoldNotMet();
    error RankNoLongerMet();
    error RankOutOfRange();
    error RateRisesWithRank();
    error ReferrerStakeTooLow();
    error SameReferrer();
    error SeedWindowExpired();
    error SeedWindowOutOfRange();
    error SeedingClosed();
    error SelfOrOwnerOnly();
    error ShareCapExceeded();
    error SourceGasBelowFloor();
    error SourceNotContract();
    error StakingNotContract();
    error TeamStakeIsZero();
    error TierNotConfigured();
    error TierPaysNothing();
    error TooManyAtOnce();
    error TooManySources();
    error UplineExistsInStaking();
    error WouldFormALoop();
    error ZeroAddress();
    error ZeroAdmin();
    error ZeroReferrer();
    error ZeroSelector();
    error ZeroUser();


    // ====================== CONSTANTS ======================

    uint8   public constant CAT_REFERRAL = 3;
    uint256 public constant BPS_DENOM    = 10_000;
    uint256 public constant LEVELS       = 15;

    uint256 public constant MAX_TOTAL_LEVEL_BPS = 6_000;

    /// Mirrors RewardPool.MAX_SINGLE_ALLOC. Confirm against the deployed
    /// pool before wiring.
    uint256 public constant MAX_SINGLE_ALLOC = 10_000 * 1e18;

    uint256 public constant RANK_HOLD    = 24 hours;
    uint256 public constant BONUS_PERIOD = 30 days;

    /// Arrears are capped. A wallet that stops calling for a year has
    /// not been owed for a year -- it simply was not collecting, and
    /// the emission it would have drawn was spent on somebody else.
    ///
    /// Seven days, not sixty, and the reason is a bound rather than a
    /// policy. Rank is only ever measured at the two ends of an accrual
    /// window; nothing observes the middle. Whatever a wallet does
    /// between two calls is therefore priced at the endpoints, and this
    /// constant is what limits how much can hide in that gap. At sixty
    /// days the worst case is a full R5 window -- 4,000 OSG -- against a
    /// daily referral budget near 1,800. At seven it is 466, which is
    /// survivable even if a rank check is wrong somewhere.
    ///
    /// It costs nothing to anyone accruing on the daily cadence this
    /// contract was built around.
    uint256 public constant MAX_ACCRUAL_WINDOW = 7 days;

    /// No rank asks for more than fifteen directs, and every entry in
    /// the list costs a stakeOf() walk across every stake source. Fifty
    /// leaves room for a task that wants more without inviting a list
    /// long enough to price the call out of a block.
    uint256 public constant MAX_DIRECTS_PER_CALL = 50;

    /// How far register() climbs looking for the registering wallet
    /// before accepting a referrer.
    ///
    /// This bounds the check, it does not make it complete: a referrer
    /// sitting more than thirty-two links above would not be seen, so a
    /// cycle is possible in principle on a very deep legacy chain. That
    /// is survivable rather than ignored -- the commission walk only
    /// climbs LEVELS links and breaks the moment it meets the claimant
    /// again, so a cycle cannot pay anyone commission on their own
    /// reward, and cannot loop. Thirty-two is twice the paying depth,
    /// which is the useful range, and an unbounded climb here would let
    /// one very deep chain make registration cost more gas than a block
    /// allows.
    uint256 public constant LOOP_SCAN_DEPTH = 32;

    /// How long after registering a bond may still be corrected by the
    /// owner, and only while the wallet has not yet been counted as a
    /// direct. Long enough to fix somebody who followed the wrong link,
    /// far too short to move a team that has started earning.
    uint256 public constant CORRECTION_WINDOW = 24 hours;

    /// Cap on stake sources. stakeOf() runs once per source, and
    /// _verifiedDirectVolume() runs stakeOf() once per direct, so the
    /// worst case is MAX_DIRECTS_PER_CALL x MAX_STAKE_SOURCES external
    /// reads in a single accrueRankBonus(). Six leaves room for Flexi and
    /// two more after it while keeping that product survivable.
    uint256 public constant MAX_STAKE_SOURCES = 6;

    /// Floors for the two gas settings below. Set either too low and the
    /// feature it guards stops working silently, so neither can be turned
    /// off by accident.
    uint256 public constant MIN_SOURCE_GAS = 100_000;
    uint256 public constant MIN_LEVEL_GAS  = 30_000;

    // ====================== WIRING ======================

    IOSGStaking    public immutable staking;
    IOSGRewardPool public immutable pool;

    IOSGTreasury public treasury;

    /// A contract that can answer "how much OSG does this wallet hold
    /// with you", and the function to ask it with.
    struct StakeSource {
        address addr;
        bytes4  selector;   // f(address) returns (uint256)
    }

    /// Every programme whose balances count toward a rank, a direct's
    /// qualification, and the referrer threshold. Add TermStaking and
    /// LPMining at deploy; add Flexi, or whatever follows, with one owner
    /// call and no redeployment.
    StakeSource[] public stakeSources;

    /// Contracts allowed to report a reward claim or a liquidity change.
    mapping(address => bool) public isSource;

    // ====================== THE LOCAL TREE ======================

    /// Written once by register(), never overwritten. Address zero means
    /// "ask OSGStaking instead".
    mapping(address => address) public nativeReferrer;

    /// Directs registered HERE that have reached minDirectStake. Add
    /// OSGStaking's own totalReferrals to get the figure levels open on.
    mapping(address => uint256) public nativeDirects;

    /// parent -> children, in registration order. The tree is stored
    /// child-first everywhere else, which answers "who is above me" in
    /// one read and "who is below me" not at all. A downline screen needs
    /// the other direction, and no amount of cleverness recovers it from
    /// the parent pointers alone -- it has to be written down.
    ///
    /// Only wallets registered HERE appear. Legacy teams live inside
    /// OSGStaking, which exposes no child list, so those have to be
    /// assembled off-chain from its events. See OSGReferralLens.
    mapping(address => address[]) private _children;

    /// Everyone who has ever registered under this wallet, staked or not.
    /// Never falls. A bond is permanent, so somebody who withdraws stops
    /// counting toward levels but does not leave the team -- and a UI
    /// that shows only the qualified figure makes it look as though they
    /// vanished.
    mapping(address => uint256) public registeredDirects;

    /// When each local bond was written. Only used by the correction
    /// window below.
    mapping(address => uint256) public registeredAt;

    /// Whether a locally-registered wallet is currently counted
    /// toward its referrer RIGHT NOW. Moves in both directions --
    /// syncDirect() sets it and clears it from live stake.
    mapping(address => bool) public directCounted;

    /// What a wallet must hold, across all three programmes, before it
    /// counts as a direct for its referrer.
    uint256 public minDirectStakeFixed = 100 * 1e18;

    /// What a wallet must hold before others may register beneath it.
    uint256 public minReferrerStakeFixed = 100 * 1e18;

    // ================= USD-DENOMINATED THRESHOLDS =================
    //
    // A fixed 100 OSG entry price is a different barrier at $0.95 than
    // it is at $5. Holding the requirement at a dollar figure keeps the
    // door the same width as the token moves.
    //
    // The SHAPE and the SOURCE are separate on purpose. Today the owner
    // posts the price; the day an oracle exists it writes to the same
    // place, and nothing here has to be redeployed.

    bool    public usdPricing;                    // off = plain OSG
    uint256 public minDirectStakeUsd   = 100e8;   // $100, 8 decimals
    uint256 public minReferrerStakeUsd = 100e8;

    address public priceOracle;                   // 0 = owner-posted
    uint256 public osgUsdPosted = 1e8;            // $1.00

    /// An oracle that answers outside this band is ignored and the
    /// posted price stands. A feed that breaks must not be able to
    /// swing who qualifies.
    uint256 public priceFloor = 1e6;              // $0.01
    uint256 public priceCeil  = 1000e8;           // $1000

    /// Gas allowed to each stake source per read. TermStaking's
    /// stakedOf() walks a wallet's position array at roughly 4,300 gas a
    /// position, so 400,000 covers about ninety of them. A wallet that
    /// outgrows the budget reads as ZERO, not as an error -- which is why
    /// this is settable rather than fixed. Measure the real cost against
    /// the largest live account and raise it before anyone reaches the
    /// wall, not after.
    uint256 public sourceGasLimit = 400_000;

    /// Gas that must remain before the walk attempts ONE more level.
    /// Roughly 45,000-60,000 buys a level today, so 80,000 leaves margin.
    ///
    /// The point of this is to stop the hook running out of gas mid-walk,
    /// because it runs inside the downline user's own claim and a revert
    /// there loses every level rather than the tail of a deep chain. Set
    /// it to the cost of the whole walk instead of one step and it does
    /// the opposite -- it breaks at the first level and nothing accrues.
    uint256 public minGasPerLevel = 80_000;

    // ====================== LEVEL TABLE ======================

    /// L1 15% - L2 10% - L3 5% - L4 3% - L5 2% - L6-L15 1% each = 45%.
    uint256[LEVELS] public levelBps;

    /// Direct referrals needed to open each level: one per level.
    uint256[LEVELS] public levelConditions;

    uint256 public totalLevelBps;

    // ====================== COMMISSION LEDGER ======================

    mapping(address => uint256) public owed;
    mapping(address => uint256) public paid;

    /// Commission base, not a team-volume figure -- the full reward is
    /// added at every level that credits, so the same OSG is counted more
    /// than once across a deep chain. Do not surface it as team volume.
    mapping(address => uint256) public volume;

    // ====================== ACHIEVEMENT BONUS ======================

    struct Tier {
        uint256 directsNeeded;
        uint256 selfStakeNeeded; // OSG, the claimant's own
        uint256 stakeNeeded;     // OSG, summed over directs
        uint256 monthlyPayout;   // OSG -- always OSG, see below
        uint256 selfStakeUsd;    // 8 decimals, used when usdPricing
        uint256 stakeUsdNeeded;  // 8 decimals, used when usdPricing
    }

    // The BAR is a dollar figure; the PRIZE is OSG. A requirement has to
    // hold its real size as the token moves, or the door quietly closes
    // on newcomers. The payout comes out of emission, which is counted
    // in OSG, so that is what it stays denominated in.
    /// Index 1..maxRank. Index 0 is unused so a rank of 0 can mean
    /// "none". Sized at 11 so ranks can be added later without a
    /// redeploy -- v4.2 was fixed at four and that is exactly why
    /// R4 and R5 could not be bolted on.
    Tier[11] public tiers;
    uint8 public maxRank = 5;

    mapping(address => uint256) public rankSince;
    mapping(address => uint8)   public rankOf;
    mapping(address => uint256) public lastBonusAt;
    mapping(address => uint256) public bonusPaidTotal;

    /// The rank a wallet was last actually PAID at.
    ///
    /// accrueRankBonus prices an elapsed window at a single rate, but
    /// the window has two ends and the rank can differ at each. Pricing
    /// it at today's rank alone let a wallet sit at R1 for the whole
    /// window, reach R5 for one day, and collect the entire window at
    /// R5. payRank = min(live, stored) closed the falling direction and
    /// left the rising one open.
    ///
    /// Storing the last paid rank closes it without punishing anyone:
    /// the window is priced at the LOWER of the two ends, so nothing is
    /// ever overpaid and nothing already earned is taken away.
    ///
    /// Zero means "never accrued" and skips the comparison -- a first
    /// accrual has no earlier end to be lower than.
    mapping(address => uint8) public lastAccrualRank;

    // ====================== MIGRATION ======================

    /// Once true, the seed functions are dead for good. They also expire
    /// on their own at seedDeadline, so forgetting to call lockSeeding()
    /// costs a week rather than leaving an owner key that can rewrite
    /// anybody's balance for the life of the contract.
    bool public seedLocked;
    uint256 public immutable seedDeadline;

    /// Stops accrual dead without reverting, so the ledger can be
    /// exported into the next contract while it stands still.
    bool public accrualFrozen;

    /// Every wallet this contract has ever touched, so the next
    /// migration is a paged read rather than an event crawl. v4.2 had
    /// no such list and that is precisely why its ledger cannot be
    /// enumerated today.
    address[] public allUsers;
    mapping(address => bool) private _listed;

    // ====================== PAY SOURCES ======================

    enum PaySource { POOL, TREASURY }

    /// Rank bonus rides the daily emission by default. RewardPool's
    /// distribute() carries an emissionActive modifier, so when
    /// emission ends this has to move to TREASURY or rank pay stops.
    PaySource public rankPaySource    = PaySource.POOL;
    PaySource public airdropPaySource = PaySource.TREASURY;

    /// Share of the day's referral budget each may consume. What is
    /// left over is what level commission draws on, so the sum is
    /// capped to leave commission a floor it can rely on.
    uint256 public bonusShareBps   = 3_000;
    uint256 public airdropShareBps = 3_000;
    uint256 public constant MAX_COMBINED_SHARE_BPS = 6_000;

    /// A share of the day has to be measured against the day, not
    /// against whatever is left when a claim happens to arrive.
    /// Taking 30% of the remainder over and over reaches nearly the
    /// whole budget, which would leave level commission with nothing
    /// while every individual call still looked obedient.
    uint256 public spendDay;
    uint256 public rankSpentToday;
    uint256 public airdropSpentToday;



    /// Rank shortfalls, kept apart from level commission so the two
    /// never have to be told apart after the fact.
    mapping(address => uint256) public bonusOwed;

    // ====================== AIRDROP ======================

    mapping(address => uint256) public airdropOwed;
    mapping(address => uint256) public airdropPaid;
    uint256 public totalAirdropAssigned;
    uint256 public totalAirdropPaid;

    // ====================== ADMINS ======================

    uint8 public constant PERM_GRANT = 1; // assign airdrop directly
    mapping(address => uint8) public adminPerms;

    /// The task board writes airdrop entitlements here and nothing
    /// else. It never holds OSG and never calls the reward pool, so a
    /// broken board stops new tasks and moves no money.
    address public taskBoard;

    // ====================== SWITCHES ======================

    bool public commissionPaused;
    bool public rankPaused;
    bool public airdropPaused;

    /// Wallets per batch call. Three digits by design: past a few
    /// hundred the transaction stops fitting in a block.
    uint16 public maxBatch = 300;

    // ====================== EVENTS ======================

    event Registered(address indexed user, address indexed referrer);
    event DirectQualified(address indexed user, address indexed referrer, uint256 referrerDirects);
    event DirectDropped(address indexed user, address indexed referrer, uint256 referrerDirects);
    event ReferrerCorrected(address indexed user, address indexed oldReferrer, address indexed newReferrer);
    event StakeThresholdsUpdated(uint256 minDirectStake, uint256 minReferrerStake);
    event GasParamsUpdated(uint256 sourceGasLimit, uint256 minGasPerLevel);

    event CommissionAccrued(address indexed earner, address indexed from, uint8 level, uint256 amount);
    event CommissionPaid(address indexed earner, uint256 amount, uint256 remainingOwed);
    event PayoutCapped(address indexed earner, uint256 paidNow, uint256 remaining);
    event CommissionTruncated(address indexed from, uint256 levelsCompleted);

    event RankUpdated(address indexed user, uint8 oldRank, uint8 newRank, uint256 directVolume);
    event BonusPaid(address indexed user, uint8 rank, uint256 requested, uint256 received);
    event BonusShort(address indexed user, uint256 requested, uint256 received);

    event SourceUpdated(address indexed source, bool allowed);
    event LevelTableUpdated(uint256 totalBps);
    event TierUpdated(uint8 rank, uint256 directsNeeded, uint256 selfStakeNeeded, uint256 stakeNeeded, uint256 monthlyPayout);
    event TreasuryUpdated(address treasury);
    event StakeSourceAdded(address indexed addr, bytes4 selector, uint256 count);
    event StakeSourceRemoved(address indexed addr, bytes4 selector, uint256 count);
    event SeedingLocked();
    event AccrualFrozen(bool frozen);
    event PaySourceUpdated(uint8 what, PaySource src);
    event SharesUpdated(uint256 bonusBps, uint256 airdropBps);
    event AdminUpdated(address indexed admin, uint8 perms);
    event MaxBatchUpdated(uint16 n);
    event SwitchUpdated(uint8 what, bool paused);
    event AirdropAssigned(address indexed user, uint256 amount, uint256 taskId);
    event AirdropClaimed(address indexed user, uint256 amount, uint256 remaining);
    event AirdropShort(address indexed user, uint256 asked, uint256 sent);
    event AirdropRevoked(address indexed user, uint256 amount);
    event CarryPeriodsUpdated(uint256 periods);
    event UsdPricingSet(bool on);
    event TierUsdUpdated(uint8 rank, uint256 selfUsd, uint256 teamUsd);
    event RankAccrued(address indexed user, uint8 rank, uint256 daysElapsed, uint256 amount);
    event UsdThresholdsUpdated(uint256 directUsd, uint256 referrerUsd);
    event OsgPricePosted(uint256 price);
    event PriceOracleSet(address oracle);
    event PriceBandUpdated(uint256 lo, uint256 hi);
    event TaskBoardUpdated(address board);

    // ====================== CONSTRUCTION ======================

    constructor(
        address _staking,
        address _pool,
        address _owner,
        uint256 _seedDays
    ) Ownable(_owner) {
        if (!(_staking.code.length > 0)) revert StakingNotContract();
        if (!(_pool.code.length    > 0)) revert PoolNotContract();

        staking = IOSGStaking(_staking);
        pool    = IOSGRewardPool(_pool);
        if (!(_seedDays >= 1 && _seedDays <= 90)) revert SeedWindowOutOfRange();
        seedDeadline = block.timestamp + (_seedDays * 1 days);

        levelBps = [
            uint256(1_500), 1_000, 500, 300, 200,
            100, 100, 100, 100, 100,
            100, 100, 100, 100, 100
        ];
        for (uint256 i = 0; i < LEVELS; i++) {
            levelConditions[i] = i + 1;
            totalLevelBps += levelBps[i];
        }
        if (!(totalLevelBps <= MAX_TOTAL_LEVEL_BPS)) revert LevelTableTooRich();

        // R1..R5. The payout is a flat 2% of the team stake each rank
        // asks for. What discourages splitting one large team into
        // several small ones is the DIRECTS requirement, not the rate:
        // earning R5's 2,000 through R1 costs twenty wallets and 300
        // directs against fifteen. setTier() now enforces the flat-or-
        // falling rule rather than leaving it to a comment.
        tiers[1] = Tier(10,    500 * 1e18,   5_000 * 1e18,   100 * 1e18,    500e8,   5_000e8);
        tiers[2] = Tier(15,  1_000 * 1e18,  10_000 * 1e18,   200 * 1e18,  1_000e8,  10_000e8);
        tiers[3] = Tier(15,  3_000 * 1e18,  25_000 * 1e18,   500 * 1e18,  3_000e8,  25_000e8);
        tiers[4] = Tier(15,  5_000 * 1e18,  50_000 * 1e18, 1_000 * 1e18,  5_000e8,  50_000e8);
        tiers[5] = Tier(15, 10_000 * 1e18, 100_000 * 1e18, 2_000 * 1e18, 10_000e8, 100_000e8);
    }

    // ====================== THE TREE ======================

    /// The local bond wins; OSGStaking is the fallback. Reading in this
    /// order is what lets old teams carry over without anybody touching
    /// them, and register() guarantees the two can never both be set for
    /// the same wallet.
    function _referrerOf(address user) internal view returns (address) {
        address local = nativeReferrer[user];
        if (local != address(0)) return local;
        (, , , , , , address legacy, , , , ) = staking.users(user);
        return legacy;
    }

    function referrerOf(address user) external view returns (address) {
        return _referrerOf(user);
    }

    /// Directs from both trees. Levels open on this number.
    function _directCount(address user) internal view returns (uint256) {
        (, , , , , , , uint256 legacyDirects, , , ) = staking.users(user);
        return legacyDirects + nativeDirects[user];
    }

    /// True if `target` sits anywhere above `start`. Bounded, so a chain
    /// that is already circular for some legacy reason cannot hang this.
    function _reachesUpward(address start, address target) internal view returns (bool) {
        address current = start;
        for (uint256 i = 0; i < LOOP_SCAN_DEPTH; i++) {
            if (current == address(0)) return false;
            if (current == target)     return true;
            current = _referrerOf(current);
        }
        return false;
    }

    /// Bind yourself under a referrer. Once only, and permanent.
    ///
    /// The referrer must already hold minReferrerStake, so an upline is
    /// always somebody with money of their own in the system -- the same
    /// condition OSGStaking enforced, now measured across all three
    /// programmes instead of Active Staking alone.
    function register(address referrer) external whenNotPaused {
        address user = msg.sender;
        if (!(referrer != address(0))) revert ZeroReferrer();
        if (!(referrer != user)) revert CannotReferYourself();
        if (!(nativeReferrer[user] == address(0))) revert AlreadyRegistered();

        (, , , , , , address legacy, , , , ) = staking.users(user);
        if (!(legacy == address(0))) revert UplineExistsInStaking();

        if (!(stakeOf(referrer) >= minReferrerStake())) revert ReferrerStakeTooLow();
        if (!(!_reachesUpward(referrer, user))) revert WouldFormALoop();

        nativeReferrer[user] = referrer;
        registeredAt[user] = block.timestamp;
        unchecked { registeredDirects[referrer] += 1; }
        _children[referrer].push(user);
        _list(user);
        _list(referrer);
        emit Registered(user, referrer);

        // Somebody who funded the wallet before registering should not
        // have to wait for a second deposit to be counted.
        _syncDirect(user);
    }

    /// Bind a wallet that has no upline anywhere. For repairing an
    /// onboarding that went wrong, not for reassigning live teams --
    /// the same one-time rules apply and an existing bond blocks it.
    function registerFor(address user, address referrer) external onlyOwner {
        if (!(user != address(0))) revert ZeroUser();
        if (!(referrer != address(0))) revert ZeroReferrer();
        if (!(referrer != user)) revert CannotReferItself();
        if (!(nativeReferrer[user] == address(0))) revert AlreadyRegistered();

        (, , , , , , address legacy, , , , ) = staking.users(user);
        if (!(legacy == address(0))) revert UplineExistsInStaking();

        // The same stake test register() applies. Without it the owner
        // could write a bond the contract would refuse from the user,
        // and an upline earning on somebody it was never eligible to
        // take is the one outcome nobody would accept as an accident.
        if (!(stakeOf(referrer) >= minReferrerStake())) revert ReferrerStakeTooLow();
        if (!(!_reachesUpward(referrer, user))) revert WouldFormALoop();

        nativeReferrer[user] = referrer;
        registeredAt[user] = block.timestamp;
        unchecked { registeredDirects[referrer] += 1; }
        _children[referrer].push(user);
        _list(user);
        _list(referrer);
        emit Registered(user, referrer);
        _syncDirect(user);
    }

    /// Repoint a bond that was written under the wrong referrer.
    ///
    /// Deliberately narrow. It expires CORRECTION_WINDOW after the
    /// registration and closes the moment the wallet counts as a direct,
    /// so it can undo a bad link but cannot be used to move somebody who
    /// has staked and started earning for their upline. Outside those two
    /// conditions a bond is permanent, which is the only version of this
    /// that does not turn every referral dispute into an appeal.
    function correctReferrer(address user, address newReferrer) external onlyOwner {
        address old = nativeReferrer[user];
        if (!(old != address(0))) revert NotRegisteredHere();
        if (!(!directCounted[user])) revert AlreadyCountedAsADirect();
        if (!(block.timestamp <= registeredAt[user] + CORRECTION_WINDOW)) revert CorrectionWindowClosed();
        if (!(newReferrer != address(0))) revert ZeroReferrer();
        if (!(newReferrer != user)) revert CannotReferItself();
        if (!(newReferrer != old)) revert SameReferrer();
        if (!(stakeOf(newReferrer) >= minReferrerStake())) revert ReferrerStakeTooLow();
        if (!(!_reachesUpward(newReferrer, user))) revert WouldFormALoop();

        nativeReferrer[user] = newReferrer;
        registeredAt[user] = block.timestamp;
        if (registeredDirects[old] > 0) {
            unchecked { registeredDirects[old] -= 1; }
        }
        unchecked { registeredDirects[newReferrer] += 1; }

        // Linear, and deliberately so. This runs owner-only, inside a
        // 24-hour window, on a wallet that has not yet qualified -- so
        // the list being walked is a young one. An index map would make
        // it constant-time and cost every registration more storage
        // forever to speed up a call that should be rare.
        address[] storage sibs = _children[old];
        for (uint256 i = 0; i < sibs.length; i++) {
            if (sibs[i] == user) {
                sibs[i] = sibs[sibs.length - 1];
                sibs.pop();
                break;
            }
        }
        _children[newReferrer].push(user);

        emit ReferrerCorrected(user, old, newReferrer);
        _syncDirect(user);
    }

    /// Bring a wallet's counted/not-counted state in line with what it
    /// actually holds right now. Adds a direct that has reached
    /// minDirectStake; REMOVES one that has fallen below it.
    ///
    /// Open to anyone, and it has to be. A one-way latch let a single
    /// 100 OSG float be walked from wallet to wallet, qualifying each in
    /// turn, so fifteen levels cost one stake and some patience rather
    /// than fifteen stakes. Reading live state in both directions is the
    /// only thing that actually closes that.
    ///
    /// An open door is safe here because this function cannot lie: it
    /// writes exactly what the chain already says, so the worst a hostile
    /// caller can do is make the count accurate.
    function syncDirect(address user) external {
        _syncDirect(user);
    }

    /// seedTree writes the bond but not the qualification, and levels
    /// open on the qualified count. Without this pass a migrated team
    /// would land with its tree intact and its levels shut. Open to
    /// anyone, since it only ever tells the truth about a stake.
    function syncDirects(address[] calldata users) external {
        if (!(users.length > 0 && users.length <= maxBatch)) revert BatchOutOfRange();
        for (uint256 i = 0; i < users.length; i++) _syncDirect(users[i]);
    }

    /// Retained under its old name so nothing that already calls it
    /// breaks. Same two-way behaviour.
    function qualify(address user) external {
        _syncDirect(user);
    }

    function _syncDirect(address user) internal {
        address ref = nativeReferrer[user];
        if (ref == address(0)) return;

        bool qualifies = qualifyingStakeOf(user) >= minDirectStake();
        bool counted   = directCounted[user];
        if (qualifies == counted) return;

        if (qualifies) {
            directCounted[user] = true;
            unchecked { nativeDirects[ref] += 1; }
            emit DirectQualified(user, ref, nativeDirects[ref]);
        } else {
            directCounted[user] = false;
            if (nativeDirects[ref] > 0) {
                unchecked { nativeDirects[ref] -= 1; }
            }
            emit DirectDropped(user, ref, nativeDirects[ref]);
        }
    }

    /// Called by TermStaking and LPMining whenever a wallet's stake
    /// moves. Its only job here is to notice a new direct crossing the
    /// threshold. Sources wrap this in try/catch, so a revert would be
    /// swallowed rather than surfaced -- hence it does nothing that can
    /// fail, and reports nothing back.
    function onLiquidityChange(address user, uint256, bool) external {
        if (!(isSource[msg.sender])) revert NotASource();
        _syncDirect(user);
    }

    // ====================== LEVEL COMMISSION ======================

    /// Called by a source contract when it pays a reward. Walks up to
    /// fifteen levels and credits each unlocked one.
    ///
    /// This only ever writes to `owed`. It never transfers and never
    /// touches RewardPool, because it runs inside the downline user's own
    /// claim and a referral-side failure must never cost that user their
    /// reward.
    ///
    /// Deliberately NOT whenNotPaused: a pause must stop payouts, not
    /// erase entitlements. Sources swallow reverts, so a paused accrual
    /// would vanish without a trace while the downline claim succeeded.
    function onRewardClaimed(address user, uint256 rewardAmount) external {
        if (!(isSource[msg.sender])) revert NotASource();
        if (rewardAmount == 0 || user == address(0)) return;
        // A clean cut-over point for the next migration. Returns
        // instead of reverting, so a frozen ledger never costs a
        // downline wallet its own reward.
        if (accrualFrozen) return;

        address current = user;
        for (uint256 i = 0; i < LEVELS; i++) {
            // Stop while there is still gas to return with. Running out
            // here reverts the whole hook, and the hook is inside the
            // downline user's claim, so every level would be lost rather
            // than the tail of a very deep chain.
            if (gasleft() < minGasPerLevel) {
                emit CommissionTruncated(user, i);
                break;
            }

            address ref = _referrerOf(current);
            if (ref == address(0)) break;
            // A chain that loops back to the claimant would otherwise pay
            // them commission on their own reward.
            if (ref == user) break;
            current = ref;

            if (!_levelUnlocked(ref, i + 1)) continue;

            // An upline that has taken its own money out stops earning.
            // Checked only on levels that are already open, so a wallet
            // with two levels pays for two of these reads, not fifteen.
            if (stakeOf(ref) < minReferrerStake()) continue;

            uint256 cut = (rewardAmount * levelBps[i]) / BPS_DENOM;
            if (cut == 0) continue;

            owed[ref]   += cut;
            volume[ref] += rewardAmount;
            // Registering the earner in the exportable list costs one
            // cold write, once per wallet ever. It is skipped when gas
            // is tight rather than risking the walk -- the next accrual
            // picks it up.
            if (!_listed[ref] && gasleft() > minGasPerLevel + 40_000) {
                _listed[ref] = true;
                allUsers.push(ref);
            }
            emit CommissionAccrued(ref, user, uint8(i + 1), cut);
        }
    }

    /// Take whatever commission has accrued, in chunks if it is large.
    function claimMyReferral() external nonReentrant whenNotPaused {
        if (!(!commissionPaused)) revert CommissionPaused();
        uint256 due = owed[msg.sender];
        if (!(due > 0)) revert NothingOwed();

        uint256 payout = due > MAX_SINGLE_ALLOC ? MAX_SINGLE_ALLOC : due;
        ( , , , , , uint256 referralAvail, ) = pool.getTodayStats();
        if (payout > referralAvail) payout = referralAvail;
        if (!(payout > 0)) revert NoReferralBudgetAvailableToday();

        owed[msg.sender] -= payout;
        paid[msg.sender] += payout;

        pool.distribute(msg.sender, payout, CAT_REFERRAL);
        emit CommissionPaid(msg.sender, payout, owed[msg.sender]);

        if (owed[msg.sender] > 0) {
            emit PayoutCapped(msg.sender, payout, owed[msg.sender]);
        }
    }

    // ====================== ACHIEVEMENT BONUS ======================

    /// Total OSG a wallet holds staked across all three programmes.
    ///
    /// What counts toward BECOMING a direct: the registered sources only,
    /// deliberately excluding Active Staking.
    ///
    /// Active Staking fires no hooks. A wallet that qualifies on it and
    /// then unstakes would stay counted until somebody happened to call
    /// syncDirect(), which a Sybil never would -- so one float could be
    /// walked from wallet to wallet and open every level. TermStaking and
    /// LPMining report withdrawals in the same transaction, so a direct
    /// funded through them cannot outlive its own stake.
    ///
    /// This does not take anything away from existing teams: directs
    /// earned inside OSGStaking are counted by OSGStaking and added on
    /// top in _directCount(). It only decides who counts as a NEW direct,
    /// and new members belong in Term or LP anyway.
    function qualifyingStakeOf(address user) public view returns (uint256 total) {
        uint256 n = stakeSources.length;
        for (uint256 i = 0; i < n; i++) {
            StakeSource storage src = stakeSources[i];
            (bool ok, bytes memory data) = src.addr.staticcall{gas: sourceGasLimit}(
                abi.encodeWithSelector(src.selector, user)
            );
            if (ok && data.length >= 32) {
                total += abi.decode(data, (uint256));
            }
        }
    }

    /// Every source is read through a raw staticcall and a failure counts
    /// as zero rather than reverting. Every rank path runs through here,
    /// and so does _syncDirect, so one wrong address would otherwise take
    /// registration and the bonus programme down together. Understating a
    /// rank is recoverable; a dead contract is not.
    function stakeOf(address user) public view returns (uint256 total) {
        (uint256 activeStake, , , , , , , , , , ) = staking.users(user);
        total = activeStake;

        uint256 n = stakeSources.length;
        for (uint256 i = 0; i < n; i++) {
            StakeSource storage s = stakeSources[i];
            (bool ok, bytes memory data) = s.addr.staticcall{gas: sourceGasLimit}(
                abi.encodeWithSelector(s.selector, user)
            );
            // A missing contract, a renamed function or a short answer
            // all count as zero. staticcall on a non-contract succeeds
            // with empty data, which the length check catches.
            if (ok && data.length >= 32) {
                total += abi.decode(data, (uint256));
            }
        }
    }

    /// Sum the stake of a supplied list of directs, after checking every
    /// entry is genuinely a direct of `user` and that the list holds no
    /// duplicates. Ascending order is what rules duplicates out.
    function _verifiedDirectVolume(address user, address[] calldata directs)
        internal
        view
        returns (uint256 count, uint256 stakeTotal)
    {
        if (!(directs.length <= MAX_DIRECTS_PER_CALL)) revert TooManyAtOnce();

        // Hoisted: the threshold can reach the price oracle, and asking
        // it once per direct would be fifty external calls to answer one
        // question.
        uint256 bar = minDirectStake();

        address previous;
        for (uint256 i = 0; i < directs.length; i++) {
            address d = directs[i];
            if (!(d > previous)) revert ListMustAscendNoDuplicates();
            previous = d;

            if (!(_referrerOf(d) == user)) revert NotYourDirect();

            // Registered is not the same as staked. Ten empty wallets
            // must not stand in for ten stakers.
            //
            // The test is made HERE and NOW rather than read from
            // directCounted, for two reasons. directCounted is only ever
            // written for wallets that registered on this contract, so
            // trusting it would make every direct inherited from
            // OSGStaking invisible and lock legacy teams out of every
            // rank. And because this is a live read, the stale-flag
            // problem that keeps Active Staking out of qualifyingStakeOf
            // does not arise: a wallet that unstakes simply fails the
            // check the next time it is asked. Every kind of stake --
            // Flexi, Term, LP -- therefore counts, which is also what
            // the member sees when they look at their own balance.
            uint256 st = stakeOf(d);
            if (st < bar) continue;

            unchecked { count += 1; }
            stakeTotal += st;
        }
    }

    function _rankFor(uint256 directCount, uint256 stakeTotal, uint256 selfStake)
        internal
        view
        returns (uint8 rank)
    {
        // Counts down from the top so the highest tier a wallet meets is
        // the one returned. Written as `r > 0` rather than `r >= 1`
        // because r is unsigned: at r == 0 the decrement would wrap to
        // 255 and the loop would never end.
        // One price read for the whole walk. Asking the oracle once per
        // comparison meant up to ten external calls to answer a single
        // question, all of which had to agree.
        uint256 px = usdPricing ? osgUsdPrice() : 0;

        for (uint8 r = maxRank; r > 0; r--) {
            Tier storage t = tiers[r];
            if (t.monthlyPayout == 0) continue;

            uint256 needTeam = px == 0
                ? t.stakeNeeded
                : (t.stakeUsdNeeded * 1e18) / px;
            uint256 needSelf = px == 0
                ? t.selfStakeNeeded
                : (t.selfStakeUsd * 1e18) / px;

            if (directCount >= t.directsNeeded
                && stakeTotal >= needTeam
                && selfStake  >= needSelf) {
                return r;
            }
        }
        return 0;
    }

    /// Prove -- or re-prove -- a rank.
    ///
    /// Restricted to the wallet itself or the owner. An empty directs
    /// list is a valid list that proves a rank of zero, and recording a
    /// change resets the 24-hour clock, so leaving this open would let a
    /// stranger drop any wallet to rank zero and repeat indefinitely.
    /// Nothing is lost by closing it: accrueRankBonus() re-proves the rank
    /// live, so a stale high rank in storage cannot be cashed in.
    ///
    /// Changing rank in EITHER direction restarts the clock, so a wallet
    /// about to collect at its current rank should collect first and
    /// refresh afterwards.
    function refreshRank(address user, address[] calldata directs)
        external
        whenNotPaused
    {
        if (!(msg.sender == user || msg.sender == owner())) revert SelfOrOwnerOnly();

        (uint256 count, uint256 stakeTotal) = _verifiedDirectVolume(user, directs);
        uint8 newRank = _rankFor(count, stakeTotal, stakeOf(user));
        uint8 oldRank = rankOf[user];

        if (newRank != oldRank) {
            rankOf[user] = newRank;
            rankSince[user] = newRank == 0 ? 0 : block.timestamp;
            emit RankUpdated(user, oldRank, newRank, stakeTotal);
        }
    }

    /// Turn time held at a rank into an entitlement.
    ///
    /// The month is a RATE, not an event. A wallet that reaches R3 today
    /// starts earning from today at R3's daily rate, and if it slips to
    /// R2 tomorrow it earns at R2's rate from tomorrow. Nothing is
    /// forfeited and nothing is back-paid at a rank no longer held --
    /// the rank is re-proved live on every call and the elapsed days are
    /// priced at whatever is true right now.
    ///
    /// The wallet itself or the owner, and nobody else. The rank is
    /// proved from a directs list the CALLER supplies, so an open door
    /// would let a stranger hand in a short list, have the month priced
    /// at a lower rank, and advance the clock past it. The difference
    /// would not be recoverable. refreshRank is closed for the same
    /// reason; this one moves money, so it matters more.
    function accrueRankBonus(address user, address[] calldata directs)
        external
        nonReentrant
        whenNotPaused
    {
        if (!(msg.sender == user || msg.sender == owner())) revert SelfOrOwnerOnly();
        if (!(!rankPaused)) revert RankBonusPaused();

        uint8 storedRank = rankOf[user];
        if (!(storedRank > 0)) revert NoRankRefreshRankFirst();
        if (!(block.timestamp >= rankSince[user] + RANK_HOLD)) revert RankHoldNotMet();

        (uint256 count, uint256 stakeTotal) = _verifiedDirectVolume(user, directs);
        uint8 liveRank = _rankFor(count, stakeTotal, stakeOf(user));
        if (!(liveRank > 0)) revert RankNoLongerMet();

        // What the wallet demonstrably holds at THIS end of the window.
        // This is the figure that gets stored, and it must not be
        // confused with what gets paid.
        uint8 capNow = liveRank < storedRank ? liveRank : storedRank;

        // What the window is PAID at: the lower of the two ends. A rank
        // that rose during the window does not back-date itself over
        // time spent lower down.
        uint8 payRank = capNow;
        uint8 lastRank = lastAccrualRank[user];
        if (lastRank != 0 && lastRank < payRank) payRank = lastRank;

        uint256 monthly = tiers[payRank].monthlyPayout;
        if (!(monthly > 0)) revert TierPaysNothing();

        // The clock starts at the 24-hour mark, not at registration, so a
        // wallet that qualified long ago and never called cannot show up
        // with a year of arrears.
        uint256 since = lastBonusAt[user];
        if (since == 0) since = rankSince[user] + RANK_HOLD;
        if (!(block.timestamp > since)) revert NothingAccruedYet();

        uint256 elapsed = block.timestamp - since;
        if (elapsed > MAX_ACCRUAL_WINDOW) elapsed = MAX_ACCRUAL_WINDOW;

        uint256 amount = (monthly * elapsed) / BONUS_PERIOD;
        if (!(amount > 0)) revert NothingAccruedYet();

        lastBonusAt[user]   = block.timestamp;
        bonusOwed[user]    += amount;
        // capNow, NOT payRank. Storing payRank would latch the wallet at
        // the lower rank for good: every later window would price
        // against a figure that only ever fell. capNow is what the
        // wallet holds today, so the next window opens at the rank it
        // has actually reached.
        lastAccrualRank[user] = capNow;
        _list(user);

        emit RankAccrued(user, payRank, elapsed / 1 days, amount);
    }

    // ====================== VIEWS ======================
    //
    // Only what the contract needs for its own decisions, plus the raw
    // getters a reader needs to reach everything else. Every aggregate,
    // health check and screen-shaped view lives in OSGReferralLens, which
    // holds no state and can be redeployed as often as the interface
    // changes without touching a single stored balance.

    function _levelUnlocked(address user, uint256 level) internal view returns (bool) {
        if (level == 0 || level > LEVELS) return false;
        return _directCount(user) >= levelConditions[level - 1];
    }

    /// Directs that count toward opening levels: legacy plus qualified.
    function directReferrals(address user) external view returns (uint256) {
        return _directCount(user);
    }

    /// Everyone registered directly under this wallet, in the order they
    /// joined. Registration order, not qualification -- a wallet that has
    /// withdrawn is still on the list.
    function childrenOf(address user) external view returns (address[] memory) {
        return _children[user];
    }

    /// A page of the child list, for a wallet with more directs than one
    /// call should return.
    function childrenSlice(address user, uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory page, uint256 total)
    {
        address[] storage all = _children[user];
        total = all.length;
        if (offset >= total) return (new address[](0), total);

        uint256 n = total - offset;
        if (n > limit) n = limit;
        page = new address[](n);
        for (uint256 i = 0; i < n; i++) page[i] = all[offset + i];
    }

    function childrenCount(address user) external view returns (uint256) {
        return _children[user].length;
    }

    function stakeSourceCount() external view returns (uint256) {
        return stakeSources.length;
    }

    function version() external pure returns (string memory) {
        return "OSGReferral v5";
    }

    function _requireSeedOpen() internal view {
        if (!(!seedLocked)) revert SeedingClosed();
        if (!(block.timestamp <= seedDeadline)) revert SeedWindowExpired();
    }

    function seedStatus() external view returns (bool open, uint256 secondsLeft) {
        if (seedLocked || block.timestamp > seedDeadline) return (false, 0);
        return (true, seedDeadline - block.timestamp);
    }

    /// Carry the commission ledger across. Idempotent by overwrite, so a
    /// batch can be re-sent if a transaction is lost.
    function seedLedger(
        address[] calldata users,
        uint256[] calldata owedAmt,
        uint256[] calldata paidAmt,
        uint256[] calldata volumeAmt
    ) external onlyOwner {
        _requireSeedOpen();
        if (!(users.length == owedAmt.length &&
            users.length == paidAmt.length &&
            users.length == volumeAmt.length)) revert LengthMismatch();
        for (uint256 i = 0; i < users.length; i++) {
            owed[users[i]]   = owedAmt[i];
            paid[users[i]]   = paidAmt[i];
            volume[users[i]] = volumeAmt[i];
            _list(users[i]);
        }
    }

    /// Carry the bonus clocks across. lastBonusAt is the one that
    /// matters: leave it at zero and a wallet paid last week could
    /// collect again the day this contract goes live.
    function seedBonus(
        address[] calldata users,
        uint8[]   calldata ranks,
        uint256[] calldata since,
        uint256[] calldata lastAt,
        uint256[] calldata bonusTotal
    ) external onlyOwner {
        _requireSeedOpen();
        if (!(users.length == ranks.length &&
            users.length == since.length &&
            users.length == lastAt.length &&
            users.length == bonusTotal.length)) revert LengthMismatch();
        for (uint256 i = 0; i < users.length; i++) {
            if (!(ranks[i] <= maxRank)) revert RankOutOfRange();
            rankOf[users[i]]         = ranks[i];
            // Seeded as well, so a migrated wallet's first accrual has
            // an earlier end to be compared against. Left at zero the
            // comparison is skipped and the first window prices at
            // today's rank -- the exact hole this pair of writes exists
            // to close.
            lastAccrualRank[users[i]] = ranks[i];
            rankSince[users[i]]      = since[i];
            lastBonusAt[users[i]]    = lastAt[i];
            bonusPaidTotal[users[i]] = bonusTotal[i];
            _list(users[i]);
        }
    }

    /// Close the seed doors for good. Do this the moment the figures
    /// have been checked -- an owner key that can rewrite balances is a
    /// standing invitation, and there is no reason to keep it open.
    function lockSeeding() external onlyOwner {
        seedLocked = true;
        emit SeedingLocked();
    }

    // ====================== ADMIN ======================

    function setSource(address source, bool allowed) external onlyOwner {
        if (!(source != address(0))) revert ZeroAddress();
        isSource[source] = allowed;
        emit SourceUpdated(source, allowed);
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = IOSGTreasury(_treasury);
        emit TreasuryUpdated(_treasury);
    }

    /// Register a programme whose balances should count. `selector` is
    /// the four bytes of a f(address) view returning uint256 --
    /// selectorFor() will compute it.
    ///
    /// The same address may appear twice under DIFFERENT selectors, which
    /// is legitimate if one contract reports two separate pots. The same
    /// address and selector together may not: that would count the money
    /// twice and inflate a rank.
    function addStakeSource(address addr, bytes4 selector) external onlyOwner {
        if (!(addr.code.length > 0)) revert SourceNotContract();
        if (!(selector != bytes4(0))) revert ZeroSelector();
        if (!(stakeSources.length < MAX_STAKE_SOURCES)) revert TooManySources();

        for (uint256 i = 0; i < stakeSources.length; i++) {
            if (!(stakeSources[i].addr != addr || stakeSources[i].selector != selector)) revert AlreadyASource();
        }

        stakeSources.push(StakeSource({ addr: addr, selector: selector }));
        emit StakeSourceAdded(addr, selector, stakeSources.length);
    }

    /// Remove by index. The last entry is moved into the gap, so indices
    /// after a removal are not what they were -- read stakeSourceHealth()
    /// again before removing a second one.
    ///
    /// Removing a source LOWERS every rank that depended on it, and
    /// lowers stakeOf() for the referrer threshold with it, immediately,
    /// because both read live.
    ///
    /// directCounted does NOT follow on its own. Nothing can walk every
    /// registered wallet from inside a transaction, so a wallet that
    /// qualified through the removed source stays counted until
    /// syncDirect() is called for it. The same applies in reverse after
    /// addStakeSource(). Treat a source change as a two-part operation:
    /// change the list, then sweep syncDirect() over the affected
    /// wallets. The DirectQualified and DirectDropped events are the
    /// record of that sweep having been done.
    function removeStakeSource(uint256 index) external onlyOwner {
        if (!(index < stakeSources.length)) revert IndexOutOfRange();
        StakeSource memory gone = stakeSources[index];
        stakeSources[index] = stakeSources[stakeSources.length - 1];
        stakeSources.pop();
        emit StakeSourceRemoved(gone.addr, gone.selector, stakeSources.length);
    }

    /// Both thresholds are live: raising minDirectStake does not un-count
    /// a direct already counted, and lowering it does not back-fill one.
    /// Anyone below the new line can be picked up with qualify().
    function setStakeThresholds(uint256 _minDirect, uint256 _minReferrer) external onlyOwner {
        if (!(_minDirect > 0)) revert MinDirectStakeMustBePositive();
        if (!(_minReferrer > 0)) revert MinReferrerStakeMustBePositive();
        minDirectStakeFixed   = _minDirect;
        minReferrerStakeFixed = _minReferrer;
        emit StakeThresholdsUpdated(_minDirect, _minReferrer);
    }

    /// Retune the two gas figures once the real cost has been measured.
    /// Floors stop either being set so low it silently stops working:
    /// too little source gas reads a live stake as zero, too little level
    /// gas breaks the walk before the first level accrues.
    function setGasParams(uint256 _sourceGas, uint256 _levelGas) external onlyOwner {
        if (!(_sourceGas >= MIN_SOURCE_GAS)) revert SourceGasBelowFloor();
        if (!(_levelGas  >= MIN_LEVEL_GAS)) revert LevelGasBelowFloor();
        sourceGasLimit = _sourceGas;
        minGasPerLevel = _levelGas;
        emit GasParamsUpdated(_sourceGas, _levelGas);
    }

    function setLevelBps(uint256[LEVELS] calldata newBps) external onlyOwner {
        uint256 sum;
        for (uint256 i = 0; i < LEVELS; i++) sum += newBps[i];
        if (!(sum <= MAX_TOTAL_LEVEL_BPS)) revert LevelTableTooRich();

        levelBps = newBps;
        totalLevelBps = sum;
        emit LevelTableUpdated(sum);
    }

    /// Conditions must not fall as the levels rise, and level 1 must ask
    /// for at least one direct -- a zero there would open the first level
    /// to every wallet on the chain.
    function setLevelConditions(uint256[LEVELS] calldata newConditions) external onlyOwner {
        if (!(newConditions[0] >= 1)) revert Level1NeedsADirect();
        for (uint256 i = 1; i < LEVELS; i++) {
            if (!(newConditions[i] >= newConditions[i - 1])) revert ConditionsMustNotFall();
        }
        levelConditions = newConditions;
    }

    function setTier(
        uint8 rank,
        uint256 directsNeeded,
        uint256 selfStakeNeeded,
        uint256 stakeNeeded,
        uint256 monthlyPayout
    ) external onlyOwner {
        if (!(rank >= 1 && rank <= maxRank)) revert RankOutOfRange();
        if (!(stakeNeeded > 0)) revert TeamStakeIsZero();
        // The rate must not RISE as the ranks rise. A cheaper rank
        // paying a better rate is an invitation to split one team into
        // several, and in v4.2 this rule lived only in a comment.
        if (rank > 1 && tiers[rank - 1].monthlyPayout > 0) {
            if (!(monthlyPayout * tiers[rank - 1].stakeNeeded
                    <= tiers[rank - 1].monthlyPayout * stakeNeeded)) revert RateRisesWithRank();
        }
        // Checking only the rank below leaves the door open the other
        // way: raising R1's rate above R2's would make splitting one
        // team into several the cheaper move, which is the exact
        // behaviour this rule exists to prevent.
        if (rank < maxRank && tiers[rank + 1].monthlyPayout > 0) {
            if (!(tiers[rank + 1].monthlyPayout * stakeNeeded
                    <= monthlyPayout * tiers[rank + 1].stakeNeeded)) revert RateRisesWithRank();
        }
        Tier storage cur = tiers[rank];
        tiers[rank] = Tier(
            directsNeeded, selfStakeNeeded, stakeNeeded, monthlyPayout,
            cur.selfStakeUsd, cur.stakeUsdNeeded
        );
        emit TierUpdated(rank, directsNeeded, selfStakeNeeded, stakeNeeded, monthlyPayout);
    }


    // =====================================================================
    //  ADMIN ROLES
    // =====================================================================

    /// The owner appoints, the owner revokes, and the owner decides how
    /// much each appointee may do. An admin never moves OSG directly --
    /// everything an admin touches lands in a ledger the wallet itself
    /// still has to claim.
    modifier onlyAdmin(uint8 perm) {
        if (!(msg.sender == owner() || (adminPerms[msg.sender] & perm) != 0)) revert NotPermitted();
        _;
    }

    /// The dollar side of a tier, set on its own so the OSG figures a
    /// reader already knows are never disturbed by a currency change.
    function setTierUsd(uint8 rank, uint256 selfUsd, uint256 teamUsd)
        external
        onlyOwner
    {
        if (!(rank >= 1 && rank <= maxRank)) revert RankOutOfRange();
        if (!(teamUsd > 0 && selfUsd > 0)) revert ThresholdIsZero();

        // The same flat-or-falling rule setTier enforces on the OSG
        // figures. When usdPricing is on these are the numbers that
        // decide, so leaving them unchecked would have left the door to
        // splitting open in the currency that was actually in use.
        uint256 pay = tiers[rank].monthlyPayout;
        if (rank > 1 && tiers[rank - 1].monthlyPayout > 0) {
            if (!(pay * tiers[rank - 1].stakeUsdNeeded
                    <= tiers[rank - 1].monthlyPayout * teamUsd))
                revert RateRisesWithRank();
        }
        if (rank < maxRank && tiers[rank + 1].monthlyPayout > 0) {
            if (!(tiers[rank + 1].monthlyPayout * teamUsd
                    <= pay * tiers[rank + 1].stakeUsdNeeded))
                revert RateRisesWithRank();
        }

        tiers[rank].selfStakeUsd   = selfUsd;
        tiers[rank].stakeUsdNeeded = teamUsd;
        emit TierUsdUpdated(rank, selfUsd, teamUsd);
    }

    function setAdmin(address who, uint8 perms) external onlyOwner {
        if (!(who != address(0))) revert ZeroAdmin();
        if (!(perms <= 1)) revert BadPermission();
        adminPerms[who] = perms;
        emit AdminUpdated(who, perms);
    }

    // =====================================================================
    //  PAYMENT
    // =====================================================================

    function _list(address user) internal {
        if (user != address(0) && !_listed[user]) {
            _listed[user] = true;
            allUsers.push(user);
        }
    }

    /// Draw against a slice of today's referral budget. The slice is what
    /// keeps rank pay and airdrop from eating the level commission that
    /// the existing base already lives on.
    function _rollDay() internal {
        uint256 day = (block.timestamp - pool.startTime()) / 1 days;
        if (day != spendDay) {
            spendDay          = day;
            rankSpentToday    = 0;
            airdropSpentToday = 0;
        }
    }

    /// The quota is a slice of the DAY's referral budget, and what has
    /// already been drawn against it today is subtracted. The day is
    /// measured on the pool's own clock so the two never drift apart.
    function _payFromPool(address to, uint256 amount, bool isRank)
        internal
        returns (uint256 sent)
    {
        _rollDay();

        ( , , uint256 refUsed, , , uint256 refAvail, ) = pool.getTodayStats();
        uint256 dayTotal = refUsed + refAvail;

        uint256 quota = (dayTotal * (isRank ? bonusShareBps : airdropShareBps))
                        / BPS_DENOM;
        uint256 spent = isRank ? rankSpentToday : airdropSpentToday;
        if (spent >= quota) return 0;

        uint256 ceiling = quota - spent;
        // Never promise more than the pool actually has left today,
        // and never more than one allocation may carry.
        if (ceiling > refAvail)         ceiling = refAvail;
        if (ceiling > MAX_SINGLE_ALLOC) ceiling = MAX_SINGLE_ALLOC;

        sent = amount > ceiling ? ceiling : amount;
        if (sent == 0) return 0;

        if (isRank) { rankSpentToday += sent; }
        else        { airdropSpentToday += sent; }

        pool.distribute(to, sent, CAT_REFERRAL);
    }

    function _payRank(address to, uint256 amount) internal returns (uint256) {
        if (rankPaySource == PaySource.TREASURY) {
            if (address(treasury) == address(0)) return 0;
            return treasury.spendTeamBonus(to, amount);
        }
        return _payFromPool(to, amount, true);
    }

    function _payAirdrop(address to, uint256 amount) internal returns (uint256) {
        if (airdropPaySource == PaySource.TREASURY) {
            if (address(treasury) == address(0)) return 0;
            return treasury.spendAirdrop(to, amount);
        }
        return _payFromPool(to, amount, false);
    }

    /// Collect a rank month that was only partly paid. Kept separate from
    /// claimMyReferral so the two ledgers never blur into one figure.
    function claimBonusOwed() external nonReentrant whenNotPaused {
        if (!(!rankPaused)) revert RankBonusPaused();
        uint256 due = bonusOwed[msg.sender];
        if (!(due > 0)) revert NothingOwed();

        uint256 want = due > MAX_SINGLE_ALLOC ? MAX_SINGLE_ALLOC : due;
        uint256 sent = _payRank(msg.sender, want);
        if (!(sent > 0)) revert NoRankBudgetToday();

        bonusOwed[msg.sender]      = due - sent;
        bonusPaidTotal[msg.sender] += sent;
        emit BonusPaid(msg.sender, rankOf[msg.sender], want, sent);
    }

    // =====================================================================
    //  AIRDROP
    // =====================================================================

    /// Nothing is sent here, which is why hundreds of wallets fit in one
    /// call: RewardPool allows a distributor a single distribute() per
    /// block. Entitlement and payment had to be separated for the design
    /// to work at all. Pass add=false to take back what has not yet been
    /// collected -- OSG already sent is gone.
    function adjustAirdrop(address[] calldata users, uint256[] calldata amounts, bool add)
        external
        onlyAdmin(PERM_GRANT)
    {
        if (!(users.length == amounts.length)) revert LengthMismatch();
        if (!(users.length > 0 && users.length <= maxBatch)) revert BatchOutOfRange();
        if (!add && !(msg.sender == owner())) revert NotPermitted();

        for (uint256 i = 0; i < users.length; i++) {
            address u = users[i];
            uint256 amt = amounts[i];
            if (u == address(0) || amt == 0) continue;

            if (add) {
                airdropOwed[u]       += amt;
                totalAirdropAssigned += amt;
                _list(u);
                emit AirdropAssigned(u, amt, type(uint256).max);
            } else {
                uint256 due = airdropOwed[u];
                uint256 cut = amt > due ? due : amt;
                airdropOwed[u]        = due - cut;
                totalAirdropAssigned -= cut;
                emit AirdropRevoked(u, cut);
            }
        }
    }

    function setTaskBoard(address board) external onlyOwner {
        taskBoard = board;
        emit TaskBoardUpdated(board);
    }

    /// The single door the task board may write through. One wallet,
    /// one amount, no token movement -- the wallet still has to come
    /// and claim it, which is what keeps the reward pool's one-call-
    /// per-block rule out of the way.
    function grantAirdrop(address user, uint256 amount) external {
        if (!(msg.sender == taskBoard
                || msg.sender == owner()
                || (adminPerms[msg.sender] & PERM_GRANT) != 0)) revert NotPermitted();
        if (!(user != address(0))) revert ZeroUser();
        if (!(amount > 0)) revert AmountIsZero();

        airdropOwed[user]    += amount;
        totalAirdropAssigned += amount;
        _list(user);
        emit AirdropAssigned(user, amount, type(uint256).max);
    }

    /// Same verification accrueRankBonus uses, exposed so the task
    /// board measures directs and team stake by exactly one
    /// definition rather than keeping a second copy of the rules.
    /// The rank a wallet meets RIGHT NOW. rankOf is the stored rank and
    /// can outlive the conditions that earned it, so anything deciding
    /// eligibility has to re-prove it rather than trust the record.
    function currentRank(address user, address[] calldata directs)
        external
        view
        returns (uint8)
    {
        (uint256 count, uint256 stakeTotal) = _verifiedDirectVolume(user, directs);
        return _rankFor(count, stakeTotal, stakeOf(user));
    }

    /// OSG per dollar, from the oracle when it answers sanely and from
    /// the posted price otherwise.
    function osgUsdPrice() public view returns (uint256) {
        if (priceOracle != address(0)) {
            try IOSGPriceOracle(priceOracle).osgUsdPrice() returns (uint256 q) {
                if (q >= priceFloor && q <= priceCeil) return q;
            } catch {}
        }
        return osgUsdPosted;
    }

    function usdToOsg(uint256 usd8) public view returns (uint256) {
        uint256 px = osgUsdPrice();
        if (px == 0) return 0;
        return (usd8 * 1e18) / px;
    }

    function minDirectStake() public view returns (uint256) {
        return usdPricing ? usdToOsg(minDirectStakeUsd) : minDirectStakeFixed;
    }

    function minReferrerStake() public view returns (uint256) {
        return usdPricing ? usdToOsg(minReferrerStakeUsd) : minReferrerStakeFixed;
    }

    function setUsdPricing(bool on) external onlyOwner {
        usdPricing = on;
        emit UsdPricingSet(on);
    }

    function setUsdThresholds(uint256 directUsd, uint256 referrerUsd)
        external
        onlyOwner
    {
        if (!(referrerUsd > 0 && directUsd > 0)) revert ThresholdIsZero();
        minDirectStakeUsd   = directUsd;
        minReferrerStakeUsd = referrerUsd;
        emit UsdThresholdsUpdated(directUsd, referrerUsd);
    }

    /// The owner posts the price today. An oracle contract given this
    /// same door tomorrow changes nothing else.
    function setOsgUsdPosted(uint256 px) external onlyOwner {
        if (!(px >= priceFloor && px <= priceCeil)) revert PriceOutOfBand();
        osgUsdPosted = px;
        emit OsgPricePosted(px);
    }

    function setPriceOracle(address o) external onlyOwner {
        priceOracle = o;
        emit PriceOracleSet(o);
    }

    function setPriceBand(uint256 lo, uint256 hi) external onlyOwner {
        if (!(lo > 0 && hi > lo)) revert BadBand();
        priceFloor = lo;
        priceCeil  = hi;
        emit PriceBandUpdated(lo, hi);
    }

    function verifiedDirectVolume(address user, address[] calldata directs)
        external
        view
        returns (uint256 count, uint256 stakeTotal)
    {
        return _verifiedDirectVolume(user, directs);
    }

    /// Undo an entitlement granted in error. Owner only, and only
    /// what has not been collected yet -- OSG already sent is gone.
    function revokeAirdrop(address[] calldata users, uint256[] calldata amounts)
        external
        onlyOwner
    {
        if (!(users.length == amounts.length)) revert LengthMismatch();
        if (!(users.length > 0 && users.length <= maxBatch)) revert BatchOutOfRange();

        for (uint256 i = 0; i < users.length; i++) {
            address u   = users[i];
            uint256 due = airdropOwed[u];
            if (due == 0) continue;
            uint256 cut = amounts[i] > due ? due : amounts[i];
            airdropOwed[u]        = due - cut;
            totalAirdropAssigned -= cut;
            emit AirdropRevoked(u, cut);
        }
    }

    function claimAirdrop() external nonReentrant whenNotPaused {
        if (!(!airdropPaused)) revert AirdropPaused();
        uint256 due = airdropOwed[msg.sender];
        if (!(due > 0)) revert NothingOwed();

        uint256 want = due > MAX_SINGLE_ALLOC ? MAX_SINGLE_ALLOC : due;
        uint256 sent = _payAirdrop(msg.sender, want);
        if (!(sent > 0)) revert NoAirdropBudgetToday();

        airdropOwed[msg.sender] = due - sent;
        airdropPaid[msg.sender] += sent;
        totalAirdropPaid        += sent;

        emit AirdropClaimed(msg.sender, sent, airdropOwed[msg.sender]);
        if (sent < want) emit AirdropShort(msg.sender, want, sent);
    }

    // =====================================================================
    //  EXPORT -- paged reads for the next migration
    // =====================================================================

    function usersLength() external view returns (uint256) {
        return allUsers.length;
    }

    // =====================================================================
    //  MIGRATION IN
    // =====================================================================

    /// Write the local tree straight across. registerFor() refuses a
    /// wallet that already has a Staking upline, which is correct for
    /// repairs and wrong for a migration, so seeding gets its own door --
    /// one that shuts with the rest of them.
    function seedTree(address[] calldata users, address[] calldata refs)
        external
        onlyOwner
    {
        if (!(!seedLocked)) revert SeedingClosed();
        if (!(block.timestamp <= seedDeadline)) revert SeedWindowExpired();
        if (!(users.length == refs.length)) revert LengthMismatch();
        if (!(users.length > 0 && users.length <= maxBatch)) revert BatchOutOfRange();

        for (uint256 i = 0; i < users.length; i++) {
            address u = users[i];
            address r = refs[i];
            if (!(u != address(0) && r != address(0))) revert ZeroAddress();
            if (!(u != r)) revert CannotReferItself();
            if (!(!_reachesUpward(r, u))) revert WouldFormALoop();

            // Overwriting a local upline would leave the previous
            // referrer's child list and direct count pointing at a
            // wallet that is no longer theirs. Seeding is a one-way
            // write; a correction is what correctReferrer is for.
            if (!(nativeReferrer[u] == address(0))) revert AlreadyRegistered();

            unchecked { registeredDirects[r] += 1; }
            _children[r].push(u);
            nativeReferrer[u] = r;
            registeredAt[u]   = block.timestamp;
            _list(u);
            _list(r);
            emit Registered(u, r);
        }
    }

    // =====================================================================
    //  SWITCHES
    // =====================================================================

    function setRankPaySource(PaySource src) external onlyOwner {
        rankPaySource = src;
        emit PaySourceUpdated(0, src);
    }

    function setAirdropPaySource(PaySource src) external onlyOwner {
        airdropPaySource = src;
        emit PaySourceUpdated(1, src);
    }

    /// What rank pay and airdrop may take out of the daily referral
    /// budget. The cap is what leaves level commission a floor.
    function setShares(uint256 bonusBps, uint256 airdropBps) external onlyOwner {
        if (!(bonusBps + airdropBps <= MAX_COMBINED_SHARE_BPS)) revert ShareCapExceeded();
        bonusShareBps   = bonusBps;
        airdropShareBps = airdropBps;
        emit SharesUpdated(bonusBps, airdropBps);
    }

    function setMaxRank(uint8 newMax) external onlyOwner {
        if (!(newMax >= 1 && newMax <= 10)) revert BadRankCount();
        // Every rank being switched on has to actually pay something,
        // otherwise _rankFor walks past it and the rank exists in name
        // only.
        for (uint8 r = 1; r <= newMax; r++) {
            if (!(tiers[r].monthlyPayout > 0)) revert TierNotConfigured();
        }
        maxRank = newMax;
    }

    function setMaxBatch(uint16 n) external onlyOwner {
        if (!(n >= 1 && n <= 999)) revert BadBatchSize();
        maxBatch = n;
        emit MaxBatchUpdated(n);
    }

    function setAccrualFrozen(bool frozen) external onlyOwner {
        accrualFrozen = frozen;
        emit AccrualFrozen(frozen);
    }

    function setCommissionPaused(bool p) external onlyOwner {
        commissionPaused = p;
        emit SwitchUpdated(0, p);
    }

    function setRankPaused(bool p) external onlyOwner {
        rankPaused = p;
        emit SwitchUpdated(1, p);
    }

    function setAirdropPaused(bool p) external onlyOwner {
        airdropPaused = p;
        emit SwitchUpdated(2, p);
    }


    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
