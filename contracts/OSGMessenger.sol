// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/**
 * ------------------------------------------------------------
 * OSG Messenger v7 (FINAL — MediaStorage wired)
 * OneX Smart Gold Ecosystem
 * ------------------------------------------------------------
 *
 * FIXES OVER V5:
 *  - pragma 0.8.34 (consistent with rest of ecosystem)
 *  - owner set in constructor (deploy = Multisig, later Timelock)
 *  - uses OZ IERC20 only (removed duplicate local interface)
 *  - GROUP messages paginated (getGroupMessages) — gas-DoS safe
 *  - underflow guards on unreadCount
 *  - setPublicKey added (E2E key registration)
 *  - OZ v5 imports (utils/ — NOT security/)
 *  - ReentrancyGuard + SafeERC20
 * ------------------------------------------------------------
 */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IMemberNFT {
    function isMessagingFeeExempt(address user) external view returns (bool);
}

interface IPriceOracle {
    function getPrice() external view returns (uint256);
}

interface IMediaStorage {
    function getMediaSafe(uint256 mediaId) external view returns (
        string memory cid,
        string memory mimeType,
        uint256 size,
        uint256 timestamp,
        address owner_,
        uint256 price,
        bool    isPublic,
        uint256 viewCount
    );
}

contract OSGMessenger is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ===== CORE =====
    IERC20       public osgToken;
    address      public treasury;
    IMemberNFT   public memberNFT;
    IPriceOracle public priceOracle;
    IMediaStorage public mediaStorage;

    // ===== CONFIG =====
    uint256 public feeUSD          = 2e16;   // $0.02
    uint256 public messagingFeeOSG = 1e18;
    uint256 public burnPercent     = 20;     // % of OSG fee burned
    uint256 public cooldown        = 10 seconds;
    uint256 public paymentFee      = 100;    // 1% (bp /10000)
    uint256 public expiryTime      = 30 days;

    bool public paused;
    bool public useOSGFee;

    // ===== SECURITY =====
    mapping(address => uint256) public lastSent;
    mapping(address => bool)    public allowedTokens;

    // ===== USER DATA =====
    mapping(address => string) public publicKeys;

    // ===== MESSAGE =====
    struct Message {
        address from;
        string  cid;
        string  fileType;
        uint256 timestamp;
        bool    isRead;
        bool    isDeleted;
    }

    mapping(address => Message[]) private inbox;
    mapping(address => uint256)   public unreadCount;

    // ===== GROUP =====
    struct Group {
        string  name;
        address admin;
    }

    uint256 public groupCount;
    mapping(uint256 => Group) public groups;
    mapping(uint256 => mapping(address => bool)) public groupMembers;
    mapping(uint256 => Message[]) private groupMessages;

    // ===== EVENTS =====
    event MessageSent(address indexed from, address indexed to, uint256 index);
    event MessageDeleted(address indexed user, uint256 index);
    event MessageRead(address indexed user, uint256 index);
    event PaymentSent(address indexed from, address indexed to, address token, uint256 amount);
    event GroupCreated(uint256 indexed id, string name, address indexed admin);
    event GroupMessage(uint256 indexed gid, address indexed from, uint256 index);
    event MemberUpdated(uint256 indexed gid, address user, bool status);
    event PublicKeySet(address indexed user);
    event ConfigUpdated(string what);
    event Paused(bool status);

    // ===== MODIFIERS =====
    modifier notPaused() {
        require(!paused, "Paused");
        _;
    }

    modifier antiSpam() {
        require(block.timestamp >= lastSent[msg.sender] + cooldown, "Cooldown");
        lastSent[msg.sender] = block.timestamp;
        _;
    }

    constructor(
        address _token,
        address _treasury,
        address _owner
    ) Ownable(_owner) {
        require(_token.code.length > 0, "Token must be contract");
        require(_treasury != address(0), "Invalid treasury");
        require(_owner    != address(0), "Invalid owner");

        osgToken = IERC20(_token);
        treasury = _treasury;
    }

    // ===== PUBLIC KEY (E2E) =====

    function setPublicKey(string calldata pubKey) external {
        require(bytes(pubKey).length > 0 && bytes(pubKey).length <= 256, "Invalid key");
        publicKeys[msg.sender] = pubKey;
        emit PublicKeySet(msg.sender);
    }

    // ===== FEE =====

    function getMaticFee() public view returns (uint256) {
        if (address(priceOracle) == address(0)) return 0;
        uint256 price = priceOracle.getPrice();
        require(price > 0, "Oracle error");
        return (feeUSD * 1e18) / price;
    }

    function getUserFee(address user) public view returns (uint256) {
        if (address(memberNFT) != address(0)) {
            if (memberNFT.isMessagingFeeExempt(user)) return 0;
        }
        return getMaticFee();
    }

    // ===== MESSAGE =====

    function sendMessage(
        address to,
        string calldata cid,
        string calldata fileType
    ) external payable nonReentrant notPaused antiSpam {

        require(to != address(0), "Invalid recipient");
        require(to != msg.sender, "Self send");
        require(bytes(cid).length > 0 && bytes(cid).length <= 128, "Invalid CID");
        require(bytes(fileType).length > 0 && bytes(fileType).length <= 20, "Invalid type");

        bool exempt = address(memberNFT) != address(0)
            && memberNFT.isMessagingFeeExempt(msg.sender);

        // ===== STORE FIRST (CEI) =====
        inbox[to].push(Message(msg.sender, cid, fileType, block.timestamp, false, false));
        unreadCount[to]++;

        emit MessageSent(msg.sender, to, inbox[to].length - 1);

        // ===== FEE =====
        if (!exempt) {
            if (useOSGFee) {
                uint256 burnAmt  = (messagingFeeOSG * burnPercent) / 100;
                uint256 treasAmt = messagingFeeOSG - burnAmt;

                osgToken.safeTransferFrom(msg.sender, treasury, treasAmt);
                if (burnAmt > 0) {
                    osgToken.safeTransferFrom(msg.sender, DEAD, burnAmt);
                }
            } else {
                uint256 fee = getUserFee(msg.sender);
                require(msg.value >= fee, "Insufficient fee");

                if (fee > 0) {
                    (bool sent, ) = treasury.call{value: fee}("");
                    require(sent, "Fee failed");
                }

                uint256 refund = msg.value - fee;
                if (refund > 0) {
                    (bool ok, ) = msg.sender.call{value: refund}("");
                    require(ok, "Refund fail");
                }
            }
        } else {
            // exempt users using native path get any sent value refunded
            if (!useOSGFee && msg.value > 0) {
                (bool ok, ) = msg.sender.call{value: msg.value}("");
                require(ok, "Refund fail");
            }
        }
    }

    // ===== MEDIA MESSAGE (v7 — wired to OSGMediaStorage) =====
    // Verifies the sender owns mediaId, then stores the CID as a message.
    // Reverts if mediaStorage is not set (use sendMessage until wired).

    function sendMediaMessage(
        address to,
        uint256 mediaId,
        string calldata cid,
        string calldata fileType
    ) external payable nonReentrant notPaused antiSpam {

        require(address(mediaStorage) != address(0), "Media not wired");
        require(to != address(0), "Invalid recipient");
        require(to != msg.sender, "Self send");
        require(mediaId > 0, "Invalid mediaId");
        require(bytes(cid).length > 0 && bytes(cid).length <= 128, "Invalid CID");
        require(bytes(fileType).length > 0 && bytes(fileType).length <= 20, "Invalid type");

        // ownership verify (8 returns — owner_ is the 5th)
        (,,,, address mediaOwner,,,) = mediaStorage.getMediaSafe(mediaId);
        require(mediaOwner == msg.sender, "Not media owner");

        bool exempt = address(memberNFT) != address(0)
            && memberNFT.isMessagingFeeExempt(msg.sender);

        // STORE FIRST (CEI)
        inbox[to].push(Message(msg.sender, cid, fileType, block.timestamp, false, false));
        unreadCount[to]++;
        emit MessageSent(msg.sender, to, inbox[to].length - 1);

        // FEE (same logic as sendMessage)
        if (!exempt) {
            if (useOSGFee) {
                uint256 burnAmt  = (messagingFeeOSG * burnPercent) / 100;
                uint256 treasAmt = messagingFeeOSG - burnAmt;
                osgToken.safeTransferFrom(msg.sender, treasury, treasAmt);
                if (burnAmt > 0) {
                    osgToken.safeTransferFrom(msg.sender, DEAD, burnAmt);
                }
            } else {
                uint256 fee = getUserFee(msg.sender);
                require(msg.value >= fee, "Insufficient fee");
                if (fee > 0) {
                    (bool sent, ) = treasury.call{value: fee}("");
                    require(sent, "Fee failed");
                }
                uint256 refund = msg.value - fee;
                if (refund > 0) {
                    (bool ok, ) = msg.sender.call{value: refund}("");
                    require(ok, "Refund fail");
                }
            }
        } else {
            if (!useOSGFee && msg.value > 0) {
                (bool ok, ) = msg.sender.call{value: msg.value}("");
                require(ok, "Refund fail");
            }
        }
    }

    // Returns the owner of mediaId (convenience for DApp)
    function verifyMediaOwner(uint256 mediaId) external view returns (address) {
        require(address(mediaStorage) != address(0), "Media not wired");
        (,,,, address mediaOwner,,,) = mediaStorage.getMediaSafe(mediaId);
        return mediaOwner;
    }

    // ===== DELETE / READ =====

    function deleteMessage(uint256 index) external {
        require(index < inbox[msg.sender].length, "Invalid index");
        Message storage m = inbox[msg.sender][index];
        require(!m.isDeleted, "Already deleted");

        if (!m.isRead && unreadCount[msg.sender] > 0) {
            unreadCount[msg.sender]--;
        }
        m.isDeleted = true;
        emit MessageDeleted(msg.sender, index);
    }

    function markAsRead(uint256 index) external {
        require(index < inbox[msg.sender].length, "Invalid index");
        Message storage m = inbox[msg.sender][index];
        if (!m.isRead && !m.isDeleted) {
            m.isRead = true;
            if (unreadCount[msg.sender] > 0) {
                unreadCount[msg.sender]--;
            }
            emit MessageRead(msg.sender, index);
        }
    }

    // ===== PAYMENT =====

    function sendPayment(
        address to,
        address token,
        uint256 amount,
        string calldata cid
    ) external payable nonReentrant notPaused antiSpam {

        require(to != address(0), "Invalid");

        if (token == address(0)) {
            require(msg.value > 0, "No MATIC");

            uint256 fee = (msg.value * paymentFee) / 10000;
            uint256 net = msg.value - fee;

            if (fee > 0) {
                (bool f1,) = treasury.call{value: fee}("");
                require(f1, "Fee fail");
            }
            (bool f2,) = to.call{value: net}("");
            require(f2, "Send fail");

        } else {
            require(allowedTokens[token], "Not allowed");
            require(amount > 0, "Invalid amount");

            IERC20 t = IERC20(token);
            uint256 fee = (amount * paymentFee) / 10000;
            uint256 net = amount - fee;

            if (fee > 0) {
                t.safeTransferFrom(msg.sender, treasury, fee);
            }
            t.safeTransferFrom(msg.sender, to, net);
        }

        inbox[to].push(Message(msg.sender, cid, "payment", block.timestamp, false, false));
        unreadCount[to]++;

        emit PaymentSent(msg.sender, to, token, token == address(0) ? msg.value : amount);
    }

    // ===== GROUP =====

    function createGroup(string calldata name) external {
        require(bytes(name).length > 0 && bytes(name).length <= 64, "Invalid");
        groupCount++;
        groups[groupCount] = Group(name, msg.sender);
        groupMembers[groupCount][msg.sender] = true;
        emit GroupCreated(groupCount, name, msg.sender);
    }

    function toggleGroupMember(uint256 gid, address user, bool status) external {
        require(gid > 0 && gid <= groupCount, "Invalid group");
        require(msg.sender == groups[gid].admin, "Only admin");
        require(user != address(0), "Invalid user");
        if (!status) {
            require(user != groups[gid].admin, "Admin cannot be removed");
        }
        groupMembers[gid][user] = status;
        emit MemberUpdated(gid, user, status);
    }

    function sendGroupMessage(uint256 gid, string calldata cid, string calldata fileType)
        external
        notPaused
        antiSpam
    {
        require(groupMembers[gid][msg.sender], "Not member");
        require(bytes(cid).length > 0 && bytes(cid).length <= 128, "Invalid CID");
        require(bytes(fileType).length > 0 && bytes(fileType).length <= 20, "Invalid type");

        groupMessages[gid].push(
            Message(msg.sender, cid, fileType, block.timestamp, false, false)
        );
        emit GroupMessage(gid, msg.sender, groupMessages[gid].length - 1);
    }

    // ===== VIEW (PAGINATED — gas-DoS safe) =====

    function getInboxLength(address user) external view returns (uint256) {
        return inbox[user].length;
    }

    function getMessages(uint256 start, uint256 limit)
        external view returns (Message[] memory)
    {
        uint256 len = inbox[msg.sender].length;
        if (start >= len) return new Message[](0);

        uint256 end = start + limit;
        if (end > len) end = len;

        Message[] memory result = new Message[](end - start);
        uint256 j;
        for (uint256 i = start; i < end; ) {
            result[j++] = inbox[msg.sender][i];
            unchecked { i++; }
        }
        return result;
    }

    function getActiveMessages(uint256 start, uint256 limit)
        external view returns (Message[] memory)
    {
        uint256 len = inbox[msg.sender].length;
        if (start >= len) return new Message[](0);

        uint256 end = (start + limit > len) ? len : start + limit;

        uint256 count;
        for (uint256 i = start; i < end; ) {
            if (!inbox[msg.sender][i].isDeleted) count++;
            unchecked { i++; }
        }

        Message[] memory result = new Message[](count);
        uint256 j;
        for (uint256 i = start; i < end; ) {
            if (!inbox[msg.sender][i].isDeleted) {
                result[j++] = inbox[msg.sender][i];
            }
            unchecked { i++; }
        }
        return result;
    }

    function getGroupMessagesLength(uint256 gid) external view returns (uint256) {
        return groupMessages[gid].length;
    }

    // GROUP messages paginated (fixes the unbounded-array gas risk)
    function getGroupMessages(uint256 gid, uint256 start, uint256 limit)
        external view returns (Message[] memory)
    {
        uint256 len = groupMessages[gid].length;
        if (start >= len) return new Message[](0);

        uint256 end = start + limit;
        if (end > len) end = len;

        Message[] memory result = new Message[](end - start);
        uint256 j;
        for (uint256 i = start; i < end; ) {
            result[j++] = groupMessages[gid][i];
            unchecked { i++; }
        }
        return result;
    }

    // ===== ADMIN =====

    function setOracle(address _oracle) external onlyOwner {
        priceOracle = IPriceOracle(_oracle);
        emit ConfigUpdated("oracle");
    }

    function setNFT(address _nft) external onlyOwner {
        memberNFT = IMemberNFT(_nft);
        emit ConfigUpdated("nft");
    }

    function setMediaStorage(address _ms) external onlyOwner {
        require(_ms.code.length > 0, "Must be contract");
        mediaStorage = IMediaStorage(_ms);
        emit ConfigUpdated("mediaStorage");
    }

    function setUseOSGFee(bool status) external onlyOwner {
        useOSGFee = status;
        emit ConfigUpdated("useOSGFee");
    }

    function setAllowedToken(address token, bool status) external onlyOwner {
        require(token != address(0), "Invalid token");
        allowedTokens[token] = status;
        emit ConfigUpdated("allowedToken");
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Invalid");
        treasury = _treasury;
        emit ConfigUpdated("treasury");
    }

    function setFees(uint256 _feeUSD, uint256 _msgFeeOSG, uint256 _burnPct, uint256 _payFeeBp)
        external onlyOwner
    {
        require(_burnPct <= 100, "Burn max 100%");
        require(_payFeeBp <= 1000, "Pay fee max 10%");
        feeUSD          = _feeUSD;
        messagingFeeOSG = _msgFeeOSG;
        burnPercent     = _burnPct;
        paymentFee      = _payFeeBp;
        emit ConfigUpdated("fees");
    }

    function setCooldown(uint256 _seconds) external onlyOwner {
        require(_seconds <= 1 hours, "Max 1h");
        cooldown = _seconds;
        emit ConfigUpdated("cooldown");
    }

    function setPause(bool _status) external onlyOwner {
        paused = _status;
        emit Paused(_status);
    }

    function version() external pure returns (string memory) {
        return "OSGMessenger v7";
    }

    receive() external payable {}
}
