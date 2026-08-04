// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/*
 * ======================================================================
 *  OSGReferral v3
 *  Category-3 distributor. 15 fixed levels, plus two self-funded
 *  treasury programmes.
 *
 *  Replaces the v2 draft, which was never deployed. v2 split two fixed
 *  POOLS between everyone who qualified, so a level's value depended on
 *  how many others held it and no percentage could honestly be quoted.
 *  This one pays a FIXED percentage of each distribution, so the number
 *  on the screen is the number that arrives.
 * ======================================================================
 *
 *  WHY A FIXED PERCENTAGE IS SAFE HERE
 *    A percentage of a DEPOSIT would be unbounded -- one 50,000 OSG
 *    deposit at 20% would swallow eight days of the whole Referral
 *    bucket. A percentage of a DISTRIBUTION cannot be, because
 *    distribution is already capped upstream:
 *
 *        Mining bucket (60% split)      3,528.60 OSG/day maximum
 *        x 25% across all fifteen levels  882.15 OSG/day maximum
 *        + Staking's own built-in referral 270.53
 *        ------------------------------------------------
 *                                       1,152.68 of 1,176.20 available
 *
 *    The ceiling is structural: sources can only ever hand this contract
 *    a share of a number the RewardPool already limits. That is the whole
 *    reason commissions hook onto claims and never onto deposits.
 *
 *    MAX_TOTAL_LEVEL_BPS is set at 3,000 rather than the 2,500 in use, so
 *    the levels can be tuned without a redeploy, and levelsSolvent()
 *    reports whether the current table still fits beside everything else
 *    drawing on the bucket.
 *
 *  NOTHING IS EVER TAKEN FROM A DEPOSITOR
 *    A downline member's own reward is untouched. Commission is minted
 *    separately out of the Referral bucket. Somebody distributed 100 OSG
 *    still receives 100 OSG; their level-4 upline receives 2 OSG as well.
 *
 *  DEPTH REQUIRES WIDTH
 *    Level N pays only once the user holds N direct referrals, read live
 *    from OSGStaking.users().totalReferrals. Fifteen wallets in a chain
 *    unlock nothing. Combined with Staking's own rules -- a referrer must
 *    hold 100 OSG staked, a direct must have staked at least 10 -- a
 *    fifteen-deep sybil has to fund every referrer in the spine, which is
 *    where the cost actually lands.
 *
 *  TWO TREASURY PROGRAMMES, BOTH SELF-LIMITING
 *    1. INSTANT   a one-off percentage to the direct referrer when their
 *                 introduction first deposits.
 *    2. GIFT      an achievement bonus once a direct's cumulative deposit
 *                 crosses a threshold, granted in whole steps.
 *
 *    Each has its own pool, each can be topped up by anyone at any time,
 *    and each simply STOPS when its pool empties -- the hook skips it and
 *    returns. A deposit is never blocked by an empty treasury, and no
 *    announcement is needed to end a programme that ends itself.
 *
 *    A shortfall is never a forfeit. Entitlement and payment are tracked
 *    separately, so a bonus cut short by an empty pool stays owed, and
 *    settleInstant()/settleGift() -- both permissionless -- pay it out
 *    once the pool is refilled.
 *
 *    Both pools hold real OSG transferred in, not emission. They cost the
 *    Referral bucket nothing.
 *
 *    STATE THIS PLAINLY IN ANY MARKETING. These two programmes are NOT
 *    permanent and NOT guaranteed. They last exactly as long as their
 *    pools do, the owner may set either rate to zero, and
 *    withdrawTreasury() can pull unspent OSG back out. That is
 *    appropriate for a promotion funded from the founder's own holdings
 *    rather than from emission -- but describing it as a permanent
 *    benefit would be false, and the on-chain balance is public, so the
 *    day it runs dry is visible to everyone whether or not it is
 *    announced. The level commissions are the durable part; these are
 *    not.
 *
 *    Level commission is NEVER held here -- it is minted by RewardPool on
 *    claim -- so nothing the owner does to the treasury can touch it.
 *
 *    WEIGHTED VOLUME, DELIBERATELY -- AND CAPPED
 *    Both treasury programmes size their bonus from NORMALISED volume,
 *    the same figure the level commissions use, so a source worth 5x an
 *    LP unit pays 5x. That is the correct answer if the weights are
 *    right: 100 LP and 100 OSG are not the same amount of value, and
 *    paying them identically would quietly punish whichever source is
 *    denominated in the larger unit.
 *
 *    The risk is not the design, it is a mis-set weight -- a future
 *    Activity source registered at 50,000 bps would otherwise empty the
 *    instant pool in a handful of deposits. maxInstantPerIntro bounds
 *    exactly that, to a number chosen in advance, so the worst a wrong
 *    weight can do is pay the maximum instead of draining the pot.
 *
 *    Switching to raw deposit amounts would be the alternative. It is
 *    rejected because it would put two different notions of "volume" in
 *    one contract, and the cap already removes the hazard that motivated
 *    it.
 *
 *  ADMIN-LESS MONEY PATH
 *    Hooks fire automatically, and each user pulls their own balance with
 *    claimMyReferral(). RewardPool's one-distribute-per-block cooldown
 *    resolves itself because separate claimers land in separate blocks.
 *    The owner cannot withhold, redirect or delay a single OSG.
 *
 *    Configuration stays owner-gated on purpose: an open setSource()
 *    would let anyone register a fake contract and mint unlimited
 *    commission. The honest way to decentralise that is to hand ownership
 *    to the TimelockDAO, not to leave it open.
 * ======================================================================
 */

