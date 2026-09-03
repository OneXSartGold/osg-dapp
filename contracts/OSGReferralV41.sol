// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/*
 * ======================================================================
 *  OSGReferral v4.1
 *  Category-3 (Referral) distributor.
 * ======================================================================
 *
 *  CHANGES FROM v4 (review of 10 Aug 2026)
 *  ---------------------------------------
 *  1. refreshRank() is now restricted to the wallet itself or the owner.
 *     In v4 anyone could call it for anyone, and an empty directs list is
 *     a valid list, so a stranger could set any wallet's rank to zero for
 *     the cost of gas. That reset rankSince as well, so the 24-hour hold
 *     could be restarted indefinitely and the bonus blocked forever.
 *     Letting a stranger LOWER a rank bought nothing anyway --
 *     claimTeamBonus() re-proves the rank live before it pays.
 *
 *  2. claimTeamBonus() now reverts when the treasury pays nothing. In v4
 *     the period was marked spent before the transfer and never unwound,
 *     so a wallet that arrived after the treasury's rolling 30-day
 *     ceiling was exhausted burned a whole month for zero OSG. Reverting
 *     is safe here precisely because nothing moved: a revert cannot undo
 *     a payment that never happened, so the repeated-call drain the
 *     original ordering guarded against is not reachable. A PARTIAL
 *     payment still consumes the month -- that part is deliberate.
 *
 *  3. onRewardClaimed() no longer carries whenNotPaused. Sources call it
 *     inside try/catch, so under v4 a pause did not defer commission, it
 *     destroyed it silently while downline claims carried on. Pausing is
 *     meant to stop money leaving, not to erase what people are owed.
 *     claimMyReferral() still respects the pause, which is where it
 *     belongs.
 *
 *  4. stakeOf() reads TermStaking and LPMining defensively. A wrong
 *     address or a renamed function in setWiring() would otherwise
 *     revert every read path -- refreshRank, claimTeamBonus and
 *     previewRank all funnel through here -- and brick the whole bonus
 *     programme. A failed read now contributes zero, which understates a
 *     rank and never inflates one, matching how a short directs list
 *     already behaves. stakeWiringHealthy() exists so the mistake is
 *     visible rather than silent.
 *
 *  TWO SEPARATE PROGRAMMES, TWO SEPARATE PURSES
 *  --------------------------------------------
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
 *  Keeping the purses apart is the point. A bonus scheme funded from the
 *  same bucket as the commissions would quietly reduce everybody's
 *  commission every time someone new qualified.
 *
 *  WHY 45% NEEDED A NEW CONTRACT
 *  -----------------------------
 *  v3 has `uint256 public constant MAX_TOTAL_LEVEL_BPS = 3_000`. A
 *  constant cannot be changed after deployment, and setLevelBps() checks
 *  against it, so 45% was unreachable there. Everything else here is v3's
 *  logic with the table widened and the bonus added.
 *
 *  THE TREE IS NOT STORED HERE
 *  ---------------------------
 *  Who referred whom lives in OSGStaking and is read live. Nobody
 *  re-registers, and a team built two years ago counts today exactly as
 *  it did then. v3 works the same way, and it has been confirmed on
 *  mainnet: a wallet with five old directs showed five levels open here
 *  the day the contract went live.
 *
 *  HOW A RANK IS PROVEN
 *  --------------------
 *  A1/A2/A3 need the total staked by a wallet's DIRECT referrals. That
 *  list can be any length, and walking an unbounded list on-chain is how
 *  a contract becomes unusable for exactly the people it was meant to
 *  reward -- the ones with the biggest teams.
 *
 *  So the caller supplies the list and the contract checks it:
 *
 *    - each address must actually name the caller as its referrer, read
 *      live from OSGStaking, so the list cannot be padded with strangers
 *    - the list must be in strictly ascending order, which makes a
 *      duplicate impossible to slip in and costs one comparison per
 *      entry rather than a nested loop
 *
 *  The caller pays the gas for the length of their own list, and a short
 *  list only ever understates a rank -- never inflates it.
 *
 *  STAKE MEANS ALL THREE PLACES
 *  ----------------------------
 *  A direct's stake is the sum of what they hold in Active Staking, in
 *  TermStaking and in LP Mining. LP is counted at the OSG valuation that
 *  LPMining itself froze in at deposit -- deliberately not a live price,
 *  because a shallow pool makes any live price something an attacker can
 *  move for the length of one transaction.
 * ======================================================================
 */

