// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Nonces.sol";

contract OneXSmartGold is ERC20, ERC20Permit, ERC20Votes, Pausable, Ownable {

    uint256 public constant MAX_SUPPLY      = 23_000_000 * 1e18;
    uint256 public constant TEAM_SUPPLY     =    460_000 * 1e18;
    uint256 public constant TIMELOCK        = 72 hours;
    uint256 public constant RESCUE_TIMELOCK = 48 hours;
    uint256 public constant MAX_MINTERS     = 10;
    uint256 public constant HARD_DAILY_CAP  = 9_000 * 1e18;
    uint256 public constant HARD_HOURLY_CAP =   500 * 1e18;

    bool public immutable isTestnet;

    address public governance;
    address public pendingGovernance;
    uint256 public govChangeAt;

    mapping(address => bool)    public authorizedMinters;
    mapping(address => bool)    public isCoreRewardPool;
    mapping(address => uint256) public pendingMinters;
    mapping(address => uint256) public pendingRemovals;
    uint256 public totalMinters;

    bool public mintersInitialized;   // ← NEW: one-time init guard

    struct RescueRequest {
        address token;
        uint256 amount;
        uint256 executeAt;
        bool    isMATIC;
        bool    exists;
    }
    mapping(bytes32 => RescueRequest) public rescueRequests;

    uint256 public mintedThisHour;
    uint256 public hourStart;
    uint256 public dailyMinted;
    uint256 public mintDay;

    event GovernanceProposed(address indexed newGov, uint256 executeAt);
    event GovernanceUpdated(address indexed oldGov, address indexed newGov);
    event GovernanceCancelled(address indexed cancelled);
    event MinterProposed(address indexed minter, uint256 executeAt);
    event MinterProposalCancelled(address indexed minter);
    event MinterAdded(address indexed minter, bool isCorePool);
    event MinterRemovalProposed(address indexed minter, uint256 executeAt);
    event MinterRemovalCancelled(address indexed minter);
    event MinterRemoved(address indexed minter, string reason);
    event CoreRewardPoolSet(address indexed pool, bool status);
    event MintersInitialized(address indexed rewardPool);   // ← NEW
    event CircuitBreakerTriggered(uint256 amount, address indexed minter);
    event EmergencyAction(string action, address indexed by);
    event RescueRequested(bytes32 indexed id, address token, uint256 amount, uint256 executeAt);
    event RescueExecuted(bytes32 indexed id, address token, uint256 requested, uint256 actual);
    event RescueCancelled(bytes32 indexed id);
    event MATICRescueRequested(bytes32 indexed id, uint256 amount, uint256 executeAt);

    modifier onlyGov() {
        require(msg.sender == governance, "Not governance");
        _;
    }
    modifier onlyMinter() {
        require(authorizedMinters[msg.sender], "Not authorized minter");
        _;
    }

    constructor(
        address _multisig,
        address _dao,
        address _vesting,
        bool    _isTestnet
    )
        ERC20("OneX Smart Gold", "OSG")
        ERC20Permit("OneX Smart Gold")
        Ownable(_multisig)
    {
        require(_multisig != address(0), "Invalid multisig");
        require(_dao      != address(0), "Invalid DAO");
        require(_vesting  != address(0), "Invalid vesting");

        isTestnet = _isTestnet;

        if (!_isTestnet) {
            require(_dao.code.length > 0, "DAO must be contract");
        }

        governance = _dao;

        // Team 2% → Vesting
        _mint(_vesting, TEAM_SUPPLY);
        _delegate(_vesting, _multisig);

        // minters NOT set here — circular dependency.
        // Call initializeMinters(rewardPool) after RewardPool deployed.

        uint256 ts = block.timestamp;
        hourStart  = (ts / 1 hours) * 1 hours;
        mintDay    = ts / 1 days;
    }

    // ============ NEW: one-time minter init (circular dependency fix) ============
    // Only RewardPool is a minter. Call once after RewardPool deployed.
    function initializeMinters(address _rewardPool) external onlyGov {
        require(!mintersInitialized,        "Already initialized");
        require(_rewardPool != address(0),  "Invalid RewardPool");
        if (!isTestnet) {
            require(_rewardPool.code.length > 0, "RewardPool must be contract");
        }
        isCoreRewardPool[_rewardPool]  = true;
        authorizedMinters[_rewardPool] = true;
        totalMinters = 1;
        mintersInitialized = true;

        emit CoreRewardPoolSet(_rewardPool, true);
        emit MinterAdded(_rewardPool, true);
        emit MintersInitialized(_rewardPool);
    }

    function clock() public view override returns (uint48) {
        return uint48(block.number);
    }
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=blocknumber&from=default";
    }
    function nonces(address owner)
        public view override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }

    function mint(address to, uint256 amount) external onlyMinter {
        require(to     != address(0), "Zero address");
        require(amount >  0,          "Zero amount");
        require(totalSupply() + amount <= MAX_SUPPLY, "Max supply reached");
        require(isCoreRewardPool[msg.sender], "Only core reward pool");
        _checkCircuitBreaker(amount);
        _mint(to, amount);
    }

    function _checkCircuitBreaker(uint256 amount) internal {
        uint256 ts = block.timestamp;
        if (ts >= hourStart + 1 hours) {
            hourStart      = (ts / 1 hours) * 1 hours;
            mintedThisHour = 0;
        }
        mintedThisHour += amount;
        if (mintedThisHour > HARD_HOURLY_CAP) {
            _pause();
            emit CircuitBreakerTriggered(mintedThisHour, msg.sender);
            revert("Hourly hard cap exceeded");
        }
        uint256 today = ts / 1 days;
        if (today > mintDay) {
            mintDay     = today;
            dailyMinted = 0;
        }
        dailyMinted += amount;
        require(dailyMinted <= HARD_DAILY_CAP, "Daily hard cap exceeded");
    }

    function burn(uint256 amount) external {
        require(amount > 0, "Zero amount");
        _burn(msg.sender, amount);
    }

    function _update(address from, address to, uint256 value)
        internal override(ERC20, ERC20Votes)
    {
        if (from != address(0) && to != address(0)) {
            require(!paused(), "Transfers paused");
        }
        super._update(from, to, value);
        if (to != address(0) && delegates(to) == address(0) && balanceOf(to) > 0) {
            _delegate(to, to);
        }
    }

    // ===== MINTER MANAGEMENT (for FUTURE minters, 72h timelock) =====
    function proposeMinter(address _minter) external onlyGov {
        require(_minter != address(0),        "Invalid address");
        require(!authorizedMinters[_minter],  "Already minter");
        require(totalMinters < MAX_MINTERS,   "Max minters reached");
        require(pendingMinters[_minter] == 0, "Already proposed");
        pendingMinters[_minter] = block.timestamp + TIMELOCK;
        emit MinterProposed(_minter, pendingMinters[_minter]);
    }
    function approveMinter(address _minter) external onlyGov {
        uint256 executeAt = pendingMinters[_minter];
        require(executeAt != 0,               "Not proposed");
        require(block.timestamp >= executeAt, "Timelock active");
        require(!authorizedMinters[_minter],  "Already active");
        require(totalMinters < MAX_MINTERS,   "Max minters reached");
        if (!isTestnet) {
            require(_minter.code.length > 0, "Must be contract");
        }
        authorizedMinters[_minter] = true;
        pendingMinters[_minter]    = 0;
        totalMinters++;
        if (!isCoreRewardPool[_minter]) {
            isCoreRewardPool[_minter] = true;
            emit CoreRewardPoolSet(_minter, true);
        }
        emit MinterAdded(_minter, true);
    }
    function cancelMinterProposal(address _minter) external onlyGov {
        require(pendingMinters[_minter] != 0, "Not proposed");
        pendingMinters[_minter] = 0;
        emit MinterProposalCancelled(_minter);
    }
    function proposeMinterRemoval(address _minter) external onlyGov {
        require(authorizedMinters[_minter],    "Not a minter");
        require(pendingRemovals[_minter] == 0, "Already proposed");
        pendingRemovals[_minter] = block.timestamp + TIMELOCK;
        emit MinterRemovalProposed(_minter, pendingRemovals[_minter]);
    }
    function confirmMinterRemoval(address _minter) external onlyGov {
        uint256 executeAt = pendingRemovals[_minter];
        require(executeAt != 0,               "Not proposed");
        require(block.timestamp >= executeAt, "Timelock active");
        require(authorizedMinters[_minter],   "Already removed");
        authorizedMinters[_minter] = false;
        pendingRemovals[_minter]   = 0;
        if (totalMinters > 0) totalMinters--;
        if (isCoreRewardPool[_minter]) {
            isCoreRewardPool[_minter] = false;
            emit CoreRewardPoolSet(_minter, false);
        }
        emit MinterRemoved(_minter, "governance");
    }
    function cancelMinterRemoval(address _minter) external onlyGov {
        require(pendingRemovals[_minter] != 0, "Not proposed");
        pendingRemovals[_minter] = 0;
        emit MinterRemovalCancelled(_minter);
    }
    function emergencyRemoveMinter(address _minter) external onlyOwner {
        require(authorizedMinters[_minter], "Not a minter");
        authorizedMinters[_minter] = false;
        pendingRemovals[_minter]   = 0;
        if (totalMinters > 0) totalMinters--;
        if (isCoreRewardPool[_minter]) {
            isCoreRewardPool[_minter] = false;
            emit CoreRewardPoolSet(_minter, false);
        }
        emit MinterRemoved(_minter, "emergency");
        emit EmergencyAction("EMERGENCY_REMOVE_MINTER", msg.sender);
    }
    function setCoreRewardPool(address _pool, bool _status) external onlyGov {
        require(_pool != address(0), "Invalid address");
        if (_status) {
            require(authorizedMinters[_pool], "Must be approved minter first");
            if (!isTestnet) {
                require(_pool.code.length > 0, "Must be contract");
            }
        }
        isCoreRewardPool[_pool] = _status;
        emit CoreRewardPoolSet(_pool, _status);
    }

    // ===== GOVERNANCE 2-step + 72h =====
    function proposeGovernance(address _newGov) external onlyGov {
        require(_newGov != address(0), "Invalid address");
        require(_newGov != governance, "Same governance");
        pendingGovernance = _newGov;
        govChangeAt       = block.timestamp + TIMELOCK;
        emit GovernanceProposed(_newGov, govChangeAt);
    }
    function acceptGovernance() external {
        require(msg.sender == pendingGovernance, "Not pending gov");
        require(block.timestamp >= govChangeAt,  "Timelock active");
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

    // ===== PAUSE =====
    function pause() external onlyGov {
        _pause();
        emit EmergencyAction("PAUSE", msg.sender);
    }
    function unpause() external onlyGov {
        _unpause();
        uint256 ts     = block.timestamp;
        mintedThisHour = 0;
        dailyMinted    = 0;
        hourStart      = (ts / 1 hours) * 1 hours;
        mintDay        = ts / 1 days;
        emit EmergencyAction("UNPAUSE", msg.sender);
    }
    function emergencyPause() external onlyOwner {
        _pause();
        emit EmergencyAction("EMERGENCY_PAUSE", msg.sender);
    }

    // ===== RESCUE 48h =====
    function requestRescueTokens(address token, uint256 amount)
        external onlyGov returns (bytes32 id)
    {
        require(token  != address(this), "Cannot rescue OSG");
        require(token  != address(0),    "Invalid token");
        require(amount >  0,             "Zero amount");
        uint256 executeAt = block.timestamp + RESCUE_TIMELOCK;
        id = keccak256(abi.encode(token, amount, executeAt, block.number, msg.sender));
        require(!rescueRequests[id].exists, "ID collision");
        rescueRequests[id] = RescueRequest(token, amount, executeAt, false, true);
        emit RescueRequested(id, token, amount, executeAt);
    }
    function requestRescueMATIC() external onlyGov returns (bytes32 id) {
        uint256 bal = address(this).balance;
        require(bal > 0, "No MATIC");
        uint256 executeAt = block.timestamp + RESCUE_TIMELOCK;
        id = keccak256(abi.encode(address(0), bal, executeAt, block.number, msg.sender));
        require(!rescueRequests[id].exists, "ID collision");
        rescueRequests[id] = RescueRequest(address(0), bal, executeAt, true, true);
        emit MATICRescueRequested(id, bal, executeAt);
    }
    function executeRescue(bytes32 id) external onlyGov {
        RescueRequest storage r = rescueRequests[id];
        require(r.exists,                       "Not requested");
        require(block.timestamp >= r.executeAt, "Timelock active");
        uint256 requested = r.amount;
        bool    isMATIC   = r.isMATIC;
        address token     = r.token;
        delete rescueRequests[id];
        uint256 actualSent;
        if (isMATIC) {
            uint256 bal = address(this).balance;
            actualSent  = bal < requested ? bal : requested;
            require(actualSent > 0, "No MATIC available");
            (bool success, ) = payable(governance).call{value: actualSent}("");
            require(success, "MATIC transfer failed");
        } else {
            uint256 balBefore = IERC20Min(token).balanceOf(address(this));
            require(balBefore >= requested, "Insufficient balance");
            IERC20Min(token).transfer(governance, requested);
            uint256 balAfter = IERC20Min(token).balanceOf(address(this));
            actualSent = balBefore - balAfter;
            require(actualSent > 0, "Transfer verification failed");
        }
        emit RescueExecuted(id, token, requested, actualSent);
    }
    function cancelRescue(bytes32 id) external onlyGov {
        require(rescueRequests[id].exists, "Not requested");
        delete rescueRequests[id];
        emit RescueCancelled(id);
    }

    // ===== VIEWS =====
    function getMinterInfo(address account) external view returns (
        bool isAuthorized, bool isCorePool, uint256 pendingAt, uint256 removalAt
    ) {
        isAuthorized = authorizedMinters[account];
        isCorePool   = isCoreRewardPool[account];
        pendingAt    = pendingMinters[account];
        removalAt    = pendingRemovals[account];
    }
    function getStats() external view returns (
        uint256 totalSupplyAmt, uint256 maxSupplyAmt, uint256 remaining,
        uint256 minterCount, bool isPaused, bool testnet, address currentGov, address currentOwner
    ) {
        totalSupplyAmt = totalSupply();
        maxSupplyAmt   = MAX_SUPPLY;
        remaining      = MAX_SUPPLY - totalSupply();
        minterCount    = totalMinters;
        isPaused       = paused();
        testnet        = isTestnet;
        currentGov     = governance;
        currentOwner   = owner();
    }

    receive() external payable {}
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}
