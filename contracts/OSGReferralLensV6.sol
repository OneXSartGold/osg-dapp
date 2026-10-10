// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/*
 *  OSGReferralLensV6 -- read-only views over OSGReferralV6.
 *
 *  Holds no money, no owner, no state. It exists so the DApp can keep the
 *  exact same view calls it used with Referral v5 (Lens v3 + Health v5):
 *  every function here has the same signature and the same return shape
 *  as the v5 function of the same name, so the app only swaps addresses.
 *
 *  Differences from v5 that a screen should know about:
 *    - Levels: as many as core.levelCount() (50 by default), not 15.
 *    - A level can need a rank as well as directs. A rank opens its levels
 *      for RANK_VALIDITY (8 days) after it was last proven.
 *    - An upline earns on its stake in hooked sources (Term, LP, Tiers) as
 *      last reported by the hooks (core.cachedStake), not on Active stake.
 *    - "paid" and "bonusPaidTotal" are not public on v6, so the card
 *      returns 0 for them. The app reads them from storage instead.
 *    - A wallet counts as legacy when its bond came from OSGStaking: either
 *      it has no local bond, or its local bond equals its OSGStaking bond
 *      (bonds copied in at migration).
 */

interface IReferralV6View {
    function referrerOf(address user) external view returns (address);
    function nativeReferrer(address user) external view returns (address);
    function children(address user, uint256 i) external view returns (address);
    function childrenCount(address user) external view returns (uint256);
    function directReferrals(address user) external view returns (uint256);
    function registeredDirects(address user) external view returns (uint256);
    function cachedStake(address user) external view returns (uint256);
    function stakeOf(address user) external view returns (uint256);
    function qualifyingStakeOf(address user) external view returns (uint256);
    function owed(address user) external view returns (uint256);
    function volume(address user) external view returns (uint256);
    function rankOf(address user) external view returns (uint8);
    function rankSince(address user) external view returns (uint256);
    function rankProvedAt(address user) external view returns (uint256);
    function minDirectStake() external view returns (uint256);
    function minReferrerStake() external view returns (uint256);
    function levelCount() external view returns (uint8);
    function levels(uint256 i) external view returns (uint16 bps, uint8 directs, uint8 minRank);
    function totalLevelBps() external view returns (uint256);
    function stakeSourceCount() external view returns (uint256);
    function spotModule() external view returns (address);
    function staking() external view returns (address);
    function pool() external view returns (address);
    function paused() external view returns (bool);
    function seedLocked() external view returns (bool);
    function seedDeadline() external view returns (uint256);
    function RANK_VALIDITY() external view returns (uint256);
}

interface IStakingV6Read {
    function users(address user) external view returns (
        uint256 staked, uint256, uint256, uint256, uint256, uint256 stakedAt,
        address referrer, uint256 totalReferrals, uint256, uint256, uint256
    );
    function getDirectReferrals(address user) external view returns (address[] memory);
}

interface IPoolV6Read {
    function getTodayStats() external view returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256);
}

