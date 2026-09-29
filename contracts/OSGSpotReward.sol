// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/**
 *  OSGSpotReward
 *  ─────────────
 *  A one-time reward for the DIRECT sponsor of each new stake, paid from
 *  the Treasury airdrop pool.
 *
 *  THE RULES
 *   - Only the staker's direct sponsor (v5 referrerOf) can claim it.
 *   - The sponsor must hold at least `minSelfStake` of their own stake,
 *     measured by Referral v5 stakeOf (every stake source v5 counts).
 *   - Every stake counts from the sponsor's first direct onward, as long
 *     as it started after `startAt` and is still open.
 *   - Amount = position amount x source base % x rateBps.
 *   - Each stake pays once: paid[source][staker][index].
 *   - A sponsor stops earning once they reach `stopRank` (Rank 2). The
 *     moment this contract first sees that rank is stored for good.
 *     Stakes that started before that moment can still be claimed;
 *     stakes after it cannot.
 *
 *  WHERE STAKES COME FROM
 *   Stake contracts are registered as sources. A source answers
 *   ISpotSource. Existing contracts (Term, LP) are read through small
 *   adapters; new contracts can implement ISpotSource directly. Sources
 *   can be added or switched off. Payments are recorded against the
 *   UNDERLYING stake contract, and two sources for the same underlying
 *   contract are refused, so one stake can never be paid twice.
 *
 *  MONEY
 *   Paid by Treasury.spendAirdrop. That call pays what the pool holds
 *   and does not revert when it is short, so this contract requires the
 *   FULL amount to arrive; otherwise the whole claim reverts and the
 *   stakes stay unpaid, to be claimed once the pool is refilled.
 *   A per-stake ceiling and a daily ceiling bound what can leave.
 *
 *  ROLES
 *   owner    -- settings, sources, start, unpause (Ownable2Step).
 *   guardian -- pause only (address(0) = no guardian; owner can always pause).
 *
 *  CHANGES AFTER START
 *   Rate, minimum self stake, per-stake ceiling, stop rank and a source's
 *   base % can only change through propose -> wait CHANGE_DELAY (48 h) ->
 *   apply, so sponsors see every change coming. Before start they apply
 *   at once. The daily ceiling changes at once (it only delays payments,
 *   it never removes them). Pausing, or switching one source off, is
 *   immediate: both are emergency stops that delay, not cancel.
 *   A change can only be applied while the contract is running and at
 *   least CHANGE_DELAY after the last unpause / source re-activation, so
 *   a pause can never eat the sponsors' notice window. A source cannot be
 *   switched off while a change is pending (use pause for emergencies).
 *   Only one change of each kind may be pending; cancel to re-propose.
 */

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ISpotSource {
    /// The stake contract this source reads. A contract that implements
    /// ISpotSource itself returns address(this). Two sources may never
    /// share one, and payments are recorded against it.
    function spotUnderlying() external view returns (address);
    function spotPositionCount(address user) external view returns (uint256);
    /// amount in OSG terms, when it started, and whether it is still open.
    function spotPosition(address user, uint256 index)
        external view returns (uint256 amount, uint256 startTime, bool open);
}

interface IReferralV5Spot {
    function referrerOf(address user) external view returns (address);
    function stakeOf(address user) external view returns (uint256);
    function rankOf(address user) external view returns (uint8);
    function currentRank(address user, address[] calldata directs) external view returns (uint8);
    function childrenSlice(address user, uint256 offset, uint256 limit)
        external view returns (address[] memory page, uint256 total);
    function staking() external view returns (address);
}

interface ILegacyStakingSpot {
    function getDirectReferrals(address user) external view returns (address[] memory);
}

interface ITreasurySpot {
    function spendAirdrop(address to, uint256 amount) external returns (uint256 paid);
}

