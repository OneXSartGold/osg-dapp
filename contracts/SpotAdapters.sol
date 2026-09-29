// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/**
 *  Read-only adapters that let OSGSpotReward read the existing Term
 *  Staking and LP Mining contracts through ISpotSource. They hold no
 *  funds and have no owner; each is fixed to one contract at deploy.
 */

interface ITermStakingSpot {
    function positionCount(address user) external view returns (uint256);
    function positions(address user, uint256 i) external view returns (
        uint256 amount, uint256 cap, uint256 rewardDebt, uint256 rewardPaid,
        uint256 unpaid, uint256 startTime, bool capped, bool closed
    );
}

interface ILPMiningSpot {
    function positionCount(address user) external view returns (uint256);
    function positions(address user, uint256 i) external view returns (
        uint256 lpAmount, uint256 osgValue, uint256 rewardDebt, uint256 rewardPaid,
        uint256 unpaid, uint256 startTime, bool closed
    );
}

/// Term Staking: amount = principal.
contract SpotAdapterTerm {
    ITermStakingSpot public immutable term;

    constructor(address _term) {
        require(_term.code.length > 0, "term not contract");
        term = ITermStakingSpot(_term);
    }

    function spotUnderlying() external view returns (address) {
        return address(term);
    }

    function spotPositionCount(address user) external view returns (uint256) {
        return term.positionCount(user);
    }

    function spotPosition(address user, uint256 index)
        external view returns (uint256 amount, uint256 startTime, bool open)
    {
        (uint256 a, , , , , uint256 st, , bool closed) = term.positions(user, index);
        return (a, st, !closed);
    }
}

/// LP Mining: amount = osgValue (OSG-denominated size fixed at deposit,
/// about 2x the OSG added). OSGSpotReward applies the source's base %
/// (50% = the OSG actually added).
contract SpotAdapterLP {
    ILPMiningSpot public immutable lp;

    constructor(address _lp) {
        require(_lp.code.length > 0, "lp not contract");
        lp = ILPMiningSpot(_lp);
    }

    function spotUnderlying() external view returns (address) {
        return address(lp);
    }

    function spotPositionCount(address user) external view returns (uint256) {
        return lp.positionCount(user);
    }

    function spotPosition(address user, uint256 index)
        external view returns (uint256 amount, uint256 startTime, bool open)
    {
        (, uint256 v, , , , uint256 st, bool closed) = lp.positions(user, index);
        return (v, st, !closed);
    }
}
