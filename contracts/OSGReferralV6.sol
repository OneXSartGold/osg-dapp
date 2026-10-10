// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/*
 * ======================================================================
 *  OSGReferral v6
 *  One contract for the whole referral programme: level commission
 *  (up to 50 levels), rank bonus, spot bonus and task / airdrop.
 *  Everything is paid from the RewardPool referral category. There is
 *  no treasury and no second contract that holds money.
 * ======================================================================
 *
 *  MONEY
 *  -----
 *  The only way OSG leaves is RewardPool.distribute(user, amount, 3).
 *  This contract never holds tokens. Each day's referral budget (D) is
 *  what the pool reports for its referral category (used + available).
 *
 *  D is split into four parts:  LEVELS, RANK, SPOT, TASK.
 *  Owner sets RANK, SPOT and TASK shares; LEVELS gets the rest and can
 *  never be set below MIN_LEVEL_SHARE_BPS (40%).
 *
 *  For the first `reserveSeconds` of each pool day every part's unused
 *  share is held for it; a part can take its own share plus anything no
 *  other part is holding. After that the remaining budget is open to
 *  every part, first come first served. TASK only holds what is
 *  actually owed to task winners, so an idle season holds nothing. A
 *  paused part holds nothing. Unused budget is never minted; the pool
 *  carries it forward under its own rules.
 *
 *  RATES ARE CEILINGS
 *  ------------------
 *  Level commission and rank bonus accrue at the configured rate times
 *  a scale (1e18 = 100%). At each day roll the scale for the new day is
 *  set from the previous day:
 *      scale = min(1, capacity / demand at full rate)
 *  so when demand outruns the budget every rate shrinks by the same
 *  proportion, and when demand falls the scale returns to 100% (never
 *  above). This keeps the owed ledger from growing without bound.
 *
 *  LEVEL WALK
 *  ----------
 *  Called by a stake source inside the downline's own reward claim
 *  (sources wrap it in try/catch). The walk only writes ledgers. If gas
 *  runs short part-way, the rest of the walk is stored as a deferred
 *  entry that anyone can finish with resumeWalk(id); nothing is lost
 *  silently.
 *
 *  SETTINGS
 *  --------
 *  setAll() changes the level table, ranks, pot shares, spot rules and
 *  stake thresholds in ONE owner transaction, inside hard limits fixed
 *  in this code. Changes apply to future accruals only; nothing already
 *  owed is reduced. The project's policy is to announce every change to
 *  the community 48 hours before it is made.
 *
 *  SPOT MODULE
 *  -----------
 *  Spot rules (which stakes, paid-once records, the stop rank) live in
 *  OSGSpotV6 because one contract cannot exceed 24 KB. The module holds
 *  no money and cannot pay anyone by itself: it asks paySpot() here,
 *  which pays only inside the SPOT share of the same daily pot, only
 *  while spot is switched on, and at most MAX_SINGLE_ALLOC per call.
 *  Spot settings (rate, stop rank, ...) are stored HERE and changed
 *  with the same setAll() as everything else.
 *
 *  ROLES
 *  -----
 *  owner     everything above, seeding, wiring. Two-step transfer.
 *            renounceOwnership is disabled.
 *  guardian  may pause the whole contract or one part. Only the owner
 *            unpauses.
 *  admin     (PERM_GRANT) may assign task / airdrop entitlements.
 * ======================================================================
 */

interface IOSGStakingLegacy {
    function users(address user) external view returns (
        uint256 staked, uint256 rewardDebt, uint256 pendingHarvest, uint256 unstakeRequestAt,
        uint256 totalEarned, uint256 stakedAt, address referrer, uint256 totalReferrals,
        uint256 totalReferralEarned, uint256 totalTeamVolume, uint256 teamBonusEarned
    );
}

interface IOSGRewardPoolV6 {
    function distribute(address user, uint256 amount, uint8 category) external;
    function getTodayStats() external view returns (
        uint256 stakingUsedAmt, uint256 miningUsedAmt, uint256 referralUsedAmt,
        uint256 stakingAvail, uint256 miningAvail, uint256 referralAvail,
        uint256 dailyBase
    );
    function startTime() external view returns (uint256);
    function referralPercent() external view returns (uint256);
    function syncDays() external;
}

/// Settings types, shared with OSGReferralV6Rules.
struct LevelCfg {
    uint16 bps;       // commission, basis points of the downline's reward
    uint8  directs;   // qualified directs needed
    uint8  minRank;   // 0 = none
}

struct Tier {
    uint256 directsNeeded;
    uint256 selfStakeNeeded;  // OSG
    uint256 teamStakeNeeded;  // OSG, summed over qualified directs
    uint256 monthlyPayout;    // OSG
}

struct PotCfg {
    uint16 rankShareBps;
    uint16 spotShareBps;
    uint16 taskShareBps;
    uint16 scaleTargetBps;    // part of capacity the scale aims at
    uint32 reserveSeconds;    // 0..86400; 0 = no holding
}

struct SpotCfg {
    uint16  rateBps;
    uint8   stopRank;
    bool    enabled;
    uint256 minSelfStake;
    uint256 maxPerStake;
}

