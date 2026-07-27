// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IRewardPool {
    function distribute(address user, uint256 amount, uint8 category) external;
    function getDailyBase()    external view returns (uint256);
    function startTime()       external view returns (uint256);
    function emissionEndTime() external view returns (uint256);
    function getUserReward(address user) external view returns (uint256);
    function stakingPercent()  external view returns (uint256);
    function emissionStopped() external view returns (bool);
}

contract OSGStaking is ReentrancyGuard, Pausable, Ownable {

    using SafeERC20 for IERC20;

    uint8   public constant CAT_STAKING  = 1;
    uint8   public constant CAT_REFERRAL = 3;

    uint256 public constant MIN_STAKE        = 10     * 1e18;
    uint256 public constant MIN_CLAIM        = 1      * 1e18;
    uint256 public constant MAX_REWARD_CLAIM = 10_000 * 1e18;
    uint256 public constant UNSTAKE_COOLDOWN = 12 hours;
    uint256 public constant PRECISION        = 1e18;
    uint256 public constant MAX_FEE_BP       = 200;
    uint256 public constant REF_DEPTH        = 5;

    uint256 public constant REF_L1    = 50;
    uint256 public constant REF_L2    = 30;
    uint256 public constant REF_L3    = 20;
    uint256 public constant REF_L4    = 10;
    uint256 public constant REF_L5    = 5;
    uint256 public constant REF_DENOM = 1000;

    uint8 public constant REASON_LOW_STAKE = 1;
    uint8 public constant REASON_INACTIVE  = 2;
    uint8 public constant REASON_ZERO_ADDR = 3;
    uint8 public constant REASON_CIRCULAR  = 4;
    uint8 public constant REASON_SELF      = 5;

    IERC20      public immutable osgToken;
    IRewardPool public           rewardPool;

    uint256 public accRewardPerShare;
    uint256 public lastUpdateTime;
    uint256 public totalStaked;
    uint256 public totalUsers;
    uint256 public activeStakers;

    address public treasury;
    uint256 public stakeFee   = 0;
    uint256 public unstakeFee = 0;

    uint256 public referralReserve;
    uint256 public teamBonusReserve;

    uint256 public minReferrerStake        = 100 * 1e18;
    uint256 public minReferrerDays         = 1 days;
    bool    public referralEnabled         = true;
    bool    public emitSkippedInDistribute = false;

    struct UserInfo {
        uint256 staked;
        uint256 rewardDebt;
        uint256 pendingHarvest;
        uint256 unstakeRequestAt;
        uint256 totalEarned;
        uint256 stakedAt;
        address referrer;
        uint256 totalReferrals;
        uint256 totalReferralEarned;
        uint256 totalTeamVolume;
        uint256 teamBonusEarned;
    }

    mapping(address => UserInfo)  public  users;
    mapping(address => address[]) private _directRefs;
    mapping(address => bool)      private _inList;
    mapping(address => uint256)   public  pendingReferralReward;

    uint256 public totalPendingReferral;
    uint256 public totalRewardDistributed;
    uint256 public totalReferralAccrued;
    uint256 public totalTeamBonusDistributed;

    event StakerRegistered(address indexed user, uint256 indexed at, address indexed referrer);
    event StakerReactivated(address indexed user, uint256 indexed at);
    event StakerExited(address indexed user, uint256 indexed at);
    event Staked(address indexed user, uint256 amount, address indexed referrer, uint256 totalStaked);
    event StakeAdded(address indexed user, uint256 added, uint256 newTotal);
    event UnstakeRequested(address indexed user, uint256 amount, uint256 availableAt);
    event UnstakeCancelled(address indexed user);
    event Unstaked(address indexed user, uint256 amount);
    event StakingRewardDistributed(address indexed user, uint256 amount, uint256 remaining);
    event StakingRewardDistributeFailed(address indexed user, uint256 amount, string reason);
    event ReferralAccrued(address indexed referrer, address indexed staker, uint256 amount, uint8 level);
    event ReferralPaid(address indexed user, uint256 amount);
    event ReferralRejected(address indexed referrer, address indexed staker, uint8 reasonCode);
    event ReferralSkipped(address indexed referrer, address indexed staker, uint8 level, uint8 code);
    event TeamBonusDistributed(address indexed user, uint256 amount, uint8 rank, address indexed by);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event PoolUpdated(uint256 accRewardPerShare, uint256 rewardAdded);
    event ReferralReserveFunded(uint256 amount, uint256 newTotal);
    event TeamBonusReserveFunded(uint256 amount, uint256 newTotal);
    event ExcessOSGSwept(address indexed to, uint256 amount);
    event TokenRescued(address indexed token, uint256 amount);
    event RewardPoolUpdated(address indexed pool);
    event TreasuryUpdated(address indexed treasury);
    event FeesUpdated(uint256 stakeFee, uint256 unstakeFee);
    event ReferralToggled(bool enabled);
    event ReferralParamsUpdated(uint256 minStake, uint256 minDays);
    event EmergencyAction(string action, address indexed by);

    constructor(
        address _osgToken,
        address _rewardPool,
        address _treasury,
        address _owner
    ) Ownable(_owner) {
        require(_osgToken.code.length   > 0, "Token must be contract");
        require(_rewardPool.code.length > 0, "Pool must be contract");
        require(_treasury   != address(0),   "Invalid treasury");
        osgToken       = IERC20(_osgToken);
        rewardPool     = IRewardPool(_rewardPool);
        treasury       = _treasury;
        lastUpdateTime = block.timestamp;
    }

    receive()  external payable { revert("No native token"); }
    fallback() external payable { revert("Invalid call"); }

    function _isCircular(address staker, address referrer)
        internal view returns (bool)
    {
        address cur = referrer;
        for (uint256 i = 0; i < REF_DEPTH; ) {
            if (cur == address(0)) return false;
            if (cur == staker)    return true;
            cur = users[cur].referrer;
            unchecked { i++; }
        }
        return false;
    }

    function _checkReferrer(address referrer)
        internal view returns (bool ok, uint8 code)
    {
        if (referrer == address(0))
            return (false, REASON_ZERO_ADDR);
        UserInfo storage r = users[referrer];
        if (r.staked < minReferrerStake)
            return (false, REASON_LOW_STAKE);
        if (r.stakedAt == 0 || block.timestamp < r.stakedAt + minReferrerDays)
            return (false, REASON_INACTIVE);
        return (true, 0);
    }

    function _updatePool() internal {
        uint256 ts      = block.timestamp;
        uint256 endTime = rewardPool.emissionEndTime();

        if (ts <= lastUpdateTime || totalStaked == 0) {
            lastUpdateTime = ts;
            return;
        }

        uint256 dailyBase  = rewardPool.getDailyBase();
        uint256 stakingPct = rewardPool.stakingPercent();
        bool    stopped    = rewardPool.emissionStopped();

        if (dailyBase == 0 || stopped || lastUpdateTime >= endTime) {
            lastUpdateTime = ts;
            return;
        }

        uint256 effectiveTs = ts > endTime ? endTime : ts;
        uint256 elapsed     = effectiveTs - lastUpdateTime;

        if (elapsed > 0) {
            uint256 dailyStaking = (dailyBase * stakingPct) / 100;
            uint256 reward       = (dailyStaking * elapsed) / 1 days;
            if (reward > 0) {
                accRewardPerShare += (reward * PRECISION) / totalStaked;
                emit PoolUpdated(accRewardPerShare, reward);
            }
        }

        lastUpdateTime = effectiveTs;
    }

    function _settlePending(UserInfo storage u) internal {
        if (u.staked == 0) return;
        uint256 gross = (u.staked * accRewardPerShare) / PRECISION;
        if (gross > u.rewardDebt) {
            u.pendingHarvest += gross - u.rewardDebt;
        }
        u.rewardDebt = (u.staked * accRewardPerShare) / PRECISION;
    }

    function _accrueReferral(address staker, uint256 stakingReward) internal {
        if (!referralEnabled) return;

        address[5] memory refs;
        uint256[5] memory pcts = [REF_L1, REF_L2, REF_L3, REF_L4, REF_L5];

        refs[0] = users[staker].referrer;
        for (uint8 i = 1; i < 5; ) {
            if (refs[i-1] == address(0)) break;
            refs[i] = users[refs[i-1]].referrer;
            unchecked { i++; }
        }

        for (uint8 i = 0; i < 5; ) {
            address ref = refs[i];
            if (ref == address(0)) break;
            (bool ok, uint8 code) = _checkReferrer(ref);
            if (ok) {
                uint256 refReward = (stakingReward * pcts[i]) / REF_DENOM;
                if (refReward > 0) {
                    pendingReferralReward[ref]     += refReward;
                    users[ref].totalReferralEarned += refReward;
                    totalPendingReferral           += refReward;
                    totalReferralAccrued           += refReward;
                    emit ReferralAccrued(ref, staker, refReward, i + 1);
                }
            } else if (emitSkippedInDistribute) {
                emit ReferralSkipped(ref, staker, i + 1, code);
            }
            unchecked { i++; }
        }
    }

    function _updateTeamVolume(address staker, uint256 amount) internal {
        address ref = users[staker].referrer;
        if (ref == address(0)) return;
        users[ref].totalTeamVolume += amount;
    }

    function pendingReward(address _user) public view returns (uint256) {
        UserInfo storage u = users[_user];
        if (u.staked == 0) return u.pendingHarvest;

        uint256 ts      = block.timestamp;
        uint256 endTime = rewardPool.emissionEndTime();
        uint256 simAcc  = accRewardPerShare;

        if (ts > lastUpdateTime && totalStaked > 0 && lastUpdateTime < endTime) {
            uint256 dailyBase  = rewardPool.getDailyBase();
            uint256 stakingPct = rewardPool.stakingPercent();
            bool    stopped    = rewardPool.emissionStopped();

            if (dailyBase > 0 && !stopped) {
                uint256 effectiveTs = ts > endTime ? endTime : ts;
                uint256 elapsed     = effectiveTs > lastUpdateTime
                    ? effectiveTs - lastUpdateTime : 0;
                if (elapsed > 0) {
                    uint256 daily  = (dailyBase * stakingPct) / 100;
                    uint256 reward = (daily * elapsed) / 1 days;
                    simAcc += (reward * PRECISION) / totalStaked;
                }
            }
        }

        uint256 gross   = (u.staked * simAcc) / PRECISION;
        uint256 pending = gross > u.rewardDebt ? gross - u.rewardDebt : 0;
        return u.pendingHarvest + pending;
    }

    function canClaimNow(address user)
        external view
        returns (bool canClaim, uint256 amount, uint256 total, string memory reason)
    {
        total  = pendingReward(user);
        amount = total > MAX_REWARD_CLAIM ? MAX_REWARD_CLAIM : total;
        if (paused())
            return (false, amount, total, "Contract paused");
        if (total < MIN_CLAIM)
            return (false, amount, total, "Below minimum 1 OSG");
        if (rewardPool.emissionStopped())
            return (false, amount, total, "Emission stopped");
        return (true, amount, total, "");
    }

    function stake(uint256 amount, address referrer)
        external
        nonReentrant
        whenNotPaused
    {
        require(amount >= MIN_STAKE, "Minimum 10 OSG required");
        require(
            block.timestamp <= rewardPool.emissionEndTime(),
            "Staking emission period ended"
        );

        UserInfo storage u = users[msg.sender];

        if (referralEnabled && referrer != address(0) && u.referrer == address(0)) {
            if (referrer == msg.sender) {
                emit ReferralRejected(referrer, msg.sender, REASON_SELF);
            } else if (_isCircular(msg.sender, referrer)) {
                emit ReferralRejected(referrer, msg.sender, REASON_CIRCULAR);
            } else {
                (bool ok, uint8 code) = _checkReferrer(referrer);
                if (ok) {
                    u.referrer = referrer;
                    users[referrer].totalReferrals++;
                    _directRefs[referrer].push(msg.sender);
                } else {
                    emit ReferralRejected(referrer, msg.sender, code);
                }
            }
        }

        _updatePool();
        _settlePending(u);

        uint256 before   = osgToken.balanceOf(address(this));
        osgToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = osgToken.balanceOf(address(this)) - before;
        require(received > 0, "Zero received");

        if (stakeFee > 0) {
            uint256 fee = (received * stakeFee) / 10_000;
            if (fee > 0) {
                osgToken.safeTransfer(treasury, fee);
                received -= fee;
            }
        }
        require(received > 0, "Zero after fee");

        bool wasEmpty = u.staked == 0;

        u.staked    += received;
        u.rewardDebt = (u.staked * accRewardPerShare) / PRECISION;
        totalStaked += received;
        _updateTeamVolume(msg.sender, received);

        if (!_inList[msg.sender]) {
            _inList[msg.sender] = true;
            totalUsers++;
            u.stakedAt = block.timestamp;
            emit StakerRegistered(msg.sender, block.timestamp, u.referrer);
        } else if (wasEmpty) {
            u.stakedAt = block.timestamp;
            emit StakerReactivated(msg.sender, block.timestamp);
        }

        if (wasEmpty) activeStakers++;

        emit Staked(msg.sender, received, u.referrer, totalStaked);
    }

    function addToStake(uint256 amount)
        external
        nonReentrant
        whenNotPaused
    {
        require(amount >= MIN_STAKE, "Minimum 10 OSG");
        require(
            block.timestamp <= rewardPool.emissionEndTime(),
            "Staking emission period ended"
        );

        UserInfo storage u = users[msg.sender];
        require(u.staked > 0, "Use stake() first");

        _updatePool();
        _settlePending(u);

        uint256 before   = osgToken.balanceOf(address(this));
        osgToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = osgToken.balanceOf(address(this)) - before;
        require(received > 0, "Zero received");

        if (stakeFee > 0) {
            uint256 fee = (received * stakeFee) / 10_000;
            if (fee > 0) {
                osgToken.safeTransfer(treasury, fee);
                received -= fee;
            }
        }
        require(received > 0, "Zero after fee");

        u.staked    += received;
        u.rewardDebt = (u.staked * accRewardPerShare) / PRECISION;
        totalStaked += received;
        _updateTeamVolume(msg.sender, received);

        emit StakeAdded(msg.sender, received, u.staked);
    }

    function requestUnstake() external nonReentrant whenNotPaused {
        UserInfo storage u = users[msg.sender];
        require(u.staked > 0,            "Nothing staked");
        require(u.unstakeRequestAt == 0, "Already requested");
        u.unstakeRequestAt = block.timestamp;
        emit UnstakeRequested(
            msg.sender,
            u.staked,
            block.timestamp + UNSTAKE_COOLDOWN
        );
    }

    function cancelUnstake() external nonReentrant {
        UserInfo storage u = users[msg.sender];
        require(u.unstakeRequestAt > 0, "No pending request");
        u.unstakeRequestAt = 0;
        emit UnstakeCancelled(msg.sender);
    }

    function unstake() external nonReentrant {
        UserInfo storage u = users[msg.sender];
        require(u.staked > 0,           "Nothing staked");
        require(u.unstakeRequestAt > 0, "Request first");
        require(
            block.timestamp >= u.unstakeRequestAt + UNSTAKE_COOLDOWN,
            "12h cooldown not complete"
        );

        _updatePool();
        _settlePending(u);

        uint256 amount = u.staked;

        if (unstakeFee > 0) {
            uint256 fee = (amount * unstakeFee) / 10_000;
            if (fee > 0) {
                osgToken.safeTransfer(treasury, fee);
                amount -= fee;
            }
        }

        totalStaked        -= u.staked;
        u.staked            = 0;
        u.rewardDebt        = 0;
        u.unstakeRequestAt  = 0;

        if (activeStakers > 0) activeStakers--;

        emit StakerExited(msg.sender, block.timestamp);
        emit Unstaked(msg.sender, amount);

        osgToken.safeTransfer(msg.sender, amount);
    }

    function claimReward()
        external
        nonReentrant
        whenNotPaused
    {
        UserInfo storage u = users[msg.sender];

        _updatePool();
        _settlePending(u);

        uint256 total = u.pendingHarvest;
        require(total >= MIN_CLAIM, "Minimum 1 OSG to claim");

        uint256 harvest = total > MAX_REWARD_CLAIM ? MAX_REWARD_CLAIM : total;

        try rewardPool.distribute(msg.sender, harvest, CAT_STAKING) {

            u.pendingHarvest       -= harvest;
            u.totalEarned          += harvest;
            totalRewardDistributed += harvest;

            _accrueReferral(msg.sender, harvest);

            emit StakingRewardDistributed(msg.sender, harvest, u.pendingHarvest);

        } catch Error(string memory reason) {
            emit StakingRewardDistributeFailed(msg.sender, harvest, reason);
            revert(string(abi.encodePacked("Distribute failed: ", reason)));

        } catch {
            emit StakingRewardDistributeFailed(msg.sender, harvest, "Unknown");
            revert("RewardPool distribute failed - retry next block");
        }
    }

    function emergencyWithdraw() external nonReentrant {
        UserInfo storage u = users[msg.sender];
        require(u.staked > 0, "Nothing staked");

        uint256 amount = u.staked;
        totalStaked        -= amount;
        u.staked            = 0;
        u.rewardDebt        = 0;
        u.unstakeRequestAt  = 0;
        u.pendingHarvest    = 0;

        if (activeStakers > 0) activeStakers--;

        emit StakerExited(msg.sender, block.timestamp);
        emit EmergencyWithdraw(msg.sender, amount);

        osgToken.safeTransfer(msg.sender, amount);
    }

    function fundReferralReserve(uint256 amount) external onlyOwner {
        require(amount > 0, "Zero amount");
        uint256 before   = osgToken.balanceOf(address(this));
        osgToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = osgToken.balanceOf(address(this)) - before;
        require(received > 0, "Zero received");
        referralReserve += received;
        emit ReferralReserveFunded(received, referralReserve);
    }

    function fundTeamBonusReserve(uint256 amount) external onlyOwner {
        require(amount > 0, "Zero amount");
        uint256 before   = osgToken.balanceOf(address(this));
        osgToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = osgToken.balanceOf(address(this)) - before;
        require(received > 0, "Zero received");
        teamBonusReserve += received;
        emit TeamBonusReserveFunded(received, teamBonusReserve);
    }

    function distributeReferralReward(address user)
        external
        onlyOwner
        nonReentrant
    {
        require(user != address(0), "Invalid user");
        uint256 amount = pendingReferralReward[user];
        require(amount > 0,                "No pending referral");
        require(referralReserve >= amount, "Insufficient referral reserve");

        pendingReferralReward[user] = 0;
        if (totalPendingReferral >= amount) totalPendingReferral -= amount;
        referralReserve -= amount;

        osgToken.safeTransfer(user, amount);
        emit ReferralPaid(user, amount);
    }

    function teamBonusDistribute(address user, uint256 amount, uint8 rank)
        external
        onlyOwner
        nonReentrant
    {
        require(user   != address(0),       "Invalid user");
        require(amount >  0,                "Zero amount");
        require(rank   >= 1 && rank <= 4,   "Rank: 1-4");
        require(users[user].staked > 0,     "User not active");
        require(teamBonusReserve >= amount, "Insufficient team bonus reserve");

        users[user].teamBonusEarned += amount;
        totalTeamBonusDistributed  += amount;
        teamBonusReserve           -= amount;

        osgToken.safeTransfer(user, amount);
        emit TeamBonusDistributed(user, amount, rank, msg.sender);
    }

    function sweepExcessOSG(address to, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        require(to     != address(0), "Invalid recipient");
        require(amount >  0,          "Zero amount");
        uint256 balance   = osgToken.balanceOf(address(this));
        uint256 allocated = totalStaked + referralReserve + teamBonusReserve;
        require(balance > allocated,           "No excess to sweep");
        require(amount <= balance - allocated, "Exceeds excess");
        osgToken.safeTransfer(to, amount);
        emit ExcessOSGSwept(to, amount);
    }

    function rescueToken(address token, uint256 amount) external onlyOwner {
        require(token  != address(osgToken),   "Cannot rescue OSG");
        require(token  != address(rewardPool), "Cannot rescue RewardPool");
        require(token  != address(0),          "Invalid token");
        require(amount >  0,                   "Zero amount");
        IERC20(token).safeTransfer(owner(), amount);
        emit TokenRescued(token, amount);
    }

    function setRewardPool(address _pool) external onlyOwner {
        require(_pool.code.length > 0, "Must be contract");
        rewardPool = IRewardPool(_pool);
        emit RewardPoolUpdated(_pool);
    }

    function setTreasury(address _t) external onlyOwner {
        require(_t != address(0), "Invalid");
        treasury = _t;
        emit TreasuryUpdated(_t);
    }

    function setFees(uint256 _s, uint256 _u) external onlyOwner {
        require(_s <= MAX_FEE_BP && _u <= MAX_FEE_BP, "Max 2%");
        stakeFee   = _s;
        unstakeFee = _u;
        emit FeesUpdated(_s, _u);
    }

    function setReferralEnabled(bool _e) external onlyOwner {
        referralEnabled = _e;
        emit ReferralToggled(_e);
    }

    function setReferralParams(uint256 _minStake, uint256 _minDays)
        external onlyOwner
    {
        require(_minStake >= MIN_STAKE, "Too low");
        require(_minDays  <= 30 days,   "Max 30 days");
        minReferrerStake = _minStake;
        minReferrerDays  = _minDays;
        emit ReferralParamsUpdated(_minStake, _minDays);
    }

    function setEmitSkipped(bool _e) external onlyOwner {
        emitSkippedInDistribute = _e;
    }

    function pause()   external onlyOwner { _pause();   emit EmergencyAction("PAUSE",   msg.sender); }
    function unpause() external onlyOwner { _unpause(); emit EmergencyAction("UNPAUSE", msg.sender); }

    // ─────────────────────────────────────────────────
    //  VIEW FUNCTIONS
    // ─────────────────────────────────────────────────

    function version() external pure returns (string memory) {
        return "OSGStaking v11";
    }

    function isRewardPoolLive()
        external view
        returns (bool live, string memory reason)
    {
        if (address(rewardPool) == address(0))
            return (false, "RewardPool not set");
        if (paused())
            return (false, "Staking paused");
        if (rewardPool.emissionStopped())
            return (false, "Emission stopped");
        if (block.timestamp > rewardPool.emissionEndTime())
            return (false, "Emission period ended");
        if (rewardPool.getDailyBase() == 0)
            return (false, "Daily base is zero");
        return (true, "");
    }

    // Stack too deep fix — split into 2 functions
    function getUserStakingInfo(address _user) external view returns (
        uint256 staked,
        uint256 pendingStaking,
        uint256 nextClaimChunk,
        uint256 rewardPoolPending,
        uint256 unstakeRequestAt,
        uint256 unstakeAvailableAt,
        bool    canUnstakeNow,
        bool    unstakePending,
        uint256 totalEarned,
        uint256 stakedAt,
        uint256 sharePercent
    ) {
        UserInfo storage u  = users[_user];
        uint256 ts          = block.timestamp;
        staked              = u.staked;
        pendingStaking      = pendingReward(_user);
        nextClaimChunk      = pendingStaking > MAX_REWARD_CLAIM
            ? MAX_REWARD_CLAIM : pendingStaking;
        rewardPoolPending   = rewardPool.getUserReward(_user);
        unstakeRequestAt    = u.unstakeRequestAt;
        unstakeAvailableAt  = u.unstakeRequestAt > 0
            ? u.unstakeRequestAt + UNSTAKE_COOLDOWN : 0;
        canUnstakeNow       = u.unstakeRequestAt > 0 &&
                              ts >= u.unstakeRequestAt + UNSTAKE_COOLDOWN;
        unstakePending      = u.unstakeRequestAt > 0;
        totalEarned         = u.totalEarned;
        stakedAt            = u.stakedAt;
        sharePercent        = totalStaked > 0
            ? (u.staked * 10_000) / totalStaked : 0;
    }

    function getUserReferralInfo(address _user) external view returns (
        address referrer,
        uint256 totalReferrals,
        uint256 totalReferralEarned,
        uint256 pendingReferral,
        uint256 teamBonusEarned,
        uint256 totalTeamVolume
    ) {
        UserInfo storage u  = users[_user];
        referrer            = u.referrer;
        totalReferrals      = u.totalReferrals;
        totalReferralEarned = u.totalReferralEarned;
        pendingReferral     = pendingReferralReward[_user];
        teamBonusEarned     = u.teamBonusEarned;
        totalTeamVolume     = u.totalTeamVolume;
    }

    function getPoolInfo() external view returns (
        uint256 staked,
        uint256 totalUsersEver,
        uint256 currentActiveStakers,
        uint256 accRPS,
        uint256 dailyStakingEmission,
        uint256 rewardDistributed,
        uint256 referralAccrued,
        uint256 pendingReferralTotal,
        uint256 referralReserveAmt,
        uint256 teamBonusReserveAmt,
        uint256 teamBonusAmt,
        bool    isPaused,
        bool    emissionActive
    ) {
        staked               = totalStaked;
        totalUsersEver       = totalUsers;
        currentActiveStakers = activeStakers;
        accRPS               = accRewardPerShare;
        rewardDistributed    = totalRewardDistributed;
        referralAccrued      = totalReferralAccrued;
        pendingReferralTotal = totalPendingReferral;
        referralReserveAmt   = referralReserve;
        teamBonusReserveAmt  = teamBonusReserve;
        teamBonusAmt         = totalTeamBonusDistributed;
        isPaused             = paused();
        uint256 dailyBase    = rewardPool.getDailyBase();
        uint256 pct          = rewardPool.stakingPercent();
        dailyStakingEmission = (dailyBase * pct) / 100;
        emissionActive       = dailyBase > 0 &&
                               !rewardPool.emissionStopped() &&
                               block.timestamp <= rewardPool.emissionEndTime();
    }

    function referralReserveCoverage() external view returns (
        uint256 reserve,
        uint256 totalLiability,
        uint256 coverageRatioBP,
        bool    isFullyCovered,
        uint256 shortfall
    ) {
        reserve         = referralReserve;
        totalLiability  = totalPendingReferral;
        isFullyCovered  = reserve >= totalLiability;
        shortfall       = isFullyCovered ? 0 : totalLiability - reserve;
        coverageRatioBP = totalLiability > 0
            ? (reserve * 10_000) / totalLiability
            : 10_000;
    }

    function getEmissionSchedule() external view returns (
        uint256 currentDailyBase,
        uint256 stakingDailyEmission,
        uint256 halvingNumber,
        uint256 emissionEndsAt,
        uint256 emissionEndsIn,
        uint256 timeToNextHalving,
        bool    emissionStopped,
        bool    emissionEnded
    ) {
        uint256 ts           = block.timestamp;
        currentDailyBase     = rewardPool.getDailyBase();
        uint256 pct          = rewardPool.stakingPercent();
        stakingDailyEmission = (currentDailyBase * pct) / 100;
        emissionEndsAt       = rewardPool.emissionEndTime();
        emissionEndsIn       = emissionEndsAt > ts ? emissionEndsAt - ts : 0;
        emissionStopped      = rewardPool.emissionStopped();
        emissionEnded        = ts > emissionEndsAt;
        uint256 start        = rewardPool.startTime();
        uint256 elapsed      = ts > start ? ts - start : 0;
        halvingNumber        = elapsed / (3 * 365 days);
        if (halvingNumber > 4) halvingNumber = 4;
        if (halvingNumber < 4) {
            uint256 nextTime  = start + ((halvingNumber + 1) * 3 * 365 days);
            timeToNextHalving = nextTime > ts ? nextTime - ts : 0;
        }
    }

    function getReferralChain(address _user)
        external view
        returns (address l1, address l2, address l3, address l4, address l5)
    {
        l1 = users[_user].referrer;
        if (l1 != address(0)) l2 = users[l1].referrer;
        if (l2 != address(0)) l3 = users[l2].referrer;
        if (l3 != address(0)) l4 = users[l3].referrer;
        if (l4 != address(0)) l5 = users[l4].referrer;
    }

    function getDirectReferrals(address _user)
        external view returns (address[] memory)
    {
        return _directRefs[_user];
    }

    function checkReferrerEligibility(address referrer)
        external view returns (bool eligible, uint8 reasonCode)
    {
        return _checkReferrer(referrer);
    }

    function isCircularReferral(address staker, address referrer)
        external view returns (bool)
    {
        return _isCircular(staker, referrer);
    }

    function getReasonDescription(uint8 code)
        external pure returns (string memory)
    {
        if (code == REASON_LOW_STAKE) return "Referrer stake too low";
        if (code == REASON_INACTIVE)  return "Referrer not active long enough";
        if (code == REASON_ZERO_ADDR) return "Zero address";
        if (code == REASON_CIRCULAR)  return "Circular referral";
        if (code == REASON_SELF)      return "Self referral";
        return "Unknown";
    }

    function getContractBalances() external view returns (
        uint256 totalBalance,
        uint256 stakedPrincipal,
        uint256 referralReserveAmt,
        uint256 teamBonusReserveAmt,
        uint256 totalAllocated,
        uint256 excess
    ) {
        totalBalance        = osgToken.balanceOf(address(this));
        stakedPrincipal     = totalStaked;
        referralReserveAmt  = referralReserve;
        teamBonusReserveAmt = teamBonusReserve;
        totalAllocated      = totalStaked + referralReserve + teamBonusReserve;
        excess              = totalBalance > totalAllocated
            ? totalBalance - totalAllocated : 0;
    }
}
