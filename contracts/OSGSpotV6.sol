// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/*
 * ======================================================================
 *  OSGSpotV6 -- spot bonus rules for OSGReferral v6
 * ======================================================================
 *
 *  A one-time bonus to the DIRECT sponsor of each new stake:
 *      amount = position amount x source base % x rate, capped per stake
 *
 *  This contract holds no OSG and cannot pay anyone by itself. It checks
 *  a claim, records each stake as paid, and asks OSGReferralV6.paySpot()
 *  to pay. paySpot pays only inside the SPOT share of the referral pot,
 *  only while spot is switched on, and reverts when today's room is
 *  short -- in which case this whole call reverts, nothing is marked
 *  paid, and the stakes can be claimed later.
 *
 *  All spot SETTINGS (rate, stop rank, minimum own stake, per-stake cap,
 *  on/off) are read from OSGReferralV6, so one owner transaction there
 *  changes them together with every other referral setting.
 *
 *  Rules carried over from the v1 spot contract:
 *   - only the staker's direct sponsor can claim, and only for a bond
 *     stored in OSGReferralV6 (registered there, or seeded from v5 /
 *     OSGStaking) -- so every direct that earns spot also counts toward
 *     the sponsor's stop rank;
 *   - the sponsor must hold minSelfStake of their own;
 *   - only stakes that started at or after spotStartAt, and are still
 *     open when claimed, count;
 *   - each stake pays once, keyed by (underlying stake contract, staker,
 *     position index); two sources for one underlying are refused;
 *   - a sponsor stops earning once they reach stopRank. The moment this
 *     contract first sees it is stored for good; stakes that started
 *     at or before that moment are still paid. "Reached" means the stored
 *     rank, or the stop-rank conditions met by OSGReferralV6's own running
 *     counters (qualified directs, their cached stake, own stake) -- never
 *     a list the caller supplies, and never the bare number of wallets
 *     registered under the sponsor.
 *
 *  No end date. The owner switches spot off with OSGReferralV6.
 * ======================================================================
 */

interface ISpotSourceV6 {
    function spotUnderlying() external view returns (address);
    function spotPositionCount(address user) external view returns (uint256);
    function spotPosition(address user, uint256 index)
        external view returns (uint256 amount, uint256 startTime, bool open);
}

interface IReferralV6ForSpot {
    function referrerOf(address user) external view returns (address);
    function nativeReferrer(address user) external view returns (address);
    function stakeOf(address user) external view returns (uint256);
    function rankOf(address user) external view returns (uint8);
    function directReferrals(address user) external view returns (uint256);
    function teamStake(address user) external view returns (uint256);
    function tiers(uint256 rank) external view returns (
        uint256 directsNeeded, uint256 selfStakeNeeded, uint256 teamStakeNeeded, uint256 monthlyPayout
    );
    function spot() external view returns (
        uint16 rateBps, uint8 stopRank, bool enabled, uint256 minSelfStake, uint256 maxPerStake
    );
    function paySpot(address to, uint256 amount) external;
}

