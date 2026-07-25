// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/*
 * ======================================================================
 *  WARNING: DRAFT v4 -- LP-AMOUNT-BASED + tierWeightBps budget split.
 *  Verified against actual RewardPool.sol / Staking.sol, but STILL
 *  requires Remix compile + testnet dry-run before mainnet.
 * ======================================================================
 *  KEY CHANGE vs v3 draft:
 *  Each tier now has its own tierWeightBps -- its slice of the TOTAL
 *  LP-mining daily budget (getLpMiningDailyBudget()). Without this, if
 *  a second tier (T2) were ever activated alongside T1, BOTH would
 *  independently claim the FULL total budget (double-counting), which
 *  would either overpay depositors or fail against RewardPool's daily
 *  cap. Now, activating a new tier is just:
 *    updateTierConfig(T2, ...) + setTierWeightBps(T2, X) +
 *    setTierWeightBps(T1, 10000-X)   -- NO redeploy needed.
 *  setTierWeightBps() always validates all 5 tiers' weights sum to
 *  <= 100% (bounded 5-iteration loop, gas-safe).
 *  KEY CHANGE vs v2 draft:
 *  Rewards, capacity, and deposits are now tracked in raw LP-token
 *  units (accRewardPerShare per LP unit), NOT in discrete "slots".
 *  This fixes an inconsistency where OSGLPMining tracked positions by
 *  slot-count while OSGLPReferral's teamLiquidityLp always tracked raw
 *  LP amount -- the two are now aligned on the same unit.
 *
 *  "T1 = 10 slots x 0.10 LP" is still the PUBLIC/marketing framing
 *  (see minDeposit + capacityLp below), but internally there are no
 *  discrete slots: a user can deposit ANY amount >= minDeposit, not
 *  just multiples of 0.10 LP, and rewards scale exactly with LP held.
 *
 *  KEY ARCHITECTURAL FIX (carried over from v2):
 *  RewardPool.setDistributor(addr, cat) binds ONE address to ONE
 *  category permanently. So Mining (cat 2) and Referral (cat 3)
 *  payouts CANNOT come from the same contract address. This contract
 *  (OSGLPMining) is registered ONLY as the category-2 (Mining)
 *  distributor. All referral/bonus logic lives in the companion
 *  OSGLPReferral.sol, registered separately as category-3.
 *
 *  This contract calls OSGLPReferral's hooks on every deposit/withdraw
 *  so team-liquidity tracking there stays in sync. The hook call is
 *  wrapped in try/catch so a referral-side failure (e.g. per-block-
 *  cooldown collision) NEVER blocks or reverts a user's own Mining
 *  deposit/withdraw/claim.
 *
 *  STILL TO VERIFY BEFORE DEPLOY:
 *   1. LP token decimals (assumed 18 below -- QuickSwap V2 pairs are
 *      normally 18, confirm on Polygonscan for 0xA15214B0...Cd2).
 *   2. Compile in Remix against the real RewardPool/Staking bytecode.
 *   3. setDistributor(thisAddress, 2) done AFTER full testnet dry-run --
 *      no 48h delay protects this call, per project rule section 11.
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
    uint256 public constant FIRST_WITHDRAW_LOCK = 24 hours; // only the first-ever deposit
    /// Mirrors RewardPool.MAX_SINGLE_ALLOC (10,000 OSG) -- belt-and-braces
    /// check here too, so a huge accrued claim fails fast with a clear
    /// reason instead of reverting deep inside RewardPool.
    uint256 public constant MAX_SINGLE_ALLOC = 10_000 * 1e18;

    // ====================== IMMUTABLES ======================
    IERC20         public immutable lpToken;
    IOSGRewardPool public immutable pool;

    // ====================== REFERRAL HOOK TARGET ======================
    /// The companion OSGLPReferral contract. Owner-settable (not
    /// immutable) so it can be pointed at a redeployed referral
    /// contract if ever needed, without redeploying Mining itself.
    IOSGLPReferral public referralContract;

    // ====================== MINING SHARE (owner-adjustable) ======================
    uint256 public miningShareBps = 50;    // 0.5% of the Mining bucket, per finalized spec
    uint256 public maxShareBps    = 5_000; // 50% ceiling, owner-adjustable up to ABSOLUTE_MAX

    // ====================== TIERS (LP-amount based) ======================
    enum TierId { T1, T2, T3, T4, T5 }

    struct TierConfig {
        uint256 minDeposit;        // minimum LP per deposit call (e.g. 0.10 LP = "1 slot")
        uint256 capacityLp;        // total LP capacity for this tier (e.g. 1.0 LP for T1)
        uint256 totalDepositedLp;  // currently deposited LP, system-wide, this tier
        bool    active;            // owner can enable/disable
        uint256 tierWeightBps;     // this tier's share of getLpMiningDailyBudget(), in bps
        uint256 accRewardPerShare; // cumulative reward per LP unit, scaled 1e18
        uint256 lastRewardTime;
    }
    mapping(TierId => TierConfig) public tiers;
    /// Sum of all 5 tiers' tierWeightBps -- kept in sync by setTierWeightBps()
    /// so it never needs to be recomputed with an unbounded loop elsewhere.
    uint256 public totalTierWeightBps;

    struct UserTierInfo {
        uint256 lpAmount;   // raw LP deposited by this user in this tier
        uint256 rewardDebt; // staking-style accounting against accRewardPerShare
    }
    mapping(address => mapping(TierId => UserTierInfo)) public userTier;

    /// Set once on a wallet's very first deposit (any tier), never updated again.
    mapping(address => uint256) public firstDepositTime;

    // ====================== EVENTS ======================
    event Deposited(address indexed user, TierId tier, uint256 lpAmount);
    event Withdrawn(address indexed user, TierId tier, uint256 lpAmount);
    event MiningClaimed(address indexed user, TierId tier, uint256 amount);
    event ReferralHookFailed(address indexed user, string what, bytes reason);
    event TierConfigUpdated(TierId tier, uint256 minDeposit, uint256 capacityLp, bool active);
    event MiningShareUpdated(uint256 newBps, address indexed by);
    event TierWeightUpdated(TierId indexed tier, uint256 newWeightBps, uint256 totalWeightBps);
    event ReferralContractUpdated(address indexed newContract);

    constructor(address _lpToken, address _pool, address _owner) Ownable(_owner) {
        require(_lpToken.code.length > 0, "lpToken not contract");
        require(_pool.code.length    > 0, "pool not contract");
        lpToken = IERC20(_lpToken);
        pool    = IOSGRewardPool(_pool);

        // T1 active at launch -- min deposit 0.10 LP ("1 slot"), total
        // capacity 1.0 LP (== 10 slots worth), 100% of the LP-mining
        // budget (only active tier at launch), per finalized spec.
        // WARNING: 0.10/1.0 ether assumes 18 decimals -- VERIFY on
        // Polygonscan for the real LP token before deploy.
        tiers[TierId.T1] = TierConfig({
            minDeposit: 0.10 ether,
            capacityLp: 1.0 ether,
            totalDepositedLp: 0,
            active: true,
            tierWeightBps: BPS_DENOM, // 100% -- only active tier at launch
            accRewardPerShare: 0,
            lastRewardTime: block.timestamp
        });
        totalTierWeightBps = BPS_DENOM;
        // T2-T5 remain inactive/zeroed/zero-weight; owner configures +
        // activates later via updateTierConfig() + setTierWeightBps(),
        // rebalancing weights across tiers WITHOUT redeploying.
    }

    // ====================== DEPOSIT / WITHDRAW / CLAIM ======================

    /// Deposits lpAmount of LP into tierId. Must be >= tier.minDeposit
    /// (the "1 slot" floor), but does NOT need to be a multiple of it --
    /// any amount above the floor is accepted, and rewards scale exactly
    /// with LP held (no discrete slots internally).
    function deposit(TierId tierId, uint256 lpAmount) external nonReentrant whenNotPaused {
        TierConfig storage t = tiers[tierId];
        require(t.active, "tier not active");
        require(lpAmount >= t.minDeposit, "below minimum deposit (1 slot)");
        require(t.totalDepositedLp + lpAmount <= t.capacityLp, "exceeds tier capacity");

        _updateTierRewards(tierId);
        _settlePending(msg.sender, tierId);

        lpToken.safeTransferFrom(msg.sender, address(this), lpAmount);

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

    /// Withdraws lpAmount of LP from tierId. Partial withdrawal is
    /// always allowed (any amount up to the user's balance, no minimum)
    /// -- only the FIRST-EVER deposit is time-locked, per finalized spec.
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
        _settlePending(msg.sender, tierId);

        u.lpAmount -= lpAmount;
        u.rewardDebt = (u.lpAmount * t.accRewardPerShare) / 1e18;
        t.totalDepositedLp -= lpAmount;

        lpToken.safeTransfer(msg.sender, lpAmount);

        _notifyLiquidityChange(msg.sender, lpAmount, false);

        emit Withdrawn(msg.sender, tierId, lpAmount);
    }

    /// Claims pending mining reward for one tier. Also notifies the
    /// Referral contract so it can pay any live Recurring Maintenance
    /// Bonus in the same transaction (best-effort -- see _notifyClaim).
    function claim(TierId tierId) external nonReentrant whenNotPaused {
        _updateTierRewards(tierId);
        _settlePending(msg.sender, tierId);
    }

    // ====================== INTERNAL -- REWARD SETTLEMENT ======================

    function _settlePending(address user, TierId tierId) internal {
        TierConfig storage t = tiers[tierId];
        UserTierInfo storage u = userTier[user][tierId];
        if (u.lpAmount == 0) return;

        uint256 accumulated = (u.lpAmount * t.accRewardPerShare) / 1e18;
        uint256 pending = accumulated > u.rewardDebt ? accumulated - u.rewardDebt : 0;
        u.rewardDebt = accumulated;

        if (pending == 0) return;
        require(pending <= MAX_SINGLE_ALLOC, "single claim exceeds cap - contact support");

        // Fail-loud by design for the MINING payout itself: if this
        // reverts (e.g. per-block cooldown already used by this
        // contract this block), the whole tx reverts, rewardDebt is
        // NOT advanced, and pending stays fully claimable on retry.
        pool.distribute(user, pending, CAT_MINING);
        emit MiningClaimed(user, tierId, pending);

        _notifyClaim(user, pending);
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

    /// Settles every currently-active tier at its OLD rate before any
    /// change that affects reward-rate math shared across tiers
    /// (miningShareBps) or a specific tier's own share (tierWeightBps).
    /// Bounded 5-iteration loop, gas-safe regardless of tier count.
    function _settleAllActiveTiers() internal {
        TierId[5] memory all = [TierId.T1, TierId.T2, TierId.T3, TierId.T4, TierId.T5];
        for (uint8 i = 0; i < 5; i++) {
            if (tiers[all[i]].active) {
                _updateTierRewards(all[i]);
            }
        }
    }

    /// LP Mining's own daily OSG budget = miningShareBps % of RewardPool's
    /// live Mining-category bucket (dailyBase * miningPercent / 100).
    /// NOTE: RewardPool's miningPercent is 0-100 (not bps); miningShareBps
    /// here IS in bps (10000 = 100%) -- units differ by design, kept
    /// explicit below to avoid mixing them up. This is the TOTAL budget
    /// across ALL tiers combined -- use getTierDailyBudget() for a
    /// single tier's actual share.
    function getLpMiningDailyBudget() public view returns (uint256) {
        ( , , , , , , uint256 dailyBase) = pool.getTodayStats();
        uint256 miningPct    = pool.miningPercent();           // e.g. 40, out of 100
        uint256 miningBucket = (dailyBase * miningPct) / 100;  // RewardPool convention
        return (miningBucket * miningShareBps) / BPS_DENOM;    // our own bps convention
    }

    /// This specific tier's slice of getLpMiningDailyBudget(), per its
    /// tierWeightBps. This is what makes multiple active tiers
    /// (T1 + T2 + ...) split the SAME total budget instead of each
    /// independently claiming the full amount (which would double-count
    /// and blow through RewardPool's daily cap).
    function getTierDailyBudget(TierId tierId) public view returns (uint256) {
        return (getLpMiningDailyBudget() * tiers[tierId].tierWeightBps) / BPS_DENOM;
    }

    function pendingMiningReward(address user, TierId tierId) external view returns (uint256) {
        TierConfig storage t = tiers[tierId];
        UserTierInfo storage u = userTier[user][tierId];
        if (u.lpAmount == 0) return 0;

        uint256 acc = t.accRewardPerShare;
        if (block.timestamp > t.lastRewardTime && t.totalDepositedLp > 0) {
            uint256 elapsed = block.timestamp - t.lastRewardTime;
            uint256 reward = (getTierDailyBudget(tierId) * elapsed) / 1 days;
            acc += (reward * 1e18) / t.totalDepositedLp;
        }
        uint256 accumulated = (u.lpAmount * acc) / 1e18;
        return accumulated > u.rewardDebt ? accumulated - u.rewardDebt : 0;
    }

    // ====================== INTERNAL -- REFERRAL CONTRACT NOTIFICATIONS ======================
    // Both hooks are wrapped in try/catch: a Referral-side failure (e.g.
    // per-block-cooldown collision on ITS distribute() call, or the
    // referral contract not yet configured) must NEVER block or revert
    // a user's own deposit/withdraw/claim in THIS contract.

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

    /// Total LP capacity for a tier (used by OSGLPReferral as the 100%
    /// basis for rank thresholds -- keep OSGLPReferral.poolCapacityLp in
    /// sync manually via setPoolCapacityLp() whenever this changes).
    function tierCapacityLp(TierId tierId) external view returns (uint256) {
        return tiers[tierId].capacityLp;
    }

    // ====================== ADMIN -- CONFIG ======================

    /// Validates the address is non-zero and IS a deployed contract,
    /// reducing the risk of pointing hooks at a wrong/EOA address by
    /// mistake (a wrong contract address would silently fail every
    /// hook call via the try/catch, going unnoticed for a while).
    function setReferralContract(address _referral) external onlyOwner {
        require(_referral != address(0), "zero address");
        require(_referral.code.length > 0, "referral must be a contract");
        referralContract = IOSGLPReferral(_referral);
        emit ReferralContractUpdated(_referral);
    }

    /// If active is set to false here, this tier's tierWeightBps is
    /// AUTOMATICALLY forced to 0 (its budget share is freed up for
    /// other tiers) -- an inactive tier can never silently keep a
    /// non-zero weight. Re-enabling a tier does NOT restore a weight;
    /// call setTierWeightBps() explicitly afterward to give it a share.
    function updateTierConfig(
        TierId tierId, uint256 minDeposit, uint256 capacityLp, bool active
    ) external onlyOwner {
        _updateTierRewards(tierId);
        TierConfig storage t = tiers[tierId];
        require(capacityLp >= t.totalDepositedLp, "capacity below deposited amount");
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

    /// miningShareBps affects getLpMiningDailyBudget() which EVERY tier's
    /// reward rate depends on -- so ALL currently-active tiers are
    /// settled at their OLD rate first, before the new share takes
    /// effect. Otherwise a tier not touched around the change moment
    /// could have some of its pending reward computed retroactively at
    /// the NEW rate instead of the rate that actually applied during
    /// that elapsed time (not a fund-safety bug, just an accounting
    /// precision issue this avoids).
    function setMiningShareBps(uint256 newBps) external onlyOwner {
        require(newBps <= maxShareBps, "exceeds maxShareBps");
        _settleAllActiveTiers();
        miningShareBps = newBps;
        emit MiningShareUpdated(newBps, msg.sender);
    }

    /// Rebalances how much of the TOTAL LP-mining daily budget each
    /// tier receives. Always validates that the sum across all 5 tiers
    /// stays <= 100% (BPS_DENOM), so activating a new tier (T2, T3...)
    /// later just means calling this -- NO redeploy needed, and no risk
    /// of tiers double-claiming the same budget.
    ///
    /// Before applying the change, ALL currently-active tiers are
    /// settled (_updateTierRewards) at their OLD weights first, so
    /// reward accounting up to the exact moment of this change stays
    /// accurate for every tier, not just the one being reweighted.
    ///
    /// An inactive tier can never hold a non-zero weight -- this
    /// prevents budget share silently sitting unused (or being
    /// double-booked) on a tier nobody can deposit into.
    function setTierWeightBps(TierId tierId, uint256 newWeightBps) external onlyOwner {
        require(newWeightBps == 0 || tiers[tierId].active, "cannot weight an inactive tier");

        _settleAllActiveTiers();

        TierId[5] memory all = [TierId.T1, TierId.T2, TierId.T3, TierId.T4, TierId.T5];
        uint256 total = 0;
        for (uint8 i = 0; i < 5; i++) {
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

    /// Recover tokens sent here by mistake. Cannot touch the LP token
    /// itself -- deposited LP belongs to depositors and must stay safe.
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(lpToken), "cannot rescue deposited LP token");
        require(to != address(0) && amount > 0, "bad args");
        IERC20(token).safeTransfer(to, amount);
    }

    function version() external pure returns (string memory) {
        return "OSGLPMining v5 (draft, LP-amount-based + tierWeightBps + settlement hygiene, T1 launch)";
    }
}
