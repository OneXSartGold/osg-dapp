// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/*
 * ======================================================================
 *  OSGTermStaking v2
 *  Category-2 (Mining) distributor. Stake OSG, receive OSG.
 *
 *  WHAT CHANGED FROM v1
 *    Three additions, nothing removed:
 *      capacity     -- a ceiling on how much principal the contract will
 *                      take in at all, so the 2x liability it signs up
 *                      for stays inside what the budget can actually pay.
 *      LOCK_PERIOD  -- withdraw() also waits out a term, not just the cap.
 *      stakedOf()   -- one number per wallet, for the referral contract.
 *    The accumulator, the cap, the settlement path and every exit route
 *    are byte-for-byte what v1 ran on mainnet.
 * ======================================================================
 *
 *  THE PROMISE, PRECISELY
 *    Stake N OSG. You are distributed 2N OSG in total, and then the
 *    position stops and the principal is returned. HOW MUCH is fixed at
 *    deposit. HOW LONG is not, and is never promised.
 *
 *    No oracle is involved anywhere: the deposit is OSG and the payout is
 *    OSG, so there is no exchange rate to look up and nothing for a flash
 *    loan to move. That is the whole reason this design was chosen over a
 *    dollar-denominated one -- the OSG/WPOL pair is shallow enough to be
 *    pushed around inside a single transaction.
 *
 *  WHY THE RATE FLOATS
 *    maxRateBps is a CEILING, not a rate. Every position earns from one
 *    shared accumulator fed by the Mining bucket:
 *
 *        idealDaily = totalStaked * maxRateBps / 10000
 *        dailyDist  = min(idealDaily, dailyBudget)
 *
 *    While the bucket covers everyone, everyone earns the full ceiling.
 *    Past that point every participant's daily rate falls together, in
 *    proportion -- nobody's TOTAL changes, it simply takes longer.
 *
 *    This is what makes the contract structurally unable to over-promise.
 *    A fixed-rate design with a capacity limit has to be defended by an
 *    owner who remembers to check the arithmetic before every raise; here
 *    the ceiling defends itself, and a halving simply halves the budget
 *    and stretches the timeline with no admin call at all.
 *
 *  DEPOSITS ON BEHALF
 *    depositFor() lets a whitelisted contract open a position for another
 *    address, paying for it itself. It exists so a community distribution
 *    can arrive ALREADY STAKED: the recipient gets a position with a cap
 *    and a lock instead of a balance they can sell the same afternoon,
 *    and their upline earns from it exactly as if they had deposited.
 *
 *    The whitelist is owner-set and contract-only, deliberately. Left
 *    open, anyone could push a locked position onto any wallet, which is
 *    a way to grief an address rather than a favour to it.
 *
 *    It has its own floor, minDepositFor, because a distribution pays in
 *    tiers and the smallest of those is well below what makes sense as a
 *    product minimum. Leaving them joined would force one of the two
 *    numbers to be wrong.
 *
 *  PRINCIPAL IS NEVER TOUCHED
 *    Nothing is deducted on the way in. Stake 1,000 and 1,000 is working
 *    for you. Referral commission is paid by OSGReferral out of the
 *    Referral bucket and out of its own treasury -- never out of a
 *    depositor's stake.
 *
 *  THE EXIT
 *    withdraw() opens once the 2x cap is reached. Before that,
 *    forfeitAndWithdraw() returns 100% of the principal at any time and
 *    drops whatever had accrued but not yet been delivered.
 *
 *    There is a third condition, and it arrives on its own. Once emission
 *    ends -- roughly fifteen years out, or the day an owner calls
 *    stopEmission() -- no further reward can be minted, so a cap that has
 *    not been filled never will be. Every position still open at that
 *    point becomes withdrawable through the normal door, principal
 *    intact. Nobody has to be released by hand and nothing expires: the
 *    principal simply waits here until its owner comes for it.
 *
 *    forfeitAndWithdraw() is deliberately the only EARLY exit, and it
 *    deliberately never touches RewardPool. If RewardPool is paused, if
 *    emission has stopped, if this contract is paused, if settlement
 *    itself reverts -- principal still comes home. A 200-day-style lock
 *    with no such door is how deposits get trapped by a bug, so there is
 *    no separate emergencyWithdraw: this IS it, and the forfeited reward
 *    is what stops it being used as a way around the lock.
 *
 *  LESSONS CARRIED FROM OSGLPMining v6
 *    L1  Settlement runs in an OUTER frame via _trySettle(). v6 shipped a
 *        version where a failing settle took the pending reward with it.
 *    L2  Every exit path accrues first. v6's emergencyWithdraw originally
 *        did not, and burned reward that had been legitimately earned.
 *    L3  Payouts are capped by BOTH MAX_SINGLE_ALLOC and the live
 *        miningAvail, then the remainder is kept in `unpaid`. The Mining
 *        bucket's daily budget is smaller than MAX_SINGLE_ALLOC, so
 *        capping by the constant alone still reverts.
 *    L4  RewardPool allows one distribute() per distributor per block, so
 *        a failed payout must never be fatal -- it stays in `unpaid`.
 *    L5  Referral hooks are try/catch. A referral-side failure must never
 *        block someone's own deposit, claim or exit.
 *
 *  BEFORE DEPLOY
 *    RewardPool.setDistributor(this, 2) and setMiningShareBps() must both
 *    be done, and this contract's share plus OSGLPMining's must stay at
 *    or under 100% of the Mining bucket. Nothing enforces that across
 *    contracts -- RewardPool would simply reject whichever distribute()
 *    call arrives last. payoutHealth() reports the local half of it.
 * ======================================================================
 */