contract OSGReferralLensV6 {
    uint256 internal constant RANK_HOLD = 24 hours;
    uint256 internal constant LOOP_SCAN_DEPTH = 64;

    IReferralV6View public immutable core;
    IStakingV6Read public immutable legacyStaking;

    constructor(address _core) {
        require(_core.code.length > 0, "core not contract");
        core = IReferralV6View(_core);
        address stk = IReferralV6View(_core).staking();
        require(stk.code.length > 0, "staking not contract");
        legacyStaking = IStakingV6Read(stk);
    }

    // ====================== TYPES (same as v5) ======================

    struct UplineEntry {
        uint8   level;
        address wallet;
        uint256 stake;
        uint256 levelBps;
        bool    levelOpen;
        bool    stakeOk;
        bool    earning;
    }

    struct Node {
        uint8   level;
        address wallet;
        uint256 stake;
        uint256 qualifyingStake;
        bool    qualified;
        bool    isLegacy;
        address referrer;
        uint256 joinedAt;
    }

    struct LevelRow {
        uint8   level;
        uint256 members;
        uint256 legacyMembers;
        uint256 qualified;
        uint256 totalStake;
        uint256 levelBps;
        uint256 directsNeeded;
        bool    open;
    }

    struct WalletCard {
        address referrer;
        bool    hasUpline;
        bool    uplineIsLegacy;
        uint256 legacyDirects;
        uint256 registeredDirects;
        uint256 qualifiedDirects;
        uint256 directsForLevels;
        uint256 levelsOpen;
        uint256 activeBps;
        uint256 stake;
        uint256 qualifyingStake;
        bool    countsAsDirect;
        uint256 owed;
        uint256 paid;
        uint256 volume;
        uint8   rank;
        uint256 rankHoldRemaining;
        uint256 bonusCooldownRemaining;
        uint256 bonusPaidTotal;
    }

    struct Cfg {
        uint256 n;
        uint16[] bps;
        uint8[] directs;
        uint8[] minRank;
    }

    // ====================== HELPERS ======================

    function _cfg() internal view returns (Cfg memory c) {
        c.n = core.levelCount();
        c.bps = new uint16[](c.n);
        c.directs = new uint8[](c.n);
        c.minRank = new uint8[](c.n);
        for (uint256 i = 0; i < c.n; i++) {
            (c.bps[i], c.directs[i], c.minRank[i]) = core.levels(i);
        }
    }

    function _rankActive(address w, uint8 need) internal view returns (bool) {
        if (need == 0) return true;
        return core.rankOf(w) >= need && block.timestamp <= core.rankProvedAt(w) + core.RANK_VALIDITY();
    }

    function _levelOpen(Cfg memory c, uint256 i, address w, uint256 directs) internal view returns (bool) {
        return directs >= c.directs[i] && _rankActive(w, c.minRank[i]);
    }

    function _legacyRef(address w) internal view returns (address r) {
        (, , , , , , r, , , , ) = legacyStaking.users(w);
    }

    function _isLegacy(address w) internal view returns (bool) {
        address local = core.nativeReferrer(w);
        if (local == address(0)) return true;
        return _legacyRef(w) == local;
    }

    function _active(address w) internal view returns (uint256 s) {
        (s, , , , , , , , , , ) = legacyStaking.users(w);
    }

    /// v6 children (registered, copied in, moved in), plus OSGStaking
    /// children that have no bond in v6 at all (joined the old tree after
    /// the migration snapshot).
    function _childrenMerged(address parent) internal view returns (address[] memory out) {
        uint256 n = core.childrenCount(parent);
        address[] memory leg;
        try legacyStaking.getDirectReferrals(parent) returns (address[] memory kids) { leg = kids; }
        catch { leg = new address[](0); }

        out = new address[](n + leg.length);
        uint256 k;
        for (uint256 i = 0; i < n; i++) out[k++] = core.children(parent, i);
        for (uint256 i = 0; i < leg.length; i++) {
            if (core.nativeReferrer(leg[i]) == address(0)) out[k++] = leg[i];
        }
        assembly { mstore(out, k) }
    }

    // ====================== UPLINE ======================

    function uplineView(address user) external view returns (UplineEntry[] memory chain) {
        Cfg memory c = _cfg();
        address[] memory found = new address[](c.n);
        uint256 n;
        address cur = user;
        for (uint256 i = 0; i < c.n; i++) {
            address ref = core.referrerOf(cur);
            if (ref == address(0) || ref == user) break;
            found[n++] = ref;
            cur = ref;
        }
        uint256 minRef = core.minReferrerStake();
        chain = new UplineEntry[](n);
        for (uint256 i = 0; i < n; i++) {
            address w = found[i];
            bool open = c.bps[i] > 0 && _levelOpen(c, i, w, core.directReferrals(w));
            bool stakeOk = core.cachedStake(w) >= minRef;
            chain[i] = UplineEntry({
                level: uint8(i + 1),
                wallet: w,
                stake: core.stakeOf(w),
                levelBps: c.bps[i],
                levelOpen: open,
                stakeOk: stakeOk,
                earning: open && stakeOk
            });
        }
    }

    function uplineOf(address user) external view returns (address referrer, bool isLegacy, bool exists) {
        referrer = core.referrerOf(user);
        exists = referrer != address(0);
        isLegacy = exists && _isLegacy(user);
    }

    // ====================== DOWNLINE ======================

    function _collect(address root, uint256 maxLevel, uint256 maxNodes)
        internal view
        returns (address[] memory wallets, uint8[] memory lvs, uint256 count, bool truncated)
    {
        wallets = new address[](maxNodes);
        lvs = new uint8[](maxNodes);
        uint256 tail;
        address[] memory kids = _childrenMerged(root);
        for (uint256 i = 0; i < kids.length; i++) {
            if (tail == maxNodes) return (wallets, lvs, tail, true);
            wallets[tail] = kids[i];
            lvs[tail] = 1;
            tail++;
        }
        uint256 head;
        while (head < tail) {
            address node = wallets[head];
            uint8 lv = lvs[head];
            head++;
            if (lv >= maxLevel) continue;
            address[] memory ch = _childrenMerged(node);
            for (uint256 i = 0; i < ch.length; i++) {
                if (tail == maxNodes) return (wallets, lvs, tail, true);
                wallets[tail] = ch[i];
                lvs[tail] = lv + 1;
                tail++;
            }
        }
        return (wallets, lvs, tail, false);
    }

    function levelSummary(address user, uint256 maxNodes)
        external view
        returns (LevelRow[] memory rows, uint256 totalMembers, bool truncated)
    {
        Cfg memory c = _cfg();
        (address[] memory w, uint8[] memory lv, uint256 count, bool cut) = _collect(user, c.n, maxNodes);
        uint256 directs = user == address(0) ? 0 : core.directReferrals(user);
        rows = new LevelRow[](c.n);
        for (uint256 i = 0; i < c.n; i++) {
            rows[i].level = uint8(i + 1);
            rows[i].levelBps = c.bps[i];
            rows[i].directsNeeded = c.directs[i];
            rows[i].open = user != address(0) && _levelOpen(c, i, user, directs);
        }
        uint256 bar = core.minDirectStake();
        for (uint256 i = 0; i < count; i++) {
            LevelRow memory r = rows[lv[i] - 1];
            r.members++;
            uint256 cached = core.cachedStake(w[i]);
            r.totalStake += cached + _active(w[i]);
            bool legacy = _isLegacy(w[i]);
            if (legacy) r.legacyMembers++;
            if (legacy || cached >= bar) r.qualified++;
        }
        return (rows, count, cut);
    }

    function downlineAtLevel(address user, uint8 level, uint256 offset, uint256 limit, uint256 maxNodes)
        external view
        returns (Node[] memory page, uint256 totalAtLevel, bool truncated)
    {
        require(level >= 1 && level <= core.levelCount(), "level out of range");
        (address[] memory w, uint8[] memory lv, uint256 count, bool cut) = _collect(user, level, maxNodes);
        for (uint256 i = 0; i < count; i++) if (lv[i] == level) totalAtLevel++;
        uint256 n = totalAtLevel > offset ? totalAtLevel - offset : 0;
        if (n > limit) n = limit;
        page = new Node[](n);
        uint256 seen;
        uint256 filled;
        for (uint256 i = 0; i < count && filled < n; i++) {
            if (lv[i] != level) continue;
            if (seen < offset) { seen++; continue; }
            page[filled++] = _node(w[i], level);
        }
        truncated = cut;
    }

    function directsView(address user) external view returns (Node[] memory list) {
        address[] memory kids = _childrenMerged(user);
        list = new Node[](kids.length);
        for (uint256 i = 0; i < kids.length; i++) list[i] = _node(kids[i], 1);
    }

    function _node(address w, uint8 level) internal view returns (Node memory nd) {
        bool legacy = _isLegacy(w);
        (, , , , , uint256 stakedAt, , , , , ) = legacyStaking.users(w);
        uint256 cached = core.cachedStake(w);
        nd.level = level;
        nd.wallet = w;
        nd.stake = core.stakeOf(w);
        nd.qualifyingStake = cached;
        nd.qualified = legacy || cached >= core.minDirectStake();
        nd.isLegacy = legacy;
        nd.referrer = core.referrerOf(w);
        nd.joinedAt = legacy ? stakedAt : 0;
    }

    // ====================== ONE-CALL SCREENS ======================

    function walletCard(address user) external view returns (WalletCard memory card) {
        Cfg memory c = _cfg();
        (, , , , , , address legacyRef, uint256 legacyDirects, , , ) = legacyStaking.users(user);
        address ref = core.referrerOf(user);
        uint256 directs = core.directReferrals(user);
        uint256 open;
        uint256 bps;
        for (uint256 i = 0; i < c.n; i++) {
            if (c.bps[i] > 0 && _levelOpen(c, i, user, directs)) {
                open = i + 1;
                bps += c.bps[i];
            }
        }
        uint256 cached = core.cachedStake(user);
        card.referrer = ref;
        card.hasUpline = ref != address(0);
        card.uplineIsLegacy = ref != address(0) && legacyRef == ref;
        card.legacyDirects = legacyDirects;
        card.registeredDirects = core.registeredDirects(user);
        card.qualifiedDirects = directs;
        card.directsForLevels = directs;
        card.levelsOpen = open;
        card.activeBps = bps;
        card.stake = core.stakeOf(user);
        card.qualifyingStake = cached;
        card.countsAsDirect = ref != address(0) && cached >= core.minDirectStake();
        card.owed = core.owed(user);
        card.volume = core.volume(user);
        card.rank = core.rankOf(user);
        if (card.rank > 0) {
            uint256 readyAt = core.rankSince(user) + RANK_HOLD;
            card.rankHoldRemaining = block.timestamp >= readyAt ? 0 : readyAt - block.timestamp;
        }
        // paid, bonusPaidTotal: not public on v6 (see header). Cooldown: none in v6.
    }

    function previewCommission(address from, uint256 rewardAmount)
        external view
        returns (address[] memory earners, uint8[] memory lvls, uint256[] memory amounts)
    {
        Cfg memory c = _cfg();
        earners = new address[](c.n);
        lvls = new uint8[](c.n);
        amounts = new uint256[](c.n);
        uint256 minRef = core.minReferrerStake();
        uint256 n;
        address cur = from;
        for (uint256 i = 0; i < c.n; i++) {
            address ref = core.referrerOf(cur);
            if (ref == address(0) || ref == from) break;
            cur = ref;
            uint256 amt;
            if (c.bps[i] > 0 && _levelOpen(c, i, ref, core.directReferrals(ref)) && core.cachedStake(ref) >= minRef) {
                amt = (rewardAmount * c.bps[i]) / 10_000;
            }
            earners[n] = ref;
            lvls[n] = uint8(i + 1);
            amounts[n] = amt;
            n++;
        }
        assembly { mstore(earners, n) mstore(lvls, n) mstore(amounts, n) }
    }

    // ====================== HEALTH (same as v5 Health) ======================

    function registerHealth(address user, address referrer) external view returns (bool ok, string memory reason) {
        if (core.paused()) return (false, "Joining is paused for a short upgrade. Please try again later.");
        if (referrer == address(0)) return (false, "This link has no sponsor in it.");
        if (user == referrer) return (false, "You cannot be your own sponsor.");
        if (core.nativeReferrer(user) != address(0)) return (false, "You are already on a team.");
        if (_legacyRef(user) != address(0)) return (false, "You are already on a team (old staking).");
        if (core.stakeOf(referrer) < core.minReferrerStake()) {
            return (false, "This sponsor has not staked enough yet to invite new members.");
        }
        address cur = referrer;
        for (uint256 i = 0; i < LOOP_SCAN_DEPTH; i++) {
            if (cur == address(0)) break;
            if (cur == user) return (false, "This sponsor is in your own team, so they cannot be your sponsor.");
            cur = core.referrerOf(cur);
        }
        return (true, "Ready to join.");
    }

    function programmeStats() external view returns (
        uint256 totalLevelBps,
        uint256 referralBudgetToday,
        uint256 minDirectStake,
        uint256 minReferrerStake,
        uint256 sourceCount,
        bool wired,
        bool paused,
        bool seedOpen
    ) {
        totalLevelBps = core.totalLevelBps();
        try IPoolV6Read(core.pool()).getTodayStats() returns (uint256, uint256, uint256, uint256, uint256, uint256 avail, uint256) {
            referralBudgetToday = avail;
        } catch {}
        minDirectStake = core.minDirectStake();
        minReferrerStake = core.minReferrerStake();
        sourceCount = core.stakeSourceCount();
        wired = sourceCount > 0 && core.spotModule() != address(0);
        paused = core.paused();
        seedOpen = !core.seedLocked() && block.timestamp <= core.seedDeadline();
    }

    function version() external pure returns (string memory) {
        return "OSGReferralLens v6 (for OSGReferral v6)";
    }
}
