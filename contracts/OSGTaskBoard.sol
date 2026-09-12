// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/*
 * =============================================================
 *  OSGTaskBoard v1
 *  Campaign board for OSGReferral v5.
 * =============================================================
 *
 *  WHAT THIS IS FOR
 *  ----------------
 *  Two kinds of task exist and they are not the same kind of thing.
 *
 *  A MEASURED task is something the chain can see for itself -- directs
 *  held, OSG staked, rank reached. Nobody has to vouch for it. The wallet
 *  presses claim, this contract asks OSGReferral what is true right now,
 *  and either it qualifies or it does not. There is no version of that
 *  which can be argued with.
 *
 *  An ATTESTED task is everything the chain cannot see: a post shared, a
 *  video made, a group grown. An admin marks the wallets that did it.
 *  That is a human judgement and it is recorded as one -- markTaskDone
 *  writes an event with a name against it.
 *
 *  Deliberately kept OUT of this contract:
 *  attestation is allowed to open a MANUAL task and nothing else. An
 *  admin cannot wave a wallet past a stake threshold it has not met,
 *  because a measured task never reads taskMarked at all.
 *
 *
 *  WHY IT IS A SEPARATE CONTRACT
 *  -----------------------------
 *  It moves no OSG. claimTask writes an entitlement into OSGReferral's
 *  airdrop ledger through grantAirdrop() and stops there; the wallet
 *  collects from OSGReferral itself. So the worst a bug in here can do
 *  is credit the wrong entitlement -- which the owner can zero -- rather
 *  than send the wrong payment, which nobody can take back.
 *
 *  It also means campaign rules can be replaced without redeploying the
 *  referral ledger. Campaign rules are the part most likely to change.
 *  Point OSGReferral at a new board and the tree, the levels, the ranks
 *  and every balance stay exactly where they are.
 *
 *  A batched grant is the only shape that works here, and not for
 *  convenience: RewardPool allows a distributor ONE distribute() per
 *  block, so a batch that actually paid out could never hold more than a
 *  single wallet. Assigning and claiming had to be separated for the
 *  design to function at all.
 */

interface IOSGReferralV5 {
    function grantAirdrop(address user, uint256 amount) external;
    function stakeOf(address user) external view returns (uint256);
    function rankOf(address user) external view returns (uint8);
    function volume(address user) external view returns (uint256);
    function verifiedDirectVolume(address user, address[] calldata directs)
        external view returns (uint256 count, uint256 stakeTotal);
    function currentRank(address user, address[] calldata directs)
        external view returns (uint8);
}