contract OSGSpotReward is Ownable2Step, Pausable, ReentrancyGuard {

    // ─────────────────────────── constants ───────────────────────────
    uint256 public constant BPS            = 10_000;
    uint256 public constant MAX_RATE_BPS   = 500;          // 5% ceiling on the rate
    uint256 public constant MAX_SOURCES    = 10;
    uint256 public constant MAX_BATCH      = 20;
    uint256 public constant MAX_DIRECTS    = 50;           // v5 MAX_DIRECTS_PER_CALL
    uint256 public constant MAX_SELF_STAKE = 10_000e18;    // bound on minSelfStake
    uint256 public constant MAX_PER_CLAIM  = 5_000e18;     // bound on maxPerClaim
    uint256 public constant MAX_DAILY      = 50_000e18;    // bound on dailyCap
    uint256 public constant CHANGE_DELAY   = 48 hours;
    uint256 public constant PAGE           = 64;           // native directs read per call

    // ─────────────────────────── wiring ──────────────────────────────
    IReferralV5Spot    public immutable referral;
    ILegacyStakingSpot public immutable legacy;
    ITreasurySpot      public immutable treasury;

    // ─────────────────────────── settings ────────────────────────────
    uint256 public rateBps      = 300;        // 3%
    uint256 public minSelfStake = 200e18;
    uint8   public stopRank     = 2;
    uint256 public maxPerClaim  = 300e18;     // per stake
    uint256 public dailyCap     = 1_000e18;   // all sponsors together, per UTC day
    uint256 public startAt;                   // 0 = not started
    address public guardian;

    struct Source {
        ISpotSource src;
        uint16      baseBps;   // share of the position amount the rate applies to
        bool        active;
    }
    Source[] public sources;
    mapping(address => bool) public isSourceAddr;
    mapping(address => bool) public isUnderlying;
    mapping(uint256 => address) public underlyingOf;   // source id => stake contract

    struct Settings {
        uint256 rateBps;
        uint256 minSelfStake;
        uint256 maxPerClaim;
        uint8   stopRank;
    }
    Settings public pendingSettings;
    uint256  public pendingSettingsEta;                // 0 = nothing pending
    mapping(uint256 => uint16)  public pendingBase;    // source id => new base %
    mapping(uint256 => uint256) public pendingBaseEta;
    uint256 public pendingBaseCount;                  // how many source ids have a pending base
    uint256 public lastReopenAt;                      // last unpause or source re-activation

    // ─────────────────────────── records ─────────────────────────────
    mapping(address => mapping(address => mapping(uint256 => bool))) public paid; // underlying => staker => index
    mapping(address => uint256) public rankReachedAt;
    mapping(address => uint256) public paidTo;
    uint256 public totalPaid;
    uint256 public currentDay;
    uint256 public spentToday;

    // ─────────────────────────── events ──────────────────────────────
    event Started(uint256 startAt);
    event SpotPaid(address indexed sponsor, uint256 indexed sourceId, address indexed staker, uint256 index, uint256 amount);
    event Claimed(address indexed sponsor, uint256 total, uint256 count);
    event RankReached(address indexed sponsor, uint256 at);
    event SourceAdded(uint256 indexed id, address src, uint16 baseBps);
    event SourceUpdated(uint256 indexed id, uint16 baseBps, bool active);
    event SettingChanged(string what, uint256 oldValue, uint256 newValue);
    event SettingsProposed(uint256 rateBps, uint256 minSelfStake, uint256 maxPerClaim, uint8 stopRank, uint256 eta);
    event SettingsApplied(uint256 rateBps, uint256 minSelfStake, uint256 maxPerClaim, uint8 stopRank);
    event SettingsCancelled();
    event SourceBaseProposed(uint256 indexed id, uint16 baseBps, uint256 eta);
    event GuardianChanged(address guardian);

    // ─────────────────────────── errors ──────────────────────────────
    error NotStarted();
    error AlreadyStarted();
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
    error DailyLimit();
    error PoolShort();
    error OutOfBounds();
    error NotGuardian();
    error RankCheckFailed();
    error ZeroAddress();
    error DuplicateSource();
    error NothingPending();
    error TooEarly();
    error PendingExists();
    error UnderlyingChanged();

    constructor(address _referral, address _treasury) Ownable(msg.sender) {
        if (_referral == address(0) || _treasury == address(0)) revert ZeroAddress();
        referral = IReferralV5Spot(_referral);
        treasury = ITreasurySpot(_treasury);
        legacy   = ILegacyStakingSpot(IReferralV5Spot(_referral).staking());
    }

    // ═══════════════════════════ claim ═══════════════════════════════

    /// Claim spot on up to MAX_BATCH stakes of your directs in one call.
    /// Returns the OSG paid. Returns 0 without paying when this call is
    /// the one that first records the caller reaching stopRank -- the
    /// record is kept, and stakes from before that moment stay claimable.
    function claimMany(
        uint256[] calldata sourceIds,
        address[] calldata stakers,
        uint256[] calldata indexes
    ) external nonReentrant whenNotPaused returns (uint256 total) {
        if (startAt == 0) revert NotStarted();
        uint256 n = sourceIds.length;
        if (n == 0 || n > MAX_BATCH || stakers.length != n || indexes.length != n) revert BadLength();

        address sponsor = msg.sender;
        if (referral.stakeOf(sponsor) < minSelfStake) revert NotEligible();

        if (rankReachedAt[sponsor] == 0 && _rankReached(sponsor)) {
            rankReachedAt[sponsor] = block.timestamp;
            emit RankReached(sponsor, block.timestamp);
            return 0;
        }
        uint256 until = rankReachedAt[sponsor];

        for (uint256 i = 0; i < n; i++) {
            uint256 amt = _checkAndMark(sourceIds[i], stakers[i], indexes[i], sponsor, until);
            total += amt;
            emit SpotPaid(sponsor, sourceIds[i], stakers[i], indexes[i], amt);
        }

        _rollDay();
        if (spentToday + total > dailyCap) revert DailyLimit();
        spentToday += total;
        totalPaid  += total;
        paidTo[sponsor] += total;

        uint256 got = treasury.spendAirdrop(sponsor, total);
        if (got != total) revert PoolShort();

        emit Claimed(sponsor, total, n);
    }

    /// Record that `sponsor` has reached stopRank, if they have. Anyone
    /// may call it; it only ever closes the window, never opens it.
    function checkRank(address sponsor) external returns (bool reached) {
        if (rankReachedAt[sponsor] != 0) return true;
        if (_rankReached(sponsor)) {
            rankReachedAt[sponsor] = block.timestamp;
            emit RankReached(sponsor, block.timestamp);
            return true;
        }
        return false;
    }

    // ═══════════════════════════ views ═══════════════════════════════

    /// What a stake would pay `sponsor` right now, and why not if 0.
    /// reason: 0 ok, 1 not started, 2 bad source, 3 source off,
    /// 4 not your direct, 5 before start, 6 after rank, 7 closed,
    /// 8 already paid, 9 zero amount, 10 sponsor stake too low.
    function quote(address sponsor, uint256 sourceId, address staker, uint256 index)
        external view returns (uint256 amount, uint8 reason)
    {
        if (startAt == 0) return (0, 1);
        if (referral.stakeOf(sponsor) < minSelfStake) return (0, 10);
        uint256 until = rankReachedAt[sponsor];
        // Not recorded yet but reached: the next claim would pay nothing.
        if (until == 0 && _rankReached(sponsor)) return (0, 6);
        if (sourceId >= sources.length) return (0, 2);
        Source memory s = sources[sourceId];
        if (!s.active) return (0, 3);
        if (referral.referrerOf(staker) != sponsor) return (0, 4);
        if (s.src.spotUnderlying() != underlyingOf[sourceId]) return (0, 2);
        (uint256 posAmt, uint256 st, bool open) = s.src.spotPosition(staker, index);
        if (st < startAt) return (0, 5);
        if (until != 0 && st > until) return (0, 6);
        if (!open) return (0, 7);
        if (paid[underlyingOf[sourceId]][staker][index]) return (0, 8);
        amount = _amountFor(posAmt, s.baseBps);
        if (amount == 0) return (0, 9);
        return (amount, 0);
    }

    function sponsorStatus(address sponsor)
        external view returns (uint256 selfStake, bool eligible, uint256 reachedAt, uint256 received)
    {
        selfStake = referral.stakeOf(sponsor);
        reachedAt = rankReachedAt[sponsor];
        eligible  = selfStake >= minSelfStake && reachedAt == 0;
        received  = paidTo[sponsor];
    }

    function sourcesCount() external view returns (uint256) {
        return sources.length;
    }

    function todayLeft() external view returns (uint256) {
        uint256 spent = (block.timestamp / 1 days == currentDay) ? spentToday : 0;
        return dailyCap > spent ? dailyCap - spent : 0;
    }

    // ═══════════════════════════ owner ═══════════════════════════════

    /// Opens claims. Stakes that started before this moment never count.
    /// One way: it cannot be moved afterwards.
    function start() external onlyOwner {
        if (startAt != 0) revert AlreadyStarted();
        startAt = block.timestamp;
        emit Started(block.timestamp);
    }

    function addSource(address src, uint16 baseBps) external onlyOwner {
        if (src == address(0) || src.code.length == 0) revert BadSource();
        if (isSourceAddr[src]) revert DuplicateSource();
        if (sources.length >= MAX_SOURCES) revert OutOfBounds();
        if (baseBps == 0 || baseBps > BPS) revert OutOfBounds();
        address u = ISpotSource(src).spotUnderlying();
        if (u == address(0) || u.code.length == 0) revert BadSource();
        if (isUnderlying[u]) revert DuplicateSource();
        isSourceAddr[src] = true;
        isUnderlying[u]   = true;
        underlyingOf[sources.length] = u;
        sources.push(Source({ src: ISpotSource(src), baseBps: baseBps, active: true }));
        emit SourceAdded(sources.length - 1, src, baseBps);
    }

    /// Switch one source on or off at once (an emergency stop for that
    /// source: stakes stay unpaid, not lost).
    function setSourceActive(uint256 id, bool active) external onlyOwner {
        if (id >= sources.length) revert BadSource();
        if (!active && (pendingSettingsEta != 0 || pendingBaseCount != 0)) revert PendingExists();
        if (active && !sources[id].active) lastReopenAt = block.timestamp;
        sources[id].active = active;
        emit SourceUpdated(id, sources[id].baseBps, active);
    }

    /// Change a source's base %. Immediate before start; after start it
    /// waits CHANGE_DELAY and is then applied with applySourceBase.
    function proposeSourceBase(uint256 id, uint16 baseBps) external onlyOwner {
        if (id >= sources.length) revert BadSource();
        if (baseBps == 0 || baseBps > BPS) revert OutOfBounds();
        if (startAt == 0) {
            sources[id].baseBps = baseBps;
            emit SourceUpdated(id, baseBps, sources[id].active);
            return;
        }
        if (pendingBaseEta[id] != 0) revert PendingExists();
        pendingBase[id]    = baseBps;
        pendingBaseEta[id] = block.timestamp + CHANGE_DELAY;
        pendingBaseCount  += 1;
        emit SourceBaseProposed(id, baseBps, pendingBaseEta[id]);
    }

    function applySourceBase(uint256 id) external onlyOwner whenNotPaused {
        uint256 eta = pendingBaseEta[id];
        if (eta == 0) revert NothingPending();
        if (block.timestamp < eta || block.timestamp < lastReopenAt + CHANGE_DELAY) revert TooEarly();
        sources[id].baseBps = pendingBase[id];
        pendingBaseEta[id] = 0;
        pendingBaseCount  -= 1;
        emit SourceUpdated(id, sources[id].baseBps, sources[id].active);
    }

    function cancelSourceBase(uint256 id) external onlyOwner {
        if (pendingBaseEta[id] == 0) revert NothingPending();
        pendingBaseEta[id] = 0;
        pendingBaseCount  -= 1;
        emit SourceBaseProposed(id, sources[id].baseBps, 0);
    }

    /// Rate, minimum self stake, per-stake ceiling and stop rank together.
    /// Immediate before start; after start they wait CHANGE_DELAY.
    function proposeSettings(uint256 rate, uint256 minSelf, uint256 maxPer, uint8 stopR) external onlyOwner {
        if (rate == 0 || rate > MAX_RATE_BPS) revert OutOfBounds();
        if (minSelf > MAX_SELF_STAKE) revert OutOfBounds();
        if (maxPer == 0 || maxPer > MAX_PER_CLAIM) revert OutOfBounds();
        if (stopR == 0 || stopR > 10) revert OutOfBounds();
        if (startAt == 0) {
            _applySettings(Settings(rate, minSelf, maxPer, stopR));
            return;
        }
        if (pendingSettingsEta != 0) revert PendingExists();
        pendingSettings    = Settings(rate, minSelf, maxPer, stopR);
        pendingSettingsEta = block.timestamp + CHANGE_DELAY;
        emit SettingsProposed(rate, minSelf, maxPer, stopR, pendingSettingsEta);
    }

    function applySettings() external onlyOwner whenNotPaused {
        if (pendingSettingsEta == 0) revert NothingPending();
        if (block.timestamp < pendingSettingsEta || block.timestamp < lastReopenAt + CHANGE_DELAY) revert TooEarly();
        pendingSettingsEta = 0;
        _applySettings(pendingSettings);
    }

    function cancelSettings() external onlyOwner {
        if (pendingSettingsEta == 0) revert NothingPending();
        pendingSettingsEta = 0;
        emit SettingsCancelled();
    }

    function setDailyCap(uint256 v) external onlyOwner {
        if (v == 0 || v > MAX_DAILY) revert OutOfBounds();
        emit SettingChanged("dailyCap", dailyCap, v);
        dailyCap = v;
    }

    function setGuardian(address g) external onlyOwner {
        guardian = g;
        emit GuardianChanged(g);
    }

    function pause() external {
        if (msg.sender != owner() && msg.sender != guardian) revert NotGuardian();
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
        lastReopenAt = block.timestamp;
    }

    // ═══════════════════════════ internal ════════════════════════════

    function _applySettings(Settings memory v) internal {
        rateBps      = v.rateBps;
        minSelfStake = v.minSelfStake;
        maxPerClaim  = v.maxPerClaim;
        stopRank     = v.stopRank;
        emit SettingsApplied(v.rateBps, v.minSelfStake, v.maxPerClaim, v.stopRank);
    }

    function _checkAndMark(uint256 sourceId, address staker, uint256 index, address sponsor, uint256 until)
        internal returns (uint256 amt)
    {
        if (sourceId >= sources.length) revert BadSource();
        Source memory s = sources[sourceId];
        if (!s.active) revert SourceOff();
        if (referral.referrerOf(staker) != sponsor) revert NotYourDirect();

        if (s.src.spotUnderlying() != underlyingOf[sourceId]) revert UnderlyingChanged();
        (uint256 posAmt, uint256 st, bool open) = s.src.spotPosition(staker, index);
        if (st < startAt) revert BeforeStart();
        if (until != 0 && st > until) revert AfterRank();
        if (!open) revert PositionClosed();

        address key = underlyingOf[sourceId];
        if (paid[key][staker][index]) revert AlreadyPaid();

        amt = _amountFor(posAmt, s.baseBps);
        if (amt == 0) revert ZeroAmount();
        paid[key][staker][index] = true;
    }

    function _amountFor(uint256 posAmt, uint16 baseBps) internal view returns (uint256 amt) {
        amt = posAmt * baseBps * rateBps / (BPS * BPS);
        if (amt > maxPerClaim) amt = maxPerClaim;
    }

    function _rollDay() internal {
        uint256 d = block.timestamp / 1 days;
        if (d != currentDay) {
            currentDay = d;
            spentToday = 0;
        }
    }

    /// Has `sponsor` reached stopRank? The directs list is gathered here,
    /// never taken from the caller -- a sponsor who left directs out would
    /// otherwise look like a lower rank.
    function _rankReached(address sponsor) internal view returns (bool) {
        if (referral.rankOf(sponsor) >= stopRank) return true;

        // Collect real directs, stopping as soon as there are more than
        // MAX_DIRECTS: such a sponsor is treated as having reached the
        // rank, and the work never grows past MAX_DIRECTS + 1 entries.
        address[] memory list = new address[](MAX_DIRECTS + 1);
        uint256 m;

        // Native directs are read a page at a time, so a huge list is
        // never loaded: the loop ends on the 51st real direct.
        uint256 offset;
        while (true) {
            (address[] memory page, uint256 totalKids) = referral.childrenSlice(sponsor, offset, PAGE);
            for (uint256 i = 0; i < page.length; i++) {
                if (referral.referrerOf(page[i]) != sponsor) continue;
                if (_has(list, m, page[i])) continue;
                list[m++] = page[i];
                if (m > MAX_DIRECTS) return true;
            }
            offset += page.length;
            if (page.length == 0 || offset >= totalKids) break;
        }

        if (address(legacy) != address(0)) {
            // A failing legacy read fails the check (and the claim): a
            // missing half of the tree must never look like a lower rank.
            address[] memory leg;
            try legacy.getDirectReferrals(sponsor) returns (address[] memory l) {
                leg = l;
            } catch {
                revert RankCheckFailed();
            }
            for (uint256 i = 0; i < leg.length; i++) {
                if (referral.referrerOf(leg[i]) != sponsor) continue;
                if (_has(list, m, leg[i])) continue;
                list[m++] = leg[i];
                if (m > MAX_DIRECTS) return true;
            }
        }

        // v5 wants the list strictly ascending (at most 50 entries here).
        for (uint256 i = 1; i < m; i++) {
            address x = list[i];
            uint256 j = i;
            while (j > 0 && list[j - 1] > x) { list[j] = list[j - 1]; j--; }
            list[j] = x;
        }
        address[] memory sorted = new address[](m);
        for (uint256 i = 0; i < m; i++) sorted[i] = list[i];

        // A v5 failure blocks the claim for now rather than guessing:
        // guessing "reached" would stop the sponsor for good on a passing
        // fault, guessing "not reached" could overpay.
        try referral.currentRank(sponsor, sorted) returns (uint8 r) {
            return r >= stopRank;
        } catch {
            revert RankCheckFailed();
        }
    }

    function _has(address[] memory a, uint256 len, address x) internal pure returns (bool) {
        for (uint256 i = 0; i < len; i++) if (a[i] == x) return true;
        return false;
    }
}
