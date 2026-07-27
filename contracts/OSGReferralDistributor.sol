// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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

interface IOSGStaking {
    function pendingReferralReward(address user) external view returns (uint256);
}

/**
 * @title OSGReferralDistributor v1
 * @notice Owner-gated bridge: pays accrued referral by MINTING from the
 *         RewardPool referral quota (category 3). Staking.referralReserve is
 *         never used → treasury / vesting / team 460k untouched.
 *
 *  ╔══════════════════════════════════════════════════════════════════╗
 *  ║  IMPORTANT — OPERATIONAL RULES (contract CANNOT enforce these):   ║
 *  ║   1. After deploy, governance MUST call                          ║
 *  ║      RewardPool.setDistributor(thisAddress, 3).                  ║
 *  ║   2. Staking.fundReferralReserve()  MUST NEVER be called again.  ║
 *  ║   3. Staking.distributeReferralReward() MUST NEVER be used again.║
 *  ║      referralReserve MUST remain ZERO forever, so the legacy     ║
 *  ║      payout path auto-reverts and the two ledgers never diverge. ║
 *  ║   All referral payouts go ONLY through this contract.            ║
 *  ╚══════════════════════════════════════════════════════════════════╝
 *
 *  DESIGN (deliberately minimal — funds safety first):
 *   - Pays only (accrued − alreadyPaid). No paid[] setter → no double-pay.
 *   - distribute() is NOT in try/catch ON PURPOSE: a failed mint must revert
 *     the whole tx so paid[user] is NOT advanced and owed stays claimable.
 *   - RewardPool per-block cooldown ⇒ ONE user per tx (batch = N sequential txs).
 */
contract OSGReferralDistributor is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    uint8   public constant CAT_REFERRAL = 3;
    uint256 public constant MAX_SINGLE   = 10_000 * 1e18; // mirrors RewardPool

    IOSGRewardPool public immutable pool;
    IOSGStaking    public immutable staking;

    bool public referralEnabled = true;             // granular freeze (≠ pause)

    mapping(address => uint256) public paid;        // cumulative credited here
    mapping(address => bool)    public paidBefore;  // analytics
    uint256 public totalPaid;
    uint256 public totalUsersPaid;                  // analytics

    event ReferralCredited(address indexed user, uint256 amount, uint256 paidTotal, address indexed by);
    event ReferralToggled(bool enabled, address indexed by);

    constructor(address _pool, address _staking, address _owner) Ownable(_owner) {
        require(_pool.code.length    > 0, "pool not contract");
        require(_staking.code.length > 0, "staking not contract");
        pool    = IOSGRewardPool(_pool);
        staking = IOSGStaking(_staking);
    }

    // ── internal payout (single source of truth) ──
    function _credit(address user, uint256 amount) internal {
        require(user != address(0), "Invalid user");          // #1
        require(isWired(),            "distributor not wired"); // #2
        require(!pool.paused(),       "pool paused");           // #3
        require(!pool.emissionStopped(), "emission stopped");   // #4

        if (!paidBefore[user]) {
            paidBefore[user] = true;
            totalUsersPaid  += 1;
        }
        paid[user] += amount;               // CEI: state before external call
        totalPaid  += amount;
        pool.distribute(user, amount, CAT_REFERRAL); // fail-loud by design
        emit ReferralCredited(user, amount, paid[user], msg.sender);
    }

    // ── core ──
    function owed(address user) public view returns (uint256) {
        uint256 accrued = staking.pendingReferralReward(user);
        uint256 already = paid[user];
        return accrued > already ? accrued - already : 0;
    }

    function payReferral(address user) external onlyOwner nonReentrant whenNotPaused {
        require(referralEnabled, "referral frozen");
        uint256 amount = owed(user);
        require(amount > 0,           "nothing owed");
        require(amount <= MAX_SINGLE, "over 10k: use payReferralAmount");
        _credit(user, amount);
    }

    function payReferralAmount(address user, uint256 amount) external onlyOwner nonReentrant whenNotPaused {
        require(referralEnabled, "referral frozen");
        require(amount > 0,           "zero amount");
        require(amount <= owed(user), "exceeds owed");
        require(amount <= MAX_SINGLE, "exceeds single-call limit");
        _credit(user, amount);
    }

    // ── dashboard / health (read-only) ──
    function isWired() public view returns (bool) {
        return pool.distributorType(address(this)) == CAT_REFERRAL
            && pool.distributorActive(address(this));
    }

    /// referral OSG still distributable TODAY from the emission quota
    function remainingReferralEmission() external view returns (uint256) {
        ( , , , , , uint256 referralAvail, ) = pool.getTodayStats();
        return referralAvail;
    }

    function health() external view returns (
        bool wired, bool enabled, bool poolPaused, bool emissionStopped
    ) {
        wired           = isWired();
        enabled         = referralEnabled;
        poolPaused      = pool.paused();
        emissionStopped = pool.emissionStopped();
    }

    /// one-call green/red status for dashboards
    function readyForProduction() external view returns (bool ready, string memory reason) {
        if (!isWired())            return (false, "not registered as category-3 distributor");
        if (paused())              return (false, "distributor paused");
        if (!referralEnabled)      return (false, "referral frozen");
        if (pool.paused())         return (false, "RewardPool paused");
        if (pool.emissionStopped())return (false, "emission stopped");
        return (true, "ready");
    }

    function version() external pure returns (string memory) {
        return "OSGReferralDistributor v1";
    }

    // ── admin ──
    function toggleReferral(bool _on) external onlyOwner {
        referralEnabled = _on;
        emit ReferralToggled(_on, msg.sender);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// Recover tokens sent here by mistake (contract holds no protocol funds).
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0) && amount > 0, "bad args");
        IERC20(token).safeTransfer(to, amount);
    }
}
