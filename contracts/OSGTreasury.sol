// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 *  OSGTreasury -- a seasonal vault for the OSG launch programmes.
 *
 *  WHAT THIS IS
 *  ------------
 *  A plain, boring box of OSG with two separate compartments:
 *
 *      teamBonusPool  -- pays the A1 / A2 / A3 achievement bonus
 *      airdropPool    -- pays the referral airdrop
 *
 *  The two never mix. Money put in for the airdrop can never be spent
 *  on bonuses and vice versa. That is deliberate: the most common way
 *  a programme like this dies is one bucket quietly eating the other.
 *
 *  WHO CAN TAKE MONEY OUT
 *  ----------------------
 *  Only whitelisted contracts (OSGReferral v4, OSGAirdrop). There is no
 *  ownerWithdraw, and rescueToken explicitly refuses OSG.
 *
 *  Be honest about what that does and does not mean. The owner controls
 *  allowSpender(), so an owner who wanted to could whitelist a contract
 *  of their own and route OSG out through it. This is an owner-trusted
 *  design, not a trustless one. What the code does guarantee is that
 *  every such move is a public, logged, on-chain event -- there is no
 *  quiet path. For a short launch programme run by one person that is
 *  the honest trade; anyone who needs more should wait for a timelock
 *  or a fixed spender set.
 *
 *  WHY IT IS SEASONAL
 *  ------------------
 *  These programmes run for a fixed launch window, not for ever.
 *  endsAt is a public timestamp. After it passes, and only then,
 *  drain() lets the owner recover whatever is left, so unspent OSG
 *  is not stranded for eternity. Before it passes, drain() reverts.
 *
 *  SPENDING DOES NOT REVERT WHEN THE VAULT IS LOW
 *  ----------------------------------------------
 *  spendTeamBonus / spendAirdrop return the amount actually paid,
 *  which may be less than asked and may be zero. They never revert on
 *  a shortfall. The calling contract is expected to record the unpaid
 *  remainder as still-owed and let the user come back later.
 *
 *  This is the lesson from OSGReferral v3: bookkeeping and payment must
 *  not share a transaction frame. If a transfer reverts inside the same
 *  frame that recorded an entitlement, the entitlement is rolled back
 *  too and the user silently loses it.
 *
 *  MONTHLY CEILING
 *  ---------------
 *  The team bonus bucket has a rolling 30-day ceiling (monthlyCap).
 *  It stops a bug, or an unexpectedly large qualifying wave, from
 *  emptying the vault in a single day. The airdrop bucket has no
 *  ceiling here -- its total is capped inside OSGAirdrop by a
 *  maximum wallet count instead.
 */
