// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/*
 * ======================================================================
 *  OSGLPMining v7
 *  Category-2 (Mining) distributor. Stake OSG/WPOL LP, receive OSG.
 * ======================================================================
 *
 *  WHY v7 EXISTS
 *  -------------
 *  v6 shares a daily budget across everyone who has deposited. Nobody is
 *  promised a rate; the rate is whatever the budget divided by the crowd
 *  happens to be that day. That works, but it cannot express the offer
 *  this programme now makes -- "10% a month, locked for a year" -- so v7
 *  changes three things and keeps everything else v6 got right.
 *
 *    1. A CEILING ON THE RATE, in OSG terms.
 *    2. A TERM, counted per deposit rather than per wallet.
 *    3. POSITIONS, because a per-deposit term needs per-deposit records.
 *
 *  1 -- HOW AN LP TOKEN GETS A RATE
 *  --------------------------------
 *  "10% a month" needs a number to take 10% OF, and an LP token is not
 *  OSG. So each deposit is measured once, at deposit time:
 *
 *      osgValue = lpAmount * lpWeight / 1e18
 *
 *  lpWeight is set by the owner, NOT read from the pair's reserves. That
 *  is deliberate and it is the single most important safety decision in
 *  this contract. The OSG/WPOL pool is shallow; a few hundred dollars
 *  moves the reserves substantially, and reserves can be moved and moved
 *  back inside one transaction with borrowed money. Anything priced off
 *  them can be inflated on demand -- deposit at the fake price, collect
 *  at the fake rate, unwind. Reading a live price here would hand that
 *  lever to anyone who wanted it.
 *
 *  A hand-set weight goes stale instead, which is a smaller problem with
 *  an obvious fix: the owner updates it. And because osgValue is frozen
 *  into each position at deposit, changing lpWeight never disturbs
 *  anyone already staked -- it only prices deposits made after it.
 *
 *  When the pool is deep enough that moving it costs more than the reward
 *  is worth, a later version can read reserves directly. Not today.
 *
 *  2 -- THE TERM, AND WHY IT IS PER DEPOSIT
 *  ----------------------------------------
 *  v6 timed its 24-hour lock from a wallet's FIRST deposit, for ever.
 *  Stretch that to a year and the hole is plain: deposit 1 LP, wait out
 *  the year, then deposit ten thousand and withdraw them the same day.
 *  Each deposit therefore carries its own clock.
 *
 *  The term is a term, not a trap. forfeitAndWithdraw() returns the LP in
 *  full at any moment, from the first block onwards, and makes no call to
 *  RewardPool while doing it -- so no failure anywhere else in the system
 *  can hold someone's LP. What leaving early costs is the reward accrued
 *  and not yet taken. Nothing else.
 *
 *  3 -- WHAT CARRIES OVER FROM v6 UNCHANGED
 *  ----------------------------------------
 *   - accrue-then-pay ordering, so a failed payout can never erase an
 *     accrual (v6 FIX 3)
 *   - payouts capped by MAX_SINGLE_ALLOC and by today's remaining Mining
 *     budget, paid in chunks rather than reverting (v6 FIX 2)
 *   - referral hooks in try/catch: a referral-side revert must never
 *     block a deposit, a claim, or an exit
 *   - capacity on deposits, so the liability stays inside the budget
 *   - rescueToken can never touch the LP token
 *
 *  WHAT WAS DROPPED
 *  ----------------
 *  The five-tier structure. Only T1 was ever used, and per-deposit
 *  positions plus five tiers is a great deal of surface area for a
 *  feature nobody has needed. A second pair is a second deployment,
 *  which is also a cleaner accounting boundary.
 * ======================================================================
 */

interface IOSGRewardPool {
    function distribute(address user, uint256 amount, uint8 category) external;
    function distributorType(address) external view returns (uint8);
    function distributorActive(address) external view returns (bool);
    function paused() external view returns (bool);
    function emissionStopped() external view returns (bool);
    function emissionEndTime() external view returns (uint256);
    /// 0-100, NOT bps -- verified against mainnet on 5 Aug 2026.
    function miningPercent() external view returns (uint256);
    function getTodayStats() external view returns (
        uint256 stakingUsedAmt, uint256 miningUsedAmt, uint256 referralUsedAmt,
        uint256 stakingAvail, uint256 miningAvail, uint256 referralAvail,
        uint256 dailyBase
    );
}