interface IOSGRewardPool {
    function distribute(address user, uint256 amount, uint8 category) external;
    function distributorType(address) external view returns (uint8);
    function distributorActive(address) external view returns (bool);
    function paused() external view returns (bool);
    function emissionStopped() external view returns (bool);
    function referralPercent() external view returns (uint256);
    function getTodayStats() external view returns (
        uint256 stakingUsedAmt, uint256 miningUsedAmt, uint256 referralUsedAmt,
        uint256 stakingAvail, uint256 miningAvail, uint256 referralAvail,
        uint256 dailyBase
    );
}

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

contract OSGReferral is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ====================== CONSTANTS ======================
    uint8   public constant CAT_REFERRAL = 3;
    uint256 public constant BPS_DENOM    = 10_000;
    uint256 public constant LEVEL_COUNT  = 15;

    /// Mirrors RewardPool.MAX_SINGLE_ALLOC.
    uint256 public constant MAX_SINGLE_ALLOC = 10_000 * 1e18;

    /// Headroom above the 2,500 bps actually in use, so the table can be
    /// retuned without a redeploy. See levelsSolvent() before raising.
    uint256 public constant MAX_TOTAL_LEVEL_BPS = 3_000;

    /// A source may be worth at most 5x an LP unit.
    uint256 public constant MAX_SOURCE_WEIGHT_BPS = 50_000;

    /// Delay before a RAISE to a live source's weight takes effect.
    uint256 public constant SOURCE_WEIGHT_DELAY = 72 hours;

    uint256 public constant MAX_INSTANT_BPS = 1_000;   // 10%
    uint256 public constant MAX_GIFT_BPS    = 2_000;   // 20%

    // ====================== IMMUTABLES ======================
    IERC20         public immutable osg;
    IOSGRewardPool public immutable pool;
    IOSGStaking    public immutable staking;

    // ====================== LEVELS ======================
    /// Percentage of a downline member's distribution, in bps.
    /// 5/4/3/2/1 then 1 for the rest = 2,500 bps = 25%.
    uint256[15] public levelBps = [
        500, 400, 300, 200, 100,
        100, 100, 100, 100, 100,
        100, 100, 100, 100, 100
    ];

    /// Direct referrals required before a level pays anything.
    uint256[15] public levelConditions = [
        uint256(1), 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
    ];

    // ====================== SOURCES ======================
    /// Any registered mining/staking contract may drive the hooks.
    /// Units differ between sources -- LP tokens, OSG, activity points --
    /// so each carries a weight and volume is recorded normalised.
    ///
    /// The weight is an owner-set, publicly readable ratio, NOT a price
    /// feed. An on-chain OSG price would have to come from the OSG/WPOL
    /// pair, and that pair is shallow enough to move inside a single
    /// transaction. A published constant cannot be manipulated by a flash
    /// loan; it can only be wrong, and wrong is visible and fixable.
    mapping(address => uint256) public sourceWeightBps;
    address[] public sources;
    mapping(address => bool) private _known;

    struct PendingWeight { uint256 weightBps; uint256 eta; }
    mapping(address => PendingWeight) public pendingWeight;

    // ====================== TREASURY ======================
    /// Real OSG held here, never emission. Separate pools so an empty
    /// instant programme cannot starve the gift programme or the reverse.
    uint256 public instantPool;
    uint256 public giftPool;

    uint256 public instantBps    = 500;              // 5% to the direct referrer
    uint256 public giftBps       = 1_000;            // 10% of each completed step
    uint256 public giftStep      = 1_000 * 1e18;     // granted per 1,000 OSG
    uint256 public giftMaxPerUser = 100_000 * 1e18;  // lifetime ceiling per referrer

    /// Absolute ceiling on a single instant bonus, whatever the source or
    /// its weight. Weights normalise units so that a 5x source genuinely
    /// pays 5x, which is correct for a level commission funded by
    /// emission -- but the treasury is a fixed pot of real OSG, and a
    /// mis-set weight on a future Activity source could otherwise drain
    /// it in a handful of deposits. This bounds that mistake to a number
    /// the owner chose in advance.
    uint256 public maxInstantPerIntro = 500 * 1e18;

    /// Cumulative deposit volume introduced by each direct, and how much
    /// of that volume has already been REWARDED.
    ///
    /// Volume, not step count. A step count would be re-measured whenever
    /// giftStep changed: with 1,000 volume rewarded at a step of 1,000,
    /// dropping the step to 100 would turn one paid step into ten earned
    /// ones and pay nine more bonuses for volume that had already been
    /// rewarded once. Volume paid is an absolute quantity and cannot be
    /// revalued, so a config change reaches only genuinely unpaid
    /// progress -- which is the intended behaviour.
    mapping(address => mapping(address => uint256)) public directVolume;
    mapping(address => mapping(address => uint256)) public giftVolumePaid;
    mapping(address => uint256) public giftEarned;

    /// Instant bonus is fixed at a wallet's first deposit, then drawn
    /// down as the pool allows, so a shortfall is never forfeited.
    mapping(address => uint256) public instantEntitled;
    mapping(address => uint256) public instantPaid;
    mapping(address => address) public instantReferrer;

    // ====================== ACCOUNTING ======================
    mapping(address => uint256) public owed;
    mapping(address => uint256) public paid;
    mapping(address => uint256) public totalVolume;   // lifetime, per user

    // ====================== EVENTS ======================
    event SourceUpdated(address indexed source, uint256 weightBps);
    /// Full detail for explorers and analytics: what was distributed, at
    /// what rate, and what that produced.
    event ReferralAccrued(
        address indexed referrer,
        address indexed from,
        uint8   level,
        uint256 rewardAmount,
        uint256 bps,
        uint256 commission,
        uint256 newOwed
    );
    event InstantEntitled(address indexed earner, address indexed from, uint256 amount);
    event InstantPaid(address indexed earner, address indexed from, uint256 amount);
    event InstantPending(address indexed earner, address indexed from, uint256 shortfall);
    event GiftPaid(address indexed earner, address indexed from, uint256 steps, uint256 amount);
    event ReferralPaid(address indexed user, uint256 amount, uint256 remainingOwed);
    event PayoutDeferred(address indexed user, uint256 owedAmount, string reason);
    event PayoutCapped(address indexed user, uint256 paidNow, uint256 remaining);
    event TreasuryFunded(address indexed from, bool isInstant, uint256 amount, uint256 newBalance);
    event TreasuryExhausted(bool isInstant);
    event TreasuryTransferFailed(address indexed earner, address indexed from, bool isInstant, bytes reason);
    event SourceWeightQueued(address indexed source, uint256 oldWeightBps, uint256 newWeightBps, uint256 eta);
    event SourceWeightCancelled(address indexed source);
    event SourceWeightExecuted(address indexed source, uint256 oldWeightBps, uint256 newWeightBps);
    event LevelBpsUpdated(uint256 level, uint256 newBps);
    event LevelConditionUpdated(uint256 level, uint256 newCondition);
    event InstantConfigUpdated(uint256 bps, uint256 maxPerIntro);
    event GiftConfigUpdated(uint256 bps, uint256 step, uint256 maxPerUser);

    error InvalidLevel();
    error NoOwed();

    modifier onlySource() {
        require(sourceWeightBps[msg.sender] > 0, "caller is not a source");
        _;
    }

    constructor(address _osg, address _pool, address _staking, address _owner)
        Ownable(_owner)
    {
        require(_osg.code.length     > 0, "osg not contract");
        require(_pool.code.length    > 0, "pool not contract");
        require(_staking.code.length > 0, "staking not contract");
        osg     = IERC20(_osg);
        pool    = IOSGRewardPool(_pool);
        staking = IOSGStaking(_staking);
    }

    // ====================== HOOKS ======================

    /// Called by a source on deposit and withdrawal. Deposits drive the
    /// two treasury programmes; withdrawals only unwind the bookkeeping.
    ///
    /// Deliberately NOT whenNotPaused: if this contract were paused while
    /// deposits continued, volume would silently drift out of sync with
    /// the source and could never be reconciled. Pausing stops payouts,
    /// not bookkeeping.
    function onLiquidityChange(address depositor, uint256 delta, bool isAdd)
        external onlySource
    {
        if (delta == 0) return;

        uint256 volume = (delta * sourceWeightBps[msg.sender]) / BPS_DENOM;
        if (volume == 0) return;

        if (!isAdd) {
            uint256 tv = totalVolume[depositor];
            totalVolume[depositor] = tv > volume ? tv - volume : 0;
            return;
        }

        totalVolume[depositor] += volume;

        (address l1, , , , ) = staking.getReferralChain(depositor);
        if (l1 == address(0)) return;

        // ---- BOOKKEEPING: main frame, must never be rolled back ----
        //
        // These two writes are the record that a deposit happened. If they
        // shared a frame with the transfers below, a token-side failure
        // would erase them along with the payment, and that deposit's
        // volume would be gone for good -- the gift steps it earned could
        // never be recovered, and an instant entitlement would vanish
        // before it was ever paid.
        _recordInstant(l1, depositor, volume);
        if (giftBps > 0 && giftStep > 0) {
            directVolume[l1][depositor] += volume;
        }

        // ---- PAYMENT: outer frame, allowed to fail ----
        //
        // safeTransfer() cannot be wrapped in try/catch directly, so a
        // paused or misbehaving token would otherwise revert somebody's
        // deposit over a promotional bonus. With the records already
        // committed above, a failure here costs nothing permanent:
        // settleInstant()/settleGift() retry it later.
        try this.payInstantFor(depositor) {
        } catch (bytes memory reason) {
            emit TreasuryTransferFailed(l1, depositor, true, reason);
        }
        try this.payGiftFor(l1, depositor) {
        } catch (bytes memory reason) {
            emit TreasuryTransferFailed(l1, depositor, false, reason);
        }
    }

    /// THE MONEY HOOK. Fires after a source has actually delivered a
    /// reward, with the amount that genuinely landed -- already capped by
    /// the source against MAX_SINGLE_ALLOC and the live daily budget. A
    /// commission is therefore never computed on a figure larger than
    /// what was really paid.
    function onRewardClaimed(address user, uint256 rewardAmount)
        external onlySource
    {
        if (rewardAmount == 0) return;

        (address l1, address l2, address l3, address l4, address l5) =
            staking.getReferralChain(user);
        address[5] memory refs = [l1, l2, l3, l4, l5];

        address current = user;
        for (uint256 i = 0; i < LEVEL_COUNT; i++) {
            address ref;
            if (i < 5) {
                ref = refs[i];
            } else {
                (, , , , , , ref, , , , ) = staking.users(current);
            }
            if (ref == address(0)) break;

            uint256 bps = levelBps[i];
            if (bps > 0 && _levelUnlocked(ref, i)) {
                uint256 amount = (rewardAmount * bps) / BPS_DENOM;
                if (amount > 0) {
                    owed[ref] += amount;
                    emit ReferralAccrued(
                        ref, user, uint8(i + 1), rewardAmount, bps, amount, owed[ref]
                    );
                }
            }

            current = ref;
        }
    }

    function _levelUnlocked(address user, uint256 levelIndex) internal view returns (bool) {
        (, , , , , , , uint256 directRefs, , , ) = staking.users(user);
        return directRefs >= levelConditions[levelIndex];
    }

    // ====================== TREASURY PROGRAMMES ======================

    /// BOOKKEEPING ONLY -- no transfer, so this can never revert on a
    /// token-side failure. The entitlement is fixed the first time a
    /// wallet deposits and is never recomputed afterwards.
    function _recordInstant(address referrer, address depositor, uint256 volume) internal {
        if (instantEntitled[depositor] != 0) return;
        if (instantBps == 0) return;

        uint256 ent = (volume * instantBps) / BPS_DENOM;
        if (ent > maxInstantPerIntro) ent = maxInstantPerIntro;
        if (ent == 0) return;

        instantEntitled[depositor] = ent;
        instantReferrer[depositor] = referrer;
        emit InstantEntitled(referrer, depositor, ent);
    }

    /// PAYMENT ONLY. Draws the entitlement down as the pool allows, so a
    /// shortfall stays owed rather than being forfeited.
    function _settleInstant(address depositor) internal {
        uint256 ent = instantEntitled[depositor];
        uint256 pd  = instantPaid[depositor];
        if (ent <= pd) return;

        address referrer = instantReferrer[depositor];
        if (referrer == address(0)) return;

        uint256 remaining = ent - pd;
        if (instantPool == 0) {
            emit TreasuryExhausted(true);
            return;
        }

        uint256 amount = remaining > instantPool ? instantPool : remaining;
        instantPaid[depositor] = pd + amount;
        instantPool -= amount;

        osg.safeTransfer(referrer, amount);
        emit InstantPaid(referrer, depositor, amount);

        if (amount < remaining) {
            emit InstantPending(referrer, depositor, remaining - amount);
        }
        if (instantPool == 0) emit TreasuryExhausted(true);
    }

    function payInstantFor(address depositor) external {
        require(msg.sender == address(this), "internal only");
        _settleInstant(depositor);
    }

    function payGiftFor(address referrer, address depositor) external {
        require(msg.sender == address(this), "internal only");
        _settleGift(referrer, depositor);
    }

    /// Permissionless. Anyone may finish paying a bonus that was cut
    /// short, and the destination is fixed, so there is nothing to steal
    /// by calling it.
    function settleInstant(address depositor) external nonReentrant {
        _settleInstant(depositor);
    }

    /// PAYMENT ONLY -- directVolume is recorded in onLiquidityChange's
    /// own frame, so nothing here can undo it.
    ///
    /// Granted in whole steps of giftStep, and only steps that were
    /// ACTUALLY PAID are recorded. If the pool or the lifetime ceiling
    /// covers three of five earned steps, only those three are recorded
    /// as paid volume -- the other two stay owed and are picked up by the
    /// next deposit or by settleGift().
    function _settleGift(address referrer, address depositor) internal {
        if (giftBps == 0 || giftStep == 0) return;

        uint256 perStep = (giftStep * giftBps) / BPS_DENOM;
        if (perStep == 0) return;

        uint256 total = directVolume[referrer][depositor];
        uint256 done  = giftVolumePaid[referrer][depositor];
        if (total <= done) return;

        uint256 steps = (total - done) / giftStep;
        if (steps == 0) return;

        // Trim by the referrer's lifetime ceiling...
        uint256 room = giftMaxPerUser > giftEarned[referrer]
            ? giftMaxPerUser - giftEarned[referrer]
            : 0;
        uint256 byRoom = room / perStep;
        if (byRoom < steps) steps = byRoom;

        // ...then by what the pool can actually cover.
        uint256 byPool = giftPool / perStep;
        if (byPool < steps) steps = byPool;

        if (steps == 0) {
            if (giftPool < perStep) emit TreasuryExhausted(false);
            return;
        }

        uint256 amount = steps * perStep;

        giftVolumePaid[referrer][depositor] = done + (steps * giftStep);
        giftEarned[referrer] += amount;
        giftPool -= amount;

        osg.safeTransfer(referrer, amount);
        emit GiftPaid(referrer, depositor, steps, amount);

        if (giftPool < perStep) emit TreasuryExhausted(false);
    }

    /// Permissionless, for the same reason as settleInstant().
    function settleGift(address referrer, address depositor) external nonReentrant {
        _settleGift(referrer, depositor);
    }

    /// Open to anyone, so a programme can be revived without the owner.
    function fundInstant(uint256 amount) external nonReentrant {
        require(amount > 0, "zero amount");
        osg.safeTransferFrom(msg.sender, address(this), amount);
        instantPool += amount;
        emit TreasuryFunded(msg.sender, true, amount, instantPool);
    }

    function fundGift(uint256 amount) external nonReentrant {
        require(amount > 0, "zero amount");
        osg.safeTransferFrom(msg.sender, address(this), amount);
        giftPool += amount;
        emit TreasuryFunded(msg.sender, false, amount, giftPool);
    }

    // ====================== PAYOUT ======================

    function _pay(address user, uint256 want) internal returns (uint256) {
        uint256 available = owed[user];
        if (available == 0) return 0;

        uint256 amount = (want == 0 || want > available) ? available : want;
        if (amount > MAX_SINGLE_ALLOC) amount = MAX_SINGLE_ALLOC;

        ( , , , , , uint256 referralAvail, ) = pool.getTodayStats();
        if (amount > referralAvail) amount = referralAvail;
        if (amount == 0) {
            emit PayoutDeferred(user, available, "no referral budget today");
            return 0;
        }

        owed[user] -= amount;
        paid[user] += amount;

        try pool.distribute(user, amount, CAT_REFERRAL) {
            emit ReferralPaid(user, amount, owed[user]);
            if (owed[user] > 0) emit PayoutCapped(user, amount, owed[user]);
            return amount;
        } catch Error(string memory reason) {
            owed[user] += amount;
            paid[user] -= amount;
            emit PayoutDeferred(user, owed[user], reason);
            return 0;
        } catch {
            owed[user] += amount;
            paid[user] -= amount;
            emit PayoutDeferred(user, owed[user], "low-level revert");
            return 0;
        }
    }

    /// The normal path. Anyone pulls their own balance whenever they like,
    /// paying their own gas. Unclaimed `owed` is never lost; it waits.
    function claimMyReferral() external nonReentrant whenNotPaused {
        if (owed[msg.sender] == 0) revert NoOwed();
        _pay(msg.sender, 0);
    }

    /// Push a payout to someone else. Open rather than owner-gated: funds
    /// can only ever reach `user`, so a stranger calling this is doing
    /// that user a favour at their own gas cost.
    function payReferral(address user) external nonReentrant {
        if (owed[user] == 0) revert NoOwed();
        _pay(user, 0);
    }

    /// Partial payout, for balances above MAX_SINGLE_ALLOC.
    function payReferralAmount(address user, uint256 amount) external nonReentrant {
        if (owed[user] == 0) revert NoOwed();
        _pay(user, amount);
    }

    // ====================== VIEWS ======================

    function referralDailyBudget() public view returns (uint256) {
        ( , , , , , , uint256 dailyBase) = pool.getTodayStats();
        return (dailyBase * pool.referralPercent()) / 100;
    }

    function totalLevelBps() public view returns (uint256 total) {
        for (uint256 i = 0; i < LEVEL_COUNT; i++) total += levelBps[i];
    }

    /// Worst case the level table can draw, given the largest daily
    /// distribution the sources could ever produce. Front-ends and the
    /// owner should check this BEFORE raising any level.
    function maxDailyLevelCost(uint256 maxSourceDistribution)
        external view returns (uint256)
    {
        return (maxSourceDistribution * totalLevelBps()) / BPS_DENOM;
    }

    /// Whether today's budget still covers the table at that volume.
    /// otherDailyDraw is what else takes from the Referral bucket -- most
    /// importantly Staking's own built-in referral, ~270.53 OSG/day.
    function levelsSolvent(uint256 maxSourceDistribution, uint256 otherDailyDraw)
        external view returns (bool ok, uint256 needed, uint256 budget)
    {
        needed = ((maxSourceDistribution * totalLevelBps()) / BPS_DENOM) + otherDailyDraw;
        budget = referralDailyBudget();
        ok = needed <= budget;
    }

    /// How many levels this user currently unlocks. Front-ends should show
    /// this beside the level table so the condition is never a surprise.
    function unlockedLevels(address user) external view returns (uint256 n) {
        (, , , , , , , uint256 directRefs, , , ) = staking.users(user);
        for (uint256 i = 0; i < LEVEL_COUNT; i++) {
            if (directRefs >= levelConditions[i]) n = i + 1;
        }
    }

    /// Combined bps this user currently earns across unlocked levels.
    function activeBps(address user) external view returns (uint256 total) {
        (, , , , , , , uint256 directRefs, , , ) = staking.users(user);
        for (uint256 i = 0; i < LEVEL_COUNT; i++) {
            if (directRefs >= levelConditions[i]) total += levelBps[i];
        }
    }

    function directReferrals(address user) external view returns (uint256) {
        (, , , , , , , uint256 directRefs, , , ) = staking.users(user);
        return directRefs;
    }

    function getLevelTable()
        external view returns (uint256[15] memory bps, uint256[15] memory conditions)
    {
        return (levelBps, levelConditions);
    }

    /// What a cut-short bonus still owes. Front-ends should surface this
    /// so a referrer can see the shortfall rather than assume it vanished.
    function instantPending(address depositor) external view returns (uint256) {
        uint256 ent = instantEntitled[depositor];
        uint256 pd  = instantPaid[depositor];
        return ent > pd ? ent - pd : 0;
    }

    /// What the pool could actually pay right now, as opposed to what
    /// has been earned. Front-ends should show BOTH -- "earned" from
    /// giftPending() and "available" from this -- so a referrer can see
    /// that a shortfall is waiting on a refill, not lost.
    function giftPayable(address referrer, address depositor)
        external view returns (uint256 steps, uint256 amount)
    {
        if (giftBps == 0 || giftStep == 0) return (0, 0);
        uint256 perStep = (giftStep * giftBps) / BPS_DENOM;
        if (perStep == 0) return (0, 0);

        uint256 total = directVolume[referrer][depositor];
        uint256 done  = giftVolumePaid[referrer][depositor];
        if (total <= done) return (0, 0);
        steps = (total - done) / giftStep;
        if (steps == 0) return (0, 0);

        uint256 room = giftMaxPerUser > giftEarned[referrer]
            ? giftMaxPerUser - giftEarned[referrer]
            : 0;
        uint256 byRoom = room / perStep;
        if (byRoom < steps) steps = byRoom;

        uint256 byPool = giftPool / perStep;
        if (byPool < steps) steps = byPool;

        amount = steps * perStep;
    }

    /// EARNED, ignoring what the pool can currently cover.
    function giftPending(address referrer, address depositor)
        external view returns (uint256 steps, uint256 amount)
    {
        if (giftBps == 0 || giftStep == 0) return (0, 0);
        uint256 perStep = (giftStep * giftBps) / BPS_DENOM;
        if (perStep == 0) return (0, 0);
        uint256 total = directVolume[referrer][depositor];
        uint256 done  = giftVolumePaid[referrer][depositor];
        if (total <= done) return (0, 0);
        steps  = (total - done) / giftStep;
        amount = steps * perStep;
    }

    function instantActive() external view returns (bool) {
        return instantBps > 0 && instantPool > 0;
    }

    function giftActive() external view returns (bool) {
        return giftBps > 0 && giftPool > 0;
    }

    /// Length of the registry, including sources whose weight is now zero
    /// -- de-registering leaves the address in place so the array never
    /// has to be compacted. Read sourceWeightBps() for what is live.
    function sourceCount() external view returns (uint256) {
        return sources.length;
    }

    function isWiredForReferral() public view returns (bool) {
        return pool.distributorType(address(this)) == CAT_REFERRAL
            && pool.distributorActive(address(this));
    }

    function payoutHealth() external view returns (bool canPayNow, string memory reason) {
        if (!isWiredForReferral()) return (false, "not registered as category-3 distributor");
        if (paused())               return (false, "referral contract paused");
        if (pool.paused())          return (false, "RewardPool paused");
        if (pool.emissionStopped()) return (false, "emission stopped");
        if (sources.length == 0)    return (false, "no source registered");
        ( , , , , , uint256 referralAvail, ) = pool.getTodayStats();
        if (referralAvail == 0)     return (false, "daily referral budget exhausted");
        return (true, "ready");
    }

    /// OSG here beyond both treasury pools arrived by mistake.
    function excessBalance() public view returns (uint256) {
        uint256 bal      = osg.balanceOf(address(this));
        uint256 reserved = instantPool + giftPool;
        return bal > reserved ? bal - reserved : 0;
    }

    // ====================== ADMIN -- SOURCES ======================

    /// 10000 = 1:1 with an LP unit. Set weightBps to 0 to de-register.
    ///
    /// Asymmetric on purpose. Registering a NEW source and switching one
    /// OFF both take effect immediately -- wiring has to be possible, and
    /// an emergency stop that waits two days is not an emergency stop.
    /// CHANGING a live source's weight is the only direction that can
    /// inflate commission, so it queues for 72 hours and is
    /// visible on-chain the whole time. Handing ownership to the
    /// TimelockDAO layers a second delay on top of this one.
    ///
    /// Existing volume is NOT rescaled when a weight changes -- rewriting
    /// history for every user is unbounded work. Set a weight once,
    /// before a source goes live.
    function setSource(address src, uint256 weightBps) external onlyOwner {
        require(src.code.length > 0, "source not contract");
        require(weightBps <= MAX_SOURCE_WEIGHT_BPS, "weight too high");

        uint256 current = sourceWeightBps[src];
        if (current == 0 || weightBps == 0) {
            _applyWeight(src, weightBps);
            return;
        }

        uint256 eta = block.timestamp + SOURCE_WEIGHT_DELAY;
        pendingWeight[src] = PendingWeight(weightBps, eta);
        emit SourceWeightQueued(src, current, weightBps, eta);
    }

    /// Permissionless: the change was announced when it was queued, and
    /// only the queued value can be applied.
    function executeSourceWeight(address src) external {
        PendingWeight memory q = pendingWeight[src];
        require(q.eta != 0, "nothing queued");
        require(block.timestamp >= q.eta, "delay not elapsed");
        uint256 oldWeight = sourceWeightBps[src];
        delete pendingWeight[src];
        _applyWeight(src, q.weightBps);
        emit SourceWeightExecuted(src, oldWeight, q.weightBps);
    }

    function cancelSourceWeight(address src) external onlyOwner {
        require(pendingWeight[src].eta != 0, "nothing queued");
        delete pendingWeight[src];
        emit SourceWeightCancelled(src);
    }

    function _applyWeight(address src, uint256 weightBps) internal {
        if (weightBps > 0 && !_known[src]) {
            _known[src] = true;
            sources.push(src);
        }
        sourceWeightBps[src] = weightBps;
        emit SourceUpdated(src, weightBps);
    }

    // ====================== ADMIN -- LEVELS ======================

    function setLevelBps(uint256 level, uint256 bps) external onlyOwner {
        if (level >= LEVEL_COUNT) revert InvalidLevel();
        uint256 newTotal = totalLevelBps() - levelBps[level] + bps;
        require(newTotal <= MAX_TOTAL_LEVEL_BPS, "exceeds max total level bps");
        levelBps[level] = bps;
        emit LevelBpsUpdated(level, bps);
    }

    function setLevelCondition(uint256 level, uint256 condition) external onlyOwner {
        if (level >= LEVEL_COUNT) revert InvalidLevel();
        levelConditions[level] = condition;
        emit LevelConditionUpdated(level, condition);
    }

    // ====================== ADMIN -- TREASURY ======================

    /// Applies to FUTURE introductions only. An entitlement is fixed the
    /// first time a wallet deposits and is never recomputed, so nobody
    /// already owed a bonus sees it move.
    function setInstantConfig(uint256 bps, uint256 maxPerIntro) external onlyOwner {
        require(bps <= MAX_INSTANT_BPS, "exceeds max");
        instantBps        = bps;
        maxInstantPerIntro = maxPerIntro;
        emit InstantConfigUpdated(bps, maxPerIntro);
    }

    /// Applies to all UNPAID progress, and only to that. Volume already
    /// rewarded is recorded as volume, not as a step count, so changing
    /// the step size re-measures what has not been paid for and cannot
    /// resurrect what has.
    function setGiftConfig(uint256 bps, uint256 step, uint256 maxPerUser)
        external onlyOwner
    {
        require(bps <= MAX_GIFT_BPS, "exceeds max");
        require(step > 0, "zero step");
        giftBps        = bps;
        giftStep       = step;
        giftMaxPerUser = maxPerUser;
        emit GiftConfigUpdated(bps, step, maxPerUser);
    }

    /// Pull unspent treasury back out. Bounded by the pool balances, so
    /// this can never reach OSG that is owed to somebody: level
    /// commission is minted by RewardPool and never held here.
    function withdrawTreasury(bool isInstant, address to, uint256 amount)
        external onlyOwner
    {
        require(to != address(0) && amount > 0, "bad args");
        if (isInstant) {
            require(amount <= instantPool, "exceeds instant pool");
            instantPool -= amount;
        } else {
            require(amount <= giftPool, "exceeds gift pool");
            giftPool -= amount;
        }
        osg.safeTransfer(to, amount);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// Anything here beyond the two pools arrived by accident.
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0) && amount > 0, "bad args");
        if (token == address(osg)) {
            require(amount <= excessBalance(), "would touch treasury");
        }
        IERC20(token).safeTransfer(to, amount);
    }

    function version() external pure returns (string memory) {
        return "OSGReferral v3";
    }
}
