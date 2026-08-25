// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title  OSGP2PExchangeV3
/// @notice On-chain P2P order book with auto-matching, for any base/quote pair.
///
/// What changed from v2, and why:
///
///  1. QUOTE CURRENCY IS NO LONGER HARD-CODED.
///     v2 could only ever settle in the chain's native coin. A pair here
///     carries its own quote token; address(0) still means native. This is
///     what makes OSG/USDT possible alongside OSG/POL.
///
///  2. PRICE IS DECIMAL-SAFE.
///     v2 divided by a fixed 1e18, which silently breaks for a 6-decimal
///     quote like USDT. Here price is "quote smallest units per ONE WHOLE
///     base token", so one formula covers every pair:
///         quoteAmount = baseAmount * price / 10**baseDecimals
///
///  3. CLOSED ORDERS LEAVE THE BOOK.
///     v2 appended order ids and never removed them, while auto-match only
///     ever scanned the first 50 entries. Once those 50 were closed orders,
///     matching was dead permanently. Here every close does a swap-and-pop,
///     so the arrays hold open orders only.
///
///  4. A FAILED PAYOUT NO LONGER REVERTS THE TRADE.
///     v2 reverted if a recipient refused native coin, so a single contract
///     that rejects POL could freeze one whole side of the book. Here the
///     amount is credited to a pending balance the recipient withdraws
///     later. This applies to the fee collector too, which in v2 was a
///     single point of failure for every trade on the exchange.
///
///  5. NO MERGING.
///     v2 folded a new order into an existing one at the same price and
///     pushed the expiry out, so escrow could be extended indefinitely. It
///     also rounded escrow down twice while refunding once, leaking a wei.
///     Orders here are always separate; removal is O(1) so nothing bloats.
///
///  6. OrderFilled CARRIES THE WHOLE TRADE — maker, taker, side, price,
///     both amounts and the fee. v2's event could not tell you who traded
///     with whom or at what price.
contract OSGP2PExchangeV3 is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // constants
    // ------------------------------------------------------------------

    uint256 public constant MAX_FEE_BPS = 200; // 2% ceiling, immutable
    uint256 public constant MAX_SCAN = 500; // ceiling for a manual accept scan
    uint256 public constant MAX_MATCH = 40; // resting orders one call may fill
    uint256 public constant AUTO_MATCH_SCAN = 50; // window auto-match looks at
    uint256 public constant MAX_EXPIRY = 30 days; // longest an order may rest
    uint256 public constant MAX_OPEN_PER_USER = 10; // open orders per wallet
    uint256 public constant SWEEP_ON_PLACE = 6; // expired orders cleared per placement

    // ------------------------------------------------------------------
    // fee
    // ------------------------------------------------------------------

    /// Fee is always taken out of the SELLER's proceeds, whichever side is
    /// maker or taker. This is exactly what v2 did; keeping it means nobody
    /// has to relearn anything.
    uint256 public feeBps = 50; // 0.5%
    address public feeCollector;

    // ------------------------------------------------------------------
    // pairs
    // ------------------------------------------------------------------

    struct Pair {
        address base; // the token being traded, e.g. OSG
        address quote; // address(0) = native coin, else an ERC20 e.g. USDT
        uint8 baseDec; // read once at addPair, never re-read
        uint8 quoteDec; // informational; the maths only needs baseDec
        uint256 minBase; // must be > 0
        bool active;
    }

    uint256 public pairCounter;
    mapping(uint256 => Pair) public pairs;
    mapping(bytes32 => bool) public pairRegistered; // base|quote already added

    // ------------------------------------------------------------------
    // orders
    // ------------------------------------------------------------------

    uint8 public constant OPEN = 0;
    uint8 public constant FILLED = 1;
    uint8 public constant CANCELLED = 2;

    struct Order {
        address maker;
        uint64 pairId;
        bool isBuy;
        uint128 price; // quote smallest units per 1 whole base token
        uint128 baseAmount; // remaining, in base smallest units
        uint40 createdAt;
        uint40 expiry;
        uint32 index; // position in its side array, for swap-and-pop
        uint8 status;
    }

    uint256 public orderCounter;
    mapping(uint256 => Order) public orders;

    /// Open orders only. Filling or cancelling removes the id at once, and
    /// _sweepExpired clears out orders that simply ran out of time.
    mapping(uint256 => uint256[]) private _buyIds;
    mapping(uint256 => uint256[]) private _sellIds;

    mapping(address => uint256) public openOrderCount;

    // ------------------------------------------------------------------
    // pull payments and liability accounting
    // ------------------------------------------------------------------

    /// Owed to someone whose payout failed. They withdraw at their leisure.
    mapping(address => uint256) public pendingNative;
    mapping(address => mapping(address => uint256)) public pendingToken;

    /// Everything the contract owes anyone: escrowed order funds plus
    /// pending payouts. rescue() may only ever touch the surplus above this.
    uint256 public liabilityNative;
    mapping(address => uint256) public liabilityToken;

    // ------------------------------------------------------------------
    // events
    // ------------------------------------------------------------------

    event PairAdded(
        uint256 indexed pairId,
        address indexed base,
        address indexed quote,
        uint256 minBase
    );
    event PairActiveSet(uint256 indexed pairId, bool active);
    event MinBaseSet(uint256 indexed pairId, uint256 minBase);
    event FeeUpdated(uint256 newFeeBps);
    event FeeCollectorUpdated(address newCollector);

    event OrderPlaced(
        uint256 indexed orderId,
        address indexed maker,
        uint256 indexed pairId,
        bool isBuy,
        uint256 price,
        uint256 baseAmount,
        uint256 expiry
    );

    event OrderFilled(
        uint256 indexed orderId,
        address indexed maker,
        address indexed taker,
        uint256 pairId,
        bool makerWasBuying,
        uint256 price,
        uint256 filledBase,
        uint256 quoteAmount,
        uint256 fee,
        uint256 remainingBase
    );

    event OrderCancelled(
        uint256 indexed orderId,
        address indexed maker,
        uint256 refundedBase,
        uint256 refundedQuote
    );

    event PayoutDeferred(address indexed to, address indexed asset, uint256 amount);
    event Withdrawn(address indexed to, address indexed asset, uint256 amount);
    event Rescued(address indexed asset, address indexed to, uint256 amount);

    // ------------------------------------------------------------------
    // errors
    // ------------------------------------------------------------------

    error NotAContract();
    error InvalidPair();
    error PairNotActive();
    error PairExists();
    error InvalidPrice();
    error InvalidAmount();
    error BelowMinimum();
    error BadExpiry();
    error TooManyOpenOrders();
    error InsufficientPayment();
    error NativeNotAccepted();
    error NotOrderOwner();
    error OrderNotOpen();
    error NotExpired();
    error NothingPending();
    error NothingToRescue();
    error ZeroAddress();
    error FeeTooHigh();
    error RenounceDisabled();

    // ------------------------------------------------------------------

    constructor(address _feeCollector) Ownable(msg.sender) {
        if (_feeCollector == address(0)) revert ZeroAddress();
        feeCollector = _feeCollector;
    }

    // ==================================================================
    // admin
    // ==================================================================

    /// @notice Register a market. Decimals are read once here and stored, so
    ///         no trade ever depends on an external call to the token.
    /// @param quote address(0) for the native coin, else an ERC20.
    function addPair(
        address base,
        address quote,
        uint256 minBase
    ) external onlyOwner returns (uint256 pairId) {
        if (base == address(0)) revert ZeroAddress();
        if (base == quote) revert ZeroAddress();
        if (minBase == 0) revert InvalidAmount(); // dust spam is how a book dies
        if (base.code.length == 0) revert NotAContract();
        if (quote != address(0) && quote.code.length == 0) revert NotAContract();

        bytes32 key = keccak256(abi.encodePacked(base, quote));
        if (pairRegistered[key]) revert PairExists();
        pairRegistered[key] = true;

        uint8 bDec = IERC20Metadata(base).decimals();
        uint8 qDec = quote == address(0) ? 18 : IERC20Metadata(quote).decimals();

        pairCounter++;
        pairs[pairCounter] = Pair({
            base: base,
            quote: quote,
            baseDec: bDec,
            quoteDec: qDec,
            minBase: minBase,
            active: true
        });

        emit PairAdded(pairCounter, base, quote, minBase);
        return pairCounter;
    }

    function setPairActive(uint256 pairId, bool active) external onlyOwner {
        if (pairId == 0 || pairId > pairCounter) revert InvalidPair();
        pairs[pairId].active = active;
        emit PairActiveSet(pairId, active);
    }

    function setMinBase(uint256 pairId, uint256 minBase) external onlyOwner {
        if (pairId == 0 || pairId > pairCounter) revert InvalidPair();
        if (minBase == 0) revert InvalidAmount();
        pairs[pairId].minBase = minBase;
        emit MinBaseSet(pairId, minBase);
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

    /// Pausing must never trap anyone's money, so cancel and withdraw stay
    /// open while paused. Renouncing would kill every setter above, which
    /// for a single-owner project is a one-click way to lose the contract.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ==================================================================
    // maths
    // ==================================================================

    /// @dev The whole decimal problem, solved in one line.
    ///      price is quote smallest units per ONE WHOLE base token.
    ///
    ///      OSG/USDT: 100 OSG at 0.87 USDT
    ///        (100e18 * 870000) / 1e18 = 87_000_000 = 87.00 USDT
    ///      OSG/POL:  100 OSG at 8.11 POL
    ///        (100e18 * 8.11e18) / 1e18 = 811e18 = 811 POL
    function quoteFor(
        uint256 pairId,
        uint256 baseAmount,
        uint256 price
    ) public view returns (uint256) {
        // An unknown pair would read baseDec as 0, making the divisor 1 and
        // the answer wrong by a factor of 10**18. The app prices orders off
        // this view, so it must refuse rather than answer nonsense.
        if (pairId == 0 || pairId > pairCounter) revert InvalidPair();
        return
            Math.mulDiv(
                baseAmount,
                price,
                10 ** uint256(pairs[pairId].baseDec)
            );
    }

    /// @dev mulDiv holds the intermediate product at full 512-bit width, so a
    ///      large amount multiplied by a large price cannot overflow on the
    ///      way to a perfectly ordinary result.
    function _quote(
        Pair memory p,
        uint256 baseAmount,
        uint256 price
    ) internal pure returns (uint256) {
        return Math.mulDiv(baseAmount, price, 10 ** uint256(p.baseDec));
    }

    // ==================================================================
    // place
    // ==================================================================

    /// @notice Place a limit order. It first fills against anything already
    ///         resting at an acceptable price, then whatever is left rests.
    /// @param price quote smallest units per one whole base token.
    /// @param expiry unix seconds; must be in the future and within 30 days.
    function placeOrder(
        uint256 pairId,
        bool isBuy,
        uint128 price,
        uint128 baseAmount,
        uint40 expiry
    ) external payable whenNotPaused nonReentrant returns (uint256 orderId) {
        Pair memory p = pairs[pairId];
        if (!p.active) revert PairNotActive();
        if (price == 0) revert InvalidPrice();
        if (baseAmount == 0) revert InvalidAmount();
        if (baseAmount < p.minBase) revert BelowMinimum();
        if (expiry <= block.timestamp || expiry > block.timestamp + MAX_EXPIRY)
            revert BadExpiry();

        if (isBuy) {
            orderId = _placeBuy(pairId, p, price, baseAmount, expiry);
        } else {
            orderId = _placeSell(pairId, p, price, baseAmount, expiry);
        }
    }

    function _placeBuy(
        uint256 pairId,
        Pair memory p,
        uint128 price,
        uint128 baseAmount,
        uint40 expiry
    ) internal returns (uint256 orderId) {
        // Take the worst case up front, refund the difference at the end.
        uint256 maxCost = _quote(p, baseAmount, price);
        uint256 funded = _takeQuote(p, maxCost);
        // A quote token that skims a cut on transfer would leave the order
        // underfunded and the contract paying the difference out of someone
        // else's escrow. Refuse rather than absorb it.
        if (funded < maxCost) revert InsufficientPayment();

        _sweepExpired(pairId, false, SWEEP_ON_PLACE);

        uint256 remaining = baseAmount;
        uint256 spent = 0;

        for (uint256 matched = 0; matched < MAX_MATCH; matched++) {
            if (remaining == 0) break;
            uint256 pos = _bestAsk(_sellIds[pairId], price);
            if (pos == type(uint256).max) break;

            uint256 sid = _sellIds[pairId][pos];
            uint256 fillBase = remaining < orders[sid].baseAmount
                ? remaining
                : orders[sid].baseAmount;

            uint256 fq = _fillAsk(p, pairId, sid, fillBase, msg.sender);
            if (fq == 0) break; // rounds to nothing; stop rather than give base away

            remaining -= fillBase;
            spent += fq;
        }

        uint256 rest = 0;
        if (remaining > 0) {
            rest = _quote(p, remaining, price);
            orderId = _rest(pairId, true, price, uint128(remaining), expiry);
        }

        uint256 used = spent + rest;
        if (funded > used) _payQuote(p, msg.sender, funded - used);
    }

    function _placeSell(
        uint256 pairId,
        Pair memory p,
        uint128 price,
        uint128 baseAmount,
        uint40 expiry
    ) internal returns (uint256 orderId) {
        if (msg.value != 0) revert NativeNotAccepted();

        // escrow the base tokens; measure what actually arrived in case the
        // token takes a cut on transfer
        uint256 got = _pullToken(p.base, baseAmount);
        if (got < p.minBase) revert BelowMinimum();

        _sweepExpired(pairId, true, SWEEP_ON_PLACE);

        uint256 remaining = got;

        for (uint256 matched = 0; matched < MAX_MATCH; matched++) {
            if (remaining == 0) break;
            uint256 pos = _bestBid(_buyIds[pairId], price);
            if (pos == type(uint256).max) break;

            uint256 bid = _buyIds[pairId][pos];
            uint256 fillBase = remaining < orders[bid].baseAmount
                ? remaining
                : orders[bid].baseAmount;

            uint256 fq = _fillBid(p, pairId, bid, fillBase, msg.sender);
            if (fq == 0) break;

            remaining -= fillBase;
        }

        if (remaining > 0) {
            orderId = _rest(pairId, false, price, uint128(remaining), expiry);
        }
    }

    // ---------- matching helpers ----------
    //
    // Kept as separate functions for two reasons: the matching loops stay
    // readable, and the compiler stops running out of stack slots.
    //
    // Both only look at the first AUTO_MATCH_SCAN entries. That window is an
    // honest limitation, not an oversight: a better price sitting deeper in
    // the book will not be found automatically. It is reachable through
    // acceptOrder(), which pages with startFrom. Since expired and closed
    // orders are now removed, those first entries are all live orders.

    function _bestAsk(
        uint256[] storage arr,
        uint256 maxPrice
    ) internal view returns (uint256 pos) {
        pos = type(uint256).max;
        uint256 bestPrice = type(uint256).max;
        uint256 scan = arr.length < AUTO_MATCH_SCAN
            ? arr.length
            : AUTO_MATCH_SCAN;
        for (uint256 i = 0; i < scan; i++) {
            Order storage o = orders[arr[i]];
            if (o.maker == msg.sender) continue; // no self-trade
            if (o.price > maxPrice) continue;
            if (o.expiry <= block.timestamp) continue;
            if (o.price < bestPrice) {
                bestPrice = o.price;
                pos = i;
            }
        }
    }

    function _bestBid(
        uint256[] storage arr,
        uint256 minPrice
    ) internal view returns (uint256 pos) {
        pos = type(uint256).max;
        uint256 bestPrice = 0;
        uint256 scan = arr.length < AUTO_MATCH_SCAN
            ? arr.length
            : AUTO_MATCH_SCAN;
        for (uint256 i = 0; i < scan; i++) {
            Order storage o = orders[arr[i]];
            if (o.maker == msg.sender) continue;
            if (o.price < minPrice) continue;
            if (o.expiry <= block.timestamp) continue;
            if (o.price > bestPrice) {
                bestPrice = o.price;
                pos = i;
            }
        }
    }

    /// @dev Taker buys base from a resting ask. Returns the quote moved, or
    ///      zero if the fill would round away to nothing.
    function _fillAsk(
        Pair memory p,
        uint256 pairId,
        uint256 orderId,
        uint256 fillBase,
        address taker
    ) internal returns (uint256 fillQuote) {
        Order storage o = orders[orderId];
        fillQuote = _quote(p, fillBase, o.price);
        if (fillQuote == 0) return 0;

        uint256 fee = (fillQuote * feeBps) / 10000;
        o.baseAmount -= uint128(fillBase);

        _payToken(p.base, taker, fillBase); // seller's escrow to the buyer
        _payQuote(p, o.maker, fillQuote - fee); // fee always off the seller
        if (fee > 0) _payQuote(p, feeCollector, fee);

        emit OrderFilled(
            orderId,
            o.maker,
            taker,
            pairId,
            false,
            o.price,
            fillBase,
            fillQuote,
            fee,
            o.baseAmount
        );

        if (o.baseAmount == 0) _close(orderId, FILLED);
    }

    /// @dev Taker sells base into a resting bid.
    function _fillBid(
        Pair memory p,
        uint256 pairId,
        uint256 orderId,
        uint256 fillBase,
        address taker
    ) internal returns (uint256 fillQuote) {
        Order storage o = orders[orderId];
        fillQuote = _quote(p, fillBase, o.price);
        if (fillQuote == 0) return 0;

        uint256 fee = (fillQuote * feeBps) / 10000;
        o.baseAmount -= uint128(fillBase);

        _payToken(p.base, o.maker, fillBase); // taker's escrow to the buyer
        _payQuote(p, taker, fillQuote - fee); // taker is the seller here
        if (fee > 0) _payQuote(p, feeCollector, fee);

        emit OrderFilled(
            orderId,
            o.maker,
            taker,
            pairId,
            true,
            o.price,
            fillBase,
            fillQuote,
            fee,
            o.baseAmount
        );

        if (o.baseAmount == 0) _close(orderId, FILLED);
    }

    function _rest(
        uint256 pairId,
        bool isBuy,
        uint128 price,
        uint128 baseAmount,
        uint40 expiry
    ) internal returns (uint256 id) {
        if (openOrderCount[msg.sender] >= MAX_OPEN_PER_USER)
            revert TooManyOpenOrders();

        orderCounter++;
        id = orderCounter;

        uint256[] storage arr = isBuy ? _buyIds[pairId] : _sellIds[pairId];

        orders[id] = Order({
            maker: msg.sender,
            pairId: uint64(pairId),
            isBuy: isBuy,
            price: price,
            baseAmount: baseAmount,
            createdAt: uint40(block.timestamp),
            expiry: expiry,
            index: uint32(arr.length),
            status: OPEN
        });

        arr.push(id);
        openOrderCount[msg.sender]++;

        emit OrderPlaced(id, msg.sender, pairId, isBuy, price, baseAmount, expiry);
    }

    /// @dev Swap-and-pop. This single function is why v3's auto-match cannot
    ///      rot the way v2's did — the arrays never accumulate dead entries.
    function _close(uint256 orderId, uint8 status) internal {
        Order storage o = orders[orderId];
        uint256[] storage arr = o.isBuy
            ? _buyIds[o.pairId]
            : _sellIds[o.pairId];

        uint256 i = o.index;
        uint256 last = arr.length - 1;
        if (i != last) {
            uint256 movedId = arr[last];
            arr[i] = movedId;
            orders[movedId].index = uint32(i);
        }
        arr.pop();

        o.status = status;
        if (openOrderCount[o.maker] > 0) openOrderCount[o.maker]--;
    }

    // ==================================================================
    // expired-order cleanup
    // ==================================================================

    /// @notice Clear expired orders off the front of one side of a book and
    ///         refund their makers.
    /// @dev    This is the other half of the fix for v2's dead auto-match.
    ///         Removing *closed* orders is not enough on its own: an order
    ///         that merely expired stays in the array, and since matching
    ///         only ever looks at the first AUTO_MATCH_SCAN slots, enough
    ///         expired orders parked at the front would starve matching just
    ///         as effectively — and cheaply, since anyone can place them.
    ///         So the front of the window is swept before every match.
    ///         Callable while paused: it only ever hands money back.
    function sweepExpired(
        uint256 pairId,
        bool isBuy,
        uint256 maxSweep
    ) external nonReentrant returns (uint256 swept) {
        return
            _sweepExpired(
                pairId,
                isBuy,
                maxSweep > AUTO_MATCH_SCAN ? AUTO_MATCH_SCAN : maxSweep
            );
    }

    function _sweepExpired(
        uint256 pairId,
        bool isBuy,
        uint256 maxSweep
    ) internal returns (uint256 swept) {
        uint256[] storage arr = isBuy ? _buyIds[pairId] : _sellIds[pairId];
        uint256 i = 0;
        uint256 scanned = 0;
        while (
            i < arr.length && swept < maxSweep && scanned < AUTO_MATCH_SCAN
        ) {
            scanned++;
            uint256 id = arr[i];
            Order storage o = orders[id];
            if (o.expiry <= block.timestamp) {
                _refundAndClose(id, o);
                swept++;
                // a different order now occupies slot i, so do not advance
            } else {
                i++;
            }
        }
    }

    // ==================================================================
    // take a specific resting order (tap-to-trade)
    // ==================================================================

    function acceptOrder(
        uint256 pairId,
        bool wantBuy, // true: taker buys base, filling sell orders
        uint128 baseAmount,
        uint128 priceLimit,
        uint256 startFrom,
        uint256 maxScan
    )
        external
        payable
        whenNotPaused
        nonReentrant
        returns (uint256 filledBase, uint256 nextIndex)
    {
        Pair memory p = pairs[pairId];
        if (!p.active) revert PairNotActive();
        if (baseAmount == 0) revert InvalidAmount();
        // placeOrder enforced the pair minimum but acceptOrder did not, so a
        // taker could buy dust and pay dust. The minimum is on what is asked
        // for, not on what comes back: a book holding less than the minimum
        // must still be clearable, so a partial fill below it stays legal.
        if (baseAmount < p.minBase) revert BelowMinimum();
        uint256 cap = maxScan > MAX_SCAN ? MAX_SCAN : maxScan;

        if (wantBuy) {
            (filledBase, nextIndex) = _takeAsks(
                pairId,
                p,
                baseAmount,
                priceLimit,
                startFrom,
                cap
            );
        } else {
            (filledBase, nextIndex) = _hitBids(
                pairId,
                p,
                baseAmount,
                priceLimit,
                startFrom,
                cap
            );
        }
    }

    function _takeAsks(
        uint256 pairId,
        Pair memory p,
        uint128 baseAmount,
        uint128 priceLimit,
        uint256 startFrom,
        uint256 cap
    ) internal returns (uint256 filledBase, uint256 nextIndex) {
        uint256 needed = _quote(p, baseAmount, priceLimit);
        uint256 budget = _takeQuote(p, needed);
        if (budget < needed) revert InsufficientPayment();

        // placeOrder sweeps, acceptOrder did not — so a book only ever taken
        // by tap-to-trade could still silt up with expired orders.
        _sweepExpired(pairId, false, SWEEP_ON_PLACE);

        uint256[] storage arr = _sellIds[pairId];
        uint256 remaining = baseAmount;
        uint256 spent = 0;
        uint256 i = startFrom;
        uint256 scanned = 0;

        while (i < arr.length && remaining > 0 && scanned < cap) {
            scanned++;
            uint256 sid = arr[i];
            Order storage o = orders[sid];

            if (
                o.maker == msg.sender ||
                o.price > priceLimit ||
                o.expiry <= block.timestamp
            ) {
                i++;
                continue;
            }

            uint256 fillBase = remaining < o.baseAmount
                ? remaining
                : o.baseAmount;
            uint256 fq = _quote(p, fillBase, o.price);
            if (fq == 0) break;
            if (spent + fq > budget) break; // cannot afford this one

            bool closes = (o.baseAmount == fillBase);
            _fillAsk(p, pairId, sid, fillBase, msg.sender);

            remaining -= fillBase;
            spent += fq;

            // when an order closes, swap-and-pop drops a different order into
            // slot i, so staying put is what examines it next
            if (!closes) i++;
        }

        filledBase = baseAmount - remaining;
        nextIndex = i;
        if (budget > spent) _payQuote(p, msg.sender, budget - spent);
    }

    function _hitBids(
        uint256 pairId,
        Pair memory p,
        uint128 baseAmount,
        uint128 priceLimit,
        uint256 startFrom,
        uint256 cap
    ) internal returns (uint256 filledBase, uint256 nextIndex) {
        if (msg.value != 0) revert NativeNotAccepted();

        uint256 got = _pullToken(p.base, baseAmount);

        _sweepExpired(pairId, true, SWEEP_ON_PLACE);

        uint256[] storage arr = _buyIds[pairId];
        uint256 remaining = got;
        uint256 i = startFrom;
        uint256 scanned = 0;

        while (i < arr.length && remaining > 0 && scanned < cap) {
            scanned++;
            uint256 bid = arr[i];
            Order storage o = orders[bid];

            if (
                o.maker == msg.sender ||
                o.price < priceLimit ||
                o.expiry <= block.timestamp
            ) {
                i++;
                continue;
            }

            uint256 fillBase = remaining < o.baseAmount
                ? remaining
                : o.baseAmount;
            bool closes = (o.baseAmount == fillBase);

            uint256 fq = _fillBid(p, pairId, bid, fillBase, msg.sender);
            if (fq == 0) break;

            remaining -= fillBase;
            if (!closes) i++;
        }

        filledBase = got - remaining;
        nextIndex = i;
        if (remaining > 0) _payToken(p.base, msg.sender, remaining);
    }

    // ==================================================================
    // cancel
    // ==================================================================

    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        if (o.maker != msg.sender) revert NotOrderOwner();
        if (o.status != OPEN) revert OrderNotOpen();
        _refundAndClose(orderId, o);
    }

    /// @notice Anyone may clear an expired order. The refund always goes to
    ///         the maker, so there is nothing to gain by front-running it.
    function cancelExpired(uint256 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        if (o.status != OPEN) revert OrderNotOpen();
        if (o.expiry > block.timestamp) revert NotExpired();
        _refundAndClose(orderId, o);
    }

    function _refundAndClose(uint256 orderId, Order storage o) internal {
        Pair memory p = pairs[o.pairId];
        uint256 amt = o.baseAmount;
        address maker = o.maker;
        bool isBuy = o.isBuy;
        uint256 price = o.price;

        o.baseAmount = 0;
        _close(orderId, CANCELLED);

        uint256 refundedQuote = 0;
        uint256 refundedBase = 0;

        if (amt > 0) {
            if (isBuy) {
                refundedQuote = _quote(p, amt, price);
                _payQuote(p, maker, refundedQuote);
            } else {
                refundedBase = amt;
                _payToken(p.base, maker, amt);
            }
        }

        emit OrderCancelled(orderId, maker, refundedBase, refundedQuote);
    }

    // ==================================================================
    // money in
    // ==================================================================

    /// @dev Bring in the quote side. Native arrives with the call; an ERC20
    ///      is pulled, measuring the real delta so a fee-on-transfer token
    ///      cannot leave the books short.
    function _takeQuote(Pair memory p, uint256 amount) internal returns (uint256) {
        if (p.quote == address(0)) {
            if (msg.value < amount) revert InsufficientPayment();
            liabilityNative += msg.value;
            return msg.value; // any excess is refunded by the caller
        }
        if (msg.value != 0) revert NativeNotAccepted();
        return _pullToken(p.quote, amount);
    }

    function _pullToken(address token, uint256 amount) internal returns (uint256) {
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 got = IERC20(token).balanceOf(address(this)) - before;
        liabilityToken[token] += got;
        return got;
    }

    // ==================================================================
    // money out — never reverts the trade
    // ==================================================================

    function _payQuote(Pair memory p, address to, uint256 amount) internal {
        if (p.quote == address(0)) _payNative(to, amount);
        else _payToken(p.quote, to, amount);
    }

    function _payNative(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = payable(to).call{ value: amount, gas: 30000 }("");
        if (ok) {
            liabilityNative -= amount;
        } else {
            pendingNative[to] += amount; // still owed, so liability stands
            emit PayoutDeferred(to, address(0), amount);
        }
    }

    function _payToken(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        try IERC20(token).transfer(to, amount) returns (bool ok) {
            if (ok) {
                liabilityToken[token] -= amount;
            } else {
                pendingToken[to][token] += amount;
                emit PayoutDeferred(to, token, amount);
            }
        } catch {
            pendingToken[to][token] += amount;
            emit PayoutDeferred(to, token, amount);
        }
    }

    /// Deliberately available while paused: a pause must never trap money.
    function withdrawNative() external nonReentrant {
        uint256 amt = pendingNative[msg.sender];
        if (amt == 0) revert NothingPending();
        pendingNative[msg.sender] = 0;
        liabilityNative -= amt;
        (bool ok, ) = payable(msg.sender).call{ value: amt }("");
        if (!ok) revert InsufficientPayment();
        emit Withdrawn(msg.sender, address(0), amt);
    }

    function withdrawToken(address token) external nonReentrant {
        uint256 amt = pendingToken[msg.sender][token];
        if (amt == 0) revert NothingPending();
        pendingToken[msg.sender][token] = 0;
        liabilityToken[token] -= amt;
        IERC20(token).safeTransfer(msg.sender, amt);
        emit Withdrawn(msg.sender, token, amt);
    }

    // ==================================================================
    // rescue — surplus only, never user funds
    // ==================================================================

    function rescueNative(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = address(this).balance;
        if (bal <= liabilityNative) revert NothingToRescue();
        uint256 amt = bal - liabilityNative;
        (bool ok, ) = payable(to).call{ value: amt }("");
        if (!ok) revert InsufficientPayment();
        emit Rescued(address(0), to, amt);
    }

    function rescueToken(address token, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal <= liabilityToken[token]) revert NothingToRescue();
        uint256 amt = bal - liabilityToken[token];
        IERC20(token).safeTransfer(to, amt);
        emit Rescued(token, to, amt);
    }

    // ==================================================================
    // views
    // ==================================================================

    function buyOrderIdsLength(uint256 pairId) external view returns (uint256) {
        return _buyIds[pairId].length;
    }

    function sellOrderIdsLength(uint256 pairId) external view returns (uint256) {
        return _sellIds[pairId].length;
    }

    function buyOrderIdAt(uint256 pairId, uint256 i) external view returns (uint256) {
        return _buyIds[pairId][i];
    }

    function sellOrderIdAt(uint256 pairId, uint256 i) external view returns (uint256) {
        return _sellIds[pairId][i];
    }

    /// @notice One call for a whole side of the book, so the app does not
    ///         have to make one RPC round trip per order.
    function bookSlice(
        uint256 pairId,
        bool isBuy,
        uint256 start,
        uint256 count
    )
        external
        view
        returns (
            uint256[] memory ids,
            address[] memory makers,
            uint256[] memory prices,
            uint256[] memory amounts,
            uint256[] memory expiries
        )
    {
        uint256[] storage arr = isBuy ? _buyIds[pairId] : _sellIds[pairId];
        uint256 len = arr.length;
        if (start >= len) {
            return (
                new uint256[](0),
                new address[](0),
                new uint256[](0),
                new uint256[](0),
                new uint256[](0)
            );
        }
        uint256 end = start + count;
        if (end > len) end = len;
        uint256 n = end - start;

        ids = new uint256[](n);
        makers = new address[](n);
        prices = new uint256[](n);
        amounts = new uint256[](n);
        expiries = new uint256[](n);

        for (uint256 k = 0; k < n; k++) {
            uint256 id = arr[start + k];
            Order storage o = orders[id];
            ids[k] = id;
            makers[k] = o.maker;
            prices[k] = o.price;
            amounts[k] = o.baseAmount;
            expiries[k] = o.expiry;
        }
    }

    receive() external payable {}
}