interface IOSGStaking {
    function getReferralChain(address user) external view returns (
        address l1, address l2, address l3, address l4, address l5
    );
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

interface ITermStaking {
    function stakedOf(address user) external view returns (uint256);
}

interface ILPMining {
    function stakedValueOf(address user) external view returns (uint256);
}

contract OSGReferral is Ownable, Pausable, ReentrancyGuard {

    // ====================== CONSTANTS ======================

    uint8   public constant CAT_REFERRAL = 3;
    uint256 public constant BPS_DENOM    = 10_000;
    uint256 public constant LEVELS       = 15;

    /// Ceiling on the sum of the level table. 45% is the intended figure;
    /// the headroom above it is there so the split can be tuned without
    /// another deployment, which is the mistake v3 made by setting this
    /// to exactly what it needed at the time.
    uint256 public constant MAX_TOTAL_LEVEL_BPS = 6_000;

    /// Mirrors RewardPool.MAX_SINGLE_ALLOC. Confirm against the deployed
    /// pool before wiring -- a lower figure there makes distribute()
    /// revert on any claim this contract sizes to its own constant.
    uint256 public constant MAX_SINGLE_ALLOC = 10_000 * 1e18;

    /// How long a rank must be held before it starts paying, and how long
    /// between payments.
    uint256 public constant RANK_HOLD    = 24 hours;
    uint256 public constant BONUS_PERIOD = 30 days;

    uint256 public constant MAX_DIRECTS_PER_CALL = 200;

    // ====================== WIRING ======================

    IOSGStaking    public immutable staking;
    IOSGRewardPool public immutable pool;

    IOSGTreasury public treasury;
    ITermStaking public termStaking;
    ILPMining    public lpMining;

    /// Contracts allowed to report a reward claim. Everything that pays
    /// OSG out of emission should be here; nothing else should.
    mapping(address => bool) public isSource;

    // ====================== LEVEL TABLE ======================

    /// Commission per level, in bps of the reward being claimed.
    /// L1 15% · L2 10% · L3 5% · L4 3% · L5 2% · L6-L15 1% each = 45%.
    uint256[LEVELS] public levelBps;

    /// Direct referrals needed to open each level: one per level.
    uint256[LEVELS] public levelConditions;

    uint256 public totalLevelBps;

    // ====================== COMMISSION LEDGER ======================

    mapping(address => uint256) public owed;
    mapping(address => uint256) public paid;

    /// Reward volume introduced by this wallet's downline. Note that the
    /// full reward is added at EVERY level that credits, so across a deep
    /// chain the same OSG is counted more than once. It is a commission
    /// base, not a team-volume figure -- do not surface it as one.
    mapping(address => uint256) public volume;

    // ====================== ACHIEVEMENT BONUS ======================

    struct Tier {
        uint256 directsNeeded;
        uint256 stakeNeeded;   // OSG, summed over directs
        uint256 monthlyPayout; // OSG
    }
    /// Index 1..3. Index 0 is unused so a rank of 0 can mean "none".
    Tier[4] public tiers;

    /// When the wallet's current rank was first reached. Reset whenever
    /// the rank changes, so dropping and re-qualifying restarts the wait.
    mapping(address => uint256) public rankSince;
    mapping(address => uint8)   public rankOf;
    mapping(address => uint256) public lastBonusAt;
    mapping(address => uint256) public bonusPaidTotal;

    // ====================== EVENTS ======================

    event CommissionAccrued(address indexed earner, address indexed from, uint8 level, uint256 amount);
    event CommissionPaid(address indexed earner, uint256 amount, uint256 remainingOwed);
    event PayoutCapped(address indexed earner, uint256 paidNow, uint256 remaining);

    event RankUpdated(address indexed user, uint8 oldRank, uint8 newRank, uint256 directVolume);
    event BonusPaid(address indexed user, uint8 rank, uint256 requested, uint256 received);
    event BonusShort(address indexed user, uint256 requested, uint256 received);

    event SourceUpdated(address indexed source, bool allowed);
    event LevelTableUpdated(uint256 totalBps);
    event TierUpdated(uint8 rank, uint256 directsNeeded, uint256 stakeNeeded, uint256 monthlyPayout);
    event WiringUpdated(address treasury, address termStaking, address lpMining);

    // ====================== CONSTRUCTION ======================

    constructor(address _staking, address _pool, address _owner) Ownable(_owner) {
        require(_staking.code.length > 0, "staking not contract");
        require(_pool.code.length    > 0, "pool not contract");

        staking = IOSGStaking(_staking);
        pool    = IOSGRewardPool(_pool);

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
        // asks for -- 100/4,000, 250/10,000 and 1,250/50,000 all come to
        // the same rate. What actually discourages splitting one large
        // team into several small ones is the DIRECTS requirement, not
        // the rate: reaching A2 five times over costs 75 directs to earn
        // exactly what one A3 earns on 15. If these figures are ever
        // retuned via setTier(), keep the rate flat or falling as the
        // tiers rise -- a lower tier paying a better rate would make
        // splitting the profitable move.
        tiers[1] = Tier({ directsNeeded: 10, stakeNeeded:  4_000 * 1e18, monthlyPayout:   100 * 1e18 });
        tiers[2] = Tier({ directsNeeded: 15, stakeNeeded: 10_000 * 1e18, monthlyPayout:   250 * 1e18 });
        tiers[3] = Tier({ directsNeeded: 15, stakeNeeded: 50_000 * 1e18, monthlyPayout: 1_250 * 1e18 });
    }

    // ====================== LEVEL COMMISSION ======================

    /// Called by a source contract when it pays a reward. Walks up to
    /// fifteen levels and credits each unlocked one.
    ///
    /// This only ever writes to `owed`. It never transfers, never touches
    /// RewardPool, and cannot revert on a payment problem -- because it
    /// runs inside the downline user's own claim, and a referral-side
    /// failure must never cost that user their reward. Sources call it
    /// inside try/catch as well; this is the second layer.
    ///
    /// Deliberately NOT whenNotPaused: a pause must stop payouts, not
    /// erase entitlements. Sources swallow reverts, so a paused accrual
    /// would vanish without a trace while the downline claim succeeded.
    function onRewardClaimed(address user, uint256 rewardAmount)
        external
    {
        require(isSource[msg.sender], "not a source");
        if (rewardAmount == 0 || user == address(0)) return;

        (address l1, address l2, address l3, address l4, address l5) =
            staking.getReferralChain(user);
        address[5] memory head = [l1, l2, l3, l4, l5];

        address current = user;
        for (uint256 i = 0; i < LEVELS; i++) {
            address ref;
            if (i < 5) {
                ref = head[i];
            } else {
                // Beyond the fifth, climb one link at a time. Staking
                // stores every wallet's own referrer, so the chain was
                // always fifteen deep -- v3 was simply the first to read
                // past five.
                (, , , , , , ref, , , , ) = staking.users(current);
            }
            if (ref == address(0)) break;
            current = ref;

            if (!_levelUnlocked(ref, i + 1)) continue;

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
    /// Both optional reads are guarded. If either contract is unset, is
    /// not a contract, or does not answer with a uint256, its share
    /// counts as zero rather than reverting the whole call. Every rank
    /// path runs through here, so a single bad setWiring() argument would
    /// otherwise take the entire bonus programme offline. Understating a
    /// rank is recoverable; a dead contract is not.
    function stakeOf(address user) public view returns (uint256 total) {
        (uint256 activeStake, , , , , , , , , , ) = staking.users(user);
        total = activeStake;

        if (address(termStaking).code.length > 0) {
            try termStaking.stakedOf(user) returns (uint256 t) {
                total += t;
            } catch {}
        }
        if (address(lpMining).code.length > 0) {
            try lpMining.stakedValueOf(user) returns (uint256 l) {
                total += l;
            } catch {}
        }
    }

    /// Sum the stake of a supplied list of directs, after checking every
    /// entry is genuinely a direct of `user` and that the list holds no
    /// duplicates.
    ///
    /// Ascending order is what rules duplicates out: each address must be
    /// strictly greater than the one before, so the same wallet cannot
    /// appear twice and the check costs one comparison per entry instead
    /// of a nested scan.
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

            (, , , , , , address ref, , , , ) = staking.users(d);
            require(ref == user, "not your direct");

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
        // the one returned. Written as `r = 3; r > 0; r--` rather than
        // `r >= 1` because r is unsigned: at r == 0 the decrement would
        // wrap to 255 and the loop would never end.
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
    /// Restricted to the wallet itself or the owner. It records only what
    /// the chain already says, so on the face of it anyone could call it
    /// for anyone; but an empty directs list is a valid list that proves
    /// a rank of zero, and recording a change resets the 24-hour clock.
    /// Left open, a stranger could drop any wallet to rank zero the
    /// moment it refreshed and repeat that indefinitely, blocking the
    /// bonus for the price of gas. Nothing is lost by closing it:
    /// claimTeamBonus() re-proves the rank live before paying, so a stale
    /// high rank in storage cannot be cashed in.
    ///
    /// A rank starts its 24-hour clock the moment it is first recorded.
    /// Changing rank in either direction restarts that clock, so the
    /// bonus cannot be captured by qualifying for a moment on the day a
    /// payment is due. Note the corollary: refreshing UPWARD also
    /// restarts it, so a wallet that is about to collect at its current
    /// rank should collect first and refresh afterwards.
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

    /// Collect a month's achievement bonus.
    ///
    /// The rank is re-proved live inside this call rather than trusted
    /// from storage -- storage says what was true when refreshRank() last
    /// ran, which may have been before the team unwound. The recorded
    /// rank still matters, because it carries the 24-hour clock; this
    /// call simply refuses to pay a rank that has since stopped being
    /// true.
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

        // Nothing at all is a different case from not enough. The
        // treasury's rolling 30-day ceiling means late claimants in a
        // busy period get zero, and under the original ordering they also
        // forfeited the month. Reverting here is safe precisely because
        // no OSG moved: there is no payment for the revert to undo, so
        // the drain this ordering guards against stays out of reach.
        require(received > 0, "treasury empty this period, try again later");

        bonusPaidTotal[msg.sender] += received;

        emit BonusPaid(msg.sender, payRank, amount, received);
        if (received < amount) {
            emit BonusShort(msg.sender, amount, received);
        }
    }

    // ====================== VIEWS ======================

    function _levelUnlocked(address user, uint256 level) internal view returns (bool) {
        if (level == 0 || level > LEVELS) return false;
        (, , , , , , , uint256 directRefs, , , ) = staking.users(user);
        return directRefs >= levelConditions[level - 1];
    }

    /// How many levels this wallet currently earns on.
    function unlockedLevels(address user) public view returns (uint256 n) {
        (, , , , , , , uint256 directRefs, , , ) = staking.users(user);
        for (uint256 i = 0; i < LEVELS; i++) {
            if (directRefs >= levelConditions[i]) n = i + 1;
        }
    }

    /// Combined bps this wallet earns across its open levels.
    function activeBps(address user) external view returns (uint256 total) {
        uint256 n = unlockedLevels(user);
        for (uint256 i = 0; i < n; i++) total += levelBps[i];
    }

    function directReferrals(address user) external view returns (uint256) {
        (, , , , , , , uint256 directRefs, , , ) = staking.users(user);
        return directRefs;
    }

    function getLevelTable() external view returns (
        uint256[LEVELS] memory bps,
        uint256[LEVELS] memory conditions
    ) {
        return (levelBps, levelConditions);
    }

    /// What a supplied list of directs is worth, without writing anything.
    /// A front-end calls this to show a rank before asking for a signature.
    function previewRank(address user, address[] calldata directs)
        external
        view
        returns (uint8 rank, uint256 count, uint256 stakeTotal)
    {
        (count, stakeTotal) = _verifiedDirectVolume(user, directs);
        rank = _rankFor(count, stakeTotal);
    }

    /// Whether the two optional stake sources actually answer. stakeOf()
    /// swallows a failure and counts zero, which is the right behaviour
    /// at runtime and the wrong thing to discover in production -- call
    /// this once after setWiring() and confirm both come back true.
    function stakeWiringHealthy() external view returns (bool termOk, bool lpOk) {
        if (address(termStaking).code.length > 0) {
            try termStaking.stakedOf(address(this)) returns (uint256) {
                termOk = true;
            } catch {}
        }
        if (address(lpMining).code.length > 0) {
            try lpMining.stakedValueOf(address(this)) returns (uint256) {
                lpOk = true;
            } catch {}
        }
    }

    /// Seconds until the recorded rank has been held long enough to pay.
    function rankHoldRemaining(address user) external view returns (uint256) {
        if (rankOf[user] == 0) return 0;
        uint256 readyAt = rankSince[user] + RANK_HOLD;
        return block.timestamp >= readyAt ? 0 : readyAt - block.timestamp;
    }

    /// Seconds until this wallet's next bonus is due.
    function bonusCooldownRemaining(address user) external view returns (uint256) {
        uint256 nextAt = lastBonusAt[user] + BONUS_PERIOD;
        return block.timestamp >= nextAt ? 0 : nextAt - block.timestamp;
    }

    /// The Referral bucket's budget for today, before anything is spent.
    function referralDailyBudget() external view returns (uint256) {
        ( , , , , , uint256 referralAvail, ) = pool.getTodayStats();
        return referralAvail;
    }

    function isWiredForReferral() public view returns (bool) {
        return pool.distributorType(address(this)) == CAT_REFERRAL
            && pool.distributorActive(address(this));
    }

    /// One call telling the UI why a commission payout would fail now.
    function payoutHealth() external view returns (bool canPayNow, string memory reason) {
        if (!isWiredForReferral())  return (false, "not registered as category-3 distributor");
        if (paused())               return (false, "referral contract paused");
        if (pool.paused())          return (false, "RewardPool paused");
        if (pool.emissionStopped()) return (false, "emission stopped");
        ( , , , , , uint256 referralAvail, ) = pool.getTodayStats();
        if (referralAvail == 0)     return (false, "daily referral budget exhausted");
        return (true, "ready");
    }

    /// And why a bonus payout would fail now.
    function bonusHealth() external view returns (bool canPayNow, string memory reason) {
        if (address(treasury) == address(0)) return (false, "treasury not set");
        if (paused())                        return (false, "referral contract paused");
        if (block.timestamp >= treasury.endsAt()) return (false, "bonus season ended");
        if (treasury.teamBonusAvailable() == 0)   return (false, "treasury empty for this period");
        return (true, "ready");
    }

    function version() external pure returns (string memory) {
        return "OSGReferral v4.1";
    }

    // ====================== ADMIN ======================

    function setSource(address source, bool allowed) external onlyOwner {
        require(source != address(0), "zero address");
        isSource[source] = allowed;
        emit SourceUpdated(source, allowed);
    }

    function setWiring(address _treasury, address _term, address _lp) external onlyOwner {
        treasury    = IOSGTreasury(_treasury);
        termStaking = ITermStaking(_term);
        lpMining    = ILPMining(_lp);
        emit WiringUpdated(_treasury, _term, _lp);
    }

    /// Retune the level table. The sum is checked against a ceiling that
    /// leaves room above 45%, so a split can be adjusted without another
    /// deployment.
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
    /// to every wallet on the chain, including ones that have never
    /// referred anybody.
    function setLevelConditions(uint256[LEVELS] calldata newConditions) external onlyOwner {
        require(newConditions[0] >= 1, "level 1 needs a direct");
        for (uint256 i = 1; i < LEVELS; i++) {
            require(newConditions[i] >= newConditions[i - 1], "conditions must not fall");
        }
        levelConditions = newConditions;
    }

    /// Adjust a tier. Existing ranks are re-evaluated on the next
    /// refreshRank() or claimTeamBonus(), both of which read live.
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
