// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/*
 * ======================================================================
 *  OSGReferralLens v3
 *  Read-only companion to OSGReferral v5.
 * ======================================================================
 *
 *  WHY THIS EXISTS AS A NEW DEPLOYMENT
 *  -----------------------------------
 *  v2 held `IOSGReferralCore public immutable core`, written once in its
 *  constructor. There is no setter. The moment the ledger address moves
 *  from v4.2 to v5 this contract has to be built again -- not because
 *  anything in it is wrong, but because it cannot be told where to look.
 *
 *  WHAT CHANGED FROM v2, AND WHAT DID NOT
 *  --------------------------------------
 *  The contract body is UNCHANGED. Every function App.jsx calls --
 *  uplineOf, uplineView, levelSummary, directsView, walletCard -- reads
 *  exactly the same set of core functions, and every one of them exists
 *  in v5 with the same signature. That was checked function by function
 *  against v5's compiled ABI rather than assumed.
 *
 *  ONE LINE WAS REMOVED FROM THE INTERFACE:
 *
 *      function tiers(uint256) external view returns (
 *          uint256 directsNeeded, uint256 stakeNeeded, uint256 monthlyPayout
 *      );
 *
 *  v4.2's Tier struct had three fields. v5's has six -- directsNeeded,
 *  selfStakeNeeded, stakeNeeded, monthlyPayout, selfStakeUsd and
 *  stakeUsdNeeded -- so the public getter returns six words. An
 *  interface declaring three would decode the first three and hand back
 *  directsNeeded, selfStakeNeeded and stakeNeeded under the names
 *  directsNeeded, stakeNeeded and monthlyPayout. No revert. Just wrong
 *  numbers, silently, on whatever screen asked.
 *
 *  Nothing in this contract calls tiers(). It was declared and never
 *  used, so removing it changes no behaviour at all -- it only removes
 *  a loaded gun from the interface. If a rank screen wants tiers later,
 *  read them from the ledger directly, where the six-field shape is
 *  what the ABI says it is.
 *
 *  The v2 header notes on the merged tree, the legacy latch and the
 *  maxNodes cap all still apply and are reproduced below, because they
 *  are the reasoning a reader needs and none of it has changed.
 *
 *
 *  READING BOTH TREES
 *  ------------------
 *  v1 read the downline from core.childrenOf() alone, on the belief that
 *  OSGStaking stored a referrer per wallet and no child list. That was
 *  wrong. OSGStaking holds `mapping(address => address[]) _directRefs`
 *  and exposes `getDirectReferrals(address)`.
 *
 *  The consequence was not cosmetic. Almost every team on this system
 *  is still a legacy team, so a v1 Lens would have shown a member with
 *  five directs exactly zero. The commission, the levels and the ranks
 *  would all have kept paying correctly; only the screen would have
 *  lied. That is the worst kind of bug on a referral page, because the
 *  number people check is the number they trust.
 *
 *  So both child lists are read at every node and merged.
 *
 *  THE TWO LISTS CANNOT OVERLAP
 *  ----------------------------
 *  register() and registerFor() both refuse any wallet that already has
 *  an OSGStaking referrer, and OSGStaking writes its referrer once, on a
 *  wallet's first stake, behind a `referrer == address(0)` guard. A
 *  wallet is therefore in exactly one of the two lists.
 *
 *  The merge tests each legacy entry anyway, on the one path where being
 *  wrong would cost something: when BOTH lists have entries. A legacy
 *  list merged against an empty native list cannot produce a duplicate
 *  whatever the entries are, and that path returns the list untested.
 *
 *  LEGACY NODES ARE NOT NATIVE NODES
 *  ---------------------------------
 *  Three fields on a Node come from core storage a legacy wallet never
 *  wrote: directCounted (false), registeredAt (zero, which a UI renders
 *  as 1970) and qualifyingStake (excludes Active Staking by design).
 *
 *  What is actually true is that OSGStaking's totalReferrals is a latch:
 *  it counts a direct when the bond is written and never lets go, and
 *  core._directCount() adds that latched figure to nativeDirects. So a
 *  legacy direct is permanently counted toward its referrer's levels, by
 *  the rule the ledger itself applies. Hence: qualified true for legacy,
 *  joinedAt from OSGStaking's stakedAt, and an isLegacy flag so the UI
 *  can say which tree a member came from instead of inferring it.
 *
 *  qualifyingStake is left as the ledger reports it. It is genuinely
 *  zero for an unmigrated member and that is the honest figure, but it
 *  is NOT what decides whether a legacy direct counts. Render it as
 *  "migrated to Term/LP so far", not as a qualification test.
 *
 *  READING THE DOWNLINE
 *  --------------------
 *  Every downline call takes a maxNodes cap and returns however much
 *  fits inside it, with a flag saying whether it ran out. A view has no
 *  gas limit of its own but the node answering it does, so an unbounded
 *  walk on a large team would time out and return nothing at all. A
 *  truncated answer that says so is worth more than a failed one.
 *
 *  The cap is also what makes a malformed legacy chain survivable. The
 *  walk does not track visited wallets, so a cycle would revisit nodes
 *  rather than hang: the queue fills to maxNodes and returns truncated.
 * ======================================================================
 */

