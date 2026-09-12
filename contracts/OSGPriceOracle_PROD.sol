// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "@openzeppelin/contracts/access/Ownable.sol";

/*
 * =============================================================
 *  OSGPriceOracle v1
 *  OSG priced in USD, for OSGReferral v5.
 * =============================================================
 *
 *  WHY A TWAP AND NOT THE SPOT PRICE
 *  ---------------------------------
 *  The pool price can be moved and moved back inside one
 *  transaction, and the capital to do it can be borrowed for the
 *  length of that transaction. At the pool's present depth the whole
 *  round trip costs about the swap fees -- roughly a hundred dollars
 *  to double the displayed price. Anything reading the spot price to
 *  decide who qualifies is reading a number the reader can choose.
 *
 *  A time-weighted average cannot be moved that way. Shifting a
 *  24-hour average means holding the pool away from its true price
 *  for hours while arbitrage drains the difference out of you. That
 *  is real money, continuously, and it scales with how deep the pool
 *  is -- which is the property we want.
 *
 *
 *  WHY THERE IS NO KEEPER REQUIREMENT
 *  ----------------------------------
 *  update() is open to anyone and rewards nobody. If it stops being
 *  called this contract goes stale and osgUsdPrice() REVERTS rather
 *  than answering with an old number. OSGReferral wraps the call in
 *  try/catch and falls back to its owner-posted price, so a silent
 *  oracle degrades to manual pricing instead of breaking anything.
 *
 *  That is the whole design: nothing here is load-bearing. It is an
 *  improvement on a manual figure, and when it stops improving it
 *  gets out of the way.
 *
 *
 *  THE PAIR
 *  --------
 *  QuickSwap V2, 0xA15214B09a9b3E1c821B94fB97d6d3BcA8201Cd2
 *      token0 = WPOL
 *      token1 = OSG
 *
 *  In UniswapV2 accounting price1 is reserve0/reserve1, which is WPOL
 *  per OSG -- the direction we want. price0 would give OSG per WPOL
 *  and every figure downstream would be inverted. Verified on-chain
 *  4 Sep 2026: 424,559 / 42,529 = 9.9827, matching the 9.9826 the
 *  explorers were showing.
 */

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function getReserves() external view returns (
        uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast
    );
}

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (
        uint80 roundId, int256 answer, uint256 startedAt,
        uint256 updatedAt, uint80 answeredInRound
    );
}

