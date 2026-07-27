// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/**
 * ------------------------------------------------------------
 * TimelockDAO (FINAL)
 * OneX Smart Gold Ecosystem
 * ------------------------------------------------------------
 *  - pragma 0.8.34 (ecosystem consistent)
 *  - MIN_DELAY = 24 hours (balanced security)
 *  - queue / execute / cancel / batch / expiry
 *  - 2-step admin transfer with delay
 *  - pause guard
 *  - ReentrancyGuard on execute
 *
 *  ROLE: after deploy, ownership/governance of all contracts is transferred here.
 *        All privileged changes go through queue -> 24h delay -> execute.
 * ------------------------------------------------------------
 */

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract TimelockDAO is ReentrancyGuard {

    uint256 public constant MIN_DELAY = 24 hours;
    uint256 public constant MAX_DELAY = 30 days;
    uint256 public constant MAX_BATCH = 10;

    address public admin;
    address public pendingAdmin;
    uint256 public adminChangeAt;
    bool    public paused;

    uint256 public queuedCount;
    uint256 public executedCount;
    uint256 public cancelledCount;

    struct Tx {
        address target;
        uint256 value;
        bytes   data;
        uint256 executeAfter;
        bool    executed;
    }

    mapping(bytes32 => Tx)     public txs;
    mapping(bytes32 => string) public txDescription;

    event Queued(bytes32 indexed id, address indexed target, uint256 value, uint256 executeAfter, bytes32 dataHash, string description);
    event Executed(bytes32 indexed id, address indexed target, uint256 value);
    event Cancelled(bytes32 indexed id);
    event TxExpired(bytes32 indexed id);
    event BatchQueued(uint256 count);
    event BatchCancelled(uint256 count);
    event AdminProposed(address indexed newAdmin, uint256 executeAt);
    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    event AdminCancelled(address indexed cancelled);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "DAO is paused");
        _;
    }

    constructor(address _admin) {
        require(_admin != address(0), "Invalid admin");
        admin = _admin;
    }

    function queue(
        address target,
        uint256 value,
        bytes calldata data,
        string calldata description
    ) external onlyAdmin whenNotPaused returns (bytes32 id) {
        require(target != address(0), "Invalid target");
        uint256 execTime = block.timestamp + MIN_DELAY;
        id = keccak256(abi.encode(target, value, data, execTime));
        require(txs[id].target == address(0), "ID already exists");
        txs[id] = Tx({
            target      : target,
            value       : value,
            data        : data,
            executeAfter: execTime,
            executed    : false
        });
        txDescription[id] = description;
        queuedCount++;
        emit Queued(id, target, value, execTime, keccak256(data), description);
    }

    function batchQueue(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[]   calldata datas,
        string[]  calldata descriptions
    ) external onlyAdmin whenNotPaused returns (bytes32[] memory ids) {
        uint256 len = targets.length;
        require(len > 0 && len <= MAX_BATCH, "Batch: 1-10");
        require(
            len == values.length &&
            len == datas.length  &&
            len == descriptions.length,
            "Length mismatch"
        );
        ids = new bytes32[](len);
        uint256 execTime = block.timestamp + MIN_DELAY;
        for (uint256 i = 0; i < len; ) {
            require(targets[i] != address(0), "Invalid target");
            bytes32 id = keccak256(abi.encode(targets[i], values[i], datas[i], execTime));
            require(txs[id].target == address(0), "ID exists");
            txs[id] = Tx({
                target      : targets[i],
                value       : values[i],
                data        : datas[i],
                executeAfter: execTime,
                executed    : false
            });
            txDescription[id] = descriptions[i];
            ids[i] = id;
            queuedCount++;
            emit Queued(id, targets[i], values[i], execTime, keccak256(datas[i]), descriptions[i]);
            unchecked { i++; }
        }
        emit BatchQueued(len);
    }

    function execute(bytes32 id)
        external payable onlyAdmin nonReentrant whenNotPaused
        returns (bytes memory)
    {
        Tx storage t = txs[id];
        require(t.target != address(0),                        "Not found");
        require(!t.executed,                                   "Already executed");
        require(block.timestamp >= t.executeAfter,             "Timelock active");
        require(block.timestamp <= t.executeAfter + MAX_DELAY, "Expired");
        require(msg.value >= t.value,                          "Insufficient ETH");
        t.executed = true;
        executedCount++;
        (bool success, bytes memory res) = t.target.call{value: t.value}(t.data);
        require(success, "Execution failed");
        uint256 excess = msg.value - t.value;
        if (excess > 0) {
            (bool refunded, ) = payable(msg.sender).call{value: excess}("");
            require(refunded, "Refund failed");
        }
        emit Executed(id, t.target, t.value);
        return res;
    }

    function cancel(bytes32 id) external onlyAdmin {
        require(txs[id].target != address(0), "Not found");
        require(!txs[id].executed,            "Already executed");
        delete txs[id];
        delete txDescription[id];
        cancelledCount++;
        emit Cancelled(id);
    }

    function batchCancel(bytes32[] calldata ids) external onlyAdmin {
        uint256 len = ids.length;
        require(len > 0 && len <= MAX_BATCH, "Batch: 1-10");
        for (uint256 i = 0; i < len; ) {
            bytes32 id = ids[i];
            if (txs[id].target != address(0) && !txs[id].executed) {
                delete txs[id];
                delete txDescription[id];
                cancelledCount++;
                emit Cancelled(id);
            }
            unchecked { i++; }
        }
        emit BatchCancelled(len);
    }

    function expireTx(bytes32 id) external {
        Tx storage t = txs[id];
        require(t.target != address(0), "Not found");
        require(!t.executed,            "Already executed");
        require(block.timestamp > t.executeAfter + MAX_DELAY, "Not expired yet");
        delete txs[id];
        delete txDescription[id];
        emit TxExpired(id);
    }

    function proposeAdmin(address _new) external onlyAdmin {
        require(_new != address(0), "Invalid address");
        require(_new != admin,      "Same admin");
        pendingAdmin  = _new;
        adminChangeAt = block.timestamp + MIN_DELAY;
        emit AdminProposed(_new, adminChangeAt);
    }

    function acceptAdmin() external {
        require(msg.sender == pendingAdmin,       "Not pending admin");
        require(block.timestamp >= adminChangeAt, "Delay active");
        address old   = admin;
        admin         = pendingAdmin;
        pendingAdmin  = address(0);
        adminChangeAt = 0;
        emit AdminUpdated(old, admin);
    }

    function cancelAdminChange() external onlyAdmin {
        require(pendingAdmin != address(0), "Nothing to cancel");
        address cancelled = pendingAdmin;
        pendingAdmin  = address(0);
        adminChangeAt = 0;
        emit AdminCancelled(cancelled);
    }

    function pause() external onlyAdmin {
        require(!paused, "Already paused");
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyAdmin {
        require(paused, "Not paused");
        paused = false;
        emit Unpaused(msg.sender);
    }

    function getTx(bytes32 id) external view returns (
        address target,
        uint256 value,
        bytes memory data,
        uint256 executeAfter,
        bool    executed,
        bool    isReady,
        bool    isExpired,
        string  memory description
    ) {
        Tx storage t = txs[id];
        target       = t.target;
        value        = t.value;
        data         = t.data;
        executeAfter = t.executeAfter;
        executed     = t.executed;
        isReady      = !t.executed &&
                       block.timestamp >= t.executeAfter &&
                       block.timestamp <= t.executeAfter + MAX_DELAY;
        isExpired    = block.timestamp > t.executeAfter + MAX_DELAY;
        description  = txDescription[id];
    }

    function getStats() external view returns (
        uint256 queued,
        uint256 executed,
        uint256 cancelled,
        uint256 minDelay,
        bool    isPaused
    ) {
        queued    = queuedCount;
        executed  = executedCount;
        cancelled = cancelledCount;
        minDelay  = MIN_DELAY;
        isPaused  = paused;
    }

    function getPendingAdmin() external view returns (
        address pending,
        uint256 executeAt,
        bool    isReady
    ) {
        pending   = pendingAdmin;
        executeAt = adminChangeAt;
        isReady   = pendingAdmin != address(0) &&
                    block.timestamp >= adminChangeAt;
    }

    receive() external payable {}
}