interface IOSGReferralCore {
    function referrerOf(address user) external view returns (address);
    function nativeReferrer(address user) external view returns (address);
    function childrenOf(address user) external view returns (address[] memory);
    function directReferrals(address user) external view returns (uint256);
    function registeredDirects(address user) external view returns (uint256);
    function nativeDirects(address user) external view returns (uint256);
    function directCounted(address user) external view returns (bool);
    function registeredAt(address user) external view returns (uint256);

    function stakeOf(address user) external view returns (uint256);
    function qualifyingStakeOf(address user) external view returns (uint256);

    function owed(address user) external view returns (uint256);
    function paid(address user) external view returns (uint256);
    function volume(address user) external view returns (uint256);

    function rankOf(address user) external view returns (uint8);
    function rankSince(address user) external view returns (uint256);
    function lastBonusAt(address user) external view returns (uint256);
    function bonusPaidTotal(address user) external view returns (uint256);

    function levelBps(uint256 i) external view returns (uint256);
    function levelConditions(uint256 i) external view returns (uint256);

    function minDirectStake() external view returns (uint256);
    function minReferrerStake() external view returns (uint256);

    function staking() external view returns (address);

    function RANK_HOLD() external view returns (uint256);
    function BONUS_PERIOD() external view returns (uint256);
}

interface IOSGStakingRead {
    function users(address user) external view returns (
        uint256 staked, uint256 rewardDebt, uint256 pendingHarvest,
        uint256 unstakeRequestAt, uint256 totalEarned, uint256 stakedAt,
        address referrer, uint256 totalReferrals, uint256 totalReferralEarned,
        uint256 totalTeamVolume, uint256 teamBonusEarned
    );

    /// The legacy child list. OSGStaking line 84 stores it, line 314
    /// writes it once per wallet, line 793 returns it.
    function getDirectReferrals(address user) external view returns (address[] memory);
}