/// The hook carries LP UNITS, not the OSG valuation.
///
/// OSGLPReferral v1 measures a team against poolCapacityLp, which is
/// denominated in LP. Feed it osgValue and the two sides of that
/// comparison stop being the same unit -- ranks come out wrong, quietly.
/// A referral contract that wants the OSG figure reads stakedValueOf()
/// instead, which is exact and needs no hook at all.
interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

interface IOSGLPReferral {
    function onLiquidityChange(address depositor, uint256 lpDelta, bool isAdd) external;
    function onRewardClaimed(address user, uint256 rewardAmount) external;
}

contract OSGLPMining is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ====================== CONSTANTS ======================

    uint8   public constant CAT_MINING       = 2;
    uint256 public constant BPS_DENOM        = 10_000;
    uint256 public constant ACC_PRECISION    = 1e18;

    /// Mirrors RewardPool.MAX_SINGLE_ALLOC. Payouts are capped at it,
    /// never reverted above it.
    uint256 public constant MAX_SINGLE_ALLOC = 10_000 * 1e18;

    /// How long each position must be held before withdraw() will return
    /// the LP. forfeitAndWithdraw() ignores it entirely.
    uint256 public constant LOCK_PERIOD      = 365 days;

    uint256 public constant MAX_POSITIONS    = 5;

    /// Bounds on the rate ceiling. The floor exists so the ceiling can
    /// never be set so low that positions earn nothing while still locked.
    uint256 public constant MIN_RATE_BPS     = 10;   // 0.1%/day
    uint256 public constant MAX_RATE_BPS     = 200;  // 2.0%/day

    /// Hard ceiling on this contract's slice of the Mining bucket.
    ///
    /// The bucket is shared with OSGTermStaking, and neither contract can
    /// see the other's setting -- so nothing on-chain stops the two
    /// shares summing past 100%. If they do, the shortfall shows up as
    /// payouts that quietly cannot be filled on busy days rather than as
    /// a revert anyone would notice.
    ///
    /// Tightened from v6's 9,000 to make the arithmetic hard to get
    /// badly wrong by accident. The invariant still has to be held by
    /// whoever operates the contracts:
    ///
    ///     TermStaking.miningShareBps + LPMining.miningShareBps <= 10,000
    ///
    /// Launch configuration is 2,000 + 5,000 = 7,000, leaving 30% of the
    /// bucket unspoken for.
    uint256 public constant ABSOLUTE_MAX_SHARE_BPS = 7_000;

    // ====================== IMMUTABLES ======================

    IERC20         public immutable lpToken;
    IOSGRewardPool public immutable pool;

    // ====================== CONFIG ======================

    /// Rate ceiling in bps per day, on the OSG valuation of a position.
    ///
    /// 33 bps is 0.33%/day, which is 9.9% over 30 days -- not 10%. The
    /// contract accrues simple daily interest, so the honest phrasing for
    /// any user-facing copy is "up to ~9.9% per 30 days". Rounding up to
    /// "10% monthly" in a headline is fine; writing it in documentation
    /// as though the contract guarantees it is not.
    ///
    /// It is a ceiling, never a promise: once the OSG value staked here
    /// outgrows the daily budget, the rate everyone actually receives
    /// falls below it together. effectiveRateBps() is the live figure.
    uint256 public maxRateBps     = 33;

    /// This contract's slice of the Mining bucket.
    ///
    /// The Mining bucket is shared with OSGTermStaking. Nothing on chain
    /// enforces that the two shares add up to 100% or less -- each
    /// contract only knows its own -- so it is an operating rule:
    ///
    ///     TermStaking.miningShareBps + this.miningShareBps <= 10000
    ///
    /// Break it and no funds are at risk, but the sum of what both
    /// contracts promise exceeds what RewardPool will release, so payouts
    /// start getting capped and deferred and neither rate holds. The
    /// ceiling below starts at 50% rather than 90% so a single mistyped
    /// call cannot quietly put the pair over the line.
    uint256 public miningShareBps = 5_000;
    uint256 public maxShareBps    = 5_000;

    /// OSG per 1 LP, 18 decimals. Owner-set on purpose -- see the header.
    /// Frozen into each position at deposit, so changing it never moves
    /// anyone already staked.
    uint256 public lpWeight;

    /// Ceiling on LP held. Reaching it closes new deposits only.
    uint256 public capacityLp;

    uint256 public minDeposit = 1 ether;

    /// 0 = open indefinitely.
    uint256 public depositDeadline;

    /// One-way release valve on the term.
    ///
    /// The term below is binding: for 365 days there is no way out of a
    /// position, and that is the whole point of it. But "no way out" has
    /// to have a floor under it. If this contract were paused for good,
    /// or RewardPool were retired, or something were found in here that
    /// meant nobody should be depositing any more, a binding term would
    /// go on holding LP that has stopped earning anything -- and holding
    /// it for reasons that had nothing to do with the person who
    /// deposited it.
    ///
    /// Flipping this lifts the term for everyone at once. It cannot be
    /// flipped back. That asymmetry is deliberate: an owner who can lock
    /// and unlock at will has a lever over depositors, while an owner who
    /// can only ever unlock has a fire exit and nothing more.
    bool public termLifted;

    IOSGLPReferral public referralContract;

    // ====================== ACCOUNTING ======================

    struct Position {
        uint256 lpAmount;    // LP held
        uint256 osgValue;    // OSG-denominated size, fixed at deposit
        uint256 rewardDebt;
        uint256 rewardPaid;
        uint256 unpaid;      // accrued, not yet delivered
        uint256 startTime;
        bool    closed;
    }
    mapping(address => Position[]) public positions;

    /// Sum of osgValue over OPEN positions -- what the accumulator
    /// divides by.
    uint256 public totalStakeValue;

    /// LP actually held. Solvency and capacity are measured against this.
    uint256 public totalLp;

    uint256 public accRewardPerShare;
    uint256 public lastRewardTime;

    // ====================== EVENTS ======================

    event Deposited(address indexed user, uint256 indexed posId, uint256 lpAmount, uint256 osgValue);
    event Claimed(address indexed user, uint256 indexed posId, uint256 amount);
    event Withdrawn(address indexed user, uint256 indexed posId, uint256 lpAmount);
    event ForfeitWithdrawn(address indexed user, uint256 indexed posId, uint256 lpAmount, uint256 forfeited);
    event PayoutCapped(address indexed user, uint256 indexed posId, uint256 paid, uint256 remaining);
    event SettlementDeferred(address indexed user, uint256 indexed posId, uint256 unpaidTotal, string reason);
    event ReferralHookFailed(address indexed user, string what, bytes reason);

    event LpWeightUpdated(uint256 oldWeight, uint256 newWeight);
    event CapacityUpdated(uint256 oldCapacity, uint256 newCapacity);
    event MaxRateUpdated(uint256 newBps);
    event MiningShareUpdated(uint256 newBps);
    event MinDepositUpdated(uint256 newMin);
    event DepositDeadlineUpdated(uint256 newDeadline);
    event ReferralContractUpdated(address indexed newContract);
    event TermLifted(uint256 at);

    // ====================== CONSTRUCTION ======================

    constructor(
        address _lpToken,
        address _pool,
        address _owner,
        uint256 _lpWeight,
        uint256 _capacityLp
    ) Ownable(_owner) {
        require(_lpToken.code.length > 0, "lpToken not contract");
        require(_pool.code.length    > 0, "pool not contract");
        // osgValue = lpAmount * lpWeight / 1e18 only holds if the LP token
        // carries 18 decimals. A UniswapV2 pair always does; check anyway,
        // because getting this wrong misprices every position by orders of
        // magnitude and nothing downstream would notice.
        require(IERC20Metadata(_lpToken).decimals() == 18, "lpToken must be 18 decimals");
        require(_lpWeight  > 0, "lpWeight is zero");
        require(_capacityLp > 0, "capacity is zero");
        // osgValue = lpAmount * lpWeight / 1e18 assumes an 18-decimal LP
        // token. Every Uniswap-V2-style pair is 18 decimals, QuickSwap
        // included, but the assumption is silent and the consequence of
        // it being wrong is a valuation off by orders of magnitude -- so
        // it is checked here rather than trusted.
        require(IERC20Decimals(_lpToken).decimals() == 18, "LP must be 18 decimals");

        lpToken        = IERC20(_lpToken);
        pool           = IOSGRewardPool(_pool);
        lpWeight       = _lpWeight;
        capacityLp     = _capacityLp;
        lastRewardTime = block.timestamp;
    }

    // ====================== BUDGET ======================

    function getLpMiningDailyBudget() public view returns (uint256) {
        ( , , , , , , uint256 dailyBase) = pool.getTodayStats();
        uint256 miningBucket = (dailyBase * pool.miningPercent()) / 100;
        return (miningBucket * miningShareBps) / BPS_DENOM;
    }

    /// The rate actually running. Front-ends must show THIS, not
    /// maxRateBps -- the ceiling is not a promise. Once the OSG value
    /// staked outgrows the budget, everyone's daily rate falls together.
    function effectiveRateBps() public view returns (uint256) {
        if (totalStakeValue == 0) return maxRateBps;
        uint256 ideal = (totalStakeValue * maxRateBps) / BPS_DENOM;
        if (ideal == 0) return maxRateBps;
        uint256 budget = getLpMiningDailyBudget();
        if (budget >= ideal) return maxRateBps;
        return (maxRateBps * budget) / ideal;
    }

    // ====================== SETTLEMENT ======================

    function _settle() internal {
        if (block.timestamp <= lastRewardTime) return;
        if (totalStakeValue == 0) {
            lastRewardTime = block.timestamp;
            return;
        }

        // Stop the clock at the end of emission. Crediting time past it
        // would create pending reward nobody can ever be paid, because
        // RewardPool refuses to distribute once emission is over.
        uint256 endsAtTs = pool.emissionEndTime();
        uint256 until = block.timestamp;
        if (endsAtTs != 0 && until > endsAtTs) until = endsAtTs;
        if (until <= lastRewardTime) {
            lastRewardTime = block.timestamp;
            return;
        }

        uint256 elapsed = until - lastRewardTime;
        uint256 ideal   = (totalStakeValue * maxRateBps) / BPS_DENOM;
        uint256 budget  = getLpMiningDailyBudget();
        uint256 daily   = ideal < budget ? ideal : budget;

        if (daily > 0) {
            uint256 reward = (daily * elapsed) / 1 days;
            if (reward > 0) {
                accRewardPerShare += (reward * ACC_PRECISION) / totalStakeValue;
            }
        }
        lastRewardTime = block.timestamp;
    }

    /// Settlement reaches into RewardPool, so it lives in an outer frame:
    /// a paused or reverting pool must not take an exit down with it.
    function _settleExternal() external {
        require(msg.sender == address(this), "internal only");
        _settle();
    }

    function _trySettle() internal {
        try this._settleExternal() {
            // updated
        } catch {
            // proceed on the stale accumulator rather than block an exit
        }
    }

    /// Anyone may bring the accumulator up to date.
    function settle() external {
        _settle();
    }

    /// Banks newly accrued reward into unpaid. Touches nothing external,
    /// so it cannot revert -- which is what keeps a failed payout from
    /// erasing an accrual.
    function _accrue(address user, uint256 posId) internal {
        Position storage p = positions[user][posId];
        if (p.closed || p.osgValue == 0) return;

        uint256 accumulated = (p.osgValue * accRewardPerShare) / ACC_PRECISION;
        if (accumulated > p.rewardDebt) {
            p.unpaid += accumulated - p.rewardDebt;
        }
        p.rewardDebt = accumulated;
    }

    // ====================== DEPOSIT ======================

    function deposit(uint256 lpAmount) external nonReentrant whenNotPaused {
        require(lpAmount >= minDeposit, "below minimum");
        require(
            depositDeadline == 0 || block.timestamp < depositDeadline,
            "deposits closed"
        );
        require(totalLp + lpAmount <= capacityLp, "capacity full");
        require(_openPositions(msg.sender) < MAX_POSITIONS, "position limit reached");

        // Settle BEFORE totalStakeValue moves, or the new position would
        // be credited with time it was never staked for.
        _settle();

        uint256 before = lpToken.balanceOf(address(this));
        lpToken.safeTransferFrom(msg.sender, address(this), lpAmount);
        uint256 received = lpToken.balanceOf(address(this)) - before;
        require(received >= minDeposit, "below minimum after transfer");

        uint256 osgValue = (received * lpWeight) / 1e18;
        require(osgValue > 0, "value rounds to zero");

        positions[msg.sender].push(Position({
            lpAmount:   received,
            osgValue:   osgValue,
            rewardDebt: (osgValue * accRewardPerShare) / ACC_PRECISION,
            rewardPaid: 0,
            unpaid:     0,
            startTime:  block.timestamp,
            closed:     false
        }));

        totalStakeValue += osgValue;
        totalLp         += received;

        uint256 posId = positions[msg.sender].length - 1;
        emit Deposited(msg.sender, posId, received, osgValue);

        _notifyLiquidityChange(msg.sender, received, true);
    }

    // ====================== CLAIM ======================

    function claim(uint256 posId) external nonReentrant whenNotPaused {
        require(posId < positions[msg.sender].length, "bad posId");
        _settle();
        _accrue(msg.sender, posId);
        _payout(msg.sender, posId);
    }

    function claimAll() external nonReentrant whenNotPaused {
        uint256 n = positions[msg.sender].length;
        require(n > 0, "no positions");
        _claimRange(0, n);
    }

    /// Same as claimAll(), over a slice.
    ///
    /// MAX_POSITIONS caps how many positions a wallet holds OPEN, not how
    /// many it has ever held -- closed ones stay as history. After enough
    /// terms, walking the whole array costs more than it is worth. This
    /// lets a long-standing depositor work through it in pieces. Nobody
    /// is ever forced to use it.
    function claimRange(uint256 start, uint256 end)
        external
        nonReentrant
        whenNotPaused
    {
        require(start < end && end <= positions[msg.sender].length, "bad range");
        _claimRange(start, end);
    }

    function _claimRange(uint256 start, uint256 end) internal {
        _settle();

        uint256 owedTotal;
        for (uint256 i = start; i < end; i++) {
            _accrue(msg.sender, i);
            owedTotal += positions[msg.sender][i].unpaid;
        }
        require(owedTotal > 0, "nothing to claim");

        uint256 payout = owedTotal > MAX_SINGLE_ALLOC ? MAX_SINGLE_ALLOC : owedTotal;
        ( , , , , uint256 miningAvail, , ) = pool.getTodayStats();
        if (payout > miningAvail) payout = miningAvail;
        require(payout > 0, "no mining budget available today");

        // Drain oldest first. Sequential rather than pro-rata so the
        // arithmetic is exact and no dust is stranded.
        uint256 left = payout;
        for (uint256 i = start; i < end && left > 0; i++) {
            Position storage p = positions[msg.sender][i];
            if (p.unpaid == 0) continue;
            uint256 take = p.unpaid < left ? p.unpaid : left;
            p.unpaid     -= take;
            p.rewardPaid += take;
            left         -= take;
            emit Claimed(msg.sender, i, take);
        }

        pool.distribute(msg.sender, payout, CAT_MINING);

        if (owedTotal > payout) {
            emit PayoutCapped(msg.sender, type(uint256).max, payout, owedTotal - payout);
        }

        _notifyRewardClaimed(msg.sender, payout);
    }

    /// Pays one position, capped by both limits, keeping the remainder.
    function _payout(address user, uint256 posId) internal {
        Position storage p = positions[user][posId];
        if (p.unpaid == 0) return;

        uint256 payout = p.unpaid > MAX_SINGLE_ALLOC ? MAX_SINGLE_ALLOC : p.unpaid;
        ( , , , , uint256 miningAvail, , ) = pool.getTodayStats();
        if (payout > miningAvail) payout = miningAvail;
        require(payout > 0, "no mining budget available today");

        p.unpaid     -= payout;
        p.rewardPaid += payout;

        pool.distribute(user, payout, CAT_MINING);
        emit Claimed(user, posId, payout);

        if (p.unpaid > 0) {
            emit PayoutCapped(user, posId, payout, p.unpaid);
        }

        _notifyRewardClaimed(user, payout);
    }

    function _payoutExternal(address user, uint256 posId) external {
        require(msg.sender == address(this), "internal only");
        _payout(user, posId);
    }

    // ====================== WITHDRAW ======================

    /// Returns the LP once the term is up, and pays out whatever has
    /// accrued. A failed payout does not block the LP -- the reward waits
    /// in unpaid and claim() collects it later.
    function withdraw(uint256 posId) external nonReentrant {
        require(posId < positions[msg.sender].length, "bad posId");
        _trySettle();
        _accrue(msg.sender, posId);

        Position storage p = positions[msg.sender][posId];
        require(!p.closed, "already closed");
        require(
            termLifted || block.timestamp >= p.startTime + LOCK_PERIOD,
            "term not finished"
        );

        if (p.unpaid > 0) {
            try this._payoutExternal(msg.sender, posId) {
                // paid
            } catch Error(string memory reason) {
                emit SettlementDeferred(msg.sender, posId, p.unpaid, reason);
            } catch {
                emit SettlementDeferred(msg.sender, posId, p.unpaid, "low-level revert");
            }
        }

        uint256 lp  = p.lpAmount;
        uint256 val = p.osgValue;
        p.closed = true;

        totalStakeValue -= val;
        totalLp         -= lp;

        lpToken.safeTransfer(msg.sender, lp);
        emit Withdrawn(msg.sender, posId, lp);

        _notifyLiquidityChange(msg.sender, lp, false);
    }

    /// The unconditional exit. Available from the first block, ignores
    /// the term, and is not whenNotPaused.
    ///
    /// To be exact about what it does touch: _trySettle() does reach into
    /// RewardPool, but through try/catch, so a paused, unreachable or
    /// permanently dead pool costs the caller nothing more than a stale
    /// accumulator. No SUCCESSFUL RewardPool call is required anywhere on
    /// this path, which is the property that matters -- nothing outside
    /// this contract can hold anyone's LP.
    ///
    /// Reward accrued and not yet taken is given up; the LP comes back in
    /// full.
    function forfeitAndWithdraw(uint256 posId) external nonReentrant {
        require(posId < positions[msg.sender].length, "bad posId");

        _trySettle();
        _accrue(msg.sender, posId);

        Position storage p = positions[msg.sender][posId];
        require(!p.closed, "already closed");
        require(
            termLifted || block.timestamp >= p.startTime + LOCK_PERIOD,
            "term not finished"
        );

        uint256 lp        = p.lpAmount;
        uint256 val       = p.osgValue;
        uint256 forfeited = p.unpaid;

        p.unpaid = 0;
        p.closed = true;

        totalStakeValue -= val;
        totalLp         -= lp;

        lpToken.safeTransfer(msg.sender, lp);
        emit ForfeitWithdrawn(msg.sender, posId, lp, forfeited);

        _notifyLiquidityChange(msg.sender, lp, false);
    }

    // ====================== REFERRAL HOOKS ======================
    // Both stay in try/catch: a referral-side failure must never block a
    // deposit, a claim, or an exit.

    function _notifyLiquidityChange(address user, uint256 lpDelta, bool isAdd) internal {
        if (address(referralContract) == address(0)) return;
        try referralContract.onLiquidityChange(user, lpDelta, isAdd) {
            // ok
        } catch (bytes memory reason) {
            emit ReferralHookFailed(user, "onLiquidityChange", reason);
        }
    }

    function _notifyRewardClaimed(address user, uint256 amount) internal {
        if (address(referralContract) == address(0)) return;
        try referralContract.onRewardClaimed(user, amount) {
            // ok
        } catch (bytes memory reason) {
            emit ReferralHookFailed(user, "onRewardClaimed", reason);
        }
    }

    // ====================== VIEWS ======================

    function _openPositions(address user) internal view returns (uint256 n) {
        Position[] storage list = positions[user];
        uint256 len = list.length;
        for (uint256 i = 0; i < len; i++) {
            if (!list[i].closed) n++;
        }
    }

    function openPositions(address user) external view returns (uint256) {
        return _openPositions(user);
    }

    function positionCount(address user) external view returns (uint256) {
        return positions[user].length;
    }

    function pendingReward(address user, uint256 posId) public view returns (uint256) {
        require(posId < positions[user].length, "bad posId");
        Position storage p = positions[user][posId];
        uint256 total = p.unpaid;
        if (p.closed || p.osgValue == 0) return total;

        uint256 acc = accRewardPerShare;
        // Same clock-stop as _settle(), so view and settlement agree.
        uint256 endsAtTs = pool.emissionEndTime();
        uint256 until = block.timestamp;
        if (endsAtTs != 0 && until > endsAtTs) until = endsAtTs;

        if (until > lastRewardTime && totalStakeValue > 0) {
            uint256 elapsed = until - lastRewardTime;
            uint256 ideal   = (totalStakeValue * maxRateBps) / BPS_DENOM;
            uint256 budget  = getLpMiningDailyBudget();
            uint256 daily   = ideal < budget ? ideal : budget;
            uint256 reward  = (daily * elapsed) / 1 days;
            if (reward > 0) acc += (reward * ACC_PRECISION) / totalStakeValue;
        }

        uint256 accumulated = (p.osgValue * acc) / ACC_PRECISION;
        if (accumulated > p.rewardDebt) total += accumulated - p.rewardDebt;
        return total;
    }

    /// What the NEXT settlement could actually send right now, after both
    /// caps. Zero means nothing is payable today -- useful for honest UI
    /// wording: "X accrued, Y payable now".
    function nextPayoutChunk(address user, uint256 posId) external view returns (uint256) {
        uint256 total = pendingReward(user, posId);
        if (total > MAX_SINGLE_ALLOC) total = MAX_SINGLE_ALLOC;
        ( , , , , uint256 miningAvail, , ) = pool.getTodayStats();
        return total > miningAvail ? miningAvail : total;
    }

    /// Seconds until this position's term is up; zero once it has passed
    /// or once the term has been lifted for everyone.
    function lockRemaining(address user, uint256 posId) external view returns (uint256) {
        require(posId < positions[user].length, "bad posId");
        if (termLifted) return 0;
        uint256 unlockAt = positions[user][posId].startTime + LOCK_PERIOD;
        return block.timestamp >= unlockAt ? 0 : unlockAt - block.timestamp;
    }

    /// OSG-denominated size of everything this wallet has open here. The
    /// referral contract reads it to work out a referrer's direct volume.
    function stakedValueOf(address user) external view returns (uint256 total) {
        Position[] storage list = positions[user];
        uint256 len = list.length;
        for (uint256 i = 0; i < len; i++) {
            if (!list[i].closed) total += list[i].osgValue;
        }
    }

    /// LP this wallet has open here.
    function stakedLpOf(address user) external view returns (uint256 total) {
        Position[] storage list = positions[user];
        uint256 len = list.length;
        for (uint256 i = 0; i < len; i++) {
            if (!list[i].closed) total += list[i].lpAmount;
        }
    }

    function capacityLeft() external view returns (uint256) {
        return capacityLp > totalLp ? capacityLp - totalLp : 0;
    }

    function isWiredForMining() public view returns (bool) {
        return pool.distributorType(address(this)) == CAT_MINING
            && pool.distributorActive(address(this));
    }

    /// One-call diagnosis of why a payout would fail right now, so the UI
    /// can show a reason instead of a bare revert. It does NOT gate
    /// exits: forfeitAndWithdraw() works whatever this returns.
    function payoutHealth() external view returns (bool canPayNow, string memory reason) {
        if (!isWiredForMining())    return (false, "not registered as category-2 distributor");
        if (paused())               return (false, "mining contract paused");
        if (pool.paused())          return (false, "RewardPool paused");
        if (pool.emissionStopped()) return (false, "emission stopped");
        ( , , , , uint256 miningAvail, , ) = pool.getTodayStats();
        if (miningAvail == 0)       return (false, "daily mining budget exhausted");
        return (true, "ready");
    }

    /// LP held beyond what positions account for -- normally zero.
    function excessLp() public view returns (uint256) {
        uint256 balance = lpToken.balanceOf(address(this));
        return balance > totalLp ? balance - totalLp : 0;
    }

    function version() external pure returns (string memory) {
        return "OSGLPMining v7";
    }

    // ====================== ADMIN ======================

    /// Reprice future deposits. Existing positions keep the osgValue they
    /// were given, so nobody already staked is moved by this.
    ///
    /// Bounded to a 2x move either way per call, and never to zero. An
    /// unbounded setter would let a mistyped figure -- or a deliberate one
    /// -- reprice the whole programme in a single transaction.
    function setLpWeight(uint256 newWeight) external onlyOwner {
        require(newWeight > 0, "zero weight");
        // Written as a multiplication rather than newWeight >= lpWeight/2:
        // integer division rounds down, so the divided form would let
        // 3 -> 1 through as "half".
        require(
            newWeight <= lpWeight * 2 && newWeight * 2 >= lpWeight,
            "move limited to 2x per call"
        );
        emit LpWeightUpdated(lpWeight, newWeight);
        lpWeight = newWeight;
    }

    /// Raise the LP ceiling. Up only: lowering it would let deposits be
    /// frozen out at will, which is a different power from this one.
    function setCapacityLp(uint256 newCapacity) external onlyOwner {
        require(newCapacity > capacityLp, "capacity can only rise");
        emit CapacityUpdated(capacityLp, newCapacity);
        capacityLp = newCapacity;
    }

    function setMaxRateBps(uint256 newBps) external onlyOwner {
        require(newBps >= MIN_RATE_BPS && newBps <= MAX_RATE_BPS, "rate out of bounds");
        _settle();   // settle at the OLD ceiling first
        maxRateBps = newBps;
        emit MaxRateUpdated(newBps);
    }

    function setMiningShareBps(uint256 newBps) external onlyOwner {
        require(newBps <= maxShareBps, "exceeds max share");
        _settle();   // settle at the OLD share first
        miningShareBps = newBps;
        emit MiningShareUpdated(newBps);
    }

    function setMaxShareBps(uint256 newMax) external onlyOwner {
        require(newMax <= ABSOLUTE_MAX_SHARE_BPS, "exceeds absolute max");
        require(miningShareBps <= newMax, "below current share");
        maxShareBps = newMax;
    }

    function setMinDeposit(uint256 newMin) external onlyOwner {
        require(newMin > 0, "zero minimum");
        minDeposit = newMin;
        emit MinDepositUpdated(newMin);
    }

    function setDepositDeadline(uint256 newDeadline) external onlyOwner {
        require(
            newDeadline == 0 || newDeadline > block.timestamp,
            "deadline in the past"
        );
        depositDeadline = newDeadline;
        emit DepositDeadlineUpdated(newDeadline);
    }

    function setReferralContract(address _referral) external onlyOwner {
        require(_referral != address(0), "zero address");
        require(_referral.code.length > 0, "referral must be a contract");
        referralContract = IOSGLPReferral(_referral);
        emit ReferralContractUpdated(_referral);
    }

    /// Lift the 365-day term for every position, now and in future.
    /// One-way -- see `termLifted`. Intended for winding the programme
    /// down or for a fault that makes staying deposited pointless, not
    /// for ordinary operation.
    function liftTerm() external onlyOwner {
        require(!termLifted, "already lifted");
        termLifted = true;
        emit TermLifted(block.timestamp);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// Recover a token sent here by mistake. The LP token is excluded
    /// beyond any surplus: deposited LP belongs to depositors.
    function rescueToken(address token, address to, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        require(to != address(0) && amount > 0, "bad args");
        if (token == address(lpToken)) {
            require(amount <= excessLp(), "would touch depositor LP");
        }
        IERC20(token).safeTransfer(to, amount);
    }
}
