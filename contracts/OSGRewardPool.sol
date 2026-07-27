// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

interface IOSG {
    function mint(address to, uint256 amount) external;
    function totalSupply() external view returns (uint256);
}

interface IRewardStorage {
    function updateReward(address user, uint256 amount) external;
    function claim(address user) external returns (uint256);
    function pendingReward(address user) external view returns (uint256);
    function restoreReward(address user, uint256 amount) external; // FIX 3
}

/**
 * @title  OSG RewardPool v2 — CHUNKED CLAIM (Fresh Deploy)
 * @notice Layer-1 Token Economy Engine
 *
 * ============================================================
 *  WHY v2 (the ONLY functional change vs the deployed pool):
 *  ------------------------------------------------------------
 *  The OSG Token has an IMMUTABLE circuit breaker:
 *      HARD_HOURLY_CAP = 500 OSG  (per hour, whole token)
 *  The old claim() pulled the user's FULL pending reward and tried
 *  to mint it in ONE token.mint() call. If pending > 500 OSG, the
 *  Token reverted, RewardPool caught it ("Mint failed - reward
 *  restored"), and the user could NEVER claim. Reward was safe but
 *  permanently stuck.
 *
 *  v2 FIX: claim() now mints at most claimChunk (default 500 OSG)
 *  per call and immediately restores the remainder to storage, so it
 *  stays claimable next hour. User claims repeatedly (once per hour)
 *  to drain a large backlog. Nothing else changed.
 *
 *  Everything else (distribute, emission, governance, storage,
 *  carry-forward, views) is byte-for-byte the same logic as before,
 *  so the rest of the ecosystem (Token, RewardStorage, Staking)
 *  needs NO change and all balances stay safe.
 * ============================================================
 *
 * Issues Fixed (carried over):
 *  FIX 1 - Team supply excluded from emission budget
 *  FIX 2 - Hard-stop after MAX_HALVINGS (15 years)
 *  FIX 3 - Mint fail → reward restored (no permanent loss)
 *  FIX 4 - EMISSION_SUPPLY = MAX_SUPPLY - TEAM_SUPPLY
 *  FIX 5 - Pending reward overflow → safe check
 *  FIX 6 - Old pool deactivation guard
 *  FIX 7 - 15yr emission hard-stop
 *  FIX 8 - Claim rollback fully safe (restoreReward)
 *  FIX 9 - v2: chunked claim (<= claimChunk per call)   ← NEW
 */
