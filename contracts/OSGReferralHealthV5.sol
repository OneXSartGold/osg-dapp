// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/*
 * ======================================================================
 *  OSGReferralHealth v2  --  for OSGReferral v5
 * ======================================================================
 *
 *  WHY THIS IS A NEW DEPLOYMENT RATHER THAN A REPOINTING
 *  -----------------------------------------------------
 *  The v1 Health held `IOSGReferralCore public immutable core`, set once
 *  in its constructor. There is no setter and there never was one, so
 *  the moment the ledger address changes this contract has to be built
 *  again. The same is true of OSGReferralLens.
 *
 *  WHAT WAS DROPPED, AND WHY
 *  -------------------------
 *  v1 carried nine functions. App.jsx calls exactly two of them --
 *  registerHealth() and programmeStats() -- and the other seven were
 *  never wired to a screen. They are not kept here.
 *
 *  That is not only a size decision. Three of them would have been
 *  WRONG against v5 rather than merely unused:
 *
 *    previewRank / rankProgress  read tiers() as three fields. v5's
 *    Tier struct has six, so the getter returns six words and an
 *    interface expecting three would silently decode the wrong ones --
 *    directsNeeded, selfStakeNeeded and stakeNeeded read as
 *    directsNeeded, stakeNeeded and monthlyPayout. No revert, just
 *    wrong numbers on a rank screen.
 *
 *    Both also loop `for (uint8 r = 3; r > 0; r--)` and return
 *    uint256[3]. v5 runs maxRank = 5, so R4 and R5 would be invisible.
 *
 *  A wrong figure that looks authoritative is worse than a missing one,
 *  so they are gone rather than half-fixed. If a rank screen wants them
 *  later they can be written against v5's real shape and deployed on
 *  their own -- this contract holds no state, so replacing it costs
 *  nothing.
 *
 *  THE ONE THING THAT HAD TO CHANGE
 *  --------------------------------
 *  v1's programmeStats() called core.isWiredForReferral(). v4.2 had it:
 *
 *      function isWiredForReferral() public view returns (bool) {
 *          return pool.distributorType(address(this)) == CAT_REFERRAL
 *              && pool.distributorActive(address(this));
 *      }
 *
 *  v5 does not. The check itself is still available -- it is a question
 *  about RewardPool, not about the ledger -- so it is asked here
 *  directly, with address(core) in place of address(this). Same answer,
 *  same meaning, and the eight return values App.jsx destructures do
 *  not move.
 *
 *  Stateless and view-only, as before.
 * ======================================================================
 */

interface IOSGReferralCore {
    function nativeReferrer(address user) external view returns (address);
    function stakeOf(address user) external view returns (uint256);
    function minDirectStake() external view returns (uint256);
    function minReferrerStake() external view returns (uint256);
    function totalLevelBps() external view returns (uint256);
    function stakeSourceCount() external view returns (uint256);
    function seedStatus() external view returns (bool open, uint256 secondsLeft);
    function paused() external view returns (bool);
    function staking() external view returns (address);
    function pool() external view returns (address);
}

interface IOSGStakingRead {
    function users(address user) external view returns (
        uint256 staked, uint256 rewardDebt, uint256 pendingHarvest,
        uint256 unstakeRequestAt, uint256 totalEarned, uint256 stakedAt,
        address referrer, uint256 totalReferrals, uint256 totalReferralEarned,
        uint256 totalTeamVolume, uint256 teamBonusEarned
    );
}

interface IOSGRewardPoolRead {
    function getTodayStats() external view returns (
        uint256 stakingUsedAmt, uint256 miningUsedAmt, uint256 referralUsedAmt,
        uint256 stakingAvail, uint256 miningAvail, uint256 referralAvail,
        uint256 dailyBase
    );
    function distributorType(address) external view returns (uint8);
    function distributorActive(address) external view returns (bool);
}

contract OSGReferralHealth {

    /// Mirrors OSGReferral.CAT_REFERRAL. The category a referral
    /// distributor has to be registered under in RewardPool.
    uint8 public constant CAT_REFERRAL = 3;

    IOSGReferralCore public immutable core;

    constructor(address _core) {
        require(_core.code.length > 0, "core not contract");
        core = IOSGReferralCore(_core);
    }

    /// Whether the ledger is registered with RewardPool as a live
    /// category-3 distributor. v4.2 answered this itself; v5 does not,
    /// so the question goes to the pool directly.
    function isWiredForReferral() public view returns (bool) {
        IOSGRewardPoolRead p = IOSGRewardPoolRead(core.pool());
        return p.distributorType(address(core)) == CAT_REFERRAL
            && p.distributorActive(address(core));
    }

    /// Why a register() would fail. Returns the reason instead of
    /// reverting, so a UI can explain the problem before the wallet
    /// ever signs.
    function registerHealth(address user, address referrer)
        external
        view
        returns (bool ok, string memory reason)
    {
        if (referrer == address(0))                  return (false, "zero referrer");
        if (referrer == user)                        return (false, "cannot refer yourself");
        if (core.nativeReferrer(user) != address(0)) return (false, "already registered");

        (, , , , , , address legacy, , , , ) = IOSGStakingRead(core.staking()).users(user);
        if (legacy != address(0))                    return (false, "already has an upline in Staking");

        if (core.stakeOf(referrer) < core.minReferrerStake())
            return (false, "referrer stake is below the minimum");

        if (core.paused())                           return (false, "referral contract paused");
        return (true, "ready");
    }

    /// The programme-wide numbers a dashboard header wants. Same eight
    /// values, in the same order, as the v4.2 Health returned.
    function programmeStats()
        external
        view
        returns (
            uint256 totalLevelBps,
            uint256 referralBudgetToday,
            uint256 minDirectStake,
            uint256 minReferrerStake,
            uint256 sourceCount,
            bool    wired,
            bool    paused,
            bool    seedOpen
        )
    {
        totalLevelBps    = core.totalLevelBps();
        minDirectStake   = core.minDirectStake();
        minReferrerStake = core.minReferrerStake();
        sourceCount      = core.stakeSourceCount();
        wired            = isWiredForReferral();
        paused           = core.paused();
        (seedOpen, )     = core.seedStatus();
        ( , , , , , referralBudgetToday, ) = IOSGRewardPoolRead(core.pool()).getTodayStats();
    }

    function version() external pure returns (string memory) {
        return "OSGReferralHealth v2 (for OSGReferral v5)";
    }
}