/// Hard limits for every setting. A pure contract with no state and no
/// owner: the referral contract asks it to check a new settings set
/// before storing it. Kept apart only to stay under the 24 KB limit.
contract OSGReferralV6Rules {
    uint256 public constant MAX_LEVELS           = 50;
    uint256 public constant MAX_TOTAL_LEVEL_BPS  = 7_500;
    uint256 public constant MAX_LEVEL_BPS        = 2_000;
    uint256 public constant MIN_LEVEL_SHARE_BPS  = 4_000;
    uint256 public constant MAX_RANK             = 10;
    uint256 public constant MAX_MONTHLY          = 20_000e18;
    uint256 public constant MAX_SPOT_RATE_BPS    = 500;
    uint256 public constant MAX_SPOT_PER_STAKE   = 5_000e18;
    uint256 public constant MAX_STAKE_THRESHOLD  = 10_000e18;
    uint256 public constant MIN_SCALE_TARGET_BPS = 5_000;
    uint256 public constant MAX_TIER_STAKE       = 10_000_000e18;
    uint256 public constant BPS                  = 10_000;

    error BadSetting(uint8 code);

    /// Reverts with BadSetting(code) on the first broken rule; returns
    /// the sum of level bps otherwise.
    function check(
        LevelCfg[] calldata lv,
        Tier[] calldata tr,
        PotCfg calldata p,
        SpotCfg calldata s,
        uint256 minDirect,
        uint256 minReferrer
    ) external pure returns (uint256 sum) {
        uint256 n = lv.length;
        if (n == 0 || n > MAX_LEVELS) revert BadSetting(1);
        if (lv[0].directs == 0) revert BadSetting(2);
        uint256 m = tr.length;
        if (m == 0 || m > MAX_RANK) revert BadSetting(7);
        for (uint256 i = 0; i < n; i++) {
            LevelCfg calldata c = lv[i];
            if (c.bps > MAX_LEVEL_BPS) revert BadSetting(3);
            if (c.minRank > m) revert BadSetting(4);
            if (i > 0 && (c.directs < lv[i - 1].directs || c.minRank < lv[i - 1].minRank)) revert BadSetting(5);
            sum += c.bps;
        }
        if (sum > MAX_TOTAL_LEVEL_BPS) revert BadSetting(6);

        for (uint256 r = 0; r < m; r++) {
            Tier calldata t = tr[r];
            if (t.monthlyPayout == 0 || t.monthlyPayout > MAX_MONTHLY || t.teamStakeNeeded == 0
                || t.selfStakeNeeded == 0 || t.directsNeeded == 0
                || t.teamStakeNeeded > MAX_TIER_STAKE || t.selfStakeNeeded > MAX_TIER_STAKE
                || t.directsNeeded > 1_000)
                revert BadSetting(8);
            if (r > 0) {
                Tier calldata b = tr[r - 1];
                // pay per unit of team stake must not rise with rank
                if (t.monthlyPayout * b.teamStakeNeeded > b.monthlyPayout * t.teamStakeNeeded)
                    revert BadSetting(9);
                if (t.teamStakeNeeded < b.teamStakeNeeded || t.selfStakeNeeded < b.selfStakeNeeded
                    || t.directsNeeded < b.directsNeeded) revert BadSetting(10);
            }
        }

        if (uint256(p.rankShareBps) + p.spotShareBps + p.taskShareBps > BPS - MIN_LEVEL_SHARE_BPS)
            revert BadSetting(11);
        if (p.scaleTargetBps < MIN_SCALE_TARGET_BPS || p.scaleTargetBps > BPS) revert BadSetting(12);
        if (p.reserveSeconds > 1 days) revert BadSetting(13);

        if (s.rateBps == 0 || s.rateBps > MAX_SPOT_RATE_BPS) revert BadSetting(14);
        if (s.maxPerStake == 0 || s.maxPerStake > MAX_SPOT_PER_STAKE) revert BadSetting(15);
        if (s.minSelfStake == 0 || s.minSelfStake > MAX_STAKE_THRESHOLD) revert BadSetting(16);
        if (s.stopRank == 0 || s.stopRank > m) revert BadSetting(17);

        if (minDirect == 0 || minDirect > MAX_STAKE_THRESHOLD
            || minReferrer == 0 || minReferrer > MAX_STAKE_THRESHOLD) revert BadSetting(18);
    }
}

