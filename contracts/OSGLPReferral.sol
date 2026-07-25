// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/*
 * ======================================================================
 *  WARNING - DRAFT v1 -- companion to OSGLPMining.sol. Requires Remix compile +
 *  testnet dry-run before mainnet (project rule section 11 -- no 48h delay
 *  protects setDistributor()).
 * ======================================================================
 *  ROLE: registered as RewardPool's category-3 (Referral) distributor,
 *  SEPARATELY from OSGLPMining (category-2, Mining) -- one address can
 *  only hold one category, confirmed from RewardPool.setDistributor().
 *
 *  Receives hooks from OSGLPMining on every deposit/withdraw/claim:
 *   - onLiquidityChange(): walks the EXISTING Staking.sol referral
 *     chain (bounded, 5 levels -- same pattern as staking.getReferralChain,
 *     no unbounded loops) to keep teamLiquidityLp in sync.
 *   - onRewardClaimed(): accrues Level Commission (owed, paid manually
 *     later) and pays the live Recurring Maintenance Bonus immediately
 *     via pool.distribute(..., CAT_REFERRAL), in the SAME tx as the
 *     Mining claim (cross-contract call, independent per-block
 *     cooldown from OSGLPMining's own CAT_MINING calls).
 *
 *  Both hooks are onlyLPMining-gated -- no one else can call them.
 *  lpMining is owner-settable (NOT immutable/constructor-only), so the
 *  circular deploy dependency is broken: deploy this contract first
 *  (or LPMining first, order doesn't matter), then call setLPMining()
 *  once both addresses exist.
 *
 *  Payment model (mirrors OSGReferralDistributor.sol's proven pattern):
 *   - Level Commission + Milestone Bonus accrue into owed() mappings,
 *     paid manually by owner via payReferral(user) -- because RewardPool
 *     has a one-call-per-block-per-distributor cooldown that makes
 *     batch auto-pay impossible.
 *   - Recurring Maintenance Bonus is NOT accrued -- it is computed live
 *     and paid automatically inside onRewardClaimed(), no owed() entry.
 * ======================================================================
 */

interface IOSGRewardPool {
    function distribute(address user, uint256 amount, uint8 category) external;
    function distributorType(address) external view returns (uint8);
    function distributorActive(address) external view returns (bool);
    function paused() external view returns (bool);
    function emissionStopped() external view returns (bool);
}

interface IOSGStaking {
    /// Confirmed signature, matches Staking.sol v11 exactly.
    function getReferralChain(address user) external view returns (
        address l1, address l2, address l3, address l4, address l5
    );
}

contract OSGLPReferral is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ====================== CONSTANTS ======================
    uint8   public constant CAT_REFERRAL = 3;
    uint256 public constant BPS_DENOM    = 10_000;
    uint256 public constant MAINTAIN_PERIOD = 24 hours;
    /// Mirrors RewardPool.MAX_SINGLE_ALLOC -- belt-and-braces check.
    uint256 public constant MAX_SINGLE_ALLOC = 10_000 * 1e18;
    /// Hard ceiling on the Recurring Maintenance Bonus (5% of a claim).
    /// Currently unreachable to exceed since rank tops out at 5 (A5) x
    /// 100 bps = 500, but kept as an explicit, named safety limit.
    uint256 public constant MAX_RECURRING_BPS = 500;
    /// Hard ceiling on the SUM of all 5 Level Commission percentages,
    /// so owner config mistakes can never push total commission above
    /// 15% of a claim.
    uint256 public constant MAX_TOTAL_LEVEL_COMMISSION_BPS = 1_500;

    // ====================== IMMUTABLES ======================
    IOSGRewardPool public immutable pool;
    IOSGStaking    public immutable staking;

    // ====================== HOOK CALLER (owner-settable, not immutable) ======================
    /// The only address allowed to call onLiquidityChange()/onRewardClaimed().
    /// NOT immutable -- owner sets this after both contracts are deployed,
    /// which avoids a circular-dependency deploy order (Referral no longer
    /// needs LPMining's address at construction time). Owner can also
    /// repoint this later if LPMining is ever redeployed.
    address public lpMining;

    // ====================== POOL CAPACITY (rank basis) ======================
    /// T1's total LP capacity (lpPerSlot * capacity), used as the 100%
    /// basis for rank thresholds. Owner must keep this in sync manually
    /// if OSGLPMining's T1 config ever changes -- NOT read live, to avoid
    /// a hard cross-contract dependency here. Call syncPoolCapacity()
    /// (view-only helper below) after any T1 config change to check.
    uint256 public poolCapacityLp;

    // ====================== TEAM LIQUIDITY & RANK ======================
    mapping(address => uint256) public teamLiquidityLp;
    mapping(address => uint256) public qualifiedSince;
    mapping(address => uint8)   public highestRankPaid; // 0-5

    // index 0 unused; [1]=A1 .. [5]=A5
    uint256[6] public rankThresholdBps; // % of poolCapacityLp
    uint256[6] public rankBonusBps;     // one-time milestone bonus, % of ONE DAY's LP-mining budget basis
    /// Since this contract doesn't know OSGLPMining's live daily budget
    /// directly, the milestone bonus basis is a flat OSG amount set by
    /// owner per rank (simpler + more predictable than deriving it from
    /// a cross-contract read). See setMilestoneBaseAmount().
    uint256 public milestoneBaseAmount = 20 * 1e18; // NOTE: placeholder, owner should tune

    // ====================== LEVEL COMMISSION ======================
    // index 0 unused; [1]=L1 .. [5]=L5 -- mirrors Staking.sol REF_L1..REF_L5
    uint16[6] public levelCommissionBps;

    mapping(address => uint256) public levelCommissionOwed;
    mapping(address => uint256) public levelCommissionPaid;
    mapping(address => uint256) public milestoneBonusOwed;
    mapping(address => uint256) public milestoneBonusPaid;

    // ====================== EVENTS ======================
    event LevelCommissionAccrued(address indexed referrer, address indexed from, uint256 amount, uint8 level);
    event MilestoneBonusAccrued(address indexed user, uint8 rank, uint256 amount);
    event RecurringBonusPaid(address indexed user, uint256 amount, uint256 bps);
    event RecurringBonusSkipped(address indexed user, string reason);
    event ReferralPaid(address indexed user, uint256 amount, address indexed by);
    event RankConfigUpdated(uint8 rank, uint256 thresholdBps, uint256 bonusBps);
    event PoolCapacityUpdated(uint256 newCapacityLp);
    event MilestoneBaseAmountUpdated(uint256 newAmount);
    event LPMiningUpdated(address indexed newLPMining);

    modifier onlyLPMining() {
        require(lpMining != address(0), "lpMining not set");
        require(msg.sender == lpMining, "caller is not LPMining");
        _;
    }

    constructor(
        address _pool,
        address _staking,
        uint256 _initialPoolCapacityLp,
        address _owner
    ) Ownable(_owner) {
        require(_pool.code.length     > 0, "pool not contract");
        require(_staking.code.length  > 0, "staking not contract");
        pool           = IOSGRewardPool(_pool);
        staking        = IOSGStaking(_staking);
        poolCapacityLp = _initialPoolCapacityLp; // e.g. 1.0 ether for T1 (10 x 0.10 LP)
        // lpMining is set separately via setLPMining() after both
        // contracts are deployed -- see onlyLPMining modifier below.

        rankThresholdBps   = [0, 1_000, 2_500, 5_000, 7_500, 10_000]; // A1..A5
        rankBonusBps       = [0, 50, 100, 150, 200, 300];             // .5/1/1.5/2/3% (of milestoneBaseAmount)
        levelCommissionBps = [0, 500, 300, 200, 100, 50];             // 5/3/2/1/.5%, mirrors staking
    }

    // ====================== HOOKS -- CALLED ONLY BY OSGLPMining ======================

    function onLiquidityChange(address depositor, uint256 lpDelta, bool isAdd)
        external
        onlyLPMining
        whenNotPaused
    {
        (address l1, address l2, address l3, address l4, address l5) =
            staking.getReferralChain(depositor);
        address[5] memory chain = [l1, l2, l3, l4, l5];

        for (uint8 i = 0; i < 5; i++) {
            address ref = chain[i];
            if (ref == address(0)) break; // bounded loop, exits early if chain is shorter

            if (isAdd) {
                teamLiquidityLp[ref] += lpDelta;
            } else {
                teamLiquidityLp[ref] = teamLiquidityLp[ref] > lpDelta
                    ? teamLiquidityLp[ref] - lpDelta
                    : 0;
            }

            _checkRankProgress(ref);
        }
    }

    function onRewardClaimed(address user, uint256 rewardAmount)
        external
        onlyLPMining
        nonReentrant
        whenNotPaused
    {
        _accrueLevelCommission(user, rewardAmount);

        uint256 recurringBps = getRecurringBonusBps(user);
        if (recurringBps == 0) return;

        uint256 bonus = (rewardAmount * recurringBps) / BPS_DENOM;
        if (bonus == 0) return;
        if (bonus > MAX_SINGLE_ALLOC) {
            emit RecurringBonusSkipped(user, "exceeds MAX_SINGLE_ALLOC");
            return;
        }

        // Fail-loud is NOT appropriate here -- this whole function is
        // already called via try/catch from OSGLPMining, so a revert
        // here just means "no recurring bonus this claim, try again
        // next time" without losing the user's mining reward (already
        // paid by OSGLPMining before this hook runs).
        pool.distribute(user, bonus, CAT_REFERRAL);
        emit RecurringBonusPaid(user, bonus, recurringBps);
    }

    // ====================== INTERNAL -- RANK / MILESTONE ======================

    function _checkRankProgress(address user) internal {
        uint8 rank = getCurrentRank(user);
        uint8 nextUnpaidRank = highestRankPaid[user] >= 5 ? 5 : highestRankPaid[user] + 1;

        if (rank > highestRankPaid[user]) {
            if (qualifiedSince[user] == 0) {
                qualifiedSince[user] = block.timestamp;
            }
            if (block.timestamp >= qualifiedSince[user] + MAINTAIN_PERIOD) {
                uint256 bonusAmount = (milestoneBaseAmount * rankBonusBps[nextUnpaidRank]) / BPS_DENOM;
                milestoneBonusOwed[user] += bonusAmount;
                highestRankPaid[user] = nextUnpaidRank;
                qualifiedSince[user] = 0;
                emit MilestoneBonusAccrued(user, nextUnpaidRank, bonusAmount);
            }
        } else if (rank < nextUnpaidRank && qualifiedSince[user] != 0) {
            qualifiedSince[user] = 0; // dropped below the rank being timed -- reset
        }
    }

    function getCurrentRank(address user) public view returns (uint8) {
        if (poolCapacityLp == 0) return 0;
        uint256 liqBps = (teamLiquidityLp[user] * BPS_DENOM) / poolCapacityLp;

        for (uint8 r = 5; r >= 1; r--) {
            if (liqBps >= rankThresholdBps[r]) return r;
            if (r == 1) break; // avoid uint8 underflow
        }
        return 0;
    }

    /// Live, cumulative recurring bonus in bps: +100 (1%) per qualified
    /// rank level, up to MAX_RECURRING_BPS. Currently rank is capped at
    /// 5 (A5) so this is already mathematically <= 500 bps -- the min()
    /// below is defense-in-depth in case rank logic ever changes.
    function getRecurringBonusBps(address user) public view returns (uint256) {
        uint256 bps = uint256(getCurrentRank(user)) * 100;
        return bps > MAX_RECURRING_BPS ? MAX_RECURRING_BPS : bps;
    }

    // ====================== INTERNAL -- LEVEL COMMISSION ======================

    function _accrueLevelCommission(address depositor, uint256 rewardBasis) internal {
        (address l1, address l2, address l3, address l4, address l5) =
            staking.getReferralChain(depositor);
        address[5] memory chain = [l1, l2, l3, l4, l5];

        for (uint8 i = 0; i < 5; i++) {
            address ref = chain[i];
            if (ref == address(0)) break;
            uint256 commission = (rewardBasis * levelCommissionBps[i + 1]) / BPS_DENOM;
            if (commission > 0) {
                levelCommissionOwed[ref] += commission;
                emit LevelCommissionAccrued(ref, depositor, commission, i + 1);
            }
        }
    }

    // ====================== ADMIN -- MANUAL PAYOUT ======================
    // Mirrors OSGReferralDistributor.sol's owner-gated, fail-loud pattern.

    function owed(address user) public view returns (uint256) {
        uint256 lcOwed = levelCommissionOwed[user] > levelCommissionPaid[user]
            ? levelCommissionOwed[user] - levelCommissionPaid[user] : 0;
        uint256 mbOwed = milestoneBonusOwed[user] > milestoneBonusPaid[user]
            ? milestoneBonusOwed[user] - milestoneBonusPaid[user] : 0;
        return lcOwed + mbOwed;
    }

    function payReferral(address user) external onlyOwner nonReentrant whenNotPaused {
        uint256 amount = owed(user);
        require(amount > 0, "nothing owed");
        require(amount <= MAX_SINGLE_ALLOC, "over cap: split into multiple pays");
        levelCommissionPaid[user] = levelCommissionOwed[user];
        milestoneBonusPaid[user]  = milestoneBonusOwed[user];
        pool.distribute(user, amount, CAT_REFERRAL); // fail-loud by design
        emit ReferralPaid(user, amount, msg.sender);
    }

    // ====================== VIEW -- HEALTH ======================

    function isWiredForReferral() public view returns (bool) {
        return pool.distributorType(address(this)) == CAT_REFERRAL
            && pool.distributorActive(address(this));
    }

    function readyForProduction() external view returns (bool ready, string memory reason) {
        if (!isWiredForReferral())     return (false, "not registered as category-3 distributor");
        if (paused())                  return (false, "referral contract paused");
        if (pool.paused())             return (false, "RewardPool paused");
        if (pool.emissionStopped())    return (false, "emission stopped");
        if (poolCapacityLp == 0)       return (false, "poolCapacityLp not set");
        if (lpMining == address(0))    return (false, "lpMining not set");
        return (true, "ready");
    }

    // ====================== ADMIN -- CONFIG ======================

    /// Set (or repoint) the OSGLPMining contract allowed to call the
    /// hooks. Owner-only, callable anytime (e.g. right after deploying
    /// both contracts, or if LPMining is ever redeployed).
    function setLPMining(address _lpMining) external onlyOwner {
        require(_lpMining.code.length > 0, "lpMining not contract");
        lpMining = _lpMining;
        emit LPMiningUpdated(_lpMining);
    }

    /// Call this after any T1 (or active tier) capacity change on
    /// OSGLPMining, so rank thresholds keep scaling correctly.
    function setPoolCapacityLp(uint256 newCapacityLp) external onlyOwner {
        require(newCapacityLp > 0, "zero capacity");
        poolCapacityLp = newCapacityLp;
        emit PoolCapacityUpdated(newCapacityLp);
    }

    function setMilestoneBaseAmount(uint256 newAmount) external onlyOwner {
        milestoneBaseAmount = newAmount;
        emit MilestoneBaseAmountUpdated(newAmount);
    }

    function setRankConfig(uint8 rank, uint256 thresholdBps, uint256 bonusBps) external onlyOwner {
        require(rank >= 1 && rank <= 5, "bad rank");
        rankThresholdBps[rank] = thresholdBps;
        rankBonusBps[rank] = bonusBps;
        emit RankConfigUpdated(rank, thresholdBps, bonusBps);
    }

    /// Sets one level's commission bps, but ALWAYS validates that the
    /// sum of all 5 levels stays within MAX_TOTAL_LEVEL_COMMISSION_BPS
    /// (15%) -- so an owner config mistake can never push total
    /// commission above the safety ceiling. Bounded 5-iteration loop,
    /// gas-safe regardless of team size.
    function setLevelCommissionBps(uint8 level, uint16 bps) external onlyOwner {
        require(level >= 1 && level <= 5, "bad level");
        uint256 total = 0;
        for (uint8 i = 1; i <= 5; i++) {
            total += (i == level) ? uint256(bps) : uint256(levelCommissionBps[i]);
        }
        require(total <= MAX_TOTAL_LEVEL_COMMISSION_BPS, "total level commission exceeds 15% cap");
        levelCommissionBps[level] = bps;
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// Recover tokens sent here by mistake -- this contract holds no
    /// protocol funds of its own (payouts are minted fresh by RewardPool).
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0) && amount > 0, "bad args");
        IERC20(token).safeTransfer(to, amount);
    }

    function version() external pure returns (string memory) {
        return "OSGLPReferral v1 (draft, companion to OSGLPMining)";
    }
}