contract OSGRewardPool is ReentrancyGuard, Pausable {

    // =====================================================
    //  CONSTANTS
    // =====================================================

    uint256 public constant BASE_DAILY       = 5_881 * 1e18;
    uint256 public constant HALVING_INTERVAL = 3 * 365 days;
    uint256 public constant MAX_HALVINGS     = 4;
    uint256 public constant EMISSION_YEARS   = 15;

    // FIX 1 + 4: Total supply minus team allocation
    uint256 public constant MAX_SUPPLY       = 23_000_000 * 1e18;
    uint256 public constant TEAM_SUPPLY      =    460_000 * 1e18;
    // FIX 4: Emission budget = only non-team supply
    uint256 public constant EMISSION_SUPPLY  = MAX_SUPPLY - TEAM_SUPPLY;

    uint256 public constant MAX_CARRY_DAYS   = 3;
    uint256 public constant MAX_LOOP         = 30;
    uint256 public constant GOVERNANCE_DELAY = 48 hours;
    uint256 public constant STORAGE_DELAY    = 72 hours;
    uint256 public constant MAX_DISTRIBUTORS = 10;
    uint256 public constant MAX_SINGLE_ALLOC = 10_000 * 1e18;

    // FIX 9 (v2): hard ceiling for the per-claim chunk = Token hourly cap
    uint256 public constant MAX_CLAIM_CHUNK  = 500 * 1e18;

    // FIX 7: Hard emission end time
    uint256 public constant EMISSION_DURATION = EMISSION_YEARS * 365 days;

    uint8 public constant CAT_STAKING  = 1;
    uint8 public constant CAT_MINING   = 2;
    uint8 public constant CAT_REFERRAL = 3;

    uint8 public constant REASON_MAX_SUPPLY      = 1;
    uint8 public constant REASON_OVERFLOW        = 2;
    uint8 public constant REASON_EMISSION_ENDED  = 3; // FIX 7

    // =====================================================
    //  CORE
    // =====================================================

    IOSG           public token;
    IRewardStorage public store;

    address public governance;
    address public pendingGovernance;
    uint256 public govChangeAt;

    address public pendingStore;
    uint256 public storeChangeAt;

    uint256 public immutable startTime;

    // FIX 7: Emission end timestamp
    uint256 public immutable emissionEndTime;

    // FIX 9 (v2): per-claim mint chunk, tunable but never above the Token cap
    uint256 public claimChunk = 500 * 1e18;

    // =====================================================
    //  EMERGENCY
    // =====================================================

    bool public emergencyMode;

    // =====================================================
    //  DISTRIBUTION PERCENTAGES
    //  Set to (70,0,30) post-deploy via updatePercents(70,0,30).
    // =====================================================

    uint256 public stakingPercent  = 40;
    uint256 public miningPercent   = 40;
    uint256 public referralPercent = 20;

    // =====================================================
    //  DISTRIBUTOR CONTROL  (FIX 6: active tracking)
    // =====================================================

    mapping(address => uint8)   public distributorType;
    mapping(address => uint256) public distributorLastBlock;
    mapping(address => bool)    public distributorActive; // FIX 6
    uint256 public distributorCount;

    // =====================================================
    //  CARRY FORWARD
    // =====================================================

    uint256 public stakingCarry;
    uint256 public miningCarry;
    uint256 public referralCarry;

    // =====================================================
    //  DAILY STATE
    // =====================================================

    uint256 public lastDay;

    uint256 public stakingUsed;
    uint256 public miningUsed;
    uint256 public referralUsed;

    // FIX 4: Track against EMISSION_SUPPLY (not MAX_SUPPLY)
    uint256 public totalAllocated;
    uint256 public totalMinted;
    uint256 public totalStakingAll;
    uint256 public totalMiningAll;
    uint256 public totalReferralAll;

    // =====================================================
    //  EMISSION CONTROL
    // =====================================================

    bool public emissionStopped;

    // =====================================================
    //  EVENTS
    // =====================================================

    event Distributed(address indexed user, uint256 amount, uint8 indexed category);
    event Claimed(address indexed user, uint256 amount);
    event MintFailed(address indexed user, uint256 amount);
    event RewardRestored(address indexed user, uint256 amount); // FIX 3
    event ClaimChunkUpdated(uint256 chunk);                     // FIX 9 (v2)

    event CarryUpdated(
        uint256 stakingCarry,
        uint256 miningCarry,
        uint256 referralCarry,
        uint256 daysProcessed,
        uint256 daysMissed,
        bool    isPartial
    );

    event AllocationRejected(address indexed user, uint256 amount, uint8 indexed reasonCode);
    event StorageCallFailed(address indexed user, bytes reason);

    event EmissionToggled(bool stopped, address indexed by);
    event EmissionEnded(uint256 at);                            // FIX 7
    event CarryFrozen(address indexed by);
    event CarryUnfrozen(address indexed by);
    event SyncRequired(uint256 daysBehind);

    event EmergencyModeEnabled(address indexed by);
    event EmergencyStoreSet(address indexed newStore, address indexed by);

    event DistributorSet(address indexed addr, uint8 category);
    event DistributorRemoved(address indexed addr);
    event PercentsUpdated(uint256 staking, uint256 mining, uint256 referral);

    event GovernanceProposed(address indexed newGov, uint256 executeAt);
    event GovernanceUpdated(address indexed oldGov, address indexed newGov);
    event GovernanceCancelled(address indexed cancelled);

    event StorageProposed(address indexed newStore, uint256 executeAt);
    event StorageUpdated(address indexed oldStore, address indexed newStore);
    event StorageCancelled(address indexed cancelled);

    event EmergencyAction(string action, address indexed by);

    // =====================================================
    //  MODIFIERS
    // =====================================================

    modifier onlyGov() {
        require(msg.sender == governance, "Not governance");
        _;
    }

    modifier onlyDistributor(uint8 cat) {
        require(
            distributorType[msg.sender] == cat &&
            distributorActive[msg.sender],        // FIX 6
            "Invalid or inactive distributor"
        );
        _;
    }

    modifier onlyAfterGovDelay() {
        require(pendingGovernance == address(0), "Governance change pending");
        _;
    }

    // FIX 7: Emission active check
    modifier emissionActive() {
        require(block.timestamp <= emissionEndTime, "Emission period ended");
        _;
    }

    // =====================================================
    //  CONSTRUCTOR
    // =====================================================

    constructor(
        address _token,
        address _store,
        address _gov
    ) {
        require(_token != address(0), "Invalid token");
        require(_store != address(0), "Invalid store");
        require(_gov   != address(0), "Invalid gov");
        require(_token.code.length > 0, "Token must be contract");
        require(_store.code.length > 0, "Store must be contract");

        token      = IOSG(_token);
        store      = IRewardStorage(_store);
        governance = _gov;
        startTime  = block.timestamp;

        // FIX 7: Set emission end time
        emissionEndTime = block.timestamp + EMISSION_DURATION;

        lastDay = (block.timestamp - startTime) / 1 days;
    }

    // =====================================================
    //  EMISSION
    // =====================================================

    function _halvingsFor(uint256 elapsed) internal pure returns (uint256) {
        uint256 h = elapsed / HALVING_INTERVAL;
        return h > MAX_HALVINGS ? MAX_HALVINGS : h;
    }

    function getHalving() public view returns (uint256) {
        return _halvingsFor(block.timestamp - startTime);
    }

    // FIX 2: Hard-stop after MAX_HALVINGS
    function getDailyBase() public view returns (uint256) {
        if (block.timestamp > emissionEndTime) return 0; // FIX 7
        return BASE_DAILY >> getHalving();
    }

    function getCategoryBase() public view returns (uint256 sb, uint256 mb, uint256 rb) {
        uint256 d = getDailyBase();
        if (d == 0) return (0, 0, 0); // FIX 2
        sb = (d * stakingPercent)  / 100;
        mb = (d * miningPercent)   / 100;
        rb = (d * referralPercent) / 100;
    }

    function getLimits() public view returns (uint256 sl, uint256 ml, uint256 rl) {
        (uint256 sb, uint256 mb, uint256 rb) = getCategoryBase();
        sl = sb + stakingCarry;
        ml = mb + miningCarry;
        rl = rb + referralCarry;
    }

    // =====================================================
    //  INTERNAL: Day Reset
    // =====================================================

    function _resetDay() internal {
        uint256 ts    = block.timestamp;
        uint256 today = (ts - startTime) / 1 days;

        if (today <= lastDay) return;

        uint256 totalDaysMissed = today - lastDay;

        if (emissionStopped) {
            lastDay      = today;
            stakingUsed  = 0;
            miningUsed   = 0;
            referralUsed = 0;
            emit CarryUpdated(stakingCarry, miningCarry, referralCarry, 0, totalDaysMissed, false);
            return;
        }

        // FIX 7: Stop carry accumulation after emission end
        if (ts > emissionEndTime) {
            lastDay      = today;
            stakingUsed  = 0;
            miningUsed   = 0;
            referralUsed = 0;
            emit CarryUpdated(0, 0, 0, 0, totalDaysMissed, false);
            return;
        }

        uint256 processUntil = lastDay + MAX_LOOP < today ? lastDay + MAX_LOOP : today;
        bool isPartial = processUntil < today;

        (uint256 sbCurrent, uint256 mbCurrent, uint256 rbCurrent) = getCategoryBase();
        uint256 maxSCarry = sbCurrent * MAX_CARRY_DAYS;
        uint256 maxMCarry = mbCurrent * MAX_CARRY_DAYS;
        uint256 maxRCarry = rbCurrent * MAX_CARRY_DAYS;

        uint256 daysProcessed = 0;

        while (lastDay < processUntil) {
            uint256 dayElapsed = lastDay * 1 days;

            // FIX 2: After emission end → no base emission
            uint256 halvings = _halvingsFor(dayElapsed);
            uint256 dayBase  = (startTime + dayElapsed > emissionEndTime)
                ? 0
                : BASE_DAILY >> halvings;

            uint256 sDayBase = (dayBase * stakingPercent)  / 100;
            uint256 mDayBase = (dayBase * miningPercent)   / 100;
            uint256 rDayBase = (dayBase * referralPercent) / 100;

            uint256 sUnused = sDayBase > stakingUsed  ? sDayBase - stakingUsed  : 0;
            uint256 mUnused = mDayBase > miningUsed   ? mDayBase - miningUsed   : 0;
            uint256 rUnused = rDayBase > referralUsed ? rDayBase - referralUsed : 0;

            stakingCarry  = stakingCarry  + sUnused > maxSCarry ? maxSCarry : stakingCarry  + sUnused;
            miningCarry   = miningCarry   + mUnused > maxMCarry ? maxMCarry : miningCarry   + mUnused;
            referralCarry = referralCarry + rUnused > maxRCarry ? maxRCarry : referralCarry + rUnused;

            lastDay++;
            stakingUsed  = 0;
            miningUsed   = 0;
            referralUsed = 0;
            daysProcessed++;
        }

        if (isPartial) {
            emit SyncRequired(totalDaysMissed - daysProcessed);
        }

        emit CarryUpdated(
            stakingCarry, miningCarry, referralCarry,
            daysProcessed, totalDaysMissed - daysProcessed, isPartial
        );
    }

    // =====================================================
    //  PUBLIC: Manual sync
    // =====================================================

    function syncDays() external {
        _resetDay();
    }

    function syncDaysBatch(uint256 loops) external {
        require(loops > 0 && loops <= 100, "Invalid loops: 1-100");
        for (uint256 i = 0; i < loops; i++) {
            uint256 today = (block.timestamp - startTime) / 1 days;
            if (today <= lastDay) break;
            _resetDay();
        }
    }

    // =====================================================
    //  DISTRIBUTE  (unchanged from deployed pool)
    // =====================================================

    function distribute(
        address user,
        uint256 amount,
        uint8   category
    )
        external
        onlyDistributor(category)
        whenNotPaused
        emissionActive  // FIX 7
    {
        require(!emissionStopped,             "Emission stopped");
        require(user   != address(0),         "Zero user");
        require(amount >  0,                  "Zero amount");
        require(address(store) != address(0), "Store not set");
        require(address(token) != address(0), "Token not set");
        require(amount <= MAX_SINGLE_ALLOC,   "Exceeds single-call limit");
        require(category >= CAT_STAKING && category <= CAT_REFERRAL, "Invalid category");

        // Per-block cooldown
        require(distributorLastBlock[msg.sender] < block.number, "One call per block per distributor");
        distributorLastBlock[msg.sender] = block.number;

        _resetDay();

        {
            uint256 today = (block.timestamp - startTime) / 1 days;
            require(today <= lastDay + MAX_LOOP, "Too many days pending, call syncDays()");
        }

        // FIX 4: Check against EMISSION_SUPPLY (not MAX_SUPPLY)
        if (totalAllocated + amount > EMISSION_SUPPLY) {
            emit AllocationRejected(user, amount, REASON_MAX_SUPPLY);
            revert("Allocation exceeds emission supply");
        }

        // FIX 5: Improved overflow check using EMISSION_SUPPLY
        uint256 pendingClaim = totalAllocated > totalMinted ? totalAllocated - totalMinted : 0;

        // FIX 1: token.totalSupply includes TEAM_SUPPLY already
        if (token.totalSupply() + pendingClaim + amount > MAX_SUPPLY) {
            emit AllocationRejected(user, amount, REASON_OVERFLOW);
            revert("Future supply overflow");
        }

        (uint256 sl, uint256 ml, uint256 rl) = getLimits();

        if (category == CAT_STAKING) {
            require(stakingUsed  + amount <= sl, "Staking cap exceeded");
            stakingUsed     += amount;
            totalStakingAll += amount;
        } else if (category == CAT_MINING) {
            require(miningUsed   + amount <= ml, "Mining cap exceeded");
            miningUsed     += amount;
            totalMiningAll += amount;
        } else {
            require(referralUsed + amount <= rl, "Referral cap exceeded");
            referralUsed     += amount;
            totalReferralAll += amount;
        }

        totalAllocated += amount;

        try store.updateReward(user, amount) {
            // success
        } catch (bytes memory reason) {
            totalAllocated -= amount;
            if (category == CAT_STAKING) {
                stakingUsed     -= amount;
                totalStakingAll -= amount;
            } else if (category == CAT_MINING) {
                miningUsed     -= amount;
                totalMiningAll -= amount;
            } else {
                referralUsed     -= amount;
                totalReferralAll -= amount;
            }
            emit StorageCallFailed(user, reason);
            revert("Reward storage failed");
        }

        emit Distributed(user, amount, category);
    }

    // =====================================================
    //  CLAIM  — v2 CHUNKED  (FIX 9)
    //  Mints at most claimChunk (<= 500 OSG) per call and
    //  restores the remainder so it stays claimable next hour.
    //  FIX 3 + 8: mint fail → reward fully restored, no loss.
    // =====================================================

    function claim()
        external
        nonReentrant
        whenNotPaused
    {
        require(address(token) != address(0), "Token not set");

        // emissionStopped does NOT block claim
        uint256 full = store.claim(msg.sender);
        require(full > 0, "No rewards");

        // v2: split into a mintable chunk (<= Token hourly cap) + remainder
        uint256 chunk     = full > claimChunk ? claimChunk : full;
        uint256 remainder = full - chunk;

        // Put the remainder straight back so it stays claimable later.
        if (remainder > 0) {
            store.restoreReward(msg.sender, remainder);
            emit RewardRestored(msg.sender, remainder);
        }

        require(token.totalSupply() + chunk <= MAX_SUPPLY, "Max supply reached");

        // CEI: State update BEFORE external call
        totalMinted += chunk;

        try IOSG(address(token)).mint(msg.sender, chunk) {
            emit Claimed(msg.sender, chunk);
        } catch {
            // FIX 3 + 8: Rollback totalMinted
            totalMinted -= chunk;

            // FIX 3: Restore the chunk too (no permanent loss)
            try store.restoreReward(msg.sender, chunk) {
                emit RewardRestored(msg.sender, chunk);
            } catch {
                emit MintFailed(msg.sender, chunk);
            }

            revert("Mint failed - reward restored");
        }
    }

    // =====================================================
    //  GOVERNANCE — 2-step + 48h
    // =====================================================

    function proposeGovernance(address _newGov) external onlyGov {
        require(_newGov != address(0), "Invalid address");
        require(_newGov != governance, "Same governance");
        pendingGovernance = _newGov;
        govChangeAt       = block.timestamp + GOVERNANCE_DELAY;
        emit GovernanceProposed(_newGov, govChangeAt);
    }

    function acceptGovernance() external {
        require(msg.sender == pendingGovernance, "Not pending gov");
        require(block.timestamp >= govChangeAt,  "Delay not passed");
        address old       = governance;
        governance        = pendingGovernance;
        pendingGovernance = address(0);
        govChangeAt       = 0;
        emit GovernanceUpdated(old, governance);
    }

    function cancelGovernance() external onlyGov {
        require(pendingGovernance != address(0), "Nothing to cancel");
        address cancelled = pendingGovernance;
        pendingGovernance = address(0);
        govChangeAt       = 0;
        emit GovernanceCancelled(cancelled);
    }

    // =====================================================
    //  STORAGE — 72h timelock
    // =====================================================

    function proposeStorage(address _newStore) external onlyGov {
        require(_newStore != address(0),     "Invalid address");
        require(_newStore != address(store), "Same store");
        require(_newStore.code.length > 0,   "Must be contract");
        pendingStore  = _newStore;
        storeChangeAt = block.timestamp + STORAGE_DELAY;
        emit StorageProposed(_newStore, storeChangeAt);
    }

    function confirmStorage() external onlyGov {
        require(pendingStore != address(0),       "Nothing pending");
        require(block.timestamp >= storeChangeAt, "Delay not passed");
        address old   = address(store);
        store         = IRewardStorage(pendingStore);
        pendingStore  = address(0);
        storeChangeAt = 0;
        emit StorageUpdated(old, address(store));
    }

    function cancelStorage() external onlyGov {
        require(pendingStore != address(0), "Nothing to cancel");
        address cancelled = pendingStore;
        pendingStore  = address(0);
        storeChangeAt = 0;
        emit StorageCancelled(cancelled);
    }

    // =====================================================
    //  EMERGENCY STORE — 2-step
    // =====================================================

    function enableEmergencyMode() external onlyGov {
        require(!emergencyMode, "Already in emergency");
        emergencyMode = true;
        emit EmergencyModeEnabled(msg.sender);
        emit EmergencyAction("EMERGENCY_MODE_ENABLED", msg.sender);
    }

    function emergencySetStore(address _store) external onlyGov {
        require(emergencyMode,            "Not in emergency mode");
        require(_store != address(0),     "Invalid address");
        require(_store.code.length > 0,   "Must be contract");
        require(_store != address(store), "Same store");
        store         = IRewardStorage(_store);
        emergencyMode = false;
        emit EmergencyStoreSet(_store, msg.sender);
        emit EmergencyAction("EMERGENCY_STORE_SET", msg.sender);
    }

    // =====================================================
    //  ADMIN  (FIX 6: distributorActive tracking)
    // =====================================================

    function setDistributor(address addr, uint8 cat)
        external
        onlyGov
        onlyAfterGovDelay
    {
        require(addr != address(0),  "Invalid address");
        require(cat <= CAT_REFERRAL, "Invalid category");
        require(
            distributorType[addr] == 0 || distributorType[addr] == cat,
            "Already assigned to different category"
        );
        if (distributorType[addr] == 0) {
            require(distributorCount < MAX_DISTRIBUTORS, "Max distributors reached");
            distributorCount++;
        }
        distributorType[addr]   = cat;
        distributorActive[addr] = true; // FIX 6
        emit DistributorSet(addr, cat);
    }

    // FIX 6: Deactivate instead of delete
    function removeDistributor(address addr) external onlyGov {
        require(addr != address(0),      "Invalid address");
        require(distributorActive[addr], "Not active distributor");
        distributorActive[addr] = false;
        distributorType[addr]   = 0;
        if (distributorCount > 0) distributorCount--;
        emit DistributorRemoved(addr);
    }

    function updatePercents(uint256 s, uint256 m, uint256 r)
        external
        onlyGov
        onlyAfterGovDelay
    {
        require(s + m + r == 100, "Must sum to 100");
        require(s > 0 && r > 0,   "Staking & referral must be > 0"); // mining 0 allowed
        stakingPercent  = s;
        miningPercent   = m;
        referralPercent = r;
        emit PercentsUpdated(s, m, r);
    }

    // FIX 9 (v2): tune per-claim chunk, hard-capped at the Token hourly cap.
    function setClaimChunk(uint256 _chunk)
        external
        onlyGov
        onlyAfterGovDelay
    {
        require(_chunk > 0 && _chunk <= MAX_CLAIM_CHUNK, "Chunk 1..500 OSG");
        claimChunk = _chunk;
        emit ClaimChunkUpdated(_chunk);
    }

    function toggleEmission(bool _stop)
        external
        onlyGov
        onlyAfterGovDelay
    {
        if (_stop) {
            require(!emissionStopped, "Already stopped");
            emissionStopped = true;
            emit CarryFrozen(msg.sender);
        } else {
            require(emissionStopped,  "Already running");
            emissionStopped = false;
            emit CarryUnfrozen(msg.sender);
        }
        emit EmissionToggled(_stop, msg.sender);
    }

    function pause() external onlyGov {
        _pause();
        emit EmergencyAction("PAUSE", msg.sender);
    }

    function unpause() external onlyGov {
        _unpause();
        emit EmergencyAction("UNPAUSE", msg.sender);
    }

    // =====================================================
    //  VIEW FUNCTIONS
    // =====================================================

    function getTodayStats() external view returns (
        uint256 stakingUsedAmt,
        uint256 miningUsedAmt,
        uint256 referralUsedAmt,
        uint256 stakingAvail,
        uint256 miningAvail,
        uint256 referralAvail,
        uint256 dailyBase
    ) {
        (uint256 sl, uint256 ml, uint256 rl) = getLimits();
        stakingUsedAmt  = stakingUsed;
        miningUsedAmt   = miningUsed;
        referralUsedAmt = referralUsed;
        stakingAvail    = sl > stakingUsed  ? sl - stakingUsed  : 0;
        miningAvail     = ml > miningUsed   ? ml - miningUsed   : 0;
        referralAvail   = rl > referralUsed ? rl - referralUsed : 0;
        dailyBase       = getDailyBase();
    }

    function getCarryStats() external view returns (
        uint256 staking,
        uint256 mining,
        uint256 referral,
        uint256 total,
        bool    frozen
    ) {
        staking  = stakingCarry;
        mining   = miningCarry;
        referral = referralCarry;
        total    = stakingCarry + miningCarry + referralCarry;
        frozen   = emissionStopped;
    }

    function getAllTimeStats() external view returns (
        uint256 allocated,
        uint256 minted,
        uint256 pendingClaim,
        uint256 staking,
        uint256 mining,
        uint256 referral
    ) {
        allocated    = totalAllocated;
        minted       = totalMinted;
        pendingClaim = totalAllocated > totalMinted ? totalAllocated - totalMinted : 0;
        staking      = totalStakingAll;
        mining       = totalMiningAll;
        referral     = totalReferralAll;
    }

    function getEmissionInfo() external view returns (
        uint256 halving,
        uint256 dailyBase,
        uint256 nextHalvingIn,
        uint256 emissionEndsIn,  // FIX 7
        uint256 remainingBudget, // FIX 4
        bool    stopped,
        uint256 daysBehind,
        bool    needsSync,
        bool    inEmergency
    ) {
        uint256 ts      = block.timestamp;
        uint256 elapsed = ts - startTime;
        halving         = _halvingsFor(elapsed);
        dailyBase       = getDailyBase();
        stopped         = emissionStopped;
        inEmergency     = emergencyMode;

        remainingBudget = EMISSION_SUPPLY > totalAllocated ? EMISSION_SUPPLY - totalAllocated : 0;
        emissionEndsIn  = emissionEndTime > ts ? emissionEndTime - ts : 0;

        uint256 today = elapsed / 1 days;
        daysBehind    = today > lastDay ? today - lastDay : 0;
        needsSync     = daysBehind > MAX_LOOP;

        if (halving < MAX_HALVINGS) {
            uint256 nextTime = startTime + ((halving + 1) * HALVING_INTERVAL);
            nextHalvingIn = nextTime > ts ? nextTime - ts : 0;
        }
    }

    function getPendingEmission() external view returns (
        uint256 stakingPending,
        uint256 miningPending,
        uint256 referralPending,
        uint256 totalPending
    ) {
        (uint256 sl, uint256 ml, uint256 rl) = getLimits();
        stakingPending  = sl > stakingUsed  ? sl - stakingUsed  : 0;
        miningPending   = ml > miningUsed   ? ml - miningUsed   : 0;
        referralPending = rl > referralUsed ? rl - referralUsed : 0;
        totalPending    = stakingPending + miningPending + referralPending;
    }

    function isHealthy() external view returns (
        bool healthy,
        bool mintedSafe,
        bool supplySafe,
        bool allocSafe,
        bool emissionSafe  // FIX 4
    ) {
        mintedSafe   = totalMinted         <= totalAllocated;
        supplySafe   = token.totalSupply() <= MAX_SUPPLY;
        allocSafe    = totalAllocated      <= EMISSION_SUPPLY; // FIX 4
        emissionSafe = block.timestamp     <= emissionEndTime; // FIX 7
        healthy      = mintedSafe && supplySafe && allocSafe;
    }

    function getUserReward(address user) external view returns (uint256) {
        return store.pendingReward(user);
    }

    function getPendingGovernance() external view returns (
        address pending,
        uint256 executeAt,
        bool    isReady
    ) {
        pending   = pendingGovernance;
        executeAt = govChangeAt;
        isReady   = pendingGovernance != address(0) && block.timestamp >= govChangeAt;
    }

    function getPendingStorage() external view returns (
        address pending,
        uint256 executeAt,
        bool    isReady
    ) {
        pending   = pendingStore;
        executeAt = storeChangeAt;
        isReady   = pendingStore != address(0) && block.timestamp >= storeChangeAt;
    }
}
