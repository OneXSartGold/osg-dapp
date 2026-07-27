// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

contract RewardStorage is Ownable, ReentrancyGuard, Pausable {

    uint256 public constant MAX_POOLS      = 5;
    uint256 public constant MAX_BATCH_SIZE = 50;

    mapping(address => uint256) private rewards;
    mapping(address => bool) public authorizedPools;
    uint256 public poolCount;

    uint256 public totalRewarded;
    uint256 public totalClaimed;
    uint256 public totalEmergencyReset;
    uint256 public totalRestored;

    event RewardAdded(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event RewardRestored(address indexed user, uint256 amount);
    event PoolAuthorized(address indexed pool, bool status);
    event EmergencyReset(address indexed user, uint256 clearedAmount, address indexed by);
    event EmergencyAction(string action, address indexed by);

    modifier onlyPool() {
        require(authorizedPools[msg.sender], "Not authorized pool");
        _;
    }

    constructor(address _owner) Ownable(_owner) {
        require(_owner != address(0), "Invalid owner");
    }

    function setAuthorizedPool(address pool, bool status) external onlyOwner {
        require(pool != address(0), "Invalid address");
        if (status) {
            require(!authorizedPools[pool], "Already added");
            require(pool.code.length > 0,   "Must be contract");
            require(poolCount < MAX_POOLS,  "Max pools reached");
            authorizedPools[pool] = true;
            poolCount++;
        } else {
            require(authorizedPools[pool], "Not active");
            authorizedPools[pool] = false;
            if (poolCount > 0) poolCount--;
        }
        emit PoolAuthorized(pool, status);
    }

    function updateReward(address user, uint256 amount) external onlyPool whenNotPaused {
        require(user != address(0), "Zero address");
        require(amount > 0,         "Zero amount");
        rewards[user] += amount;
        totalRewarded += amount;
        emit RewardAdded(user, amount);
    }

    function batchUpdateReward(address[] calldata users, uint256[] calldata amounts)
        external onlyPool whenNotPaused
    {
        uint256 len = users.length;
        require(len == amounts.length, "Length mismatch");
        require(len <= MAX_BATCH_SIZE, "Max 50 per batch");
        require(len > 0,               "Empty batch");
        for (uint256 i; i < len; ) {
            require(users[i] != address(0), "Zero address");
            require(amounts[i] > 0,         "Zero amount");
            rewards[users[i]] += amounts[i];
            totalRewarded     += amounts[i];
            emit RewardAdded(users[i], amounts[i]);
            unchecked { i++; }
        }
    }

    function claim(address user) external nonReentrant onlyPool whenNotPaused returns (uint256) {
        uint256 reward = rewards[user];
        require(reward > 0, "No reward");
        rewards[user] = 0;
        totalClaimed += reward;
        emit RewardClaimed(user, reward);
        return reward;
    }

    // restoreReward — RewardPool calls this when mint fails: puts reward back, no loss
    function restoreReward(address user, uint256 amount)
        external onlyPool whenNotPaused
    {
        require(user != address(0), "Zero address");
        require(amount > 0,         "Zero amount");
        rewards[user] += amount;
        // claim() had increased totalClaimed; revert that here
        if (totalClaimed >= amount) {
            totalClaimed -= amount;
        }
        totalRestored += amount;
        emit RewardRestored(user, amount);
    }

    function emergencyResetReward(address user) external onlyOwner {
        require(user != address(0), "Zero address");
        uint256 cleared = rewards[user];
        require(cleared > 0, "Nothing to reset");
        rewards[user] = 0;
        totalEmergencyReset += cleared;
        emit EmergencyReset(user, cleared, msg.sender);
    }

    function pause() external onlyOwner { _pause();   emit EmergencyAction("PAUSE", msg.sender); }
    function unpause() external onlyOwner { _unpause(); emit EmergencyAction("UNPAUSE", msg.sender); }

    function pendingReward(address user) external view returns (uint256) {
        return rewards[user];
    }

    function getStats() external view returns (
        uint256 rewarded, uint256 claimed, uint256 pendingTotal,
        uint256 emergencyCleared, uint256 restored, uint256 pools, bool isPaused
    ) {
        rewarded         = totalRewarded;
        claimed          = totalClaimed;
        pendingTotal     = totalRewarded > (totalClaimed + totalEmergencyReset)
            ? totalRewarded - totalClaimed - totalEmergencyReset : 0;
        emergencyCleared = totalEmergencyReset;
        restored         = totalRestored;
        pools            = poolCount;
        isPaused         = paused();
    }
}
