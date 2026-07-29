// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/*
 * ======================================================================
 *  OSGLPMining v6
 *  Live on Polygon Mainnet since 29 July 2026 at
 *  0xb0510d6f707dF47fE7427732D5507290D847b736 (verified on Polygonscan).
 *  Successor to v5 (0xF534adff723b5c89AD86343B9E4b1E64E6c82aba, paused).
 * ======================================================================
 *
 *  WHY v6 -- four fixes, all found by re-reading the deployed v5 source:
 *
 *  FIX 1 -- DEPOSITED LP COULD BECOME UNWITHDRAWABLE.
 *    In v5, withdraw() called _settlePending() which called
 *    pool.distribute() fail-loud. So ANY condition that blocked the
 *    reward payout also blocked the LP withdrawal: RewardPool paused,
 *    emissionStopped, this contract de-registered as distributor,
 *    daily Mining cap hit, per-block cooldown collision, RewardStorage
 *    paused -- and, permanently, RewardPool.emissionEndTime passing
 *    (distribute() has an emissionActive modifier and emissionEndTime
 *    is immutable, so after ~June 2041 every distribute() reverts
 *    forever, locking all deposited LP with no recovery path).
 *    v6 fixes this two ways:
 *      (a) withdraw() now banks the accrued reward FIRST via _accrue()
 *          and only then attempts the payout inside try/catch, so a
 *          failed payout blocks neither the LP transfer nor the reward.
 *      (b) emergencyWithdraw() returns LP with NO distribute() call at
 *          all, and is deliberately NOT whenNotPaused, so depositors
 *          can always exit even if the owner is unavailable or the
 *          wider reward system is permanently down. It still refreshes
 *          the tier rate first, but through try/catch, so the user is
 *          credited in full when RewardPool is healthy without the exit
 *          ever depending on it.
 *
 *  FIX 2 -- 10,000 OSG PERMANENT LOCK.
 *    v5's _settlePending had require(pending <= MAX_SINGLE_ALLOC).
 *    Once a user's pending crossed 10,000 OSG, deposit(), withdraw()
 *    AND claim() all reverted forever -- accRewardPerShare can never be
 *    reduced, and no admin function could clear it. The revert string
 *    said "contact support" but no support function existed.
 *    v6 pays out in capped chunks instead of reverting, mirroring
 *    RewardPool v2's own chunked-claim approach.
 *
 *  FIX 3 -- UNPAID REWARD IS NOW TRACKED EXPLICITLY.
 *    New UserTierInfo.unpaid field, filled by _accrue(). rewardDebt
 *    always advances to the full accumulated figure (so lpAmount
 *    changes stay safe with the standard staking formula), while
 *    anything accrued but not yet sent sits in unpaid and is paid on
 *    the next settlement.
 *
 *    IMPORTANT ORDERING RULE: _accrue() must run in the OUTER call
 *    frame, before _trySettle(). _trySettle() deliberately swallows a
 *    reverting payout, and that revert rolls back everything the inner
 *    call touched. If the accrual happened only inside that inner call,
 *    a failed payout would roll it back while the caller went on to
 *    recompute rewardDebt against the NEW lpAmount -- silently erasing
 *    the pending reward. Accruing outside first makes the rollback
 *    affect only the payout attempt itself.
 *
 *  FIX 4 -- lpToken IS NOW PER-TIER, NOT CONTRACT-WIDE.
 *    v5 had IERC20 public immutable lpToken, so every tier had to use
 *    the same LP token and a second pair (e.g. OSG/USDT) would have
 *    required a whole new contract + new distributor slot. In v6 each
 *    tier carries its own lpToken, so a future pair is just a new tier.
 *    An existing tier's lpToken can only be changed while that tier
 *    holds zero deposits.
 *
 * ----------------------------------------------------------------------
 *  UNCHANGED FROM v5 (deliberately -- these were correct):
 *   - LP-amount-based accounting (not discrete slots)
 *   - tierWeightBps budget split across tiers, sum <= 100%
 *   - _settleAllActiveTiers() hygiene before any rate change
 *   - Referral hooks wrapped in try/catch, never block Mining
 *   - 24h first-withdraw lock (applies to emergencyWithdraw too)
 *   - No unbounded loops anywhere
 *
 *  ARCHITECTURE REMINDER:
 *   RewardPool.setDistributor(addr, cat) binds ONE address to ONE
 *   category. This contract is category 2 (Mining) only. All referral
 *   and rank-bonus logic lives in the companion OSGLPReferral, which is
 *   registered separately as category 3.
 * ======================================================================
 */