contract OSGSpotV6 is Ownable2Step, ReentrancyGuard {

    uint256 public constant BPS         = 10_000;
    uint256 public constant MAX_SOURCES = 6;
    uint256 public constant MAX_BATCH   = 20;
    /// RewardPool.MAX_SINGLE_ALLOC: one claim never asks for more.
    uint256 public constant MAX_PER_CALL = 10_000e18;

    IReferralV6ForSpot public immutable referral;
    uint256            public immutable spotStartAt;
    uint256            public immutable seedDeadline;

    struct Source { ISpotSourceV6 src; address underlying; uint16 baseBps; bool active; }
    Source[] public sources;
    mapping(address => bool) public isUnderlying;

    /// underlying stake contract => staker => position index
    mapping(address => mapping(address => mapping(uint256 => bool))) public paid;
    mapping(address => uint256) public stopAt;
    mapping(address => uint256) public paidTo;
    uint256 public totalPaid;
    bool public seedLocked;

    event SpotPaid(address indexed sponsor, uint256 indexed sourceId, address indexed staker, uint256 index, uint256 amount);
    event Claimed(address indexed sponsor, uint256 total, uint256 count);
    event Stopped(address indexed sponsor, uint256 at);
    event SourceAdded(uint256 indexed id, address src, address underlying, uint16 baseBps);
    event SourceUpdated(uint256 indexed id, uint16 baseBps, bool active);
    event SeedingLocked();
    event StopCleared(address indexed sponsor);

    error SpotOff();
    error BadLength();
    error BadSource();
    error SourceOff();
    error NotYourDirect();
    error NotEligible();
    error BeforeStart();
    error AfterRank();
    error PositionClosed();
    error AlreadyPaid();
    error ZeroAmount();
    error DuplicateSource();
    error UnderlyingChanged();
    error OutOfBounds();
    error SeedingClosed();
    error RenounceDisabled();
    error TooMuch();

    constructor(address _referral, address _owner, uint256 _spotStartAt, uint256 _seedDays) Ownable(_owner) {
        if (_referral.code.length == 0) revert BadSource();
        if (_seedDays == 0 || _seedDays > 90) revert OutOfBounds();
        referral     = IReferralV6ForSpot(_referral);
        spotStartAt  = _spotStartAt;
        seedDeadline = block.timestamp + _seedDays * 1 days;
    }

    // ============================== claim ==============================

    function claimSpot(
        uint256[] calldata ids,
        address[] calldata stakers,
        uint256[] calldata indexes
    ) external nonReentrant returns (uint256 total) {
        (uint16 rate, uint8 stopRank, bool enabled, uint256 minSelf, uint256 maxPer) = referral.spot();
        if (!enabled) revert SpotOff();
        uint256 n = ids.length;
        if (n == 0 || n > MAX_BATCH || stakers.length != n || indexes.length != n) revert BadLength();

        address sponsor = msg.sender;
        if (referral.stakeOf(sponsor) < minSelf) revert NotEligible();

        uint256 until = stopAt[sponsor];
        if (until == 0 && _reached(sponsor, stopRank)) {
            // Record the stop and carry on: stakes that started at or
            // before this moment are still paid in this same call.
            until = block.timestamp;
            stopAt[sponsor] = until;
            emit Stopped(sponsor, until);
        }

        for (uint256 i = 0; i < n; i++) {
            uint256 amt = _checkAndMark(ids[i], stakers[i], indexes[i], sponsor, until, rate, maxPer);
            total += amt;
            emit SpotPaid(sponsor, ids[i], stakers[i], indexes[i], amt);
        }
        if (total > MAX_PER_CALL) revert TooMuch();
        paidTo[sponsor] += total;
        totalPaid       += total;

        // Reverts (and with it every mark above) if spot is off or the
        // day's spot room is short.
        referral.paySpot(sponsor, total);
        emit Claimed(sponsor, total, n);
    }

    /// Record that a sponsor reached the stop rank. Anyone may call; it
    /// can only close the window.
    function checkRank(address sponsor) external returns (bool) {
        if (stopAt[sponsor] != 0) return true;
        (, uint8 stopRank, , , ) = referral.spot();
        if (_reached(sponsor, stopRank)) {
            stopAt[sponsor] = block.timestamp;
            emit Stopped(sponsor, block.timestamp);
            return true;
        }
        return false;
    }

    // ============================== views ==============================

    /// What a stake would pay `sponsor` now, and why not if zero.
    /// 0 ok, 1 spot off, 2 bad source, 3 source off, 4 not your direct,
    /// 5 before start, 6 after rank, 7 closed, 8 already paid,
    /// 9 zero amount, 10 sponsor stake too low.
    function quote(address sponsor, uint256 id, address staker, uint256 index)
        external view returns (uint256 amount, uint8 reason)
    {
        (uint16 rate, uint8 stopRank, bool enabled, uint256 minSelf, uint256 maxPer) = referral.spot();
        if (!enabled) return (0, 1);
        if (referral.stakeOf(sponsor) < minSelf) return (0, 10);
        uint256 until = stopAt[sponsor];
        if (until == 0 && _reached(sponsor, stopRank)) until = block.timestamp;
        if (id >= sources.length) return (0, 2);
        Source memory s = sources[id];
        if (!s.active) return (0, 3);
        if (referral.nativeReferrer(staker) != sponsor) return (0, 4);
        if (s.src.spotUnderlying() != s.underlying) return (0, 2);
        (uint256 posAmt, uint256 st, bool open) = s.src.spotPosition(staker, index);
        if (st < spotStartAt) return (0, 5);
        if (until != 0 && st > until) return (0, 6);
        if (!open) return (0, 7);
        if (paid[s.underlying][staker][index]) return (0, 8);
        amount = _amount(posAmt, s.baseBps, rate, maxPer);
        if (amount == 0) return (0, 9);
        return (amount, 0);
    }

    function sourcesCount() external view returns (uint256) { return sources.length; }

    // ============================== owner ==============================

    function addSource(address src, uint16 baseBps) external onlyOwner {
        if (src.code.length == 0) revert BadSource();
        if (sources.length >= MAX_SOURCES) revert OutOfBounds();
        if (baseBps == 0 || baseBps > BPS) revert OutOfBounds();
        address u = ISpotSourceV6(src).spotUnderlying();
        if (u == address(0) || u.code.length == 0) revert BadSource();
        if (isUnderlying[u]) revert DuplicateSource();
        isUnderlying[u] = true;
        sources.push(Source(ISpotSourceV6(src), u, baseBps, true));
        emit SourceAdded(sources.length - 1, src, u, baseBps);
    }

    /// Base % and on/off for one source. Switching a source off only
    /// delays its stakes; nothing is lost.
    function setSource(uint256 id, uint16 baseBps, bool active) external onlyOwner {
        if (id >= sources.length) revert BadSource();
        if (baseBps == 0 || baseBps > BPS) revert OutOfBounds();
        sources[id].baseBps = baseBps;
        sources[id].active  = active;
        emit SourceUpdated(id, baseBps, active);
    }

    /// Undo a stop that was recorded in error (for example before the
    /// tree was fully seeded).
    function clearStop(address sponsor) external onlyOwner {
        stopAt[sponsor] = 0;
        emit StopCleared(sponsor);
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ============================== migration ==============================

    modifier seedOpen() {
        if (seedLocked || block.timestamp > seedDeadline) revert SeedingClosed();
        _;
    }

    /// Stakes the v1 spot contract already paid, keyed by underlying.
    function seedPaid(address[] calldata underlyings, address[] calldata stakers, uint256[] calldata indexes)
        external onlyOwner seedOpen
    {
        uint256 n = underlyings.length;
        if (n != stakers.length || n != indexes.length) revert BadLength();
        for (uint256 i = 0; i < n; i++) paid[underlyings[i]][stakers[i]][indexes[i]] = true;
    }

    /// Sponsors' stop moments and running totals from the v1 contract.
    function seedSponsors(address[] calldata sponsors, uint256[] calldata stops, uint256[] calldata totals)
        external onlyOwner seedOpen
    {
        uint256 n = sponsors.length;
        if (n != stops.length || n != totals.length) revert BadLength();
        for (uint256 i = 0; i < n; i++) {
            stopAt[sponsors[i]] = stops[i];
            totalPaid = totalPaid - paidTo[sponsors[i]] + totals[i];
            paidTo[sponsors[i]] = totals[i];
        }
    }

    function lockSeeding() external onlyOwner {
        seedLocked = true;
        emit SeedingLocked();
    }

    // ============================== internal ==============================

    function _checkAndMark(
        uint256 id, address staker, uint256 index, address sponsor, uint256 until, uint16 rate, uint256 maxPer
    ) internal returns (uint256 amt) {
        if (id >= sources.length) revert BadSource();
        Source memory s = sources[id];
        if (!s.active) revert SourceOff();
        if (referral.nativeReferrer(staker) != sponsor) revert NotYourDirect();
        if (s.src.spotUnderlying() != s.underlying) revert UnderlyingChanged();
        (uint256 posAmt, uint256 st, bool open) = s.src.spotPosition(staker, index);
        if (st < spotStartAt) revert BeforeStart();
        if (until != 0 && st > until) revert AfterRank();
        if (!open) revert PositionClosed();
        if (paid[s.underlying][staker][index]) revert AlreadyPaid();
        amt = _amount(posAmt, s.baseBps, rate, maxPer);
        if (amt == 0) revert ZeroAmount();
        paid[s.underlying][staker][index] = true;
    }

    function _amount(uint256 posAmt, uint16 baseBps, uint16 rate, uint256 maxPer) internal pure returns (uint256 amt) {
        amt = (posAmt * baseBps * rate) / (BPS * BPS);
        if (amt > maxPer) amt = maxPer;
    }

    /// Tier requirements only rise with rank (enforced by the rules
    /// contract), so meeting the stop tier itself is the test.
    function _reached(address sponsor, uint8 stopRank) internal view returns (bool) {
        if (referral.rankOf(sponsor) >= stopRank) return true;
        (uint256 d, uint256 self, uint256 team, ) = referral.tiers(stopRank);
        return referral.directReferrals(sponsor) >= d
            && referral.teamStake(sponsor) >= team
            && referral.stakeOf(sponsor) >= self;
    }
}