contract OSGTreasury is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------
    //  Immutable wiring
    // ---------------------------------------------------------------

    IERC20 public immutable osg;

    // ---------------------------------------------------------------
    //  Buckets
    // ---------------------------------------------------------------

    /// OSG reserved for the A1/A2/A3 achievement bonus.
    uint256 public teamBonusPool;

    /// OSG reserved for the referral airdrop.
    uint256 public airdropPool;

    // ---------------------------------------------------------------
    //  Season
    // ---------------------------------------------------------------

    /// End of the season. New entitlements stop being earned here --
    /// that rule lives in the programme contracts, not in the vault.
    uint256 public endsAt;

    /// Grace window after endsAt. Payouts keep working through it so
    /// anything recorded as owed near the end can still be collected.
    /// drain() stays locked until it is over.
    uint256 public constant GRACE = 30 days;

    /// Once this passes the vault is shut: no more payouts, drain opens.
    function closesAt() public view returns (uint256) {
        return endsAt + GRACE;
    }

    // ---------------------------------------------------------------
    //  Rolling monthly ceiling on the team bonus bucket
    // ---------------------------------------------------------------

    uint256 public constant PERIOD = 30 days;

    /// Ceiling per rolling 30-day period, in wei.
    uint256 public monthlyCap;

    /// Start of the current period.
    uint256 public periodStart;

    /// Spent from teamBonusPool inside the current period.
    uint256 public spentThisPeriod;

    // ---------------------------------------------------------------
    //  Whitelist
    // ---------------------------------------------------------------

    /// Contracts allowed to pull from the buckets.
    mapping(address => bool) public isSpender;

    // ---------------------------------------------------------------
    //  Lifetime counters (read-only, for the dashboard)
    // ---------------------------------------------------------------

    uint256 public totalTeamBonusFunded;
    uint256 public totalTeamBonusPaid;
    uint256 public totalAirdropFunded;
    uint256 public totalAirdropPaid;

    // ---------------------------------------------------------------
    //  Events
    // ---------------------------------------------------------------

    event TeamBonusFunded(address indexed from, uint256 amount, uint256 poolAfter);
    event AirdropFunded(address indexed from, uint256 amount, uint256 poolAfter);

    event TeamBonusPaid(
        address indexed spender,
        address indexed to,
        uint256 requested,
        uint256 paid
    );
    event AirdropPaid(
        address indexed spender,
        address indexed to,
        uint256 requested,
        uint256 paid
    );

    event TeamBonusShort(address indexed to, uint256 requested, uint256 paid, string reason);
    event AirdropShort(address indexed to, uint256 requested, uint256 paid);

    event SpenderChanged(address indexed spender, bool allowed);
    event MonthlyCapChanged(uint256 oldCap, uint256 newCap);
    event SeasonEndChanged(uint256 oldEndsAt, uint256 newEndsAt);
    event PeriodRolled(uint256 newPeriodStart);
    event Drained(
        address indexed to,
        uint256 teamBonusPart,
        uint256 airdropPart,
        uint256 unaccountedSurplus,
        uint256 totalSent
    );
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    // ---------------------------------------------------------------
    //  Construction
    // ---------------------------------------------------------------

    /**
     *  @param _osg         OSG token address.
     *  @param _seasonDays  Length of the launch season in days (e.g. 180).
     *  @param _monthlyCap  Rolling 30-day ceiling for the team bonus, in wei.
     */
    constructor(
        address _osg,
        uint256 _seasonDays,
        uint256 _monthlyCap
    ) Ownable(msg.sender) {
        require(_osg != address(0), "osg is zero");
        require(_seasonDays > 0 && _seasonDays <= 730, "season out of range");
        require(_monthlyCap > 0, "cap is zero");

        osg = IERC20(_osg);
        endsAt = block.timestamp + (_seasonDays * 1 days);
        monthlyCap = _monthlyCap;
        periodStart = block.timestamp;
    }

    // ---------------------------------------------------------------
    //  Funding -- open to anyone
    // ---------------------------------------------------------------

    /**
     *  Put OSG into the team bonus bucket. Caller must have approved
     *  this contract first. Anyone may fund; there is no reason to
     *  restrict money coming in.
     */
    function fundTeamBonus(uint256 amount) external nonReentrant {
        require(amount > 0, "amount is zero");
        osg.safeTransferFrom(msg.sender, address(this), amount);
        teamBonusPool += amount;
        totalTeamBonusFunded += amount;
        emit TeamBonusFunded(msg.sender, amount, teamBonusPool);
    }

    /// Put OSG into the airdrop bucket.
    function fundAirdrop(uint256 amount) external nonReentrant {
        require(amount > 0, "amount is zero");
        osg.safeTransferFrom(msg.sender, address(this), amount);
        airdropPool += amount;
        totalAirdropFunded += amount;
        emit AirdropFunded(msg.sender, amount, airdropPool);
    }

    // ---------------------------------------------------------------
    //  Spending -- whitelisted contracts only
    // ---------------------------------------------------------------

    /**
     *  Pay out of the team bonus bucket.
     *
     *  Returns the amount actually sent, which may be less than
     *  `amount` and may be zero. It never reverts because the vault is
     *  low or the monthly ceiling is reached -- the caller records the
     *  remainder as still owed.
     */
    function spendTeamBonus(address to, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 paid)
    {
        require(isSpender[msg.sender], "not a spender");
        require(block.timestamp < closesAt(), "vault closed");
        require(to != address(0), "to is zero");
        if (amount == 0) return 0;

        _rollPeriodIfDue();

        uint256 capLeft = monthlyCap > spentThisPeriod
            ? monthlyCap - spentThisPeriod
            : 0;

        paid = amount;
        string memory reason = "";

        if (paid > capLeft) {
            paid = capLeft;
            reason = "monthly cap";
        }
        if (paid > teamBonusPool) {
            paid = teamBonusPool;
            reason = "pool empty";
        }

        if (paid > 0) {
            teamBonusPool -= paid;
            spentThisPeriod += paid;
            totalTeamBonusPaid += paid;
            osg.safeTransfer(to, paid);
        }

        emit TeamBonusPaid(msg.sender, to, amount, paid);
        if (paid < amount) {
            emit TeamBonusShort(to, amount, paid, reason);
        }
    }

    /**
     *  Pay out of the airdrop bucket. Same contract: returns what was
     *  actually sent, never reverts on a shortfall.
     */
    function spendAirdrop(address to, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 paid)
    {
        require(isSpender[msg.sender], "not a spender");
        require(block.timestamp < closesAt(), "vault closed");
        require(to != address(0), "to is zero");
        if (amount == 0) return 0;

        paid = amount > airdropPool ? airdropPool : amount;

        if (paid > 0) {
            airdropPool -= paid;
            totalAirdropPaid += paid;
            osg.safeTransfer(to, paid);
        }

        emit AirdropPaid(msg.sender, to, amount, paid);
        if (paid < amount) {
            emit AirdropShort(to, amount, paid);
        }
    }

    // ---------------------------------------------------------------
    //  Period roll
    // ---------------------------------------------------------------

    /// Move to a fresh 30-day window if the current one has elapsed.
    function _rollPeriodIfDue() internal {
        if (block.timestamp >= periodStart + PERIOD) {
            // Jump forward in whole periods so the window never drifts.
            uint256 elapsed = block.timestamp - periodStart;
            periodStart += (elapsed / PERIOD) * PERIOD;
            spentThisPeriod = 0;
            emit PeriodRolled(periodStart);
        }
    }

    /// Anyone may nudge the period forward; it changes nothing else.
    function rollPeriod() external {
        _rollPeriodIfDue();
    }

    // ---------------------------------------------------------------
    //  Owner controls
    // ---------------------------------------------------------------

    /**
     *  Allow or revoke a spending contract. Takes effect immediately --
     *  a timelock was considered and rejected: this is a short seasonal
     *  programme run by one person, and being unable to cut off a
     *  misbehaving contract for two days is the larger risk. Every
     *  change is logged, so the history is public either way.
     */
    function allowSpender(address spender, bool allowed) external onlyOwner {
        require(spender != address(0), "spender is zero");
        isSpender[spender] = allowed;
        emit SpenderChanged(spender, allowed);
    }

    /// Adjust the rolling ceiling for the team bonus bucket.
    function setMonthlyCap(uint256 newCap) external onlyOwner {
        require(newCap > 0, "cap is zero");
        emit MonthlyCapChanged(monthlyCap, newCap);
        monthlyCap = newCap;
    }

    /**
     *  Extend the season. It can only move forward -- 6 months can
     *  become 9, never the other way round. A season that could be cut
     *  short is not a commitment, and shortening it would also pull
     *  drain() closer, which is exactly the move holders should not
     *  have to trust anyone about.
     *
     *  Once the vault has closed the season is fixed for good. Without
     *  this a drained vault could be reopened months later -- payouts
     *  would start passing their time check again against an empty
     *  contract, and the closing date would stop meaning anything.
     *  Extending has to happen while the programme is still alive.
     */
    function setEndsAt(uint256 newEndsAt) external onlyOwner {
        require(block.timestamp < closesAt(), "vault closed");
        require(newEndsAt >= endsAt, "cannot shorten season");
        require(newEndsAt <= block.timestamp + 730 days, "too far out");
        emit SeasonEndChanged(endsAt, newEndsAt);
        endsAt = newEndsAt;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ---------------------------------------------------------------
    //  End of season
    // ---------------------------------------------------------------

    /**
     *  Recover whatever is left once the vault has closed -- that is
     *  the season plus the 30-day grace window, so anyone still owed
     *  from the final days has had time to collect.
     *
     *  This sends the contract's whole OSG balance, not just the sum of
     *  the two buckets. Anyone can transfer OSG straight to this address
     *  without going through fundTeamBonus / fundAirdrop -- a mistyped
     *  send, a stray airdrop -- and that OSG is in no bucket. Draining
     *  only the accounted total would leave it here for ever, and
     *  rescueToken refuses OSG by design. One function that empties the
     *  vault completely is cleaner than a second escape hatch sitting
     *  beside it.
     *
     *  The buckets are still reported separately in the event so the
     *  split, and any unaccounted surplus, stays legible on-chain.
     */
    function drain(address to) external onlyOwner nonReentrant {
        require(block.timestamp >= closesAt(), "vault still open");
        require(to != address(0), "to is zero");

        uint256 teamPart = teamBonusPool;
        uint256 airPart = airdropPool;
        uint256 balance = osg.balanceOf(address(this));
        require(balance > 0, "nothing to drain");

        uint256 accounted = teamPart + airPart;
        uint256 surplus = balance > accounted ? balance - accounted : 0;

        teamBonusPool = 0;
        airdropPool = 0;
        osg.safeTransfer(to, balance);

        emit Drained(to, teamPart, airPart, surplus, balance);
    }

    /**
     *  Recover a token sent here by mistake. OSG is excluded on
     *  purpose -- allowing it would be a back door around every rule
     *  above.
     */
    function rescueToken(address token, address to, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        require(token != address(osg), "OSG is not rescuable");
        require(to != address(0), "to is zero");
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    // ---------------------------------------------------------------
    //  Views
    // ---------------------------------------------------------------

    /// How much the team bonus bucket can still pay right now.
    function teamBonusAvailable() public view returns (uint256) {
        uint256 spent = spentThisPeriod;
        if (block.timestamp >= periodStart + PERIOD) spent = 0;

        uint256 capLeft = monthlyCap > spent ? monthlyCap - spent : 0;
        return capLeft < teamBonusPool ? capLeft : teamBonusPool;
    }

    /// Seconds until the season ends; zero once it has.
    function secondsLeft() external view returns (uint256) {
        return block.timestamp >= endsAt ? 0 : endsAt - block.timestamp;
    }

    /// Seconds until the vault shuts for good; zero once it has.
    function secondsUntilClose() external view returns (uint256) {
        uint256 c = closesAt();
        return block.timestamp >= c ? 0 : c - block.timestamp;
    }

    /// Everything a dashboard needs in one call.
    function snapshot()
        external
        view
        returns (
            uint256 teamPool,
            uint256 airPool,
            uint256 teamAvailableNow,
            uint256 capPerPeriod,
            uint256 spentInPeriod,
            uint256 periodEndsAt,
            uint256 seasonEndsAt,
            uint256 vaultClosesAt,
            bool isPaused
        )
    {
        return (
            teamBonusPool,
            airdropPool,
            teamBonusAvailable(),
            monthlyCap,
            block.timestamp >= periodStart + PERIOD ? 0 : spentThisPeriod,
            periodStart + PERIOD,
            endsAt,
            closesAt(),
            paused()
        );
    }

    /// Balance actually held, so any accounting drift is visible.
    function heldBalance() external view returns (uint256) {
        return osg.balanceOf(address(this));
    }

    /**
     *  OSG sitting here that belongs to neither bucket -- normally
     *  zero. A non-zero figure means someone transferred OSG straight
     *  to this address instead of calling fundTeamBonus / fundAirdrop.
     *  It cannot be spent by either programme; drain() collects it once
     *  the vault closes.
     */
    function unaccountedOSG() external view returns (uint256) {
        uint256 balance = osg.balanceOf(address(this));
        uint256 accounted = teamBonusPool + airdropPool;
        return balance > accounted ? balance - accounted : 0;
    }

    function version() external pure returns (string memory) {
        return "OSGTreasury v1.3";
    }
}