contract OSGReferralLens {

    uint256 public constant LEVELS = 15;

    IOSGReferralCore public immutable core;

    /// Resolved once at construction rather than read per node. The
    /// downline walk calls into OSGStaking for every wallet it touches,
    /// and core.staking() is immutable over there, so asking it again
    /// each time buys nothing.
    IOSGStakingRead public immutable legacyStaking;

    constructor(address _core) {
        require(_core.code.length > 0, "core not contract");
        core = IOSGReferralCore(_core);

        address stk = IOSGReferralCore(_core).staking();
        require(stk.code.length > 0, "staking not contract");
        legacyStaking = IOSGStakingRead(stk);
    }

    // ====================== TYPES ======================

    struct UplineEntry {
        uint8   level;          // 1 = your direct referrer
        address wallet;
        uint256 stake;          // their total, across every source
        uint256 levelBps;       // the rate YOUR claims pay them at this level
        bool    levelOpen;      // do they have the directs to earn on it
        bool    stakeOk;        // do they hold enough to earn at all
        bool    earning;        // both of the above -- what actually decides
    }

    struct Node {
        uint8   level;
        address wallet;
        uint256 stake;              // total, all sources, Active included
        uint256 qualifyingStake;    // Term + LP only -- see header
        bool    qualified;          // counts toward the referrer's levels now
        bool    isLegacy;           // bonded in OSGStaking, not registered here
        address referrer;
        uint256 joinedAt;           // registeredAt, or first stake if legacy
    }

    struct LevelRow {
        uint8   level;
        uint256 members;
        uint256 legacyMembers;  // of those, how many came from the old tree
        uint256 qualified;
        uint256 totalStake;
        uint256 levelBps;
        uint256 directsNeeded;
        bool    open;
    }

    struct WalletCard {
        address referrer;
        bool    hasUpline;
        bool    uplineIsLegacy;     // read from OSGStaking, not registered here

        uint256 legacyDirects;      // counted inside OSGStaking, never falls
        uint256 registeredDirects;  // joined here, staked or not
        uint256 qualifiedDirects;   // joined here and currently holding enough
        uint256 directsForLevels;   // legacy + qualified: what opens levels
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

    // ====================== UPLINE ======================

    /// The whole chain above a wallet, with the rate each level earns on
    /// this wallet's claims and whether they would actually collect it.
    ///
    /// Works for legacy wallets too: the core falls back to OSGStaking
    /// when no local bond exists, so an old team reads exactly as it
    /// always did.
    function uplineView(address user) external view returns (UplineEntry[] memory chain) {
        address[] memory found = new address[](LEVELS);
        uint256 n;

        address current = user;
        for (uint256 i = 0; i < LEVELS; i++) {
            address ref = core.referrerOf(current);
            if (ref == address(0) || ref == user) break;
            found[n++] = ref;
            current = ref;
        }

        uint256 minRef = core.minReferrerStake();
        chain = new UplineEntry[](n);
        for (uint256 i = 0; i < n; i++) {
            address w = found[i];
            uint256 st = core.stakeOf(w);
            bool open = core.directReferrals(w) >= core.levelConditions(i);
            bool stakeOk = st >= minRef;

            chain[i] = UplineEntry({
                level:    uint8(i + 1),
                wallet:   w,
                stake:    st,
                levelBps: core.levelBps(i),
                levelOpen: open,
                stakeOk:  stakeOk,
                earning:  open && stakeOk
            });
        }
    }

    /// Just the immediate referrer, and where it came from. A wallet with
    /// no upline anywhere returns the zero address with both flags false,
    /// which is what a UI should render as "not registered".
    function uplineOf(address user)
        external
        view
        returns (address referrer, bool isLegacy, bool exists)
    {
        address local = core.nativeReferrer(user);
        if (local != address(0)) return (local, false, true);

        referrer = core.referrerOf(user);
        return (referrer, referrer != address(0), referrer != address(0));
    }

    // ====================== THE MERGED TREE ======================

    /// A wallet is legacy if it holds no local bond. Anything reached as
    /// somebody's child either registered here -- in which case
    /// nativeReferrer is set -- or came out of OSGStaking's list, in
    /// which case it cannot have registered here at all.
    ///
    /// This flag also decides whether a member counts toward its
    /// referrer's levels. OSGStaking's totalReferrals is a latch, and
    /// core._directCount() adds that latched figure in wholesale, so a
    /// legacy member is permanently counted and the screen has to say
    /// so. Locally registered wallets move both ways with syncDirect(),
    /// and directCounted is the live answer for those.
    function _isLegacy(address w) internal view returns (bool) {
        return core.nativeReferrer(w) == address(0);
    }

    /// Read the OSGStaking child list, tolerating a source that does not
    /// answer. A failure here should cost the legacy half of one screen,
    /// not the whole call.
    function _legacyChildren(address parent) internal view returns (address[] memory) {
        try legacyStaking.getDirectReferrals(parent) returns (address[] memory kids) {
            return kids;
        } catch {
            return new address[](0);
        }
    }

    /// Both child lists, native first, then legacy.
    ///
    /// The two early returns are not just a saving. A duplicate needs a
    /// wallet present in both lists, so when either list is empty there
    /// is nothing an overlap test could catch, and the legacy list can be
    /// handed back as it came.
    function _childrenMerged(address parent) internal view returns (address[] memory out) {
        address[] memory nat = core.childrenOf(parent);
        address[] memory leg = _legacyChildren(parent);

        if (leg.length == 0) return nat;
        if (nat.length == 0) return leg;

        out = new address[](nat.length + leg.length);
        uint256 k;
        for (uint256 i = 0; i < nat.length; i++) {
            out[k++] = nat[i];
        }
        for (uint256 i = 0; i < leg.length; i++) {
            if (_isLegacy(leg[i])) out[k++] = leg[i];
        }

        // Shrink to what was actually written. Assigning the length in
        // place is cheaper than allocating a second array to copy into,
        // and the slots beyond k were never handed out.
        assembly { mstore(out, k) }
    }

    // ====================== DOWNLINE ======================

    /// Breadth-first walk of the downline, across both trees.
    ///
    /// Bounded by maxNodes because a view still runs on somebody's node.
    /// `truncated` is the honest signal that a team outgrew the cap --
    /// page it with downlineAtLevel() rather than raising the cap until
    /// the call dies.
    function _collect(address root, uint256 maxLevel, uint256 maxNodes)
        internal
        view
        returns (address[] memory wallets, uint8[] memory levels, uint256 count, bool truncated)
    {
        if (maxLevel > LEVELS) maxLevel = LEVELS;
        wallets = new address[](maxNodes);
        levels  = new uint8[](maxNodes);

        uint256 tail;
        address[] memory kids = _childrenMerged(root);
        for (uint256 i = 0; i < kids.length; i++) {
            if (tail == maxNodes) return (wallets, levels, tail, true);
            wallets[tail] = kids[i];
            levels[tail]  = 1;
            tail++;
        }

        uint256 head;
        while (head < tail) {
            address node = wallets[head];
            uint8   lv   = levels[head];
            head++;
            if (lv >= maxLevel) continue;

            address[] memory ch = _childrenMerged(node);
            for (uint256 i = 0; i < ch.length; i++) {
                if (tail == maxNodes) return (wallets, levels, tail, true);
                wallets[tail] = ch[i];
                levels[tail]  = lv + 1;
                tail++;
            }
        }
        return (wallets, levels, tail, false);
    }

    /// One row per level: how many people, how many of them came from the
    /// old tree, how many currently count, what they hold between them,
    /// the rate, and whether the level is open to this wallet yet.
    ///
    /// This is the table a team screen is built around.
    function levelSummary(address user, uint256 maxNodes)
        external
        view
        returns (LevelRow[] memory rows, uint256 totalMembers, bool truncated)
    {
        (address[] memory w, uint8[] memory lv, uint256 count, bool cut) =
            _collect(user, LEVELS, maxNodes);

        rows = new LevelRow[](LEVELS);
        uint256 directs = core.directReferrals(user);

        for (uint256 i = 0; i < LEVELS; i++) {
            uint256 need = core.levelConditions(i);
            rows[i] = LevelRow({
                level: uint8(i + 1),
                members: 0,
                legacyMembers: 0,
                qualified: 0,
                totalStake: 0,
                levelBps: core.levelBps(i),
                directsNeeded: need,
                open: directs >= need
            });
        }

        for (uint256 i = 0; i < count; i++) {
            uint256 idx = lv[i] - 1;
            rows[idx].members++;
            rows[idx].totalStake += core.stakeOf(w[i]);

            // One read, used twice. Asking again for the qualified count
            // would be a second external call for every member of the
            // team on a full fifteen-level walk.
            //
            // Legacy members count permanently -- see _isLegacy.
            bool legacy = _isLegacy(w[i]);
            if (legacy) rows[idx].legacyMembers++;
            if (legacy || core.directCounted(w[i])) rows[idx].qualified++;
        }

        return (rows, count, cut);
    }

    /// Everyone at one depth, paged. `level` is 1-based.
    ///
    /// Split across two helpers rather than written as one function on
    /// purpose: the obvious version holds enough locals at once to run
    /// the stack out, and smaller functions cost nothing and read better.
    function downlineAtLevel(
        address user,
        uint8   level,
        uint256 offset,
        uint256 limit,
        uint256 maxNodes
    )
        external
        view
        returns (Node[] memory page, uint256 totalAtLevel, bool truncated)
    {
        require(level >= 1 && level <= LEVELS, "level out of range");

        (address[] memory w, uint8[] memory lv, uint256 count, bool cut) =
            _collect(user, level, maxNodes);

        totalAtLevel = _countAtLevel(lv, count, level);
        page = _pageAtLevel(w, lv, count, level, offset, limit, totalAtLevel);
        truncated = cut;
    }

    function _countAtLevel(uint8[] memory lv, uint256 count, uint8 level)
        internal
        pure
        returns (uint256 n)
    {
        for (uint256 i = 0; i < count; i++) {
            if (lv[i] == level) n++;
        }
    }

    function _pageAtLevel(
        address[] memory w,
        uint8[]   memory lv,
        uint256   count,
        uint8     level,
        uint256   offset,
        uint256   limit,
        uint256   totalAtLevel
    ) internal view returns (Node[] memory page) {
        uint256 n = totalAtLevel > offset ? totalAtLevel - offset : 0;
        if (n > limit) n = limit;
        page = new Node[](n);

        uint256 seen;
        uint256 filled;
        for (uint256 i = 0; i < count && filled < n; i++) {
            if (lv[i] != level) continue;
            if (seen < offset) { seen++; continue; }
            page[filled] = _node(w[i], level);
            filled++;
        }
    }

    /// The direct referrals of a wallet, in full detail, from both trees.
    /// The first screen most people want, and the cheapest of these
    /// calls.
    function directsView(address user) external view returns (Node[] memory list) {
        address[] memory kids = _childrenMerged(user);
        list = new Node[](kids.length);
        for (uint256 i = 0; i < kids.length; i++) {
            list[i] = _node(kids[i], 1);
        }
    }

    /// One row of a team screen.
    ///
    /// joinedAt is the real join date in both trees: registeredAt for a
    /// local bond, and OSGStaking's stakedAt -- the first stake, which is
    /// the transaction that wrote the bond -- for a legacy one. Reading
    /// registeredAt for a legacy wallet returns zero, which every date
    /// formatter in the world renders as 1970.
    function _node(address w, uint8 level) internal view returns (Node memory) {
        bool legacy = _isLegacy(w);

        uint256 joined;
        if (legacy) {
            (, , , , , uint256 stakedAt, , , , , ) = legacyStaking.users(w);
            joined = stakedAt;
        } else {
            joined = core.registeredAt(w);
        }

        return Node({
            level: level,
            wallet: w,
            stake: core.stakeOf(w),
            qualifyingStake: core.qualifyingStakeOf(w),
            qualified: legacy ? true : core.directCounted(w),
            isLegacy: legacy,
            referrer: core.referrerOf(w),
            joinedAt: joined
        });
    }

    // ====================== ONE-CALL SCREENS ======================

    /// Everything scalar about a wallet, in a single read.
    function walletCard(address user) external view returns (WalletCard memory card) {
        (, , , , , , address legacyRef, uint256 legacyDirects, , , ) =
            legacyStaking.users(user);

        address local = core.nativeReferrer(user);
        address ref   = local != address(0) ? local : legacyRef;

        uint256 directs = core.directReferrals(user);
        uint256 open;
        uint256 bps;
        for (uint256 i = 0; i < LEVELS; i++) {
            if (directs >= core.levelConditions(i)) {
                open = i + 1;
                bps += core.levelBps(i);
            }
        }

        card.referrer        = ref;
        card.hasUpline       = ref != address(0);
        card.uplineIsLegacy  = local == address(0) && legacyRef != address(0);

        card.legacyDirects     = legacyDirects;
        card.registeredDirects = core.registeredDirects(user);
        card.qualifiedDirects  = core.nativeDirects(user);
        card.directsForLevels  = directs;
        card.levelsOpen        = open;
        card.activeBps         = bps;

        card.stake           = core.stakeOf(user);
        card.qualifyingStake = core.qualifyingStakeOf(user);
        card.countsAsDirect  = core.directCounted(user);

        card.owed   = core.owed(user);
        card.paid   = core.paid(user);
        card.volume = core.volume(user);

        card.rank           = core.rankOf(user);
        card.bonusPaidTotal = core.bonusPaidTotal(user);

        uint256 since = core.rankSince(user);
        if (card.rank > 0) {
            uint256 readyAt = since + core.RANK_HOLD();
            card.rankHoldRemaining = block.timestamp >= readyAt ? 0 : readyAt - block.timestamp;
        }
        uint256 nextAt = core.lastBonusAt(user) + core.BONUS_PERIOD();
        card.bonusCooldownRemaining =
            block.timestamp >= nextAt ? 0 : nextAt - block.timestamp;
    }

    /// What a single reward claim by `from` would put into each upline's
    /// ledger, right now. Shows zeros where a level is closed or the
    /// upline's own stake is short, which is exactly the question people
    /// ask when a figure looks lower than they expected.
    function previewCommission(address from, uint256 rewardAmount)
        external
        view
        returns (address[] memory earners, uint8[] memory levels, uint256[] memory amounts)
    {
        address[] memory found = new address[](LEVELS);
        uint256[] memory cuts  = new uint256[](LEVELS);
        uint8[]   memory lv    = new uint8[](LEVELS);
        uint256 n;

        uint256 minRef = core.minReferrerStake();
        address current = from;

        for (uint256 i = 0; i < LEVELS; i++) {
            address ref = core.referrerOf(current);
            if (ref == address(0) || ref == from) break;
            current = ref;

            uint256 amt;
            if (core.directReferrals(ref) >= core.levelConditions(i) &&
                core.stakeOf(ref) >= minRef) {
                amt = (rewardAmount * core.levelBps(i)) / 10_000;
            }

            found[n] = ref;
            lv[n]    = uint8(i + 1);
            cuts[n]  = amt;
            n++;
        }

        earners = new address[](n);
        levels  = new uint8[](n);
        amounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            earners[i] = found[i];
            levels[i]  = lv[i];
            amounts[i] = cuts[i];
        }
    }

    function version() external pure returns (string memory) {
        return "OSGReferralLens v3 (for OSGReferral v5)";
    }
}
