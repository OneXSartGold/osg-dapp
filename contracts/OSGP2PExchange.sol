// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title OSGP2PExchangeV2
/// @notice P2P order-book exchange with AUTO-MATCHING built into order placement.
///         When a new order is placed, it first tries to fill against existing
///         opposite-side orders at an acceptable price (in the same transaction).
///         Any unfilled remainder rests in the book, exactly like v1.
///         Manual acceptOrder() is kept too, for taking a specific resting order.
contract OSGP2PExchangeV2 is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------- constants ----------
    uint256 public constant PRICE_SCALE = 1e18;
    uint256 public constant MAX_FEE_BPS = 200; // 2% hard cap
    uint256 public constant MAX_SCAN = 500; // cap for acceptOrder() manual scans (user controls startFrom to page deeper)
    uint256 public constant MAX_MATCH = 40; // cap on how many resting orders one placeOrder() can auto-fill (gas safety)
    uint256 public constant AUTO_MATCH_SCAN = 50; // cap on how many resting orders placeOrder() re-scans per match, to bound gas (keeps auto-match cheap even as the book grows; deeper/older orders still reachable via manual acceptOrder)

    // ---------- fee ----------
    uint256 public feeBps = 50; // 0.5%
    address public feeCollector;

    // ---------- pairs ----------
    struct Pair {
        address token;
        bool active;
        uint256 minAmount;
    }
    uint256 public pairCounter;
    mapping(uint256 => Pair) public pairs;
    mapping(address => bool) public tokenRegistered;

    // ---------- orders ----------
    struct Order {
        address user;
        uint256 pairId;
        bool isBuy;
        uint128 price; // scaled by PRICE_SCALE (native-currency wei per 1 whole token)
        uint128 amount; // remaining amount, token's own decimals (18)
        uint40 timestamp;
        uint40 expiryTime; // 0 = never
        uint8 status; // 0 = open, 1 = filled, 2 = cancelled
    }
    uint256 public orderCounter;
    mapping(uint256 => Order) public orders;

    // append-only per-pair id lists (closed orders stay in the list with status/amount reflecting reality)
    mapping(uint256 => uint256[]) public pairBuyOrderIds;
    mapping(uint256 => uint256[]) public pairSellOrderIds;

    // same user + same pair + same price -> existing open order id (for auto-merge instead of duplicate spam)
    mapping(address => mapping(uint256 => mapping(uint256 => uint256)))
        public userBuyPriceOrder;
    mapping(address => mapping(uint256 => mapping(uint256 => uint256)))
        public userSellPriceOrder;

    // ---------- events ----------
    event PairAdded(uint256 indexed pairId, address indexed token);
    event PairActiveSet(uint256 indexed pairId, bool active);
    event FeeUpdated(uint256 newFeeBps);
    event FeeCollectorUpdated(address newCollector);
    event OrderPlaced(
        uint256 indexed orderId,
        address indexed user,
        uint256 indexed pairId,
        bool isBuy,
        uint256 price,
        uint256 amount,
        uint256 expiryTime
    );
    event OrderFilled(
        uint256 indexed orderId,
        address indexed taker,
        uint256 filledAmount,
        uint256 remainingAmount
    );
    event OrderCancelled(
        uint256 indexed orderId,
        address indexed user,
        uint256 refundedAmount
    );
    event OrderMerged(
        uint256 indexed orderId,
        address indexed user,
        uint256 addedAmount,
        uint256 newTotalAmount,
        uint256 newExpiryTime
    );

    // ---------- errors ----------
    error PairNotActive();
    error InvalidPrice();
    error InvalidAmount();
    error InsufficientPayment();
    error NotOrderOwner();
    error OrderNotOpen();
    error NothingToCancel();
    error TransferFailed();
    error ZeroAddress();
    error FeeTooHigh();

    constructor(
        address _token,
        address _feeCollector
    ) Ownable(msg.sender) {
        if (_feeCollector == address(0)) revert ZeroAddress();
        feeCollector = _feeCollector;
        pairCounter = 1;
        pairs[1] = Pair({ token: _token, active: true, minAmount: 0 });
        tokenRegistered[_token] = true;
        emit PairAdded(1, _token);
    }

    // ================= ADMIN =================

    error TokenAlreadyRegistered();

    function addPair(
        address token,
        uint256 minAmount
    ) external onlyOwner returns (uint256 pairId) {
        if (token == address(0)) revert ZeroAddress();
        if (tokenRegistered[token]) revert TokenAlreadyRegistered();
        pairCounter++;
        pairs[pairCounter] = Pair({
            token: token,
            active: true,
            minAmount: minAmount
        });
        tokenRegistered[token] = true;
        emit PairAdded(pairCounter, token);
        return pairCounter;
    }

    function setPairActive(uint256 pairId, bool active) external onlyOwner {
        pairs[pairId].active = active;
        emit PairActiveSet(pairId, active);
    }

    function setFee(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    function setFeeCollector(address collector) external onlyOwner {
        if (collector == address(0)) revert ZeroAddress();
        feeCollector = collector;
        emit FeeCollectorUpdated(collector);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ================= PLACE ORDERS (auto-matching) =================

    /// @notice Place a buy order. Matches immediately against resting sell orders
    ///         priced at or below `price`, then rests any unfilled remainder.
    function placeBuyOrder(
        uint256 pairId,
        uint128 price,
        uint128 amount,
        uint40 expiryTime
    ) external payable whenNotPaused nonReentrant returns (uint256 orderId) {
        Pair memory pr = pairs[pairId];
        if (!pr.active) revert PairNotActive();
        if (price == 0) revert InvalidPrice();
        if (amount == 0 || amount < pr.minAmount) revert InvalidAmount();

        uint256 maxCost = (uint256(price) * uint256(amount)) / PRICE_SCALE;
        if (msg.value < maxCost) revert InsufficientPayment();

        uint256 remaining = amount;
        uint256 spent = 0;
        uint256 matched = 0;

        uint256[] storage sellIds = pairSellOrderIds[pairId];
        uint256 len = sellIds.length;
        uint256 scanLimit = len < AUTO_MATCH_SCAN ? len : AUTO_MATCH_SCAN;

        while (remaining > 0 && matched < MAX_MATCH) {
            // find the CHEAPEST eligible sell order within the scan window (price priority)
            uint256 bestIdx = type(uint256).max;
            uint256 bestPrice = type(uint256).max;
            for (uint256 i = 0; i < scanLimit; i++) {
                uint256 sid = sellIds[i];
                Order storage sOrd = orders[sid];
                if (sOrd.status != 0 || sOrd.amount == 0) continue;
                if (sOrd.user == msg.sender) continue; // no self-trade
                if (sOrd.price > price) continue; // seller wants more than this buyer offers
                if (sOrd.expiryTime != 0 && sOrd.expiryTime <= block.timestamp)
                    continue; // stale, skip (owner can cancelExpiredOrder separately)
                if (sOrd.price < bestPrice) {
                    bestPrice = sOrd.price;
                    bestIdx = i;
                }
            }
            if (bestIdx == type(uint256).max) break; // nothing eligible left

            uint256 bestSid = sellIds[bestIdx];
            Order storage bestOrd = orders[bestSid];
            matched++;
            uint256 fillAmt = remaining < bestOrd.amount
                ? remaining
                : bestOrd.amount;
            uint256 fillCost = (uint256(bestOrd.price) * fillAmt) /
                PRICE_SCALE; // pay maker's own (cheapest) ask price
            uint256 fee = (fillCost * feeBps) / 10000;
            uint256 sellerProceeds = fillCost - fee;

            bestOrd.amount -= uint128(fillAmt);
            if (bestOrd.amount == 0) bestOrd.status = 1;

            IERC20(pr.token).safeTransfer(msg.sender, fillAmt);
            _sendNative(bestOrd.user, sellerProceeds);
            if (fee > 0) _sendNative(feeCollector, fee);

            remaining -= fillAmt;
            spent += fillCost;
            emit OrderFilled(bestSid, msg.sender, fillAmt, bestOrd.amount);
        }

        uint256 restLock = 0;
        if (remaining > 0) {
            restLock = (uint256(price) * remaining) / PRICE_SCALE;
            orderId = _restBuy(pairId, price, uint128(remaining), expiryTime);
        }

        uint256 used = spent + restLock;
        if (msg.value > used) {
            _sendNative(msg.sender, msg.value - used);
        }
    }

    /// @notice Place a sell order. Matches immediately against resting buy orders
    ///         priced at or above `price`, then rests any unfilled remainder.
    function placeSellOrder(
        uint256 pairId,
        uint128 price,
        uint128 amount,
        uint40 expiryTime
    ) external whenNotPaused nonReentrant returns (uint256 orderId) {
        Pair memory pr = pairs[pairId];
        if (!pr.active) revert PairNotActive();
        if (price == 0) revert InvalidPrice();
        if (amount == 0 || amount < pr.minAmount) revert InvalidAmount();

        // escrow the full amount up front (simplest, safest accounting)
        IERC20(pr.token).safeTransferFrom(msg.sender, address(this), amount);

        uint256 remaining = amount;
        uint256 matched = 0;

        uint256[] storage buyIds = pairBuyOrderIds[pairId];
        uint256 len = buyIds.length;
        uint256 scanLimit = len < AUTO_MATCH_SCAN ? len : AUTO_MATCH_SCAN;

        while (remaining > 0 && matched < MAX_MATCH) {
            // find the highest-paying eligible buy order within the scan window (price priority)
            uint256 bestIdx = type(uint256).max;
            uint256 bestPrice = 0;
            for (uint256 i = 0; i < scanLimit; i++) {
                uint256 bid = buyIds[i];
                Order storage bOrd = orders[bid];
                if (bOrd.status != 0 || bOrd.amount == 0) continue;
                if (bOrd.user == msg.sender) continue;
                if (bOrd.price < price) continue; // buyer offers less than this seller wants
                if (bOrd.expiryTime != 0 && bOrd.expiryTime <= block.timestamp)
                    continue;
                if (bOrd.price > bestPrice) {
                    bestPrice = bOrd.price;
                    bestIdx = i;
                }
            }
            if (bestIdx == type(uint256).max) break; // nothing eligible left

            uint256 bestBid = buyIds[bestIdx];
            Order storage bestOrd = orders[bestBid];
            matched++;
            uint256 fillAmt = remaining < bestOrd.amount
                ? remaining
                : bestOrd.amount;
            uint256 fillCost = (uint256(bestOrd.price) * fillAmt) /
                PRICE_SCALE; // buyer's own (highest) bid price
            uint256 fee = (fillCost * feeBps) / 10000;
            uint256 sellerProceeds = fillCost - fee;

            bestOrd.amount -= uint128(fillAmt);
            if (bestOrd.amount == 0) bestOrd.status = 1;

            IERC20(pr.token).safeTransfer(bestOrd.user, fillAmt);
            _sendNative(msg.sender, sellerProceeds);
            if (fee > 0) _sendNative(feeCollector, fee);

            remaining -= fillAmt;
            emit OrderFilled(bestBid, msg.sender, fillAmt, bestOrd.amount);
        }

        if (remaining > 0) {
            orderId = _restSell(pairId, price, uint128(remaining), expiryTime);
        }
    }

    function _restBuy(
        uint256 pairId,
        uint128 price,
        uint128 amount,
        uint40 expiryTime
    ) internal returns (uint256) {
        uint256 existing = userBuyPriceOrder[msg.sender][pairId][price];
        if (existing != 0 && orders[existing].status == 0) {
            Order storage o = orders[existing];
            o.amount += amount;
            if (expiryTime > o.expiryTime) o.expiryTime = expiryTime;
            emit OrderMerged(existing, msg.sender, amount, o.amount, o.expiryTime);
            return existing;
        }
        orderCounter++;
        uint256 id = orderCounter;
        orders[id] = Order({
            user: msg.sender,
            pairId: pairId,
            isBuy: true,
            price: price,
            amount: amount,
            timestamp: uint40(block.timestamp),
            expiryTime: expiryTime,
            status: 0
        });
        pairBuyOrderIds[pairId].push(id);
        userBuyPriceOrder[msg.sender][pairId][price] = id;
        emit OrderPlaced(id, msg.sender, pairId, true, price, amount, expiryTime);
        return id;
    }

    function _restSell(
        uint256 pairId,
        uint128 price,
        uint128 amount,
        uint40 expiryTime
    ) internal returns (uint256) {
        uint256 existing = userSellPriceOrder[msg.sender][pairId][price];
        if (existing != 0 && orders[existing].status == 0) {
            Order storage o = orders[existing];
            o.amount += amount;
            if (expiryTime > o.expiryTime) o.expiryTime = expiryTime;
            emit OrderMerged(existing, msg.sender, amount, o.amount, o.expiryTime);
            return existing;
        }
        orderCounter++;
        uint256 id = orderCounter;
        orders[id] = Order({
            user: msg.sender,
            pairId: pairId,
            isBuy: false,
            price: price,
            amount: amount,
            timestamp: uint40(block.timestamp),
            expiryTime: expiryTime,
            status: 0
        });
        pairSellOrderIds[pairId].push(id);
        userSellPriceOrder[msg.sender][pairId][price] = id;
        emit OrderPlaced(id, msg.sender, pairId, false, price, amount, expiryTime);
        return id;
    }

    // ================= MANUAL ACCEPT (tap-to-trade on a specific resting order) =================

    /// @notice Manually accept resting orders on one side, scanning from `startFrom`.
    ///         Kept for the existing frontend "tap a price to trade instantly" flow.
    function acceptOrder(
        uint256 pairId,
        bool wantBuy, // true = taker is buying (fills sell orders), false = taker is selling (fills buy orders)
        uint128 amount,
        uint128 priceLimit,
        uint256 startFrom,
        uint256 maxScan
    )
        external
        payable
        whenNotPaused
        nonReentrant
        returns (uint256 filledAmount, uint256 nextScanIndex)
    {
        Pair memory pr = pairs[pairId];
        if (!pr.active) revert PairNotActive();
        if (amount == 0) revert InvalidAmount();
        uint256 scanCap = maxScan > MAX_SCAN ? MAX_SCAN : maxScan;

        if (wantBuy) {
            uint256[] storage sellIds = pairSellOrderIds[pairId];
            uint256 len = sellIds.length;
            uint256 remaining = amount;
            uint256 spent = 0;
            uint256 i = startFrom;
            uint256 scanned = 0;
            for (; i < len && remaining > 0 && scanned < scanCap; i++) {
                scanned++;
                uint256 sid = sellIds[i];
                Order storage sOrd = orders[sid];
                if (sOrd.status != 0 || sOrd.amount == 0) continue;
                if (sOrd.user == msg.sender) continue;
                if (sOrd.price > priceLimit) continue;
                if (sOrd.expiryTime != 0 && sOrd.expiryTime <= block.timestamp)
                    continue;

                uint256 fillAmt = remaining < sOrd.amount
                    ? remaining
                    : sOrd.amount;
                uint256 fillCost = (uint256(sOrd.price) * fillAmt) /
                    PRICE_SCALE;
                uint256 fee = (fillCost * feeBps) / 10000;
                uint256 sellerProceeds = fillCost - fee;

                if (msg.value < spent + fillCost) break; // stop before exceeding what buyer sent

                sOrd.amount -= uint128(fillAmt);
                if (sOrd.amount == 0) sOrd.status = 1;

                IERC20(pr.token).safeTransfer(msg.sender, fillAmt);
                _sendNative(sOrd.user, sellerProceeds);
                if (fee > 0) _sendNative(feeCollector, fee);

                remaining -= fillAmt;
                spent += fillCost;
                emit OrderFilled(sid, msg.sender, fillAmt, sOrd.amount);
            }
            filledAmount = amount - remaining;
            nextScanIndex = i;
            if (msg.value > spent) _sendNative(msg.sender, msg.value - spent);
        } else {
            IERC20(pr.token).safeTransferFrom(msg.sender, address(this), amount);
            uint256[] storage buyIds = pairBuyOrderIds[pairId];
            uint256 len = buyIds.length;
            uint256 remaining = amount;
            uint256 i = startFrom;
            uint256 scanned = 0;
            for (; i < len && remaining > 0 && scanned < scanCap; i++) {
                scanned++;
                uint256 bid = buyIds[i];
                Order storage bOrd = orders[bid];
                if (bOrd.status != 0 || bOrd.amount == 0) continue;
                if (bOrd.user == msg.sender) continue;
                if (bOrd.price < priceLimit) continue;
                if (bOrd.expiryTime != 0 && bOrd.expiryTime <= block.timestamp)
                    continue;

                uint256 fillAmt = remaining < bOrd.amount
                    ? remaining
                    : bOrd.amount;
                uint256 fillCost = (uint256(bOrd.price) * fillAmt) /
                    PRICE_SCALE;
                uint256 fee = (fillCost * feeBps) / 10000;
                uint256 sellerProceeds = fillCost - fee;

                bOrd.amount -= uint128(fillAmt);
                if (bOrd.amount == 0) bOrd.status = 1;

                IERC20(pr.token).safeTransfer(bOrd.user, fillAmt);
                _sendNative(msg.sender, sellerProceeds);
                if (fee > 0) _sendNative(feeCollector, fee);

                remaining -= fillAmt;
                emit OrderFilled(bid, msg.sender, fillAmt, bOrd.amount);
            }
            filledAmount = amount - remaining;
            nextScanIndex = i;
            if (remaining > 0) {
                // return unfilled tokens back to the taker
                IERC20(pr.token).safeTransfer(msg.sender, remaining);
            }
        }
    }

    // ================= CANCEL =================

    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        if (o.user != msg.sender) revert NotOrderOwner();
        if (o.status != 0) revert OrderNotOpen();
        if (o.amount == 0) revert NothingToCancel();

        uint256 refundAmount = o.amount;
        Pair memory pr = pairs[o.pairId];
        o.amount = 0;
        o.status = 2;

        if (o.isBuy) {
            uint256 refundWei = (uint256(o.price) * refundAmount) /
                PRICE_SCALE;
            _sendNative(msg.sender, refundWei);
        } else {
            IERC20(pr.token).safeTransfer(msg.sender, refundAmount);
        }
        emit OrderCancelled(orderId, msg.sender, refundAmount);
    }

    /// @notice Anyone can trigger cleanup of an expired order; refund always goes to its owner.
    function cancelExpiredOrder(uint256 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        if (o.status != 0) revert OrderNotOpen();
        if (o.expiryTime == 0 || o.expiryTime > block.timestamp)
            revert NothingToCancel();

        uint256 refundAmount = o.amount;
        Pair memory pr = pairs[o.pairId];
        address owner_ = o.user;
        o.amount = 0;
        o.status = 2;

        if (refundAmount > 0) {
            if (o.isBuy) {
                uint256 refundWei = (uint256(o.price) * refundAmount) /
                    PRICE_SCALE;
                _sendNative(owner_, refundWei);
            } else {
                IERC20(pr.token).safeTransfer(owner_, refundAmount);
            }
        }
        emit OrderCancelled(orderId, owner_, refundAmount);
    }

    // ================= VIEWS =================

    function pairBuyOrderIdsLength(
        uint256 pairId
    ) external view returns (uint256) {
        return pairBuyOrderIds[pairId].length;
    }

    function pairSellOrderIdsLength(
        uint256 pairId
    ) external view returns (uint256) {
        return pairSellOrderIds[pairId].length;
    }

    // ================= INTERNAL =================

    function _sendNative(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = payable(to).call{ value: amount }("");
        if (!ok) revert TransferFailed();
    }

    receive() external payable {}
}
