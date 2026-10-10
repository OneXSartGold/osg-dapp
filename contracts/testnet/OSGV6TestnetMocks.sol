// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

// TESTNET ONLY (Polygon Amoy). Never deploy on mainnet.
// Stand-ins for the live RewardPool, legacy OSGStaking and a Term/LP-like
// stake source, so OSGReferralV6 can be rehearsed end to end with the real
// v5 snapshot. Every write is owner-only.

interface IV6Hooks {
    function onRewardClaimed(address user, uint256 amount) external;
    function onLiquidityChange(address user, uint256 delta, bool isAdd) external;
}

abstract contract TestOwned {
    address public owner;
    constructor() { owner = msg.sender; }
    modifier onlyOwner() { require(msg.sender == owner, "owner only"); _; }
}

/// RewardPool stand-in: referral category with base + carry, one call per
/// block per distributor, 10,000 OSG single-call cap. Records credits only.
contract TestRewardPool is TestOwned {
    uint256 public startTime;
    uint256 public referralPercent = 31;
    uint256 public dailyBase = 5_881e18;
    uint256 public carry;
    uint256 public lastDay;
    uint256 public used;
    mapping(address => uint256) public credited;
    mapping(address => uint256) public lastBlock;
    uint256 public totalCredited;

    constructor(uint256 daysAgo) {
        startTime = block.timestamp - daysAgo * 1 days;
        lastDay = (block.timestamp - startTime) / 1 days;
    }

    function setCarry(uint256 c) external onlyOwner { carry = c; }
    function setDailyBase(uint256 b) external onlyOwner { dailyBase = b; }

    function _today() internal view returns (uint256) { return (block.timestamp - startTime) / 1 days; }
    function _limit() internal view returns (uint256) { return dailyBase * referralPercent / 100 + carry; }

    /// Like the live pool, the view does not roll the day.
    function syncDays() public { if (_today() != lastDay) { lastDay = _today(); used = 0; } }

    function getTodayStats() external view returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256) {
        uint256 l = _limit();
        return (0, 0, used, 0, 0, l > used ? l - used : 0, dailyBase);
    }

    function distribute(address user, uint256 amount, uint8 cat) external {
        require(cat == 3, "cat");
        require(amount > 0 && amount <= 10_000e18, "amount");
        require(lastBlock[msg.sender] < block.number, "One call per block per distributor");
        lastBlock[msg.sender] = block.number;
        syncDays();
        require(used + amount <= _limit(), "Referral cap exceeded");
        used += amount;
        credited[user] += amount;
        totalCredited += amount;
    }
}

/// Legacy OSGStaking stand-in: users() with the same 11 fields.
contract TestLegacyStaking is TestOwned {
    struct U { uint256 staked; address referrer; uint256 totalReferrals; }
    mapping(address => U) public u;

    function setMany(address[] calldata who, uint256[] calldata staked, address[] calldata refs, uint256[] calldata counts)
        external onlyOwner
    {
        require(who.length == staked.length && who.length == refs.length && who.length == counts.length, "length");
        for (uint256 i = 0; i < who.length; i++) u[who[i]] = U(staked[i], refs[i], counts[i]);
    }

    function users(address who) external view returns (
        uint256, uint256, uint256, uint256, uint256, uint256, address, uint256, uint256, uint256, uint256
    ) {
        U memory x = u[who];
        return (x.staked, 0, 0, 0, 0, 0, x.referrer, x.totalReferrals, 0, 0, 0);
    }
}

/// Term/LP-like stake source: stakedOf(), spot positions, and both hooks
/// wrapped in try/catch exactly like the live sources.
contract TestStakeSource is TestOwned {
    IV6Hooks public ref;
    mapping(address => uint256) public stakedOf;
    struct P { uint256 amount; uint256 start; bool open; }
    mapping(address => P[]) internal _pos;
    event HookFailed(bytes reason);

    function setRef(address r) external onlyOwner { ref = IV6Hooks(r); }

    function _deposit(address user, uint256 amount) internal {
        stakedOf[user] += amount;
        _pos[user].push(P(amount, block.timestamp, true));
        try ref.onLiquidityChange(user, amount, true) {} catch (bytes memory r) { emit HookFailed(r); }
    }

    function deposit(address user, uint256 amount) external onlyOwner { _deposit(user, amount); }

    function depositMany(address[] calldata users, uint256[] calldata amounts) external onlyOwner {
        require(users.length == amounts.length, "length");
        for (uint256 i = 0; i < users.length; i++) _deposit(users[i], amounts[i]);
    }

    function withdrawAll(address user) external onlyOwner {
        stakedOf[user] = 0;
        for (uint256 i = 0; i < _pos[user].length; i++) _pos[user][i].open = false;
        try ref.onLiquidityChange(user, 0, false) {} catch (bytes memory r) { emit HookFailed(r); }
    }

    /// A reward claim by `user`: fires the commission hook.
    function claim(address user, uint256 reward) external onlyOwner {
        try ref.onRewardClaimed(user, reward) {} catch (bytes memory r) { emit HookFailed(r); }
    }

    function spotUnderlying() external view returns (address) { return address(this); }
    function spotPositionCount(address user) external view returns (uint256) { return _pos[user].length; }
    function spotPosition(address user, uint256 i) external view returns (uint256, uint256, bool) {
        P memory p = _pos[user][i];
        return (p.amount, p.start, p.open);
    }
}