interface IOSGRewardPool {
    function distribute(address user, uint256 amount, uint8 category) external;
    function distributorType(address) external view returns (uint8);
    function distributorActive(address) external view returns (bool);
    function paused() external view returns (bool);
    function emissionStopped() external view returns (bool);
    function emissionEndTime() external view returns (uint256);
    function miningPercent() external view returns (uint256);
    function getTodayStats() external view returns (
        uint256 stakingUsedAmt, uint256 miningUsedAmt, uint256 referralUsedAmt,
        uint256 stakingAvail, uint256 miningAvail, uint256 referralAvail,
        uint256 dailyBase
    );
}

/// Matches OSGLPMining v6's IOSGLPReferral exactly, so one referral
/// contract serves every source without special-casing.
interface IOSGReferral {
    function onLiquidityChange(address depositor, uint256 delta, bool isAdd) external;
    function onRewardClaimed(address user, uint256 rewardAmount) external;
}

contract OSGTermStaking is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ====================== CONSTANTS ======================
    uint8   public constant CAT_MINING     = 2;
    uint256 public constant BPS_DENOM      = 10_000;
    uint256 public constant ACC_PRECISION  = 1e18;

    /// Total distributed per position, as a multiple of its principal.
    /// Immutable on purpose: it is the one number a depositor is told at
    /// the door, and it must not be movable afterwards.
    uint256 public constant CAP_MULTIPLIER = 2;

    uint256 public constant MAX_POSITIONS  = 5;

    /// Mirrors RewardPool.MAX_SINGLE_ALLOC.
    uint256 public constant MAX_SINGLE_ALLOC = 10_000 * 1e18;

    /// Bounds on the ceiling the owner may set. The floor matters more
    /// than the roof: without it, dropping the rate towards zero would
    /// hold everyone's principal hostage indefinitely, since withdraw()
    /// waits for the cap. At 0.1%/day the cap is reached in about 2,000
    /// days -- slow, but finite, and forfeitAndWithdraw() is always open.
    uint256 public constant MIN_RATE_BPS = 10;    // 0.1%/day
    uint256 public constant MAX_RATE_BPS = 200;   // 2.0%/day

    /// How long a position must be held before withdraw() will return the
    /// principal, counted from that position's own deposit.
    ///
    /// This is a term, not a trap. forfeitAndWithdraw() stays open the
    /// whole time and always returns the principal in full -- what the
    /// lock actually costs someone leaving early is the reward accrued
    /// and not yet taken, nothing else. Framed the other way round: the
    /// term is enforced economically, not by holding anyone's money.
    uint256 public constant LOCK_PERIOD = 180 days;

    // ====================== IMMUTABLES ======================
    IERC20         public immutable osg;
    IOSGRewardPool public immutable pool;

    // ====================== CONFIG ======================
    uint256 public maxRateBps     = 23;          // ~7%/month ceiling
    uint256 public miningShareBps = 2_000;       // 20% of the Mining bucket
    uint256 public maxShareBps    = 5_000;       // owner ceiling on the above
    uint256 public constant ABSOLUTE_MAX_SHARE_BPS = 9_000;
    uint256 public minDeposit     = 100 * 1e18;

    /// Ceiling on principal held. Reaching it closes NEW deposits only --
    /// every open position keeps earning and exits normally.
    ///
    /// Why it has to exist. Each deposit signs the contract up for 2x its
    /// own size, payable out of a fixed daily budget. Let principal grow
    /// without limit and the promised rate cannot hold: the same budget
    /// spread over more stake simply takes longer, until a newcomer's
    /// share is too thin to be worth anything and the earliest depositors
    /// are queueing for years. The ceiling is where that queue is allowed
    /// to stop.
    ///
    /// It only moves up. Lowering it would let an owner freeze out new
    /// deposits at will, which is a different power from the one this is
    /// meant to be.
    uint256 public capacity = 850_000 * 1e18;

    /// Separate floor for depositFor(). A community distribution pays in
    /// tiers -- 25 for a stake, 300 for LP -- and the smallest of those
    /// would revert against a 100 OSG product minimum. Tying the two
    /// together would mean either raising every airdrop tier or lowering
    /// the bar for every ordinary depositor; neither decision should be
    /// forced by the other.
    ///
    /// Dust is not a concern here: MAX_POSITIONS caps how many any wallet
    /// can hold, accounting is share-based so a small position dilutes
    /// nobody, and the claimer pays their own gas.
    uint256 public minDepositFor  = 10 * 1e18;

    /// 0 = open indefinitely. Set it ahead of a halving so no position is
    /// opened that would spend most of its life on the far side of one.
    uint256 public depositDeadline;

    IOSGReferral public referralContract;

    /// Contracts allowed to open a position for someone else. Intended
    /// for the airdrop contract, so a distribution can arrive already
    /// staked rather than landing in a wallet ready to be sold.
    mapping(address => bool) public authorizedDepositors;

    // ====================== ACCOUNTING ======================
    struct Position {
        uint256 amount;      // principal
        uint256 cap;         // amount * CAP_MULTIPLIER, fixed at deposit
        uint256 rewardDebt;
        uint256 rewardPaid;  // actually delivered
        uint256 unpaid;      // accrued, not yet delivered
        uint256 startTime;
        bool    capped;      // cap reached, no longer earning
        bool    closed;      // principal returned
    }
    mapping(address => Position[]) public positions;

    /// Principal currently EARNING. A capped position leaves this the
    /// moment it fills, otherwise it would keep diluting everyone else
    /// while being owed nothing.
    uint256 public totalStaked;

    /// Principal currently HELD, capped or not. Solvency is measured
    /// against this, never against totalStaked.
    uint256 public totalPrincipal;

    uint256 public accRewardPerShare;
    uint256 public lastRewardTime;

    // ====================== EVENTS ======================
    event Deposited(address indexed user, uint256 indexed posId, uint256 amount, uint256 cap);
    /// Fired only when payer != beneficiary, so an explorer shows the
    /// airdrop contract's deposits distinctly from ordinary ones.
    event DepositedFor(
        address indexed payer,
        address indexed beneficiary,
        uint256 indexed posId,
        uint256 amount
    );
    event Claimed(address indexed user, uint256 indexed posId, uint256 amount);
    event Withdrawn(address indexed user, uint256 indexed posId, uint256 principal);
    event ForfeitWithdrawn(address indexed user, uint256 indexed posId, uint256 principal, uint256 forfeited);
    event CapReached(address indexed user, uint256 indexed posId);
    event PayoutCapped(address indexed user, uint256 indexed posId, uint256 paidNow, uint256 remaining);
    event SettlementDeferred(bytes reason);
    event ReferralHookFailed(address indexed user, string what, bytes reason);
    event RateUpdated(uint256 newRateBps);
    event MiningShareUpdated(uint256 newShareBps);
    event CapacityUpdated(uint256 oldCapacity, uint256 newCapacity);
    event MinDepositUpdated(uint256 newMin);
    event MinDepositForUpdated(uint256 newMin);
    event DepositDeadlineUpdated(uint256 newDeadline);
    event ReferralContractUpdated(address indexed newContract);
    event AuthorizedDepositorUpdated(address indexed depositor, bool allowed);

    constructor(address _osg, address _pool, address _owner) Ownable(_owner) {
        require(_osg.code.length  > 0, "osg not contract");
        require(_pool.code.length > 0, "pool not contract");
        osg  = IERC20(_osg);
        pool = IOSGRewardPool(_pool);
        lastRewardTime = block.timestamp;
    }

    // ====================== BUDGET ======================

    function getTermStakingDailyBudget() public view returns (uint256) {
        ( , , , , , , uint256 dailyBase) = pool.getTodayStats();
        uint256 miningBase = (dailyBase * pool.miningPercent()) / 100;
        return (miningBase * miningShareBps) / BPS_DENOM;
    }

    /// The rate actually running right now. Front-ends must show THIS,
    /// not maxRateBps -- the ceiling is not a promise.
    function effectiveRateBps() public view returns (uint256) {
        if (totalStaked == 0) return maxRateBps;
        uint256 ideal = (totalStaked * maxRateBps) / BPS_DENOM;
        if (ideal == 0) return maxRateBps;
        uint256 budget = getTermStakingDailyBudget();
        if (budget >= ideal) return maxRateBps;
        return (maxRateBps * budget) / ideal;
    }

    // ====================== SETTLEMENT ======================

    function _settle() internal {
        if (block.timestamp <= lastRewardTime) return;
        if (totalStaked == 0) {
            lastRewardTime = block.timestamp;
            return;
        }

        // Stop the clock at the end of emission.
        //
        // Without this, a settlement run after emission ends would credit
        // the whole gap since the last one, including time in which there
        // was nothing to credit from. Nobody could actually be paid it --
        // RewardPool refuses to distribute once emission is over -- so it
        // would surface as pending reward that can never be claimed, and
        // as caps recorded as filled by rewards that were never delivered.
        // Cheaper to not create the number than to explain it afterwards.
        uint256 endsAtTs = pool.emissionEndTime();
        uint256 until = block.timestamp;
        if (endsAtTs != 0 && until > endsAtTs) until = endsAtTs;
        if (until <= lastRewardTime) {
            lastRewardTime = block.timestamp;
            return;
        }

        uint256 elapsed = until - lastRewardTime;
        uint256 ideal   = (totalStaked * maxRateBps) / BPS_DENOM;
        uint256 budget  = getTermStakingDailyBudget();
        uint256 daily   = ideal < budget ? ideal : budget;

        if (daily > 0) {
            uint256 reward = (daily * elapsed) / 1 days;
            if (reward > 0) {
                accRewardPerShare += (reward * ACC_PRECISION) / totalStaked;
            }
        }
        lastRewardTime = block.timestamp;
    }

    /// L1: settlement lives in an OUTER frame. getTermStakingDailyBudget()
    /// reaches into RewardPool, so a paused or reverting pool would
    /// otherwise take the caller's whole transaction -- including their
    /// exit -- down with it.
    function _settleExternal() external {
        require(msg.sender == address(this), "internal only");
        _settle();
    }

    function _trySettle() internal {
        try this._settleExternal() {
            // ok
        } catch (bytes memory reason) {
            emit SettlementDeferred(reason);
        }
    }

    /// Anyone may bring the accumulator up to date.
    function settle() external {
        _settle();
    }

    // ====================== ACCRUAL ======================

    function _accrue(address user, uint256 posId) internal {
        Position storage p = positions[user][posId];
        if (p.closed || p.capped) return;

        uint256 acc     = (p.amount * accRewardPerShare) / ACC_PRECISION;
        uint256 pending = acc > p.rewardDebt ? acc - p.rewardDebt : 0;
        p.rewardDebt    = acc;

        if (pending > 0) {
            uint256 earned = p.rewardPaid + p.unpaid;
            uint256 room   = p.cap > earned ? p.cap - earned : 0;
            if (pending > room) pending = room;
            if (pending > 0) p.unpaid += pending;
        }

        if (p.rewardPaid + p.unpaid >= p.cap) {
            p.capped = true;
            totalStaked -= p.amount;      // settled above, so this is safe
            emit CapReached(user, posId);
        }
    }

    /// Permissionless cleanup. A filled position that nobody has touched
    /// still sits in totalStaked and quietly dilutes everyone else, so
    /// anyone may pay the gas to remove it.
    function poke(address user, uint256 posId) external {
        require(posId < positions[user].length, "bad posId");
        _trySettle();
        _accrue(user, posId);
    }

    function pokeMany(address[] calldata users_, uint256[] calldata posIds) external {
        require(users_.length == posIds.length, "length mismatch");
        _trySettle();
        for (uint256 i = 0; i < users_.length; i++) {
            if (posIds[i] < positions[users_[i]].length) {
                _accrue(users_[i], posIds[i]);
            }
        }
    }

    // ====================== DEPOSIT ======================

    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        _deposit(msg.sender, msg.sender, amount, minDeposit);
    }

    /// Open a position on someone else's behalf, paying for it yourself.
    ///
    /// Gated to an owner-set whitelist, not open to everyone. An open
    /// version would let anyone push a position onto any address, and
    /// since a position carries a lock, that is a way to grief a wallet
    /// rather than a favour to it. The whitelist holds the airdrop
    /// contract and nothing else.
    ///
    /// Tokens come from the CALLER; the position, its cap and its
    /// referral credit all belong to `user`. That is what lets a
    /// distribution arrive already staked instead of landing in a wallet
    /// ready to be sold the same afternoon.
    function depositFor(address user, uint256 amount)
        external nonReentrant whenNotPaused
    {
        require(authorizedDepositors[msg.sender], "not an authorized depositor");
        require(user != address(0), "zero beneficiary");
        _deposit(user, msg.sender, amount, minDepositFor);
    }

    function _deposit(
        address beneficiary,
        address payer,
        uint256 amount,
        uint256 floor
    ) internal {
        require(amount >= floor, "below minimum");
        require(
            depositDeadline == 0 || block.timestamp < depositDeadline,
            "deposits closed"
        );
        require(_openPositions(beneficiary) < MAX_POSITIONS, "position limit reached");
        require(totalPrincipal + amount <= capacity, "capacity full");

        // Settle BEFORE totalStaked moves, or the new principal would be
        // credited with time it was never staked for.
        _settle();

        uint256 before = osg.balanceOf(address(this));
        osg.safeTransferFrom(payer, address(this), amount);
        uint256 received = osg.balanceOf(address(this)) - before;
        require(received >= floor, "below minimum after transfer");

        uint256 cap = received * CAP_MULTIPLIER;

        positions[beneficiary].push(Position({
            amount:     received,
            cap:        cap,
            rewardDebt: (received * accRewardPerShare) / ACC_PRECISION,
            rewardPaid: 0,
            unpaid:     0,
            startTime:  block.timestamp,
            capped:     false,
            closed:     false
        }));

        totalStaked    += received;
        totalPrincipal += received;

        uint256 posId = positions[beneficiary].length - 1;
        emit Deposited(beneficiary, posId, received, cap);
        if (payer != beneficiary) {
            emit DepositedFor(payer, beneficiary, posId, received);
        }

        _notifyLiquidityChange(beneficiary, received, true);
    }

    // ====================== CLAIM ======================

    function claim(uint256 posId) external nonReentrant whenNotPaused {
        require(posId < positions[msg.sender].length, "bad posId");
        _settle();
        _accrue(msg.sender, posId);
        _payout(msg.sender, posId);
    }

    /// Everything owed across every position, in ONE distribute() call.
    ///
    /// Looping claim() would not work: RewardPool allows a distributor a
    /// single distribute() per block, so only the first position would
    /// settle and the rest would revert. Aggregating first sidesteps that
    /// entirely -- one call, one block, one payout.
    function claimAll() external nonReentrant whenNotPaused {
        uint256 n = positions[msg.sender].length;
        require(n > 0, "no positions");

        _settle();

        uint256 owedTotal;
        for (uint256 i = 0; i < n; i++) {
            _accrue(msg.sender, i);
            owedTotal += positions[msg.sender][i].unpaid;
        }
        require(owedTotal > 0, "nothing to claim");

        uint256 payout = owedTotal > MAX_SINGLE_ALLOC ? MAX_SINGLE_ALLOC : owedTotal;
        ( , , , , uint256 miningAvail, , ) = pool.getTodayStats();
        if (payout > miningAvail) payout = miningAvail;
        require(payout > 0, "no mining budget available today");

        // Drain oldest position first. Sequential rather than pro-rata so
        // the arithmetic is exact -- no rounding dust left stranded in a
        // position that reads as fully paid.
        uint256 left = payout;
        for (uint256 i = 0; i < n && left > 0; i++) {
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

    /// Same as withdrawAll(), over a slice of the array.
    ///
    /// MAX_POSITIONS caps how many positions a wallet can hold OPEN, not
    /// how many it has ever held -- closed ones stay in the array as
    /// history. Someone who has been through a hundred terms would make
    /// withdrawAll() walk a hundred slots to find the few that matter,
    /// and eventually that walk costs more than it is worth. This lets
    /// them work through it in pieces instead. Ordinary users will never
    /// need it; nobody is ever forced to use it.
    function withdrawRange(uint256 start, uint256 end) external nonReentrant {
        uint256 n = positions[msg.sender].length;
        require(start < end && end <= n, "bad range");

        _trySettle();

        uint256 done;
        for (uint256 i = start; i < end; i++) {
            if (_withdrawOne(msg.sender, i)) done++;
        }
        require(done > 0, "nothing withdrawable");
    }

    /// Same as claimAll(), over a slice of the array. See withdrawRange()
    /// for why a slice is offered at all.
    function claimRange(uint256 start, uint256 end)
        external
        nonReentrant
        whenNotPaused
    {
        uint256 n = positions[msg.sender].length;
        require(start < end && end <= n, "bad range");

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

    /// L3 + L4: cap by both limits, keep the remainder, never revert on a
    /// pool-side refusal.
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

    // ====================== EXITS ======================

    /// The normal door. Opens once the position has been distributed its
    /// full 2x. Any undelivered remainder is attempted here but never
    /// blocks the principal.
    function withdraw(uint256 posId) external nonReentrant {
        require(posId < positions[msg.sender].length, "bad posId");
        _trySettle();
        _accrue(msg.sender, posId);
        require(_withdrawOne(msg.sender, posId), "locked until cap is reached");
    }

    /// Every open position that is currently withdrawable, in one call.
    /// Bounded by MAX_POSITIONS, so the loop can never run away.
    function withdrawAll() external nonReentrant {
        uint256 n = positions[msg.sender].length;
        require(n > 0, "no positions");
        _trySettle();

        uint256 done;
        for (uint256 i = 0; i < n; i++) {
            _accrue(msg.sender, i);
            if (_withdrawOne(msg.sender, i)) done++;
        }
        require(done > 0, "nothing withdrawable");
    }

    /// Returns false instead of reverting when a position is not yet
    /// eligible, so one locked position cannot block the rest of a
    /// withdrawAll().
    function _withdrawOne(address user, uint256 posId) internal returns (bool) {
        Position storage p = positions[user][posId];
        if (p.closed) return false;

        // Two doors, and the second one opens by itself. Once emission is
        // over, the cap can never be reached -- the budget that would
        // fill it no longer exists -- so holding principal against that
        // condition, or against the term, would trap it forever. Every
        // position still open at that point simply becomes withdrawable,
        // and each owner comes for theirs whenever they like; the
        // principal sits here untouched until they do.
        if (!isEmissionOver()) {
            bool capReached = p.rewardPaid + p.unpaid >= p.cap;
            if (!capReached) return false;
            if (block.timestamp < p.startTime + LOCK_PERIOD) return false;
        }

        if (p.unpaid > 0) {
            try this._payoutExternal(user, posId) {
                // ok
            } catch {
                // stays in unpaid; claim() can collect it later
            }
        }

        uint256 principal = p.amount;
        p.closed = true;
        if (!p.capped) {
            p.capped = true;
            totalStaked -= principal;
        }
        totalPrincipal -= principal;

        osg.safeTransfer(user, principal);
        emit Withdrawn(user, posId, principal);

        _notifyLiquidityChange(user, principal, false);
        return true;
    }

    function _payoutExternal(address user, uint256 posId) external {
        require(msg.sender == address(this), "internal only");
        _payout(user, posId);
    }

    /// The always-open door. 100% of the principal, at any time, with the
    /// undelivered reward dropped.
    ///
    /// Deliberately NOT whenNotPaused, and deliberately free of any call
    /// into RewardPool: _trySettle() swallows a failing pool, and nothing
    /// below it can revert. This is the guarantee that a locked position
    /// can never become a trapped one.
    function forfeitAndWithdraw(uint256 posId) external nonReentrant {
        require(posId < positions[msg.sender].length, "bad posId");
        Position storage p = positions[msg.sender][posId];
        require(!p.closed, "already closed");

        _trySettle();
        _accrue(msg.sender, posId);   // L2: accrue on every exit path

        uint256 principal = p.amount;
        uint256 forfeited = p.unpaid;

        p.unpaid = 0;
        p.closed = true;
        if (!p.capped) {
            p.capped = true;
            totalStaked -= principal;
        }
        totalPrincipal -= principal;

        osg.safeTransfer(msg.sender, principal);
        emit ForfeitWithdrawn(msg.sender, posId, principal, forfeited);

        _notifyLiquidityChange(msg.sender, principal, false);
    }

    // ====================== REFERRAL HOOKS ======================
    // L5: never let the referral side block a user's own transaction.

    function _notifyLiquidityChange(address user, uint256 delta, bool isAdd) internal {
        if (address(referralContract) == address(0)) return;
        try referralContract.onLiquidityChange(user, delta, isAdd) {
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
        Position[] storage ps = positions[user];
        for (uint256 i = 0; i < ps.length; i++) {
            if (!ps[i].closed) n++;
        }
    }

    function openPositions(address user) external view returns (uint256) {
        return _openPositions(user);
    }

    function positionCount(address user) external view returns (uint256) {
        return positions[user].length;
    }

    function getPositions(address user) external view returns (Position[] memory) {
        return positions[user];
    }

    /// Includes time since the last settlement, so a front-end shows a
    /// live figure without anyone having to poke first.
    function pendingReward(address user, uint256 posId) external view returns (uint256) {
        if (posId >= positions[user].length) return 0;
        Position storage p = positions[user][posId];
        if (p.closed || p.capped) return p.unpaid;

        uint256 acc = accRewardPerShare;
        // Same clock-stop as _settle(), so the view and the settlement
        // never disagree about what is owed.
        uint256 endsAtTs = pool.emissionEndTime();
        uint256 until = block.timestamp;
        if (endsAtTs != 0 && until > endsAtTs) until = endsAtTs;

        if (until > lastRewardTime && totalStaked > 0) {
            uint256 elapsed = until - lastRewardTime;
            uint256 ideal   = (totalStaked * maxRateBps) / BPS_DENOM;
            uint256 budget  = getTermStakingDailyBudget();
            uint256 daily   = ideal < budget ? ideal : budget;
            uint256 reward  = (daily * elapsed) / 1 days;
            if (reward > 0) acc += (reward * ACC_PRECISION) / totalStaked;
        }

        uint256 total   = (p.amount * acc) / ACC_PRECISION;
        uint256 pending = total > p.rewardDebt ? total - p.rewardDebt : 0;
        uint256 earned  = p.rewardPaid + p.unpaid;
        uint256 room    = p.cap > earned ? p.cap - earned : 0;
        if (pending > room) pending = room;
        return p.unpaid + pending;
    }

    function remainingCap(address user, uint256 posId) external view returns (uint256) {
        if (posId >= positions[user].length) return 0;
        Position storage p = positions[user][posId];
        uint256 earned = p.rewardPaid + p.unpaid;
        return p.cap > earned ? p.cap - earned : 0;
    }

    /// An ESTIMATE at today's rate, and nothing more. The rate moves with
    /// participation and with halvings, so this figure will move too.
    function estimatedDaysToCap(address user, uint256 posId) external view returns (uint256) {
        if (posId >= positions[user].length) return 0;
        Position storage p = positions[user][posId];
        if (p.capped || p.closed) return 0;

        uint256 earned = p.rewardPaid + p.unpaid;
        uint256 left   = p.cap > earned ? p.cap - earned : 0;
        if (left == 0) return 0;

        uint256 perDay = (p.amount * effectiveRateBps()) / BPS_DENOM;
        if (perDay == 0) return type(uint256).max;
        return (left + perDay - 1) / perDay;
    }

    /// After this point no further reward can ever be minted, so the cap
    /// condition on withdraw() stops being a schedule and starts being a
    /// trap. It is read live from RewardPool rather than stored here, so
    /// it cannot drift out of step with the pool it depends on.
    function isEmissionOver() public view returns (bool) {
        return pool.emissionStopped()
            || block.timestamp >= pool.emissionEndTime();
    }

    function isWiredForMining() public view returns (bool) {
        return pool.distributorType(address(this)) == CAT_MINING
            && pool.distributorActive(address(this));
    }

    function payoutHealth() external view returns (bool canPayNow, string memory reason) {
        if (!isWiredForMining())    return (false, "not registered as category-2 distributor");
        if (paused())               return (false, "term staking paused");
        if (pool.paused())          return (false, "RewardPool paused");
        if (pool.emissionStopped()) return (false, "emission stopped");
        ( , , , , uint256 miningAvail, , ) = pool.getTodayStats();
        if (miningAvail == 0)       return (false, "daily mining budget exhausted");
        return (true, "ready");
    }

    /// OSG held here beyond what depositors are owed. Anything above zero
    /// arrived by accident.
    function excessBalance() public view returns (uint256) {
        uint256 bal = osg.balanceOf(address(this));
        return bal > totalPrincipal ? bal - totalPrincipal : 0;
    }

    // ====================== ADMIN ======================

    /// Changing the ceiling changes only the SPEED. Every position's cap
    /// was fixed at deposit, so raising it empties positions sooner and
    /// lowering it stretches them -- the total owed is identical either
    /// way. Settling first is mandatory: without it, elapsed time would
    /// be re-priced at the new rate retroactively.
    function setMaxRate(uint256 newBps) external onlyOwner {
        _settle();
        require(newBps >= MIN_RATE_BPS && newBps <= MAX_RATE_BPS, "rate out of bounds");
        maxRateBps = newBps;
        emit RateUpdated(newBps);
    }

    function setMiningShareBps(uint256 newBps) external onlyOwner {
        _settle();
        require(newBps <= maxShareBps, "exceeds max share");
        miningShareBps = newBps;
        emit MiningShareUpdated(newBps);
    }

    function setMaxShareBps(uint256 newMax) external onlyOwner {
        require(newMax <= ABSOLUTE_MAX_SHARE_BPS, "exceeds absolute max");
        require(miningShareBps <= newMax, "below current share");
        maxShareBps = newMax;
    }

    /// Raise the ceiling on principal. Up only -- see `capacity`.
    function setCapacity(uint256 newCapacity) external onlyOwner {
        require(newCapacity > capacity, "capacity can only rise");
        emit CapacityUpdated(capacity, newCapacity);
        capacity = newCapacity;
    }

    function setMinDeposit(uint256 newMin) external onlyOwner {
        require(newMin > 0, "zero minimum");
        minDeposit = newMin;
        emit MinDepositUpdated(newMin);
    }

    function setMinDepositFor(uint256 newMin) external onlyOwner {
        require(newMin > 0, "zero minimum");
        minDepositFor = newMin;
        emit MinDepositForUpdated(newMin);
    }

    function setDepositDeadline(uint256 newDeadline) external onlyOwner {
        depositDeadline = newDeadline;
        emit DepositDeadlineUpdated(newDeadline);
    }

    function setReferralContract(address _referral) external onlyOwner {
        require(
            _referral == address(0) || _referral.code.length > 0,
            "referral not contract"
        );
        referralContract = IOSGReferral(_referral);
        emit ReferralContractUpdated(_referral);
    }

    /// Whitelist for depositFor(). Keep this to contracts only -- an EOA
    /// here could open locked positions on arbitrary addresses.
    function setAuthorizedDepositor(address who, bool allowed) external onlyOwner {
        require(who != address(0), "zero address");
        require(!allowed || who.code.length > 0, "depositor not contract");
        authorizedDepositors[who] = allowed;
        emit AuthorizedDepositorUpdated(who, allowed);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// Deposited principal is not reachable from here, by construction:
    /// OSG may only be swept down to excessBalance(), and any other token
    /// arrived by mistake.
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0) && amount > 0, "bad args");
        if (token == address(osg)) {
            require(amount <= excessBalance(), "would touch depositor principal");
        }
        IERC20(token).safeTransfer(to, amount);
    }

    /// Total principal this wallet is holding here, capped positions
    /// included. The referral contract reads this to work out a
    /// referrer's direct volume, so it has to count principal that is
    /// still deposited but no longer earning -- someone whose position
    /// filled its cap yesterday has not stopped being staked.
    function stakedOf(address user) external view returns (uint256 total) {
        Position[] storage list = positions[user];
        uint256 n = list.length;
        for (uint256 i = 0; i < n; i++) {
            if (!list[i].closed) total += list[i].amount;
        }
    }

    /// How many positions this wallet has ever held, open and closed.
    /// A front-end pages through withdrawRange/claimRange with this.
    function positionsLength(address user) external view returns (uint256) {
        return positions[user].length;
    }

    /// Principal the contract will still accept before deposits close.
    function capacityLeft() external view returns (uint256) {
        return capacity > totalPrincipal ? capacity - totalPrincipal : 0;
    }

    /// Seconds until this position's term is up; zero once it has passed.
    function lockRemaining(address user, uint256 posId)
        external
        view
        returns (uint256)
    {
        require(posId < positions[user].length, "bad posId");
        uint256 unlockAt = positions[user][posId].startTime + LOCK_PERIOD;
        return block.timestamp >= unlockAt ? 0 : unlockAt - block.timestamp;
    }

    function version() external pure returns (string memory) {
        return "OSGTermStaking v2";
    }
}