interface IOSGRewardPool {
    function distribute(address user, uint256 amount, uint8 category) external;
    function distributorType(address) external view returns (uint8);
    function distributorActive(address) external view returns (bool);
    function paused() external view returns (bool);
    function emissionStopped() external view returns (bool);
    /// RewardPool.miningPercent is a public state var (0-100, NOT bps) --
    /// read live instead of hardcoding the 40% split.
    function miningPercent() external view returns (uint256);
    function getTodayStats() external view returns (
        uint256 stakingUsedAmt, uint256 miningUsedAmt, uint256 referralUsedAmt,
        uint256 stakingAvail, uint256 miningAvail, uint256 referralAvail,
        uint256 dailyBase
    );
}

/// Minimal hook interface the companion Referral contract must implement.
interface IOSGLPReferral {
    function onLiquidityChange(address depositor, uint256 lpDelta, bool isAdd) external;
    function onRewardClaimed(address user, uint256 rewardAmount) external;
}

contract OSGLPMining is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ====================== CONSTANTS ======================
    uint8   public constant CAT_MINING  = 2;
    uint256 public constant BPS_DENOM   = 10_000;
    uint256 public constant ABSOLUTE_MAX_SHARE_BPS = 9_000; // 90% hard ceiling
    /// Applies to the wallet's first-ever deposit, and gates BOTH
    /// withdraw() and emergencyWithdraw() -- confirmed design choice.
    uint256 public constant FIRST_WITHDRAW_LOCK = 24 hours;
    /// Mirrors RewardPool.MAX_SINGLE_ALLOC (10,000 OSG). v6 CAPS the
    /// payout at this value instead of reverting above it.
    uint256 public constant MAX_SINGLE_ALLOC = 10_000 * 1e18;
    uint256 public constant TIER_COUNT = 5;

    // ====================== IMMUTABLES ======================
    IOSGRewardPool public immutable pool;

    // ====================== REFERRAL HOOK TARGET ======================
    IOSGLPReferral public referralContract;

    // ====================== MINING SHARE (owner-adjustable) ======================
    uint256 public miningShareBps = 50;    // 0.5% of the Mining bucket
    uint256 public maxShareBps    = 5_000; // 50% ceiling, up to ABSOLUTE_MAX

    // ====================== TIERS ======================
    enum TierId { T1, T2, T3, T4, T5 }

    struct TierConfig {
        address lpToken;           // FIX 4: per-tier LP token
        uint256 minDeposit;        // minimum LP per deposit call
        uint256 capacityLp;        // total LP capacity for this tier
        uint256 totalDepositedLp;  // currently deposited LP, this tier
        bool    active;
        uint256 tierWeightBps;     // share of getLpMiningDailyBudget()
        uint256 accRewardPerShare; // cumulative reward per LP unit, 1e18
        uint256 lastRewardTime;
    }
    mapping(TierId => TierConfig) public tiers;
    uint256 public totalTierWeightBps;

    struct UserTierInfo {
        uint256 lpAmount;
        uint256 rewardDebt;
        uint256 unpaid;    // FIX 3: accrued but not yet distributed
    }
    mapping(address => mapping(TierId => UserTierInfo)) public userTier;

    /// Set once on a wallet's very first deposit (any tier), never updated.
    mapping(address => uint256) public firstDepositTime;

    // ====================== EVENTS ======================
    event Deposited(address indexed user, TierId tier, uint256 lpAmount);
    event Withdrawn(address indexed user, TierId tier, uint256 lpAmount);
    event EmergencyWithdrawn(address indexed user, TierId tier, uint256 lpAmount, uint256 unpaidKept);
    event MiningClaimed(address indexed user, TierId tier, uint256 amount);
    event SettlementDeferred(address indexed user, TierId tier, uint256 unpaidTotal, string reason);
    event PayoutCapped(address indexed user, TierId tier, uint256 paid, uint256 remaining);
    event ReferralHookFailed(address indexed user, string what, bytes reason);
    event TierConfigUpdated(TierId tier, uint256 minDeposit, uint256 capacityLp, bool active);
    event TierLpTokenUpdated(TierId indexed tier, address indexed lpToken);
    event MiningShareUpdated(uint256 newBps, address indexed by);
    event TierWeightUpdated(TierId indexed tier, uint256 newWeightBps, uint256 totalWeightBps);
    event ReferralContractUpdated(address indexed newContract);

    constructor(address _lpToken, address _pool, address _owner) Ownable(_owner) {
        require(_lpToken.code.length > 0, "lpToken not contract");
        require(_pool.code.length    > 0, "pool not contract");
        pool = IOSGRewardPool(_pool);

        // T1 active at launch. Values below match the live v5
        // configuration on mainnet (min 100 LP, capacity 2500 LP,
        // verified via tiers(0) on 29 July 2026) so the migration is
        // like-for-like.
        tiers[TierId.T1] = TierConfig({
            lpToken: _lpToken,
            minDeposit: 100 ether,
            capacityLp: 2500 ether,
            totalDepositedLp: 0,
            active: true,
            tierWeightBps: BPS_DENOM, // 100% -- only active tier at launch
            accRewardPerShare: 0,
            lastRewardTime: block.timestamp
        });
        totalTierWeightBps = BPS_DENOM;
    }

    // ====================== DEPOSIT / WITHDRAW / CLAIM ======================

    function deposit(TierId tierId, uint256 lpAmount) external nonReentrant whenNotPaused {
        TierConfig storage t = tiers[tierId];
        require(t.active, "tier not active");
        require(t.lpToken != address(0), "tier lpToken not set");
        require(lpAmount >= t.minDeposit, "below minimum deposit");
        require(t.totalDepositedLp + lpAmount <= t.capacityLp, "exceeds tier capacity");

        _updateTierRewards(tierId);
        _accrue(msg.sender, tierId);      // bank first -- see FIX 3 ordering rule
        _trySettle(msg.sender, tierId);

        IERC20(t.lpToken).safeTransferFrom(msg.sender, address(this), lpAmount);

        UserTierInfo storage u = userTier[msg.sender][tierId];
        u.lpAmount += lpAmount;
        u.rewardDebt = (u.lpAmount * t.accRewardPerShare) / 1e18;
        t.totalDepositedLp += lpAmount;

        if (firstDepositTime[msg.sender] == 0) {
            firstDepositTime[msg.sender] = block.timestamp;
        }

        _notifyLiquidityChange(msg.sender, lpAmount, true);

        emit Deposited(msg.sender, tierId, lpAmount);
    }

    /// FIX 1(a): the accrual is banked into unpaid BEFORE the payout is
    /// attempted, and the payout itself is wrapped in try/catch. So a
    /// failed payout blocks neither the LP transfer nor the reward --
    /// the reward simply waits in unpaid until the next claim().
    function withdraw(TierId tierId, uint256 lpAmount) external nonReentrant whenNotPaused {
        require(lpAmount > 0, "zero amount");
        require(
            block.timestamp >= firstDepositTime[msg.sender] + FIRST_WITHDRAW_LOCK,
            "24h lock active on first deposit"
        );

        TierConfig storage t = tiers[tierId];
        UserTierInfo storage u = userTier[msg.sender][tierId];
        require(u.lpAmount >= lpAmount, "insufficient balance");

        _updateTierRewards(tierId);
        _accrue(msg.sender, tierId);      // bank first -- see FIX 3 ordering rule
        _trySettle(msg.sender, tierId);

        u.lpAmount -= lpAmount;
        u.rewardDebt = (u.lpAmount * t.accRewardPerShare) / 1e18;
        t.totalDepositedLp -= lpAmount;

        IERC20(t.lpToken).safeTransfer(msg.sender, lpAmount);

        _notifyLiquidityChange(msg.sender, lpAmount, false);

        emit Withdrawn(msg.sender, tierId, lpAmount);
    }

    /// FIX 1(b): unconditional exit. Makes NO call to RewardPool, is NOT
    /// whenNotPaused, and cannot be blocked by anything outside this
    /// contract. Any accrued-but-unpaid reward is KEPT (not burned) and
    /// stays claimable via claim() if/when the reward system recovers.
    /// The 24h first-deposit lock still applies, by design.
    function emergencyWithdraw(TierId tierId) external nonReentrant {
        require(
            block.timestamp >= firstDepositTime[msg.sender] + FIRST_WITHDRAW_LOCK,
            "24h lock active on first deposit"
        );

        TierConfig storage t = tiers[tierId];
        UserTierInfo storage u = userTier[msg.sender][tierId];

        uint256 amount = u.lpAmount;
        require(amount > 0, "nothing deposited");

        // Bring accRewardPerShare up to date so the user is credited for
        // time elapsed since the tier was last touched -- but do it via
        // try/catch, because _updateTierRewards() reads the budget from
        // RewardPool. If RewardPool is unreachable the update is skipped
        // and the exit still succeeds, which is the whole point of this
        // function. Then bank the accrual, BEFORE lpAmount is zeroed.
        _tryUpdateTierRewards(tierId);
        _accrue(msg.sender, tierId);

        u.lpAmount   = 0;
        u.rewardDebt = 0;
        t.totalDepositedLp -= amount;

        IERC20(t.lpToken).safeTransfer(msg.sender, amount);

        _notifyLiquidityChange(msg.sender, amount, false);

        emit EmergencyWithdrawn(msg.sender, tierId, amount, u.unpaid);
    }

    /// Claims pending mining reward for one tier. Fail-loud on purpose:
    /// if the user explicitly asked to claim and it cannot be paid, they
    /// should see the reason rather than a silent no-op.
    function claim(TierId tierId) external nonReentrant whenNotPaused {
        _updateTierRewards(tierId);
        _settlePending(msg.sender, tierId);
    }

    // ====================== INTERNAL -- REWARD SETTLEMENT ======================

    /// Banks newly accrued reward into unpaid and advances rewardDebt.
    /// Touches NO external contract, so it can never revert. Calling
    /// this in the outer frame before _trySettle() is what keeps a
    /// failed payout from erasing the user's pending reward.
    function _accrue(address user, TierId tierId) internal {
        TierConfig storage t = tiers[tierId];
        UserTierInfo storage u = userTier[user][tierId];
        if (u.lpAmount == 0) return;
        uint256 accumulated = (u.lpAmount * t.accRewardPerShare) / 1e18;
        if (accumulated > u.rewardDebt) {
            u.unpaid += accumulated - u.rewardDebt;
        }
        u.rewardDebt = accumulated;
    }

    /// Self-call wrapper letting emergencyWithdraw() refresh the tier
    /// rate without inheriting RewardPool's failure modes.
    function _updateTierRewardsExternal(TierId tierId) external {
        require(msg.sender == address(this), "internal only");
        _updateTierRewards(tierId);
    }

    function _tryUpdateTierRewards(TierId tierId) internal {
        try this._updateTierRewardsExternal(tierId) {
            // rate refreshed
        } catch {
            // RewardPool unreachable -- proceed with the stale rate
            // rather than blocking the emergency exit.
        }
    }

    /// Self-call wrapper so deposit()/withdraw() can try/catch the
    /// payout. A revert inside rolls back only what the inner call
    /// touched -- the _accrue() done by the caller survives.
    /// NOTE: intentionally NOT nonReentrant -- it is invoked via
    /// this._settleExternal(...) from inside a nonReentrant function,
    /// and is access-gated to this contract only.
    function _settleExternal(address user, TierId tierId) external {
        require(msg.sender == address(this), "internal only");
        _settlePending(user, tierId);
    }

    function _trySettle(address user, TierId tierId) internal {
        try this._settleExternal(user, tierId) {
            // paid (or nothing to pay)
        } catch Error(string memory reason) {
            emit SettlementDeferred(user, tierId, userTier[user][tierId].unpaid, reason);
        } catch (bytes memory lowLevelData) {
            emit SettlementDeferred(
                user, tierId, userTier[user][tierId].unpaid,
                lowLevelData.length == 0 ? "out of gas or no reason" : "low-level revert"
            );
        }
    }

    /// FIX 2 + FIX 3. Accrues, then pays out as much of unpaid as both
    /// caps allow; the remainder stays in unpaid for a later call.
    function _settlePending(address user, TierId tierId) internal {
        UserTierInfo storage u = userTier[user][tierId];

        _accrue(user, tierId);

        if (u.unpaid == 0) return;

        // Cap by BOTH limits. MAX_SINGLE_ALLOC alone is not enough: the
        // Mining bucket's whole daily budget (~2,352 OSG at a 40% split
        // of 5,881/day, up to ~9,409 with 3 days of carry) is smaller
        // than MAX_SINGLE_ALLOC, so a 10,000 payout would ALWAYS revert
        // with "Mining cap exceeded". Reading miningAvail live keeps the
        // payout inside whatever RewardPool can actually distribute today.
        uint256 payout = u.unpaid > MAX_SINGLE_ALLOC ? MAX_SINGLE_ALLOC : u.unpaid;
        ( , , , , uint256 miningAvail, , ) = pool.getTodayStats();
        if (payout > miningAvail) payout = miningAvail;
        require(payout > 0, "no mining budget available today");

        u.unpaid -= payout;

        pool.distribute(user, payout, CAT_MINING);
        emit MiningClaimed(user, tierId, payout);

        if (u.unpaid > 0) {
            emit PayoutCapped(user, tierId, payout, u.unpaid);
        }

        _notifyClaim(user, payout);
    }

    function _updateTierRewards(TierId tierId) internal {
        TierConfig storage t = tiers[tierId];
        if (block.timestamp <= t.lastRewardTime || t.totalDepositedLp == 0) {
            t.lastRewardTime = block.timestamp;
            return;
        }
        uint256 elapsed = block.timestamp - t.lastRewardTime;
        uint256 reward = (getTierDailyBudget(tierId) * elapsed) / 1 days;
        if (reward > 0) {
            t.accRewardPerShare += (reward * 1e18) / t.totalDepositedLp;
        }
        t.lastRewardTime = block.timestamp;
    }

    /// Settles every active tier at its OLD rate before any change that
    /// affects shared reward-rate math. Bounded 5-iteration loop.
    function _settleAllActiveTiers() internal {
        TierId[5] memory all = [TierId.T1, TierId.T2, TierId.T3, TierId.T4, TierId.T5];
        for (uint8 i = 0; i < TIER_COUNT; i++) {
            if (tiers[all[i]].active) {
                _updateTierRewards(all[i]);
            }
        }
    }

    // ====================== VIEW -- BUDGET ======================

    /// LP Mining's total daily OSG budget across ALL tiers.
    /// RewardPool.miningPercent is 0-100; miningShareBps is bps.
    function getLpMiningDailyBudget() public view returns (uint256) {
        ( , , , , , , uint256 dailyBase) = pool.getTodayStats();
        uint256 miningPct    = pool.miningPercent();
        uint256 miningBucket = (dailyBase * miningPct) / 100;
        return (miningBucket * miningShareBps) / BPS_DENOM;
    }

    function getTierDailyBudget(TierId tierId) public view returns (uint256) {
        return (getLpMiningDailyBudget() * tiers[tierId].tierWeightBps) / BPS_DENOM;
    }

    /// Includes any carried-over unpaid from a capped or deferred payout.
    function pendingMiningReward(address user, TierId tierId) public view returns (uint256) {
        TierConfig storage t = tiers[tierId];
        UserTierInfo storage u = userTier[user][tierId];

        uint256 total = u.unpaid;
        if (u.lpAmount == 0) return total;

        uint256 acc = t.accRewardPerShare;
        if (block.timestamp > t.lastRewardTime && t.totalDepositedLp > 0) {
            uint256 elapsed = block.timestamp - t.lastRewardTime;
            uint256 reward = (getTierDailyBudget(tierId) * elapsed) / 1 days;
            acc += (reward * 1e18) / t.totalDepositedLp;
        }
        uint256 accumulated = (u.lpAmount * acc) / 1e18;
        if (accumulated > u.rewardDebt) {
            total += accumulated - u.rewardDebt;
        }
        return total;
    }

    /// How much of pendingMiningReward() the NEXT settlement can actually
    /// send right now, capped by MAX_SINGLE_ALLOC AND by today's remaining
    /// Mining budget. Returns 0 when nothing can be paid today -- useful
    /// for honest UI messaging ("X OSG accrued, Y payable now").
    function nextPayoutChunk(address user, TierId tierId) external view returns (uint256) {
        uint256 total = pendingMiningReward(user, tierId);
        if (total > MAX_SINGLE_ALLOC) total = MAX_SINGLE_ALLOC;
        ( , , , , uint256 miningAvail, , ) = pool.getTodayStats();
        return total > miningAvail ? miningAvail : total;
    }

    // ====================== INTERNAL -- REFERRAL NOTIFICATIONS ======================
    // Both hooks stay in try/catch: a referral-side failure must NEVER
    // block a user's own deposit/withdraw/claim/emergency exit.

    function _notifyLiquidityChange(address depositor, uint256 lpDelta, bool isAdd) internal {
        if (address(referralContract) == address(0)) return;
        try referralContract.onLiquidityChange(depositor, lpDelta, isAdd) {
            // ok
        } catch (bytes memory reason) {
            emit ReferralHookFailed(depositor, "onLiquidityChange", reason);
        }
    }

    function _notifyClaim(address user, uint256 rewardAmount) internal {
        if (address(referralContract) == address(0)) return;
        try referralContract.onRewardClaimed(user, rewardAmount) {
            // ok
        } catch (bytes memory reason) {
            emit ReferralHookFailed(user, "onRewardClaimed", reason);
        }
    }

    // ====================== VIEW -- HEALTH ======================

    function isWiredForMining() public view returns (bool) {
        return pool.distributorType(address(this)) == CAT_MINING
            && pool.distributorActive(address(this));
    }

    /// One-call diagnosis for the UI: explains WHY a reward settlement
    /// would currently fail, so the app can show a real reason instead
    /// of a generic revert. Note this does NOT gate withdrawals --
    /// emergencyWithdraw() works regardless of what this returns, and
    /// withdraw() only defers the reward rather than failing.
    /// Does not cover the per-block cooldown (which is transient and
    /// resolves on the next block) or per-user payout caps.
    function payoutHealth() external view returns (bool canPayNow, string memory reason) {
        if (!isWiredForMining())    return (false, "not registered as category-2 distributor");
        if (paused())               return (false, "mining contract paused");
        if (pool.paused())          return (false, "RewardPool paused");
        if (pool.emissionStopped()) return (false, "emission stopped");
        ( , , , , uint256 miningAvail, , ) = pool.getTodayStats();
        if (miningAvail == 0)       return (false, "daily mining budget exhausted");
        return (true, "ready");
    }

    function tierCapacityLp(TierId tierId) external view returns (uint256) {
        return tiers[tierId].capacityLp;
    }

    function tierLpToken(TierId tierId) external view returns (address) {
        return tiers[tierId].lpToken;
    }

    /// True if token is the LP token of ANY tier -- used by rescueToken
    /// to make sure depositor funds can never be swept out.
    function isProtectedToken(address token) public view returns (bool) {
        TierId[5] memory all = [TierId.T1, TierId.T2, TierId.T3, TierId.T4, TierId.T5];
        for (uint8 i = 0; i < TIER_COUNT; i++) {
            if (tiers[all[i]].lpToken == token) return true;
        }
        return false;
    }

    // ====================== ADMIN -- CONFIG ======================

    function setReferralContract(address _referral) external onlyOwner {
        require(_referral != address(0), "zero address");
        require(_referral.code.length > 0, "referral must be a contract");
        referralContract = IOSGLPReferral(_referral);
        emit ReferralContractUpdated(_referral);
    }

    /// FIX 4: assign or change a tier's LP token. Only allowed while the
    /// tier holds ZERO deposits -- otherwise existing depositors' balances
    /// would be denominated in a token the contract no longer transfers.
    function setTierLpToken(TierId tierId, address _lpToken) external onlyOwner {
        require(_lpToken.code.length > 0, "lpToken not contract");
        TierConfig storage t = tiers[tierId];
        require(t.totalDepositedLp == 0, "tier has deposits");
        t.lpToken = _lpToken;
        emit TierLpTokenUpdated(tierId, _lpToken);
    }

    /// Deactivating a tier automatically zeroes its weight, freeing that
    /// budget share for other tiers. Re-enabling does NOT restore weight.
    function updateTierConfig(
        TierId tierId, uint256 minDeposit, uint256 capacityLp, bool active
    ) external onlyOwner {
        _updateTierRewards(tierId);
        TierConfig storage t = tiers[tierId];
        require(capacityLp >= t.totalDepositedLp, "capacity below deposited amount");
        if (active) {
            require(t.lpToken != address(0), "set tier lpToken first");
        }
        t.minDeposit = minDeposit;
        t.capacityLp = capacityLp;
        t.active     = active;

        if (!active && t.tierWeightBps > 0) {
            totalTierWeightBps -= t.tierWeightBps;
            t.tierWeightBps = 0;
            emit TierWeightUpdated(tierId, 0, totalTierWeightBps);
        }

        emit TierConfigUpdated(tierId, minDeposit, capacityLp, active);
    }

    function setMiningShareBps(uint256 newBps) external onlyOwner {
        require(newBps <= maxShareBps, "exceeds maxShareBps");
        _settleAllActiveTiers();
        miningShareBps = newBps;
        emit MiningShareUpdated(newBps, msg.sender);
    }

    /// Rebalances each tier's slice of the total budget. Always validates
    /// the sum across all 5 tiers stays <= 100%, and settles every active
    /// tier at its OLD weight first.
    function setTierWeightBps(TierId tierId, uint256 newWeightBps) external onlyOwner {
        require(newWeightBps == 0 || tiers[tierId].active, "cannot weight an inactive tier");

        _settleAllActiveTiers();

        TierId[5] memory all = [TierId.T1, TierId.T2, TierId.T3, TierId.T4, TierId.T5];
        uint256 total = 0;
        for (uint8 i = 0; i < TIER_COUNT; i++) {
            total += (all[i] == tierId) ? newWeightBps : tiers[all[i]].tierWeightBps;
        }
        require(total <= BPS_DENOM, "total tier weights exceed 100%");

        tiers[tierId].tierWeightBps = newWeightBps;
        totalTierWeightBps = total;
        emit TierWeightUpdated(tierId, newWeightBps, total);
    }

    function setMaxShareBps(uint256 newMax) external onlyOwner {
        require(newMax <= ABSOLUTE_MAX_SHARE_BPS, "exceeds absolute max");
        maxShareBps = newMax;
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// Recover tokens sent here by mistake. Can never touch ANY tier's
    /// LP token -- deposited LP belongs to depositors.
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        require(!isProtectedToken(token), "cannot rescue a tier LP token");
        require(to != address(0) && amount > 0, "bad args");
        IERC20(token).safeTransfer(to, amount);
    }

    function version() external pure returns (string memory) {
        return "OSGLPMining v6";
    }
}