contract OSGTaskBoard is Ownable, Pausable, ReentrancyGuard {

    IOSGReferralV5 public referral;

    uint8 public constant KIND_MANUAL     = 0;
    uint8 public constant KIND_DIRECTS    = 1;
    uint8 public constant KIND_SELF_STAKE = 2;
    uint8 public constant KIND_TEAM_STAKE = 3;
    uint8 public constant KIND_RANK       = 4;
    uint8 public constant KIND_VOLUME     = 5;

    uint8 public constant PERM_MARK = 1; // attest MANUAL tasks
    uint8 public constant PERM_TASK = 2; // create and edit tasks
    mapping(address => uint8) public adminPerms;

    struct Task {
        uint8   kind;
        uint256 threshold;
        uint256 reward;
        uint256 budget;
        uint256 spent;
        uint64  startsAt;
        uint64  endsAt;
        bool    active;
    }
    Task[] public tasks;

    /// One reward per wallet per task, permanently. Running the same
    /// promotion again means a new task id -- which is also what keeps
    /// each round's participant list separate instead of merging two
    /// campaigns into one unreadable list.
    mapping(uint256 => mapping(address => bool)) public taskClaimed;
    mapping(uint256 => mapping(address => bool)) public taskMarked;
    mapping(uint256 => address[]) private _winners;

    /// Wallets per batch call. Three digits by design: past a few
    /// hundred the transaction stops fitting in a block.
    uint16 public maxBatch = 300;

    event ReferralUpdated(address referral);
    event AdminUpdated(address indexed admin, uint8 perms);
    event MaxBatchUpdated(uint16 n);
    event TaskCreated(uint256 indexed id, uint8 kind, uint256 threshold, uint256 reward, uint256 budget);
    event TaskUpdated(uint256 indexed id, uint256 threshold, uint256 reward, uint256 budget, uint64 startsAt, uint64 endsAt);
    event TaskActiveSet(uint256 indexed id, bool active);
    event TaskMarked(uint256 indexed id, address indexed user, address indexed by, bool marked);
    event TaskClaimed(uint256 indexed id, address indexed user, uint256 reward);
    event TaskBudgetExhausted(uint256 indexed id);

    constructor(address _referral, address _owner) Ownable(_owner) {
        require(_referral.code.length > 0, "referral not contract");
        referral = IOSGReferralV5(_referral);
    }

    modifier onlyAdmin(uint8 perm) {
        require(
            msg.sender == owner() || (adminPerms[msg.sender] & perm) != 0,
            "not permitted"
        );
        _;
    }

    // ================= ADMIN =================

    function setReferral(address _referral) external onlyOwner {
        require(_referral.code.length > 0, "referral not contract");
        referral = IOSGReferralV5(_referral);
        emit ReferralUpdated(_referral);
    }

    function setAdmin(address who, uint8 perms) external onlyOwner {
        require(who != address(0), "zero admin");
        require(perms <= 3, "unknown permission bit");
        adminPerms[who] = perms;
        emit AdminUpdated(who, perms);
    }

    function setMaxBatch(uint16 n) external onlyOwner {
        require(n >= 1 && n <= 999, "batch size out of range");
        maxBatch = n;
        emit MaxBatchUpdated(n);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ================= TASKS =================

    function createTask(
        uint8   kind,
        uint256 threshold,
        uint256 reward,
        uint256 budget,
        uint64  startsAt,
        uint64  endsAt
    ) external onlyAdmin(PERM_TASK) returns (uint256 id) {
        require(kind <= KIND_VOLUME, "unknown task kind");
        require(reward > 0, "reward is zero");
        require(budget >= reward, "budget below one reward");
        require(endsAt == 0 || endsAt > startsAt, "bad window");

        tasks.push(Task({
            kind:      kind,
            threshold: threshold,
            reward:    reward,
            budget:    budget,
            spent:     0,
            startsAt:  startsAt,
            endsAt:    endsAt,
            active:    true
        }));
        id = tasks.length - 1;
        emit TaskCreated(id, kind, threshold, reward, budget);
    }

    /// The kind is fixed at creation and stays fixed. Changing what a
    /// task measures after wallets have already qualified under the old
    /// rule rewrites history; a different measure is a different task.
    function updateTask(
        uint256 id,
        uint256 threshold,
        uint256 reward,
        uint256 budget,
        uint64  startsAt,
        uint64  endsAt
    ) external onlyAdmin(PERM_TASK) {
        require(id < tasks.length, "no such task");
        Task storage t = tasks[id];
        require(reward > 0, "reward is zero");
        require(budget >= t.spent, "budget below what is spent");
        require(endsAt == 0 || endsAt > startsAt, "bad window");

        // Once wallets can already be qualifying, the bar and the prize
        // are settled. Moving them afterwards rewrites the deal people
        // acted on. Budget and the closing date may still move -- one
        // only ever adds room, the other only shortens or extends the
        // window a campaign was announced with.
        if (block.timestamp >= t.startsAt) {
            require(threshold == t.threshold, "threshold is fixed once live");
            require(reward    == t.reward,    "reward is fixed once live");
            require(startsAt  == t.startsAt,  "start is fixed once live");
        }

        t.threshold = threshold;
        t.reward    = reward;
        t.budget    = budget;
        t.startsAt  = startsAt;
        t.endsAt    = endsAt;
        emit TaskUpdated(id, threshold, reward, budget, startsAt, endsAt);
    }

    function setTaskActive(uint256 id, bool active) external onlyAdmin(PERM_TASK) {
        require(id < tasks.length, "no such task");
        tasks[id].active = active;
        emit TaskActiveSet(id, active);
    }

    // ================= ATTESTATION =================

    /// MANUAL tasks only. The measured kinds never read taskMarked, so
    /// this cannot be used to push a wallet past a threshold.
    function markTaskDone(uint256 id, address[] calldata users)
        external
        onlyAdmin(PERM_MARK)
    {
        require(id < tasks.length, "no such task");
        require(tasks[id].kind == KIND_MANUAL, "task is measured, not attested");
        require(users.length > 0 && users.length <= maxBatch, "batch out of range");

        for (uint256 i = 0; i < users.length; i++) {
            address u = users[i];
            if (u == address(0) || taskMarked[id][u]) continue;
            taskMarked[id][u] = true;
            emit TaskMarked(id, u, msg.sender, true);
        }
    }

    /// Undo an attestation made in error. Closes the moment the wallet
    /// has claimed -- taking back an entitlement already credited is a
    /// different kind of act and this is not the function for it.
    function unmarkTaskDone(uint256 id, address[] calldata users)
        external
        onlyAdmin(PERM_MARK)
    {
        require(id < tasks.length, "no such task");
        require(users.length > 0 && users.length <= maxBatch, "batch out of range");

        for (uint256 i = 0; i < users.length; i++) {
            address u = users[i];
            if (!taskMarked[id][u] || taskClaimed[id][u]) continue;
            taskMarked[id][u] = false;
            emit TaskMarked(id, u, msg.sender, false);
        }
    }

    // ================= ELIGIBILITY =================

    function _eligible(uint256 id, address user, address[] calldata directs)
        internal
        view
        returns (bool)
    {
        Task storage t = tasks[id];
        if (t.kind == KIND_MANUAL)     return taskMarked[id][user];
        if (t.kind == KIND_SELF_STAKE) return referral.stakeOf(user) >= t.threshold;
        // rankOf is the STORED rank and outlives the conditions that
        // earned it. A task that says "hold R3" has to mean now.
        if (t.kind == KIND_RANK)
            return uint256(referral.currentRank(user, directs)) >= t.threshold;
        if (t.kind == KIND_VOLUME)     return referral.volume(user) >= t.threshold;

        (uint256 count, uint256 stakeTotal) = referral.verifiedDirectVolume(user, directs);
        if (t.kind == KIND_DIRECTS)    return count      >= t.threshold;
        if (t.kind == KIND_TEAM_STAKE) return stakeTotal >= t.threshold;
        return false;
    }

    function isEligible(uint256 id, address user, address[] calldata directs)
        external
        view
        returns (bool)
    {
        if (id >= tasks.length) return false;
        return _eligible(id, user, directs);
    }

    /// 0 not eligible - 1 eligible - 2 already taken
    function taskStatus(uint256 id, address user, address[] calldata directs)
        external
        view
        returns (uint8)
    {
        if (id >= tasks.length) return 0;
        if (taskClaimed[id][user]) return 2;
        return _eligible(id, user, directs) ? 1 : 0;
    }

    // ================= CLAIM =================

    /// Once per wallet per task, ever. `directs` is read only by the
    /// DIRECTS and TEAM_STAKE kinds; pass an empty array otherwise.
    ///
    /// No OSG moves here. The entitlement lands in OSGReferral's airdrop
    /// ledger and the wallet collects it there.
    function claimTask(uint256 id, address[] calldata directs)
        external
        nonReentrant
        whenNotPaused
    {
        require(id < tasks.length, "no such task");
        Task storage t = tasks[id];

        require(t.active, "task not active");
        require(block.timestamp >= t.startsAt, "task has not started");
        require(t.endsAt == 0 || block.timestamp <= t.endsAt, "task has closed");
        require(!taskClaimed[id][msg.sender], "already claimed");
        require(t.spent + t.reward <= t.budget, "task budget exhausted");
        require(_eligible(id, msg.sender, directs), "not eligible");

        taskClaimed[id][msg.sender] = true;
        t.spent += t.reward;
        _winners[id].push(msg.sender);

        referral.grantAirdrop(msg.sender, t.reward);

        emit TaskClaimed(id, msg.sender, t.reward);
        // No room left for another reward at this size.
        if (t.spent + t.reward > t.budget) emit TaskBudgetExhausted(id);
    }

    // ================= VIEWS =================

    function taskCount() external view returns (uint256) {
        return tasks.length;
    }

    function winnerCount(uint256 id) external view returns (uint256) {
        return _winners[id].length;
    }

    function winners(uint256 id, uint256 from, uint256 to)
        external
        view
        returns (address[] memory page)
    {
        address[] storage w = _winners[id];
        if (to > w.length) to = w.length;
        require(from <= to, "bad range");
        page = new address[](to - from);
        for (uint256 i = from; i < to; i++) page[i - from] = w[i];
    }

    function markedFor(uint256 id, address[] calldata users)
        external
        view
        returns (bool[] memory out)
    {
        out = new bool[](users.length);
        for (uint256 i = 0; i < users.length; i++) out[i] = taskMarked[id][users[i]];
    }

    function claimedBy(uint256 id, address[] calldata users)
        external
        view
        returns (bool[] memory out)
    {
        out = new bool[](users.length);
        for (uint256 i = 0; i < users.length; i++) out[i] = taskClaimed[id][users[i]];
    }

    function version() external pure returns (string memory) {
        return "OSGTaskBoard v1";
    }
}