contract OSGPriceOracle is Ownable {

    // ================= WIRING =================

    IUniswapV2Pair  public pair;
    IAggregatorV3   public polUsdFeed;

    /// True when OSG is token1 of the pair, which decides whether the
    /// WPOL-per-OSG reading comes from price1 or price0. Set once at
    /// construction from the pair itself rather than trusted as input.
    bool public osgIsToken1;

    // ================= SNAPSHOT =================

    uint256 public priceCumulativeLast;
    uint32  public blockTimestampLast;

    /// WPOL per OSG, 18 decimals, averaged over the last window.
    uint256 public twapWpolPerOsg;
    uint256 public lastUpdated;

    // ================= SETTINGS =================

    /// Shortest span an update may average over. A shorter window is
    /// a cheaper window to manipulate, so this has a floor.
    uint256 public period = 24 hours;

    /// How old this contract's own answer may be before it refuses.
    uint256 public maxAge = 48 hours;

    /// How old the Chainlink round may be. The POL/USD feed updates on
    /// deviation or heartbeat; well past either means it has stopped.
    uint256 public maxFeedAge = 6 hours;

    event Updated(uint256 twapWpolPerOsg, uint256 elapsed);
    event PeriodUpdated(uint256 period);
    event AgeLimitsUpdated(uint256 maxAge, uint256 maxFeedAge);
    event FeedUpdated(address feed);

    error PairMismatch();
    error NoReserves();
    error TooSoon();
    error Stale();
    error FeedStale();
    error BadFeedAnswer();
    error BadSetting();

    constructor(address _pair, address _osg, address _feed, address _owner)
        Ownable(_owner)
    {
        if (_pair.code.length == 0 || _feed.code.length == 0) revert PairMismatch();

        pair       = IUniswapV2Pair(_pair);
        polUsdFeed = IAggregatorV3(_feed);

        // Every figure downstream assumes eight decimals, which is what
        // Chainlink USD feeds use. A feed that counts differently would
        // not fail -- it would report a price wrong by a factor of ten
        // billion and every threshold would move with it.
        if (polUsdFeed.decimals() != 8) revert BadFeedAnswer();

        // Which side OSG sits on decides whether the reading is WPOL per
        // OSG or its inverse. Getting it backwards would not fail -- it
        // would quietly report a price that is wrong in both directions
        // at once. So the pair is asked, at construction, and a pair
        // that does not hold OSG is refused outright.
        if      (pair.token1() == _osg) { osgIsToken1 = true;  }
        else if (pair.token0() == _osg) { osgIsToken1 = false; }
        else revert PairMismatch();

        (uint112 r0, uint112 r1, uint32 ts) = pair.getReserves();
        if (r0 == 0 || r1 == 0) revert NoReserves();

        priceCumulativeLast = osgIsToken1
            ? pair.price1CumulativeLast()
            : pair.price0CumulativeLast();
        blockTimestampLast = ts;
    }

    /// Point the reading at whichever side OSG actually sits on. Called
    /// once after deployment with the OSG token address; the pair is
    /// what answers, not the caller.
    function setOsgToken(address osg) external onlyOwner {
        if (pair.token1() == osg)      { osgIsToken1 = true;  }
        else if (pair.token0() == osg) { osgIsToken1 = false; }
        else revert PairMismatch();

        priceCumulativeLast = osgIsToken1
            ? pair.price1CumulativeLast()
            : pair.price0CumulativeLast();
        ( , , uint32 ts) = pair.getReserves();
        blockTimestampLast = ts;
        lastUpdated        = 0;   // force a fresh window
    }

    // =====================================================================
    //  READING THE PAIR
    // =====================================================================

    /// The cumulative price as of RIGHT NOW, including the stretch since
    /// the pair was last touched. Without this an untraded pair would
    /// report the same cumulative forever and the average would never
    /// move. Counters are meant to wrap; the subtraction is unchecked
    /// on purpose.
    function currentCumulative() public view returns (uint256 cum, uint32 ts) {
        (uint112 r0, uint112 r1, uint32 tsLast) = pair.getReserves();
        if (r0 == 0 || r1 == 0) revert NoReserves();

        ts  = uint32(block.timestamp % 2**32);
        cum = osgIsToken1 ? pair.price1CumulativeLast() : pair.price0CumulativeLast();

        if (tsLast != ts) {
            uint32 gap;
            unchecked { gap = ts - tsLast; }
            // UQ112x112: the ratio is shifted up by 112 bits before it
            // is scaled by time, exactly as the pair itself does it.
            uint224 ratio = osgIsToken1
                ? uint224((uint256(r0) << 112) / r1)
                : uint224((uint256(r1) << 112) / r0);
            unchecked { cum += uint256(ratio) * gap; }
        }
    }

    /// Take a new average. Open to anyone; moves nothing.
    function update() external {
        (uint256 cum, uint32 ts) = currentCumulative();

        uint32 elapsed;
        unchecked { elapsed = ts - blockTimestampLast; }
        if (elapsed < period) revert TooSoon();

        uint256 delta;
        unchecked { delta = cum - priceCumulativeLast; }

        // delta/elapsed is the average in UQ112x112; shifting back down
        // by 112 after scaling to 1e18 keeps the precision.
        uint256 avgQ112 = delta / elapsed;
        twapWpolPerOsg  = (avgQ112 * 1e18) >> 112;

        priceCumulativeLast = cum;
        blockTimestampLast  = ts;
        lastUpdated         = block.timestamp;

        emit Updated(twapWpolPerOsg, elapsed);
    }

    // =====================================================================
    //  THE ANSWER
    // =====================================================================

    function polUsd() public view returns (uint256) {
        (, int256 answer, , uint256 updatedAt, ) = polUsdFeed.latestRoundData();
        if (answer <= 0) revert BadFeedAnswer();
        if (block.timestamp - updatedAt > maxFeedAge) revert FeedStale();
        return uint256(answer);   // 8 decimals
    }

    /// OSG in USD, 8 decimals, to match how Chainlink quotes.
    ///
    /// Reverts rather than guesses. OSGReferral reads this inside a
    /// try/catch and keeps its own posted price when this refuses, so
    /// refusing is the safe answer and a stale number is not.
    function osgUsdPrice() external view returns (uint256) {
        if (twapWpolPerOsg == 0) revert Stale();
        if (lastUpdated == 0 || block.timestamp - lastUpdated > maxAge) revert Stale();

        // (WPOL per OSG, 1e18) x (USD per WPOL, 1e8) / 1e18
        return (twapWpolPerOsg * polUsd()) / 1e18;
    }

    /// What update() would produce if called now, and whether it is
    /// allowed yet. For dashboards and for deciding when to call.
    function preview()
        external
        view
        returns (uint256 wouldBeTwap, uint32 elapsed, bool ready, bool answerStale)
    {
        (uint256 cum, uint32 ts) = currentCumulative();
        unchecked { elapsed = ts - blockTimestampLast; }
        ready = elapsed >= period;

        if (elapsed > 0) {
            uint256 delta;
            unchecked { delta = cum - priceCumulativeLast; }
            wouldBeTwap = ((delta / elapsed) * 1e18) >> 112;
        }
        answerStale = lastUpdated == 0 || block.timestamp - lastUpdated > maxAge;
    }

    // =====================================================================
    //  SETTINGS
    // =====================================================================

    function setPeriod(uint256 p) external onlyOwner {
        if (!(p >= 1 hours && p <= 7 days)) revert BadSetting();
        period = p;
        emit PeriodUpdated(p);
    }

    function setAgeLimits(uint256 _maxAge, uint256 _maxFeedAge) external onlyOwner {
        if (!(_maxAge >= period && _maxAge <= 30 days)) revert BadSetting();
        if (!(_maxFeedAge >= 10 minutes && _maxFeedAge <= 7 days)) revert BadSetting();
        maxAge     = _maxAge;
        maxFeedAge = _maxFeedAge;
        emit AgeLimitsUpdated(_maxAge, _maxFeedAge);
    }

    /// If Chainlink ever retires this proxy, point at the replacement.
    function setFeed(address feed) external onlyOwner {
        if (feed.code.length == 0) revert BadSetting();
        if (IAggregatorV3(feed).decimals() != 8) revert BadFeedAnswer();
        polUsdFeed = IAggregatorV3(feed);
        emit FeedUpdated(feed);
    }

    function version() external pure returns (string memory) {
        return "OSGPriceOracle v1";
    }
}