contract OSGReferralV6 is Ownable2Step, Pausable, ReentrancyGuard {

    // =================================================================
    //  ERRORS
    // =================================================================
    error AlreadyRegistered();
    error AlreadyASource();
    error BadBatch();
    error BadLength();
    error BadSetting(uint8 code);
    error BadSource();
    error CannotReferSelf();
    error Frozen();
    error IndexOutOfRange();
    error ListMustAscend();
    error NothingAccrued();
    error NothingOwed();
    error NoBudget();
    error NoRank();
    error NotASource();
    error NotGuardian();
    error NotPermitted();
    error NotYourDirect();
    error PartPaused();
    error RankHoldNotMet();
    error RankNoLongerMet();
    error ReferrerStakeTooLow();
    error RenounceDisabled();
    error SeedingClosed();
    error SeedingOpen();
    error SelfOrOwnerOnly();
    error TooMany();
    error UplineInLegacy();
    error WouldLoop();
    error ZeroAddress();
    error ZeroAmount();

    // =================================================================
    //  CONSTANTS (hard limits that no setting can cross)
    // =================================================================
    uint8 internal constant CAT_REFERRAL         = 3;
    uint256 internal constant BPS                  = 10_000;
    uint256 internal constant ONE                  = 1e18;   // scale = 100%

    uint256 public constant MAX_LEVELS           = 50;
    uint256 internal constant MAX_RANK             = 10;

    /// Mirrors RewardPool.MAX_SINGLE_ALLOC.
    uint256 public constant MAX_SINGLE_ALLOC     = 10_000e18;

    uint256 internal constant RANK_HOLD            = 24 hours;
    uint256 internal constant BONUS_PERIOD         = 30 days;
    uint256 internal constant MAX_ACCRUAL_WINDOW   = 7 days;
    /// A proven rank opens rank-gated levels for this long; after that
    /// the wallet must prove it again
    /// (refreshRank / accrueRankBonus). Rank holders accrue at least
    /// weekly anyway (MAX_ACCRUAL_WINDOW), which re-proves the rank.
    uint256 public constant RANK_VALIDITY        = 8 days;

    uint256 internal constant MAX_DIRECTS_PER_CALL = 50;
    uint256 internal constant LOOP_SCAN_DEPTH      = 64;
    uint256 internal constant MAX_STAKE_SOURCES    = 6;
    uint256 internal constant MAX_BATCH            = 300;

    /// Gas kept back so a deferred entry can always be written.
    uint256 internal constant DEFER_RESERVE        = 150_000;
    /// Gas below which a hook does not even start (day roll + first level).
    uint256 internal constant ROLL_RESERVE         = 400_000;

    uint8 internal constant PART_LEVELS = 0;
    uint8 internal constant PART_RANK   = 1;
    uint8 internal constant PART_SPOT   = 2;
    uint8 internal constant PART_TASK   = 3;

    uint8 internal constant PERM_GRANT  = 1;

    // =================================================================
    //  WIRING
    // =================================================================
    IOSGStakingLegacy public immutable staking;
    IOSGRewardPoolV6  public immutable pool;
    OSGReferralV6Rules public immutable rules;
    uint256           public immutable poolStart;
    uint256           public immutable seedDeadline;

    address public guardian;
    address public taskBoard;
    mapping(address => uint8) internal adminPerms;

    /// Contracts allowed to call the two hooks.
    mapping(address => bool) public isSource;

    struct StakeSource { address addr; bytes4 selector; }
    StakeSource[] public stakeSources;

    // =================================================================
    //  SETTINGS
    // =================================================================
    LevelCfg[MAX_LEVELS] public levels;
    uint8   public levelCount;
    uint256 public totalLevelBps;

    Tier[MAX_RANK + 1] public tiers;   // index 1..maxRank
    uint8 public maxRank;

    PotCfg  public pot;
    SpotCfg public spot;

    uint256 public minDirectStake;
    uint256 public minReferrerStake;

    uint256 public constant sourceGasLimit = 400_000;
    uint256 public constant minGasPerLevel = 60_000;

    // =================================================================
    //  TREE
    // =================================================================
    /// Local bond. Written once. Zero = ask legacy OSGStaking.
    mapping(address => address) public nativeReferrer;
    /// True when the local bond is a seeded copy of the OSGStaking bond;
    /// such a direct is counted by OSGStaking (legacyDirects), not here.
    mapping(address => bool) internal legacyBond;
    mapping(address => uint256) internal registeredAt;
    mapping(address => uint256) public registeredDirects;
    mapping(address => address[]) public children;

    /// Qualified directs counted here (native bonds only). Moves both ways.
    mapping(address => uint256) internal nativeDirects;
    mapping(address => bool) internal directCounted;
    /// Copy of OSGStaking.totalReferrals; refreshed by anyone from chain.
    mapping(address => uint256) internal legacyDirects;
    /// Legacy directs moved away by the owner (moveReferrer).
    mapping(address => uint256) internal legacyMovedOut;
    /// Stake held in hooked sources at the last hook / sync. Used by the
    /// level walk so it needs no external calls in the common case.
    mapping(address => uint256) public cachedStake;
    /// Sum of cachedStake over this wallet's directs that are at or above
    /// minDirectStake (native and seeded legacy bonds). Kept by
    /// _syncDirect; used by the spot module's stop-rank check.
    mapping(address => uint256) public teamStake;

    // =================================================================
    //  LEDGERS
    // =================================================================
    mapping(address => uint256) public owed;
    mapping(address => uint256) internal paid;
    mapping(address => uint256) public volume;
    uint256 public totalOwed;

    mapping(address => uint8)   public rankOf;
    mapping(address => uint256) public rankSince;
    mapping(address => uint256) public rankProvedAt;
    mapping(address => uint8) internal lastAccrualRank;
    mapping(address => uint256) public lastBonusAt;
    mapping(address => uint256) public bonusOwed;
    mapping(address => uint256) internal bonusPaidTotal;
    uint256 public totalBonusOwed;

    mapping(address => uint256) public airdropOwed;
    mapping(address => uint256) internal airdropPaid;
    uint256 public totalAirdropAssigned;   // outstanding
    uint256 public totalAirdropPaid;

    address public spotModule;
    uint256 public totalSpotPaid;

    // =================================================================
    //  DAY / POT STATE
    // =================================================================
    uint256 public curDay;
    uint256[4] public spentToday;   // index = part; belongs to curDay
    uint256 internal levelDemandToday;    // at full rate
    uint256 internal rankDemandWeek;      // at full rate, this pool week
    uint256 public rankWeek;
    uint256 public prevRankScale = ONE;   // last week's rank scale
    uint256 public levelScale = ONE;
    uint256 public rankScale  = ONE;

    bool[4] public partPaused;
    bool public accrualFrozen;

    /// scale: the level scale of the day the reward was claimed, so a walk
    /// finished on a later day pays every level at the same rate. 0 means
    /// the hook deferred before rolling the day; the resume day's scale
    /// is then used.
    struct Deferred { address claimant; uint8 nextLevel; uint64 scale; address cursor; uint96 amount; }
    mapping(uint256 => Deferred) internal deferred;
    uint256 public deferredNext;
    uint256 public deferredOpen;

    bool public seedLocked;
    address[] public allUsers;
    mapping(address => bool) internal _listed;

    // =================================================================
    //  EVENTS
    // =================================================================
    event Registered(address indexed user, address indexed referrer, bool legacy);
    event DirectQualified(address indexed user, address indexed referrer, uint256 count);
    event DirectDropped(address indexed user, address indexed referrer, uint256 count);
    event LegacyDirectsSynced(address indexed user, uint256 count);
    event ReferrerMoved(address indexed user, address indexed oldRef, address indexed newRef);

    event CommissionAccrued(address indexed earner, address indexed from, uint8 level, uint256 amount);
    event WalkDeferred(uint256 indexed id, address indexed claimant, uint8 nextLevel, uint256 amount);
    event WalkResumed(uint256 indexed id);
    event Paid(address indexed user, uint256 levels, uint256 rank, uint256 task, uint256 total);

    event RankUpdated(address indexed user, uint8 oldRank, uint8 newRank);
    event RankAccrued(address indexed user, uint8 rank, uint256 secondsPriced, uint256 amount);

    event SpotPaidOut(address indexed to, uint256 amount);

    event AirdropAssigned(address indexed user, uint256 amount);

    event DayRolled(uint256 indexed day, uint256 levelScale, uint256 rankScale);
    event SettingsUpdated(uint8 levelCount, uint256 totalLevelBps, uint8 maxRank);
    event PartPausedSet(uint8 part, bool paused);
    event SourceSet(address indexed source, bool allowed);
    event StakeSourceAdded(address indexed addr, bytes4 selector);
    event StakeSourceRemoved(address indexed addr, bytes4 selector);
    event SpotModuleSet(address module);
    event GuardianSet(address guardian);
    event TaskBoardSet(address board);
    event AdminSet(address indexed admin, uint8 perms);
    event AccrualFrozen(bool frozen);
    event SeedingLocked();

    // =================================================================
    //  CONSTRUCTION
    // =================================================================
    constructor(
        address _staking,
        address _pool,
        address _owner,
        address _rules,
        uint256 _seedDays
    ) Ownable(_owner) {
        if (_staking.code.length == 0 || _pool.code.length == 0 || _rules.code.length == 0) revert ZeroAddress();
        if (_seedDays == 0 || _seedDays > 90) revert BadSetting(0);
        staking      = IOSGStakingLegacy(_staking);
        pool         = IOSGRewardPoolV6(_pool);
        rules        = OSGReferralV6Rules(_rules);
        poolStart    = IOSGRewardPoolV6(_pool).startTime();
        seedDeadline = block.timestamp + _seedDays * 1 days;
        curDay       = (block.timestamp - poolStart) / 1 days;
        rankWeek     = curDay / 7;
        // Born paused and frozen: seed first, lock, then unpause/unfreeze.
        _pause();
        accrualFrozen = true;

        // Global Plan v2.1
        //   L1-L5   15/10/5/3/2 %   1..5 directs        no rank
        //   L6-L15  1 % each        6..15 directs       R1
        //   L16-L25 1 % each        15 + ceil((L-15)/3) R2
        //   L26-L50 0.5 % each      15 + ceil((L-15)/3) R3
        uint16[5] memory head = [uint16(1_500), 1_000, 500, 300, 200];
        uint256 sum;
        for (uint256 i = 0; i < MAX_LEVELS; i++) {
            uint256 L = i + 1;
            LevelCfg memory c;
            if (L <= 5)       { c = LevelCfg(head[i], uint8(L), 0); }
            else if (L <= 15) { c = LevelCfg(100, uint8(L), 1); }
            else if (L <= 25) { c = LevelCfg(100, uint8(15 + (L - 15 + 2) / 3), 2); }
            else              { c = LevelCfg(50,  uint8(15 + (L - 15 + 2) / 3), 3); }
            levels[i] = c;
            sum += c.bps;
        }
        levelCount    = uint8(MAX_LEVELS);
        totalLevelBps = sum;   // 6,750

        tiers[1] = Tier( 6,    500e18,   5_000e18,   100e18);
        tiers[2] = Tier(15,  1_000e18,  10_000e18,   200e18);
        tiers[3] = Tier(15,  3_000e18,  25_000e18,   500e18);
        tiers[4] = Tier(15,  5_000e18,  50_000e18, 1_000e18);
        tiers[5] = Tier(15, 10_000e18, 100_000e18, 2_000e18);
        maxRank = 5;

        pot  = PotCfg(2_500, 1_000, 1_000, 9_000, 20 hours);
        spot = SpotCfg(300, 2, false, 100e18, 300e18);

        minDirectStake   = 100e18;
        minReferrerStake = 100e18;
    }

    // =================================================================
    //  TREE
    // =================================================================
    function _referrerOf(address user) internal view returns (address) {
        address r = nativeReferrer[user];
        if (r != address(0)) return r;
        (, , , , , , address legacy, , , , ) = staking.users(user);
        return legacy;
    }

    function _legacyReferrer(address user) internal view returns (address legacy) {
        (, , , , , , legacy, , , , ) = staking.users(user);
    }

    function _directCount(address user) internal view returns (uint256) {
        uint256 l = legacyDirects[user];
        uint256 m = legacyMovedOut[user];
        return nativeDirects[user] + (l > m ? l - m : 0);
    }

    function _reachesUpward(address start, address target) internal view returns (bool) {
        address cur = start;
        for (uint256 i = 0; i < LOOP_SCAN_DEPTH; i++) {
            if (cur == address(0)) return false;
            if (cur == target) return true;
            cur = _referrerOf(cur);
        }
        return false;
    }

    function _bond(address user, address ref, bool legacy) internal {
        nativeReferrer[user] = ref;
        legacyBond[user]     = legacy;
        registeredAt[user]   = block.timestamp;
        registeredDirects[ref] += 1;
        children[ref].push(user);
        _list(user);
        _list(ref);
        emit Registered(user, ref, legacy);
    }

    /// Bind yourself under a referrer. Once only, permanent.
    function register(address referrer) external whenNotPaused {
        _checkNewBond(msg.sender, referrer);
        _bond(msg.sender, referrer, false);
        _syncDirect(msg.sender);
    }

    function _checkNewBond(address user, address referrer) internal view {
        if (user == address(0) || referrer == address(0)) revert ZeroAddress();
        if (user == referrer) revert CannotReferSelf();
        if (nativeReferrer[user] != address(0)) revert AlreadyRegistered();
        if (_legacyReferrer(user) != address(0)) revert UplineInLegacy();
        if (stakeOf(referrer) < minReferrerStake) revert ReferrerStakeTooLow();
        if (_reachesUpward(referrer, user)) revert WouldLoop();
    }

    /// Owner tool: put `users` under `newRef`, at any time. For handing a
    /// position or a team to another wallet, or bringing back a team
    /// placed under the wrong wallet. Every move is a public event. Only
    /// the bond moves: balances, ranks and anything already owed stay
    /// with the wallets that earned them. A moved legacy (OSGStaking)
    /// bond becomes a native bond; OSGStaking's own count for the old
    /// referrer cannot be lowered and stays as it is.
    function moveReferrer(address[] calldata users, address newRef) external onlyOwner {
        if (users.length == 0 || users.length > MAX_BATCH) revert BadBatch();
        if (newRef == address(0)) revert ZeroAddress();
        for (uint256 i = 0; i < users.length; i++) {
            address u = users[i];
            if (u == newRef) revert CannotReferSelf();
            if (_reachesUpward(newRef, u)) revert WouldLoop();
            address old = nativeReferrer[u];
            if (old == newRef) continue;
            // A wallet still on its OSGStaking bond is counted in that
            // upline's legacyDirects, which can never fall on-chain: record
            // the move-out so the upline is not credited twice.
            address legacyRef = legacyBond[u] ? old : (old == address(0) ? _legacyReferrer(u) : address(0));
            if (legacyRef != address(0)) legacyMovedOut[legacyRef] += 1;
            if (old != address(0)) {
                if (directCounted[u]) {
                    teamStake[old] -= cachedStake[u];
                    if (!legacyBond[u]) nativeDirects[old] -= 1;
                    directCounted[u] = false;
                }
                registeredDirects[old] -= 1;
                address[] storage k = children[old];
                for (uint256 j = 0; j < k.length; j++) {
                    if (k[j] == u) { k[j] = k[k.length - 1]; k.pop(); break; }
                }
            }
            emit ReferrerMoved(u, old, newRef);
            _bond(u, newRef, false);
            _syncDirect(u);
        }
    }

    /// Bring a wallet's cached stake and its counted-as-direct state in
    /// line with the chain. Open to anyone: it can only write the truth.
    function syncDirect(address user) external { _syncDirect(user); }

    function syncDirects(address[] calldata users) external {
        if (users.length == 0 || users.length > MAX_BATCH) revert BadBatch();
        for (uint256 i = 0; i < users.length; i++) _syncDirect(users[i]);
    }

    /// Copy OSGStaking.totalReferrals. Open to anyone.
    function syncLegacyDirects(address[] calldata users) external {
        if (users.length == 0 || users.length > MAX_BATCH) revert BadBatch();
        for (uint256 i = 0; i < users.length; i++) {
            (, , , , , , , uint256 n, , , ) = staking.users(users[i]);
            legacyDirects[users[i]] = n;
            emit LegacyDirectsSynced(users[i], n);
        }
    }

    function _syncDirect(address user) internal {
        uint256 q    = qualifyingStakeOf(user);
        uint256 oldQ = cachedStake[user];
        cachedStake[user] = q;

        address ref = nativeReferrer[user];
        if (ref == address(0)) return;

        bool was = directCounted[user];
        bool now_ = q >= minDirectStake;
        // directCounted doubles as "included in teamStake[ref]", and the
        // amount included is always the cachedStake written with it.
        if (was) teamStake[ref] -= oldQ;
        if (now_) teamStake[ref] += q;
        if (was == now_) return;
        directCounted[user] = now_;
        if (legacyBond[user]) return;   // counted by OSGStaking instead
        if (now_) {
            nativeDirects[ref] += 1;
            emit DirectQualified(user, ref, nativeDirects[ref]);
        } else {
            nativeDirects[ref] -= 1;
            emit DirectDropped(user, ref, nativeDirects[ref]);
        }
    }

    /// Stake sources call this on every deposit / withdrawal.
    function onLiquidityChange(address user, uint256, bool) external {
        if (!isSource[msg.sender]) revert NotASource();
        _syncDirect(user);
    }

    // =================================================================
    //  STAKE READS
    // =================================================================
    /// Hooked sources only (Term, LP, Tiers ...). Decides who counts as a
    /// direct and feeds cachedStake. A failing source reads as zero.
    function qualifyingStakeOf(address user) public view returns (uint256 total) {
        uint256 n = stakeSources.length;
        for (uint256 i = 0; i < n; i++) total += _readSource(stakeSources[i], user);
    }

    /// Hooked sources plus legacy Active Staking.
    function stakeOf(address user) public view returns (uint256 total) {
        (uint256 active, , , , , , , , , , ) = staking.users(user);
        total = active + qualifyingStakeOf(user);
    }

    function _readSource(StakeSource storage s, address user) internal view returns (uint256) {
        (bool ok, bytes memory data) = s.addr.staticcall{gas: sourceGasLimit}(
            abi.encodeWithSelector(s.selector, user)
        );
        if (ok && data.length >= 32) return abi.decode(data, (uint256));
        return 0;
    }

    // =================================================================
    //  LEVEL COMMISSION
    // =================================================================
    /// Called by a stake source when it pays a reward. Never reverts for
    /// a business reason (sources swallow reverts anyway). Not paused by
    /// pause(): a pause stops payouts, it must not erase entitlements.
    function onRewardClaimed(address user, uint256 amount) external {
        if (!isSource[msg.sender]) revert NotASource();
        if (amount == 0 || user == address(0) || accrualFrozen) return;
        if (amount > type(uint96).max) amount = type(uint96).max;
        // Too little gas even to start: keep the whole walk for later.
        if (gasleft() < ROLL_RESERVE) { _defer(user, user, amount, 0, 0); return; }
        _rollDay();
        _walk(user, amount, 0, user, levelScale);
    }

    /// Finish a walk that ran short of gas. Anyone may call.
    function resumeWalk(uint256 id) external {
        if (accrualFrozen) revert Frozen();
        Deferred memory d = deferred[id];
        if (d.claimant == address(0)) revert NothingOwed();
        delete deferred[id];
        deferredOpen -= 1;
        emit WalkResumed(id);
        _rollDay();
        _walk(d.claimant, d.amount, d.nextLevel, d.cursor, d.scale == 0 ? levelScale : d.scale);
    }

    function _walk(address claimant, uint256 amount, uint256 startLevel, address cursor, uint256 scale) internal {
        uint256 n     = levelCount;
        uint256 bar   = minReferrerStake;
        uint256 needGas = minGasPerLevel + DEFER_RESERVE;
        uint256 demand;
        address cur = cursor;

        for (uint256 i = startLevel; i < n; i++) {
            if (gasleft() < needGas) { _defer(claimant, cur, amount, i, scale); break; }
            address ref = _referrerOf(cur);
            if (ref == address(0) || ref == claimant) break;
            cur = ref;

            LevelCfg memory c = levels[i];
            if (c.bps == 0) continue;
            if (c.minRank != 0 && !_rankActive(ref, c.minRank)) continue;
            if (_directCount(ref) < c.directs) continue;
            // Upline's own stake in hooked sources (Term, LP, Tiers ...), as
            // last reported by the hooks. No external calls in the walk.
            if (cachedStake[ref] < bar) continue;

            uint256 full = (amount * c.bps) / BPS;
            demand += full;
            uint256 cut = (full * scale) / ONE;
            if (cut == 0) continue;

            owed[ref]   += cut;
            volume[ref] += amount;
            totalOwed   += cut;
            if (!_listed[ref]) { _listed[ref] = true; allUsers.push(ref); }
            emit CommissionAccrued(ref, claimant, uint8(i + 1), cut);
        }
        if (demand > 0) levelDemandToday += demand;
    }

    function _defer(address claimant, address cursor, uint256 amount, uint256 level, uint256 scale) internal {
        uint256 id = deferredNext++;
        deferred[id] = Deferred(claimant, uint8(level), uint64(scale), cursor, uint96(amount));
        deferredOpen += 1;
        emit WalkDeferred(id, claimant, uint8(level), amount);
    }

    function _rankActive(address user, uint8 need) internal view returns (bool) {
        return rankOf[user] >= need && block.timestamp <= rankProvedAt[user] + RANK_VALIDITY;
    }

    // =================================================================
    //  RANK
    // =================================================================
    function _verifiedDirectVolume(address user, address[] calldata directs)
        internal view returns (uint256 count, uint256 team)
    {
        if (directs.length > MAX_DIRECTS_PER_CALL) revert TooMany();
        uint256 bar = minDirectStake;
        address prev;
        for (uint256 i = 0; i < directs.length; i++) {
            address d = directs[i];
            if (d <= prev) revert ListMustAscend();
            prev = d;
            if (_referrerOf(d) != user) revert NotYourDirect();
            uint256 st = stakeOf(d);
            if (st < bar) continue;
            count += 1;
            team  += st;
        }
    }

    function _rankFor(uint256 count, uint256 team, uint256 self) internal view returns (uint8) {
        for (uint8 r = maxRank; r > 0; r--) {
            Tier storage t = tiers[r];
            if (count >= t.directsNeeded && team >= t.teamStakeNeeded && self >= t.selfStakeNeeded) return r;
        }
        return 0;
    }

    /// Prove a rank. Self or owner only (a stranger could hand in a short
    /// list). Refreshes the 30-day validity used by rank-gated levels.
    function refreshRank(address user, address[] calldata directs) external whenNotPaused {
        if (msg.sender != user && msg.sender != owner()) revert SelfOrOwnerOnly();
        (uint256 count, uint256 team) = _verifiedDirectVolume(user, directs);
        uint8 r = _rankFor(count, team, stakeOf(user));
        _setRank(user, r);
        rankProvedAt[user] = r == 0 ? 0 : block.timestamp;
    }

    function _setRank(address user, uint8 r) internal {
        uint8 old = rankOf[user];
        if (r == old) return;
        rankOf[user]    = r;
        rankSince[user] = r == 0 ? 0 : block.timestamp;
        if (r == 0) {
            // time without a rank must never be priced as rank time later
            lastBonusAt[user] = 0;
            lastAccrualRank[user] = 0;
        }
        _list(user);
        emit RankUpdated(user, old, r);
    }

    /// Turn time held at a rank into an entitlement (v5 rules: priced at
    /// the lower end of the window, at most 7 days per call, times the
    /// day's rank scale).
    function accrueRankBonus(address user, address[] calldata directs) public nonReentrant whenNotPaused {
        if (msg.sender != user && msg.sender != owner()) revert SelfOrOwnerOnly();
        if (partPaused[PART_RANK]) revert PartPaused();
        _accrueRank(user, directs);
    }

    function _accrueRank(address user, address[] calldata directs) internal {
        uint8 stored = rankOf[user];
        if (stored == 0) revert NoRank();
        if (block.timestamp < rankSince[user] + RANK_HOLD) revert RankHoldNotMet();

        (uint256 count, uint256 team) = _verifiedDirectVolume(user, directs);
        uint8 live = _rankFor(count, team, stakeOf(user));
        if (live == 0) revert RankNoLongerMet();

        uint8 capNow = live < stored ? live : stored;
        uint8 payRank = capNow;
        uint8 last = lastAccrualRank[user];
        if (last != 0 && last < payRank) payRank = last;

        uint256 since = lastBonusAt[user];
        if (since == 0) since = rankSince[user] + RANK_HOLD;
        if (block.timestamp <= since) revert NothingAccrued();
        uint256 elapsed = block.timestamp - since;
        if (elapsed > MAX_ACCRUAL_WINDOW) elapsed = MAX_ACCRUAL_WINDOW;

        _rollDay();
        uint256 full = (tiers[payRank].monthlyPayout * elapsed) / BONUS_PERIOD;
        // A window that began in an earlier pool week is priced at the
        // lower of this week's and last week's scale, so waiting for a
        // new week cannot lift time that was spent under a cut.
        uint256 sc = rankScale;
        if (since < poolStart + rankWeek * 7 days && prevRankScale < sc) sc = prevRankScale;
        uint256 amount = (full * sc) / ONE;
        if (amount == 0) revert NothingAccrued();
        rankDemandWeek += full;

        lastBonusAt[user]     = block.timestamp;
        lastAccrualRank[user] = capNow;
        rankProvedAt[user]    = block.timestamp;
        if (live < stored) {
            // keep the clock: the wallet just accrued, so no hold is needed
            rankOf[user] = live;
            emit RankUpdated(user, stored, live);
        }
        bonusOwed[user] += amount;
        totalBonusOwed  += amount;
        _list(user);
        emit RankAccrued(user, payRank, elapsed, amount);
    }

    // =================================================================
    //  PAYING (levels, rank, task)
    // =================================================================
    function claimMyReferral() external { _claim(1); }
    function claimBonusOwed()  external { _claim(2); }
    function claimAirdrop()    external { _claim(4); }
    function claimAll()        external { _claim(7); }

    function _claim(uint8 mask) internal nonReentrant whenNotPaused {
        _rollDay();
        address u = msg.sender;
        (, , uint256 used, , , uint256 avail, ) = pool.getTodayStats();
        uint256 dayTotal = used + avail;
        uint256 total;
        uint256[3] memory got;

        for (uint8 k = 0; k < 3; k++) {
            if (mask & (uint8(1) << k) == 0) continue;
            uint8 part = k == 0 ? PART_LEVELS : (k == 1 ? PART_RANK : PART_TASK);
            if (partPaused[part]) { if (mask == (uint8(1) << k)) revert PartPaused(); continue; }

            uint256 due = part == PART_LEVELS ? owed[u] : (part == PART_RANK ? bonusOwed[u] : airdropOwed[u]);
            if (due == 0) continue;

            uint256 room = _roomFor(part, avail - total, dayTotal);
            if (room > MAX_SINGLE_ALLOC - total) room = MAX_SINGLE_ALLOC - total;
            uint256 pay = due < room ? due : room;
            if (pay == 0) continue;

            spentToday[part] += pay;
            total += pay;
            got[k] = pay;
            if (part == PART_LEVELS) {
                owed[u] = due - pay; paid[u] += pay; totalOwed -= pay;
            } else if (part == PART_RANK) {
                bonusOwed[u] = due - pay; bonusPaidTotal[u] += pay; totalBonusOwed -= pay;
            } else {
                airdropOwed[u] = due - pay; airdropPaid[u] += pay;
                totalAirdropAssigned -= pay; totalAirdropPaid += pay;
            }
        }
        if (total == 0) revert NoBudget();
        pool.distribute(u, total, CAT_REFERRAL);
        emit Paid(u, got[0], got[1], got[2], total);
    }

    /// How much `part` may take right now, given what the pool still has.
    function _roomFor(uint8 part, uint256 avail, uint256 dayTotal) internal view returns (uint256) {
        if (avail == 0) return 0;
        if (pot.reserveSeconds == 0 || _secondsIntoDay() >= pot.reserveSeconds) return avail;
        uint256 held;
        for (uint8 q = 0; q < 4; q++) {
            if (q != part) held += _holdOf(q, dayTotal);
        }
        return avail > held ? avail - held : 0;
    }

    function _holdOf(uint8 part, uint256 dayTotal) internal view returns (uint256) {
        if (partPaused[part]) return 0;
        if (part == PART_SPOT && !spot.enabled) return 0;
        uint256 quota = (dayTotal * _shareOf(part)) / BPS;
        uint256 s = spentToday[part];
        if (s >= quota) return 0;
        uint256 h = quota - s;
        if (part == PART_TASK && h > totalAirdropAssigned) h = totalAirdropAssigned;
        return h;
    }

    function _shareOf(uint8 part) internal view returns (uint256) {
        if (part == PART_RANK) return pot.rankShareBps;
        if (part == PART_SPOT) return pot.spotShareBps;
        if (part == PART_TASK) return pot.taskShareBps;
        return BPS - pot.rankShareBps - pot.spotShareBps - pot.taskShareBps;
    }

    function _secondsIntoDay() internal view returns (uint256) {
        return (block.timestamp - poolStart) % 1 days;
    }

    /// New pool day: bring the pool's own day up to date, set today's
    /// level scale from yesterday and the week's rank scale from last
    /// week, and reset the counters.
    function _rollDay() internal {
        uint256 d = (block.timestamp - poolStart) / 1 days;
        if (d == curDay) return;

        // getTodayStats() is a view and does not roll the pool's day.
        pool.syncDays();

        (, , , , , , uint256 dailyBase) = pool.getTodayStats();
        uint256 base   = (dailyBase * pool.referralPercent()) / 100;
        uint256 target = pot.scaleTargetBps;

        uint256 ls = ONE;
        if (d == curDay + 1 && levelDemandToday > 0) {
            uint256 other = spentToday[PART_RANK] + spentToday[PART_SPOT] + spentToday[PART_TASK];
            uint256 lCap = (base * _shareOf(PART_LEVELS)) / BPS;
            if (base > other && base - other > lCap) lCap = base - other;
            lCap = (lCap * target) / BPS;
            if (levelDemandToday > lCap) ls = (lCap * ONE) / levelDemandToday;
        }
        levelScale = ls;

        // Rank bonus is accrued in windows of up to 7 days, so its demand
        // is measured per pool week rather than per day.
        uint256 wk = d / 7;
        if (wk != rankWeek) {
            uint256 rs = ONE;
            if (wk == rankWeek + 1 && rankDemandWeek > 0) {
                uint256 rCap = (((base * pot.rankShareBps) / BPS) * target * 7) / BPS;
                if (rankDemandWeek > rCap) rs = (rCap * ONE) / rankDemandWeek;
            }
            prevRankScale  = rankScale;
            rankScale      = rs;
            rankWeek       = wk;
            rankDemandWeek = 0;
        }

        curDay = d;
        levelDemandToday = 0;
        spentToday[0] = 0; spentToday[1] = 0; spentToday[2] = 0; spentToday[3] = 0;
        emit DayRolled(d, ls, rankScale);
    }

    // =================================================================
    //  SPOT (rules and records live in the spot module; money comes
    //  from here, inside the SPOT share of the same referral pot)
    // =================================================================
    /// Pay a spot bonus that the spot module has already checked and
    /// recorded. Full amount or revert: the module then leaves the stakes
    /// unpaid, to be claimed later.
    function paySpot(address to, uint256 amount) external nonReentrant whenNotPaused {
        if (msg.sender != spotModule) revert NotPermitted();
        if (!spot.enabled || partPaused[PART_SPOT]) revert PartPaused();
        if (amount == 0 || amount > MAX_SINGLE_ALLOC) revert ZeroAmount();
        _rollDay();
        (, , uint256 used, , , uint256 avail, ) = pool.getTodayStats();
        if (amount > _roomFor(PART_SPOT, avail, used + avail)) revert NoBudget();
        spentToday[PART_SPOT] += amount;
        totalSpotPaid += amount;
        _list(to);
        pool.distribute(to, amount, CAT_REFERRAL);
        emit SpotPaidOut(to, amount);
    }

    // =================================================================
    //  TASK / AIRDROP
    // =================================================================
    function grantAirdrop(address user, uint256 amount) external {
        if (msg.sender != taskBoard && msg.sender != owner() && (adminPerms[msg.sender] & PERM_GRANT) == 0)
            revert NotPermitted();
        if (user == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _grant(user, amount);
    }

    function _grant(address user, uint256 amount) internal {
        airdropOwed[user]    += amount;
        totalAirdropAssigned += amount;
        _list(user);
        emit AirdropAssigned(user, amount);
    }

    // =================================================================
    //  SETTINGS (one owner transaction, hard limits)
    // =================================================================
    /// Every setting in one owner transaction. OSGReferralV6Rules
    /// enforces the hard limits; a broken rule reverts the whole call.
    function setAll(
        LevelCfg[] calldata lv,
        Tier[] calldata tr,
        PotCfg calldata p,
        SpotCfg calldata s,
        uint256 minDirect,
        uint256 minReferrer
    ) external onlyOwner {
        // Finish every deferred walk first, so none is cut short by a
        // smaller table (resumeWalk is open to anyone).
        // (Skipped while accrual is frozen, so a freeze cannot lock settings.)
        if (deferredOpen != 0 && !accrualFrozen) revert NotPermitted();
        uint256 sum = rules.check(lv, tr, p, s, minDirect, minReferrer);
        uint256 n = lv.length;
        uint256 m = tr.length;
        for (uint256 i = 0; i < MAX_LEVELS; i++) {
            if (i < n) levels[i] = lv[i];
            else delete levels[i];
        }
        for (uint256 r = 1; r <= MAX_RANK; r++) {
            if (r <= m) tiers[r] = tr[r - 1];
            else delete tiers[r];
        }
        levelCount       = uint8(n);
        totalLevelBps    = sum;
        maxRank          = uint8(m);
        pot              = p;
        spot             = s;
        minDirectStake   = minDirect;
        minReferrerStake = minReferrer;
        emit SettingsUpdated(uint8(n), sum, uint8(m));
    }

    /// The spot on/off button.
    function setSpotEnabled(bool on) external onlyOwner {
        spot.enabled = on;
        emit SettingsUpdated(levelCount, totalLevelBps, maxRank);
    }

    // =================================================================
    //  PAUSES
    // =================================================================
    modifier onlyGuard() {
        if (msg.sender != owner() && msg.sender != guardian) revert NotGuardian();
        _;
    }

    function pause() external onlyGuard { _pause(); }
    function unpause() external onlyOwner {
        if (!seedLocked && block.timestamp <= seedDeadline) revert SeedingOpen();
        _unpause();
    }

    function pausePart(uint8 part) external onlyGuard {
        if (part > 3) revert BadSetting(19);
        partPaused[part] = true;
        emit PartPausedSet(part, true);
    }

    function unpausePart(uint8 part) external onlyOwner {
        if (part > 3) revert BadSetting(19);
        partPaused[part] = false;
        emit PartPausedSet(part, false);
    }

    /// Stops accrual without reverting (migration cut-over).
    function setAccrualFrozen(bool f) external onlyOwner {
        accrualFrozen = f;
        emit AccrualFrozen(f);
    }

    // =================================================================
    //  WIRING
    // =================================================================
    function setSource(address src, bool allowed) external onlyOwner {
        if (src == address(0)) revert ZeroAddress();
        isSource[src] = allowed;
        emit SourceSet(src, allowed);
    }

    function addStakeSource(address addr, bytes4 selector) external onlyOwner {
        if (addr.code.length == 0 || selector == bytes4(0)) revert BadSource();
        if (stakeSources.length >= MAX_STAKE_SOURCES) revert TooMany();
        for (uint256 i = 0; i < stakeSources.length; i++) {
            if (stakeSources[i].addr == addr && stakeSources[i].selector == selector) revert AlreadyASource();
        }
        stakeSources.push(StakeSource(addr, selector));
        emit StakeSourceAdded(addr, selector);
    }

    function removeStakeSource(uint256 index) external onlyOwner {
        uint256 len = stakeSources.length;
        if (index >= len) revert IndexOutOfRange();
        StakeSource memory gone = stakeSources[index];
        stakeSources[index] = stakeSources[len - 1];
        stakeSources.pop();
        emit StakeSourceRemoved(gone.addr, gone.selector);
    }

    function setSpotModule(address m) external onlyOwner {
        spotModule = m;
        emit SpotModuleSet(m);
    }

    function setGuardian(address g) external onlyOwner {
        guardian = g;
        emit GuardianSet(g);
    }

    function setTaskBoard(address b) external onlyOwner {
        taskBoard = b;
        emit TaskBoardSet(b);
    }

    function setAdmin(address who, uint8 perms) external onlyOwner {
        if (who == address(0)) revert ZeroAddress();
        if (perms > PERM_GRANT) revert BadSetting(21);
        adminPerms[who] = perms;
        emit AdminSet(who, perms);
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // =================================================================
    //  MIGRATION IN (closes for good at lockSeeding or seedDeadline)
    // =================================================================
    modifier seedOpen() {
        if (seedLocked || block.timestamp > seedDeadline) revert SeedingClosed();
        _;
    }

    /// Copy bonds. legacy[i] = true copies an OSGStaking bond (must match
    /// the chain); false copies a v5 native bond (OSGStaking must have none).
    function seedTree(address[] calldata users, address[] calldata refs, bool[] calldata legacy)
        external onlyOwner seedOpen
    {
        uint256 n = users.length;
        if (n != refs.length || n != legacy.length) revert BadLength();
        if (n == 0 || n > MAX_BATCH) revert BadBatch();
        for (uint256 i = 0; i < n; i++) {
            address u = users[i];
            address r = refs[i];
            if (u == address(0) || r == address(0)) revert ZeroAddress();
            if (u == r) revert CannotReferSelf();
            if (nativeReferrer[u] != address(0)) revert AlreadyRegistered();
            address onChain = _legacyReferrer(u);
            if (legacy[i] ? onChain != r : onChain != address(0)) revert NotPermitted();
            if (_reachesUpward(r, u)) revert WouldLoop();
            _bond(u, r, legacy[i]);
            _syncDirect(u);
        }
    }

    struct SeedRow {
        address user;
        uint256 owed;
        uint256 paid;
        uint256 volume;
        uint8   rank;
        uint8   lastAccrualRank;   // v5 lastAccrualRank, kept for the lower-end rule
        uint256 rankSince;
        uint256 lastBonusAt;
        uint256 bonusPaid;
        uint256 bonusOwed;
        uint256 airdropOwed;
        uint256 airdropPaid;
    }

    /// Carry every per-wallet balance and rank clock across from v5.
    /// Overwrites, so a lost batch can be re-sent: safe because nothing
    /// can be claimed until seeding is closed (unpause requires it) and
    /// accrual stays frozen until the owner unfreezes it.
    /// rankProvedAt starts now: a seeded rank opens its levels for
    /// RANK_VALIDITY and must then be proven again.
    function seedUsers(SeedRow[] calldata rows) external onlyOwner seedOpen {
        if (rows.length == 0 || rows.length > MAX_BATCH) revert BadBatch();
        for (uint256 i = 0; i < rows.length; i++) {
            SeedRow calldata r = rows[i];
            address u = r.user;
            if (u == address(0)) revert ZeroAddress();
            if (r.rank > maxRank) revert BadSetting(23);
            totalOwed            = totalOwed - owed[u] + r.owed;
            totalBonusOwed       = totalBonusOwed - bonusOwed[u] + r.bonusOwed;
            totalAirdropAssigned = totalAirdropAssigned - airdropOwed[u] + r.airdropOwed;
            totalAirdropPaid     = totalAirdropPaid - airdropPaid[u] + r.airdropPaid;
            owed[u]            = r.owed;
            paid[u]            = r.paid;
            volume[u]          = r.volume;
            rankOf[u]          = r.rank;
            lastAccrualRank[u] = r.lastAccrualRank;
            rankSince[u]       = r.rankSince;
            rankProvedAt[u]    = r.rank == 0 ? 0 : block.timestamp;
            lastBonusAt[u]     = r.lastBonusAt;
            bonusPaidTotal[u]  = r.bonusPaid;
            bonusOwed[u]       = r.bonusOwed;
            airdropOwed[u]     = r.airdropOwed;
            airdropPaid[u]     = r.airdropPaid;
            _list(u);
        }
    }

    function lockSeeding() external onlyOwner {
        seedLocked = true;
        emit SeedingLocked();
    }

    // =================================================================
    //  VIEWS
    // =================================================================

    function referrerOf(address user) external view returns (address) { return _referrerOf(user); }
    function directReferrals(address user) external view returns (uint256) { return _directCount(user); }

    function verifiedDirectVolume(address user, address[] calldata directs)
        external view returns (uint256 count, uint256 stakeTotal)
    {
        return _verifiedDirectVolume(user, directs);
    }

    function currentRank(address user, address[] calldata directs) external view returns (uint8) {
        (uint256 count, uint256 team) = _verifiedDirectVolume(user, directs);
        return _rankFor(count, team, stakeOf(user));
    }

    function childrenCount(address user) external view returns (uint256) { return children[user].length; }
    function stakeSourceCount() external view returns (uint256) { return stakeSources.length; }
    function usersLength() external view returns (uint256) { return allUsers.length; }

    function _list(address user) internal {
        if (user != address(0) && !_listed[user]) {
            _listed[user] = true;
            allUsers.push(user);
        }
    }
}
