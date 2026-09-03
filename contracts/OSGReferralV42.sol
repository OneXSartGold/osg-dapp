// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/*
 * ======================================================================
 *  OSGReferral v4.2
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
}

interface IOSGTreasury {
    /// Returns what was actually sent -- may be less than asked, may be
    /// zero, and never reverts on a shortfall.
    function spendTeamBonus(address to, uint256 amount) external returns (uint256 paid);
    function teamBonusAvailable() external view returns (uint256);
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

    uint256 public constant MAX_DIRECTS_PER_CALL = 200;

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
    /// reads in a single claimTeamBonus(). Six leaves room for Flexi and
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
    uint256 public minDirectStake = 100 * 1e18;

    /// What a wallet must hold before others may register beneath it.
    uint256 public minReferrerStake = 100 * 1e18;

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
        uint256 stakeNeeded;   // OSG, summed over directs
        uint256 monthlyPayout; // OSG
    }
    /// Index 1..3. Index 0 is unused so a rank of 0 can mean "none".
    Tier[4] public tiers;

    mapping(address => uint256) public rankSince;
    mapping(address => uint8)   public rankOf;
    mapping(address => uint256) public lastBonusAt;
    mapping(address => uint256) public bonusPaidTotal;

    // ====================== MIGRATION ======================

    /// Once true, the seed functions are dead for good. They also expire
    /// on their own at seedDeadline, so forgetting to call lockSeeding()
    /// costs a week rather than leaving an owner key that can rewrite
    /// anybody's balance for the life of the contract.
    bool public seedLocked;
    uint256 public immutable seedDeadline;

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
    event TierUpdated(uint8 rank, uint256 directsNeeded, uint256 stakeNeeded, uint256 monthlyPayout);
    event TreasuryUpdated(address treasury);
    event StakeSourceAdded(address indexed addr, bytes4 selector, uint256 count);
    event StakeSourceRemoved(address indexed addr, bytes4 selector, uint256 count);
    event SeedingLocked();

    // ====================== CONSTRUCTION ======================

    constructor(address _staking, address _pool, address _owner) Ownable(_owner) {
        require(_staking.code.length > 0, "staking not contract");
        require(_pool.code.length    > 0, "pool not contract");

        staking = IOSGStaking(_staking);
        pool    = IOSGRewardPool(_pool);
        seedDeadline = block.timestamp + 7 days;

        levelBps = [
            uint256(1_500), 1_000, 500, 300, 200,
            100, 100, 100, 100, 100,
            100, 100, 100, 100, 100
        ];
        for (uint256 i = 0; i < LEVELS; i++) {
            levelConditions[i] = i + 1;
            totalLevelBps += levelBps[i];
        }
        require(totalLevelBps <= MAX_TOTAL_LEVEL_BPS, "level table too rich");

        // A1 / A2 / A3. The payout is a flat 2.5% of the stake each tier
        // asks for. What discourages splitting one large team into
        // several small ones is the DIRECTS requirement, not the rate:
        // reaching A2 five times over costs 75 directs to earn exactly
        // what one A3 earns on 15. If these are ever retuned via
        // setTier(), keep the rate flat or falling as the tiers rise.
        tiers[1] = Tier({ directsNeeded: 10, stakeNeeded:  4_000 * 1e18, monthlyPayout:   100 * 1e18 });
        tiers[2] = Tier({ directsNeeded: 15, stakeNeeded: 10_000 * 1e18, monthlyPayout:   250 * 1e18 });
        tiers[3] = Tier({ directsNeeded: 15, stakeNeeded: 50_000 * 1e18, monthlyPayout: 1_250 * 1e18 });
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
        require(referrer != address(0), "zero referrer");
        require(referrer != user,       "cannot refer yourself");
        require(nativeReferrer[user] == address(0), "already registered");

        (, , , , , , address legacy, , , , ) = staking.users(user);
        require(legacy == address(0), "already has an upline in Staking");

        require(stakeOf(referrer) >= minReferrerStake, "referrer stake too low");
        require(!_reachesUpward(referrer, user), "that would form a loop");

        nativeReferrer[user] = referrer;
        registeredAt[user] = block.timestamp;
        unchecked { registeredDirects[referrer] += 1; }
        _children[referrer].push(user);
        emit Registered(user, referrer);

        // Somebody who funded the wallet before registering should not
        // have to wait for a second deposit to be counted.
        _syncDirect(user);
    }

    /// Bind a wallet that has no upline anywhere. For repairing an
    /// onboarding that went wrong, not for reassigning live teams --
    /// the same one-time rules apply and an existing bond blocks it.
    function registerFor(address user, address referrer) external onlyOwner {
        require(user != address(0),     "zero user");
        require(referrer != address(0), "zero referrer");
        require(referrer != user,       "cannot refer itself");
        require(nativeReferrer[user] == address(0), "already registered");

        (, , , , , , address legacy, , , , ) = staking.users(user);
        require(legacy == address(0), "already has an upline in Staking");

        // The same stake test register() applies. Without it the owner
        // could write a bond the contract would refuse from the user,
        // and an upline earning on somebody it was never eligible to
        // take is the one outcome nobody would accept as an accident.
        require(stakeOf(referrer) >= minReferrerStake, "referrer stake too low");
        require(!_reachesUpward(referrer, user), "that would form a loop");

        nativeReferrer[user] = referrer;
        registeredAt[user] = block.timestamp;
        unchecked { registeredDirects[referrer] += 1; }
        _children[referrer].push(user);
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
        require(old != address(0), "not registered here");
        require(!directCounted[user], "already counted as a direct");
        require(
            block.timestamp <= registeredAt[user] + CORRECTION_WINDOW,
            "correction window closed"
        );
        require(newReferrer != address(0), "zero referrer");
        require(newReferrer != user, "cannot refer itself");
        require(newReferrer != old, "same referrer");
        require(stakeOf(newReferrer) >= minReferrerStake, "referrer stake too low");
        require(!_reachesUpward(newReferrer, user), "that would form a loop");

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

    /// Retained under its old name so nothing that already calls it
    /// breaks. Same two-way behaviour.
    function qualify(address user) external {
        _syncDirect(user);
    }

    function _syncDirect(address user) internal {
        address ref = nativeReferrer[user];
        if (ref == address(0)) return;

        bool qualifies = qualifyingStakeOf(user) >= minDirectStake;
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
        require(isSource[msg.sender], "not a source");
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
        require(isSource[msg.sender], "not a source");
        if (rewardAmount == 0 || user == address(0)) return;

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
            if (stakeOf(ref) < minReferrerStake) continue;

            uint256 cut = (rewardAmount * levelBps[i]) / BPS_DENOM;
            if (cut == 0) continue;

            owed[ref]   += cut;
            volume[ref] += rewardAmount;
            emit CommissionAccrued(ref, user, uint8(i + 1), cut);
        }
    }

    /// Take whatever commission has accrued, in chunks if it is large.
    function claimMyReferral() external nonReentrant whenNotPaused {
        uint256 due = owed[msg.sender];
        require(due > 0, "nothing owed");

        uint256 payout = due > MAX_SINGLE_ALLOC ? MAX_SINGLE_ALLOC : due;
        ( , , , , , uint256 referralAvail, ) = pool.getTodayStats();
        if (payout > referralAvail) payout = referralAvail;
        require(payout > 0, "no referral budget available today");

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
        require(directs.length <= MAX_DIRECTS_PER_CALL, "too many at once");

        address previous;
        for (uint256 i = 0; i < directs.length; i++) {
            address d = directs[i];
            require(d > previous, "list must ascend, no duplicates");
            previous = d;

            require(_referrerOf(d) == user, "not your direct");

            stakeTotal += stakeOf(d);
        }
        count = directs.length;
    }

    function _rankFor(uint256 directCount, uint256 stakeTotal)
        internal
        view
        returns (uint8 rank)
    {
        // Counts down from the top so the highest tier a wallet meets is
        // the one returned. Written as `r > 0` rather than `r >= 1`
        // because r is unsigned: at r == 0 the decrement would wrap to
        // 255 and the loop would never end.
        for (uint8 r = 3; r > 0; r--) {
            Tier storage t = tiers[r];
            if (t.monthlyPayout == 0) continue;
            if (directCount >= t.directsNeeded && stakeTotal >= t.stakeNeeded) {
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
    /// Nothing is lost by closing it: claimTeamBonus() re-proves the rank
    /// live, so a stale high rank in storage cannot be cashed in.
    ///
    /// Changing rank in EITHER direction restarts the clock, so a wallet
    /// about to collect at its current rank should collect first and
    /// refresh afterwards.
    function refreshRank(address user, address[] calldata directs)
        external
        whenNotPaused
    {
        require(msg.sender == user || msg.sender == owner(), "self or owner only");

        (uint256 count, uint256 stakeTotal) = _verifiedDirectVolume(user, directs);
        uint8 newRank = _rankFor(count, stakeTotal);
        uint8 oldRank = rankOf[user];

        if (newRank != oldRank) {
            rankOf[user] = newRank;
            rankSince[user] = newRank == 0 ? 0 : block.timestamp;
            emit RankUpdated(user, oldRank, newRank, stakeTotal);
        }
    }

    /// Collect a month's achievement bonus. The rank is re-proved live
    /// rather than trusted from storage; the stored rank still matters
    /// because it carries the 24-hour clock.
    function claimTeamBonus(address[] calldata directs)
        external
        nonReentrant
        whenNotPaused
    {
        require(address(treasury) != address(0), "treasury not set");

        uint8 storedRank = rankOf[msg.sender];
        require(storedRank > 0, "no rank -- call refreshRank first");
        require(
            block.timestamp >= rankSince[msg.sender] + RANK_HOLD,
            "hold the rank for 24h first"
        );
        require(
            block.timestamp >= lastBonusAt[msg.sender] + BONUS_PERIOD,
            "already paid this period"
        );

        (uint256 count, uint256 stakeTotal) = _verifiedDirectVolume(msg.sender, directs);
        uint8 liveRank = _rankFor(count, stakeTotal);
        require(liveRank > 0, "rank no longer met");

        // Pay the lower of the two. Someone who has climbed since their
        // last refresh gets the old figure until they refresh again --
        // the 24-hour hold belongs to the higher rank too.
        uint8 payRank = liveRank < storedRank ? liveRank : storedRank;
        uint256 amount = tiers[payRank].monthlyPayout;
        require(amount > 0, "tier pays nothing");

        // The period is marked spent BEFORE asking for the money, so a
        // partial month still counts as a month and a near-empty treasury
        // cannot be drained by repeated calls inside one period.
        lastBonusAt[msg.sender] = block.timestamp;

        uint256 received = treasury.spendTeamBonus(msg.sender, amount);

        // Nothing at all is a different case from not enough. Reverting
        // here is safe precisely because no OSG moved: there is no
        // payment for the revert to undo.
        require(received > 0, "treasury empty this period, try again later");

        bonusPaidTotal[msg.sender] += received;

        emit BonusPaid(msg.sender, payRank, amount, received);
        if (received < amount) {
            emit BonusShort(msg.sender, amount, received);
        }
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

    function isWiredForReferral() public view returns (bool) {
        return pool.distributorType(address(this)) == CAT_REFERRAL
            && pool.distributorActive(address(this));
    }

    function version() external pure returns (string memory) {
        return "OSGReferral v4.2";
    }

    // ====================== MIGRATION FROM v4.1 ======================

    function _requireSeedOpen() internal view {
        require(!seedLocked, "seeding closed");
        require(block.timestamp <= seedDeadline, "seeding window expired");
    }

    /// Whether the seed functions still work, and for how much longer.
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
        require(
            users.length == owedAmt.length &&
            users.length == paidAmt.length &&
            users.length == volumeAmt.length,
            "length mismatch"
        );
        for (uint256 i = 0; i < users.length; i++) {
            owed[users[i]]   = owedAmt[i];
            paid[users[i]]   = paidAmt[i];
            volume[users[i]] = volumeAmt[i];
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
        require(
            users.length == ranks.length &&
            users.length == since.length &&
            users.length == lastAt.length &&
            users.length == bonusTotal.length,
            "length mismatch"
        );
        for (uint256 i = 0; i < users.length; i++) {
            require(ranks[i] <= 3, "rank out of range");
            rankOf[users[i]]         = ranks[i];
            rankSince[users[i]]      = since[i];
            lastBonusAt[users[i]]    = lastAt[i];
            bonusPaidTotal[users[i]] = bonusTotal[i];
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
        require(source != address(0), "zero address");
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
        require(addr.code.length > 0, "source not contract");
        require(selector != bytes4(0), "zero selector");
        require(stakeSources.length < MAX_STAKE_SOURCES, "too many sources");

        for (uint256 i = 0; i < stakeSources.length; i++) {
            require(
                stakeSources[i].addr != addr || stakeSources[i].selector != selector,
                "already a source"
            );
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
        require(index < stakeSources.length, "index out of range");
        StakeSource memory gone = stakeSources[index];
        stakeSources[index] = stakeSources[stakeSources.length - 1];
        stakeSources.pop();
        emit StakeSourceRemoved(gone.addr, gone.selector, stakeSources.length);
    }

    /// Both thresholds are live: raising minDirectStake does not un-count
    /// a direct already counted, and lowering it does not back-fill one.
    /// Anyone below the new line can be picked up with qualify().
    function setStakeThresholds(uint256 _minDirect, uint256 _minReferrer) external onlyOwner {
        require(_minDirect > 0, "min direct stake must be positive");
        minDirectStake   = _minDirect;
        minReferrerStake = _minReferrer;
        emit StakeThresholdsUpdated(_minDirect, _minReferrer);
    }

    /// Retune the two gas figures once the real cost has been measured.
    /// Floors stop either being set so low it silently stops working:
    /// too little source gas reads a live stake as zero, too little level
    /// gas breaks the walk before the first level accrues.
    function setGasParams(uint256 _sourceGas, uint256 _levelGas) external onlyOwner {
        require(_sourceGas >= MIN_SOURCE_GAS, "source gas below floor");
        require(_levelGas  >= MIN_LEVEL_GAS,  "level gas below floor");
        sourceGasLimit = _sourceGas;
        minGasPerLevel = _levelGas;
        emit GasParamsUpdated(_sourceGas, _levelGas);
    }

    function setLevelBps(uint256[LEVELS] calldata newBps) external onlyOwner {
        uint256 sum;
        for (uint256 i = 0; i < LEVELS; i++) sum += newBps[i];
        require(sum <= MAX_TOTAL_LEVEL_BPS, "level table too rich");

        levelBps = newBps;
        totalLevelBps = sum;
        emit LevelTableUpdated(sum);
    }

    /// Conditions must not fall as the levels rise, and level 1 must ask
    /// for at least one direct -- a zero there would open the first level
    /// to every wallet on the chain.
    function setLevelConditions(uint256[LEVELS] calldata newConditions) external onlyOwner {
        require(newConditions[0] >= 1, "level 1 needs a direct");
        for (uint256 i = 1; i < LEVELS; i++) {
            require(newConditions[i] >= newConditions[i - 1], "conditions must not fall");
        }
        levelConditions = newConditions;
    }

    function setTier(
        uint8 rank,
        uint256 directsNeeded,
        uint256 stakeNeeded,
        uint256 monthlyPayout
    ) external onlyOwner {
        require(rank >= 1 && rank <= 3, "rank out of range");
        tiers[rank] = Tier(directsNeeded, stakeNeeded, monthlyPayout);
        emit TierUpdated(rank, directsNeeded, stakeNeeded, monthlyPayout);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
