// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

import {WinToken} from "../../src/WinToken.sol";
import {WinGameHook} from "../../src/WinGameHook.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Lets a third party push IMD at the hook as ERC-6909 claims on the PoolManager, the same
/// form the hook keeps its own money in. Used to check that nobody can seed (or dilute) the bank.
contract ClaimDonor is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function donate(Currency currency, address to, uint256 amount) external {
        manager.unlock(abi.encode(currency, to, amount, msg.sender));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (Currency currency, address to, uint256 amount, address payer) =
            abi.decode(data, (Currency, address, uint256, address));
        manager.mint(to, currency.toId(), amount);
        manager.sync(currency);
        MockERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), amount);
        manager.settle();
        return "";
    }
}

/// @notice Drives the WIN/IMD pool and the game with bounded random actions from several actors.
///
/// Every action is wrapped in try/catch and never reverts, so no state change is ever thrown away
/// by the fuzzer. What the brief promises is restated here as a small reference model (fee curve,
/// 90/10 split, minimum buy, round timer, prizes) written from the brief, not from the hook; after
/// each action the hook's whole game state is compared with the model. A disagreement is recorded in
/// `violations` rather than reverted, and the invariant suite asserts that the counter stays at zero.
contract WinGameHandler is Test {
    // ------------------------------------------------------------------ the brief, restated

    uint256 internal constant SPEC_PIPS = 1_000_000;
    uint256 internal constant SPEC_LAUNCH_FEE = 500_000; // 50%
    uint256 internal constant SPEC_BASE_FEE = 30_000; // 3%
    uint256 internal constant SPEC_DECAY = 30 minutes;
    uint256 internal constant SPEC_TIMER = 10 minutes;
    uint256 internal constant SPEC_FIRST_ROUND_FLOOR = 3 hours;
    uint256 internal constant SPEC_FLOOR = 8.5 ether;
    uint256 internal constant SPEC_WAD = 1e18;
    uint256 internal constant SPEC_ESCALATOR_CAP = 1e36;
    address internal constant SPEC_TEAM = 0x611F08c7226591708B5F53F29BF53f3830D54511;

    // ------------------------------------------------------------------ system under test

    IPoolManager public immutable manager;
    WinGameHook public immutable hook;
    WinToken public immutable win;
    MockERC20 public immutable imd;
    PoolSwapTest public immutable router;
    PoolModifyLiquidityTest public immutable lpRouter;
    ClaimDonor public immutable donor;
    bool public immutable winIsCurrency0;
    uint256 public immutable launchTime;
    PoolKey internal key;
    uint256 internal immutable imdId;

    address[] public actors;

    // ------------------------------------------------------------------ ghosts

    struct Game {
        uint256 bank;
        uint256 team;
        uint256 unclaimed;
        uint64 started;
        bool active;
        address leader;
        uint64 deadline;
        uint32 qualifying;
        uint256 escalator;
        uint256 winners;
    }

    struct LedgerEntry {
        uint64 round;
        uint64 settledAt;
        address winner;
        uint256 prize;
    }

    /// @notice Every fee the hook was observed to take (measured as the growth of its claims).
    uint256 public ghostFees;
    uint256 public ghostBankIn;
    uint256 public ghostTeamIn;
    uint256 public ghostPrizesAwarded;
    uint256 public ghostPrizesPaid;
    uint256 public ghostTeamPaid;
    uint256 public ghostClaimsDonated;
    uint256 public ghostRawDonated;
    uint256 public ghostFeeBearingSwaps;
    /// @notice Largest bank ever seen and the fee rate seen on the previous swap (monotonicity).
    uint256 public ghostLastFeePips = SPEC_LAUNCH_FEE;
    mapping(address => uint256) public ghostPrizeOwed;
    mapping(address => uint256) public ghostPrizeReceived;
    mapping(address => uint256) public ghostLiquidity;
    LedgerEntry[] internal _ledger;

    uint256 public violations;
    string public firstViolation;

    // ------------------------------------------------------------------ coverage counters

    uint256 public buys;
    uint256 public sells;
    uint256 public qualifyingBuys;
    uint256 public nonQualifyingBuys;
    uint256 public boundaryQualified;
    uint256 public boundaryRejected;
    uint256 public roundsOpened;
    uint256 public lazyCloses;
    uint256 public settles;
    uint256 public earlySettleAttempts;
    uint256 public prizeClaims;
    uint256 public teamClaims;
    uint256 public donations;
    uint256 public liquidityChanges;
    uint256 public sellExactOutFills;
    /// @notice Buys flagged "must lead" that the hook refused because they fell short, and sells
    /// carrying the flag that were refused outright.
    uint256 public mustLeadRefusals;
    uint256 public mustLeadSellRefusals;
    uint256 public mustLeadLeads;

    constructor(
        IPoolManager manager_,
        WinGameHook hook_,
        WinToken win_,
        MockERC20 imd_,
        PoolSwapTest router_,
        PoolModifyLiquidityTest lpRouter_,
        PoolKey memory key_,
        uint256 launchTime_,
        address[] memory actors_
    ) {
        manager = manager_;
        hook = hook_;
        win = win_;
        imd = imd_;
        router = router_;
        lpRouter = lpRouter_;
        key = key_;
        launchTime = launchTime_;
        winIsCurrency0 = Currency.unwrap(key_.currency0) == address(win_);
        imdId = Currency.wrap(address(imd_)).toId();
        donor = new ClaimDonor(manager_);
        for (uint256 i = 0; i < actors_.length; i++) {
            actors.push(actors_[i]);
            vm.startPrank(actors_[i]);
            imd_.approve(address(donor), type(uint256).max);
            imd_.approve(address(lpRouter_), type(uint256).max);
            win_.approve(address(lpRouter_), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ================================================================== actions: buys

    /// @notice Exact-input buy of an arbitrary size (dust up to thousands of IMD).
    function buyExactIn(uint256 actorSeed, uint256 amount, uint256 idMode) external {
        uint256 gross = amount % 5 == 0 ? bound(amount, 1, 2_000) : bound(amount, 1, 2_000 ether);
        _buyExactIn(_actor(actorSeed), gross, idMode, 0);
    }

    /// @notice Exact-input buy aimed at the qualification boundary: exactly the minimum, one wei
    /// under it, or slightly over it.
    function buyAtThreshold(uint256 actorSeed, uint256 offset, uint256 idMode) external {
        uint256 minimum = _specMinimum(_specClose(_game()));
        uint256 kind = offset % 3;
        uint256 gross = kind == 0 ? minimum : kind == 1 ? minimum - 1 : minimum + bound(offset, 1, minimum / 20 + 1);
        _buyExactIn(_actor(actorSeed), gross, idMode, kind + 1);
    }

    /// @notice End-of-round sniping: jump to just before, exactly at, or just after the deadline
    /// and buy the minimum.
    function snipe(uint256 actorSeed, uint256 when, uint256 idMode) external {
        Game memory pre = _game();
        if (!pre.active) return;
        uint256 target = when % 3 == 0 ? pre.deadline - 1 : when % 3 == 1 ? pre.deadline : pre.deadline + 1;
        if (target > block.timestamp) vm.warp(target);
        uint256 minimum = _specMinimum(_specClose(_game()));
        _buyExactIn(_actor(actorSeed), minimum, idMode, 1);
    }

    /// @notice Exact-output buy: ask for WIN, pay whatever IMD it costs plus the fee on top.
    function buyExactOut(uint256 actorSeed, uint256 winAmount, uint256 idMode) external {
        address actor = _actor(actorSeed);
        winAmount = bound(winAmount, 1 ether, 20_000_000 ether);
        Identity memory id = _identity(actor, idMode);
        Before memory b = _before(actor);
        uint256 minimum = _specMinimum(_specClose(b.game));

        (bool ok, bytes memory err) = _swap(actor, id.origin, !winIsCurrency0, int256(winAmount), id.hookData);
        if (ok) {
            uint256 fee = _claims() - b.claims;
            uint256 gross = b.imdBalance - imd.balanceOf(actor);
            // Charged on top of what the pool took, so that it is exactly the rate of the gross.
            _check(
                fee == gross * specFeePips(block.timestamp) / SPEC_PIPS,
                "exact-out buy: fee is not the rate of the gross IMD paid"
            );
            _check(win.balanceOf(actor) - b.winBalance <= winAmount, "exact-out buy: received more WIN than asked");
            if (id.mustLead) _check(gross >= minimum, "a must-lead exact-out buy landed below the minimum");
            _afterBuy(b.game, gross, fee, id.trader, 0, id.mustLead);
        } else {
            // The pool can run out of WIN for a huge request against a price limit, or a must-lead
            // buy can fall short of the minimum once the pool has priced it; nothing changed either way.
            _checkUntouched(b, actor, "reverted exact-out buy");
            if (id.mustLead && _contains(err, WinGameHook.NotQualifying.selector)) mustLeadRefusals++;
        }
    }

    // ================================================================== actions: sells

    /// @notice Exact-input sell of part of the actor's WIN. One sell in nine carries the "must lead"
    /// flag, which the hook must refuse outright: a sell can never lead, so the flag is a mistake
    /// (or a probe) and the whole swap has to come back untouched.
    function sellExactIn(uint256 actorSeed, uint256 fraction) external {
        address actor = _actorWithWin(actorSeed);
        bool flagged = fraction % 9 == 0;
        uint256 amount = win.balanceOf(actor) * bound(fraction, 1, 100) / 100;
        if (amount == 0) return;
        Before memory b = _before(actor);

        if (flagged) {
            (bool ok, bytes memory err) = _swap(actor, actor, winIsCurrency0, -int256(amount), abi.encode(actor, true));
            _check(!ok, "a sell flagged must-lead went through");
            _check(
                _sameBytes(err, _afterSwapRevert(abi.encodeWithSelector(WinGameHook.MustLeadOnlyOnBuys.selector))),
                "flagged sell: unexpected error"
            );
            _checkUntouched(b, actor, "refused flagged sell");
            mustLeadSellRefusals++;
            return;
        }

        (bool sold,) = _swap(actor, actor, winIsCurrency0, -int256(amount), abi.encode(actor));
        if (sold) {
            uint256 fee = _claims() - b.claims;
            uint256 received = imd.balanceOf(actor) - b.imdBalance;
            // The fee comes out of the IMD the pool paid: gross = received + fee.
            _check(
                fee == (received + fee) * specFeePips(block.timestamp) / SPEC_PIPS,
                "exact-in sell: fee is not the rate of the IMD output"
            );
            _check(b.winBalance - win.balanceOf(actor) <= amount, "exact-in sell: took more WIN than offered");
            _afterSell(b.game, fee);
        } else {
            _violation("exact-in sell reverted");
        }
    }

    /// @notice Exact-output sell: ask for an exact amount of IMD net of the fee.
    function sellExactOut(uint256 actorSeed, uint256 imdAmount) external {
        address actor = _actorWithWin(actorSeed);
        if (win.balanceOf(actor) == 0) return;
        imdAmount = bound(imdAmount, 1, 20 ether);
        Before memory b = _before(actor);

        (bool ok,) = _swap(actor, actor, winIsCurrency0, int256(imdAmount), abi.encode(actor));
        if (ok) {
            uint256 fee = _claims() - b.claims;
            uint256 feePips = specFeePips(block.timestamp);
            _check(
                imd.balanceOf(actor) - b.imdBalance == imdAmount, "exact-out sell: seller did not get the IMD asked for"
            );
            _check(
                fee == imdAmount * feePips / (SPEC_PIPS - feePips), "exact-out sell: fee is not the rate of the gross"
            );
            sellExactOutFills++;
            _afterSell(b.game, fee);
        } else {
            // Not enough WIN in the wallet or not enough IMD in the pool: nothing may have changed.
            _check(_sameGame(b.game, _game()), "reverted exact-out sell changed state");
            _check(_claims() == b.claims, "reverted exact-out sell moved claims");
        }
    }

    // ================================================================== actions: game

    function settle(uint256 callerSeed) external {
        Game memory pre = _game();
        bool due = pre.active && block.timestamp >= pre.deadline;
        address winner = pre.leader;
        uint256 balanceBefore = imd.balanceOf(winner);
        uint256 owedBefore = hook.unclaimedPrize(winner);

        vm.prank(_actor(callerSeed));
        try hook.settle() {
            _check(due, "settle succeeded although the round was not over");
            uint256 prize = pre.bank * _specPrizeBps(pre.started) / 10_000;
            if (pre.started == 1) {
                _check(block.timestamp >= launchTime + SPEC_FIRST_ROUND_FLOOR, "round 1 ended before launch + 3h");
            }
            _recordWinner(pre.started, winner, prize);
            // settle pays the winner everything it is owed, including earlier lazily closed rounds.
            uint256 paid = owedBefore + prize;
            _check(imd.balanceOf(winner) - balanceBefore == paid, "settle: winner did not receive the prize");
            ghostPrizesPaid += paid;
            ghostPrizeReceived[winner] += paid;
            ghostPrizeOwed[winner] = 0;

            Game memory exp = _specClose(pre);
            exp.unclaimed = pre.unclaimed - owedBefore;
            _check(_sameGame(exp, _game()), "settle: state differs from the brief");
            settles++;
        } catch (bytes memory err) {
            _check(!due, "settle reverted although the round was over (prize stuck)");
            bytes4 expected = pre.active ? WinGameHook.RoundNotOver.selector : WinGameHook.NoActiveRound.selector;
            _check(bytes4(err) == expected, "settle reverted with an unexpected error");
            _check(_sameGame(pre, _game()), "reverted settle changed state");
            if (pre.active) earlySettleAttempts++;
        }
    }

    function claimPrize(uint256 winnerSeed, uint256 callerSeed) external {
        address winner = _actor(winnerSeed);
        Game memory pre = _game();
        uint256 owed = hook.unclaimedPrize(winner);
        _check(owed == ghostPrizeOwed[winner], "unclaimedPrize differs from the prizes awarded and not yet paid");
        uint256 balanceBefore = imd.balanceOf(winner);

        vm.prank(_actor(callerSeed));
        try hook.claimPrize(winner) {
            _check(owed > 0, "claimPrize succeeded with nothing owed");
            _check(imd.balanceOf(winner) - balanceBefore == owed, "claimPrize: wrong amount reached the winner");
            ghostPrizesPaid += owed;
            ghostPrizeReceived[winner] += owed;
            ghostPrizeOwed[winner] = 0;
            Game memory exp = _copy(pre);
            exp.unclaimed -= owed;
            _check(_sameGame(exp, _game()), "claimPrize changed more than the unclaimed total");
            prizeClaims++;
        } catch (bytes memory err) {
            _check(owed == 0, "claimPrize reverted although a prize was owed");
            _check(bytes4(err) == WinGameHook.NothingToClaim.selector, "claimPrize: unexpected error");
        }
    }

    function claimTeamFees(uint256 callerSeed) external {
        Game memory pre = _game();
        uint256 balanceBefore = imd.balanceOf(SPEC_TEAM);

        vm.prank(_actor(callerSeed));
        try hook.claimTeamFees() {
            _check(pre.team > 0, "claimTeamFees succeeded with nothing owed");
            _check(imd.balanceOf(SPEC_TEAM) - balanceBefore == pre.team, "team wallet did not receive its share");
            ghostTeamPaid += pre.team;
            Game memory exp = _copy(pre);
            exp.team = 0;
            _check(_sameGame(exp, _game()), "claimTeamFees touched the bank or the game");
            teamClaims++;
        } catch (bytes memory err) {
            _check(pre.team == 0, "claimTeamFees reverted although fees were owed");
            _check(bytes4(err) == WinGameHook.NothingToClaim.selector, "claimTeamFees: unexpected error");
        }
    }

    // ================================================================== actions: environment

    function warp(uint256 secs, uint256 mode) external {
        secs = mode % 4 == 0 ? bound(secs, 1, 2 hours) : bound(secs, 1, 12 minutes);
        vm.warp(block.timestamp + secs);
    }

    /// @notice Somebody sends raw IMD straight to the hook. It must not become prize money.
    function donateRaw(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1, 500 ether);
        if (imd.balanceOf(actor) < amount) return;
        Game memory pre = _game();
        vm.prank(actor);
        imd.transfer(address(hook), amount);
        ghostRawDonated += amount;
        donations++;
        _check(_sameGame(pre, _game()), "a raw IMD transfer changed the bank or the game");
    }

    /// @notice Somebody mints IMD claims on the PoolManager to the hook. Same expectation.
    function donateClaims(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1, 500 ether);
        if (imd.balanceOf(actor) < amount) return;
        Game memory pre = _game();
        vm.prank(actor);
        try donor.donate(Currency.wrap(address(imd)), address(hook), amount) {
            ghostClaimsDonated += amount;
            donations++;
        } catch {
            _violation("claim donation reverted");
        }
        _check(_sameGame(pre, _game()), "donated claims changed the bank or the game");
    }

    /// @notice Third-party liquidity in and out of the pool. The hook has no liquidity callbacks,
    /// so this must never move its money or the game.
    function modifyLiquidity(uint256 actorSeed, uint256 liquidity, bool remove) external {
        address actor = _actor(actorSeed);
        Game memory pre = _game();
        uint256 claimsBefore = _claims();
        int24 lower = TickMath.minUsableTick(key.tickSpacing);
        int24 upper = TickMath.maxUsableTick(key.tickSpacing);
        int256 change;
        if (remove) {
            uint256 held = ghostLiquidity[actor];
            if (held == 0) return;
            change = -int256(bound(liquidity, 1, held));
        } else {
            change = int256(bound(liquidity, 1e12, 1e21));
        }

        vm.prank(actor, actor);
        try lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams(lower, upper, change, bytes32(uint256(uint160(actor)))), ""
        ) {
            if (remove) ghostLiquidity[actor] -= uint256(-change);
            else ghostLiquidity[actor] += uint256(change);
            liquidityChanges++;
        } catch {
            // The actor may simply not hold the tokens the position needs.
        }
        _check(_sameGame(pre, _game()), "a liquidity change moved the bank or the game");
        _check(_claims() == claimsBefore, "a liquidity change moved the hook's claims");
    }

    /// @notice Calls every privileged entry point from an ordinary account, in whatever state the
    /// campaign has reached. All of them must refuse and leave the state alone.
    function pokeCallbacks(uint256 actorSeed, int256 amount) external {
        address actor = _actor(actorSeed);
        Game memory pre = _game();
        uint256 claimsBefore = _claims();
        SwapParams memory params = SwapParams(!winIsCurrency0, amount == 0 ? int256(-1) : amount, 0);

        vm.startPrank(actor);
        try hook.unlockCallback("") {
            _violation("unlockCallback accepted a caller that is not the PoolManager");
        } catch {}
        try hook.beforeSwap(actor, key, params, abi.encode(actor)) {
            _violation("beforeSwap accepted a caller that is not the PoolManager");
        } catch {}
        try hook.afterSwap(actor, key, params, BalanceDelta.wrap(amount), abi.encode(actor)) {
            _violation("afterSwap accepted a caller that is not the PoolManager");
        } catch {}
        try hook.beforeInitialize(actor, key, 1 << 96) {
            _violation("beforeInitialize accepted a caller that is not the PoolManager");
        } catch {}
        // The manager itself cannot be talked into paying out: an unlock by anyone else calls back
        // into the caller, not the hook.
        try manager.unlock("") {
            _violation("an EOA unlocked the manager");
        } catch {}
        vm.stopPrank();

        _check(_sameGame(pre, _game()), "a refused callback changed state");
        _check(_claims() == claimsBefore, "a refused callback moved claims");
    }

    // ================================================================== reference model

    /// @notice The brief's fee curve: 50% at launch, linear to 3% over 30 minutes.
    function specFeePips(uint256 timestamp) public view returns (uint256) {
        if (timestamp <= launchTime) return SPEC_LAUNCH_FEE;
        uint256 elapsed = timestamp - launchTime;
        if (elapsed >= SPEC_DECAY) return SPEC_BASE_FEE;
        return SPEC_LAUNCH_FEE - (SPEC_LAUNCH_FEE - SPEC_BASE_FEE) * elapsed / SPEC_DECAY;
    }

    /// @notice The minimum a buy executed right now is judged against (an expired round is closed first).
    function specMinimumNow() external view returns (uint256) {
        return _specMinimum(_specClose(_game()));
    }

    function _specPrizeBps(uint64 round) internal pure returns (uint256) {
        return round == 1 ? 2_000 : 500;
    }

    /// @dev Larger of 8.5 IMD and 20% of the upcoming prize, times 1.05^(qualifying buys this round).
    function _specMinimum(Game memory g) internal pure returns (uint256) {
        uint64 round = g.active ? g.started : g.started + 1;
        uint256 prize = g.bank * _specPrizeBps(round) / 10_000;
        uint256 base = prize * 2_000 / 10_000;
        if (base < SPEC_FLOOR) base = SPEC_FLOOR;
        return base * g.escalator / SPEC_WAD;
    }

    /// @dev What closing the round does: the prize leaves the bank for the leader, the rest stays,
    /// and the per-round state resets. Returns `g` unchanged when the round is not over.
    function _specClose(Game memory g) internal view returns (Game memory out) {
        out = _copy(g);
        if (!g.active || block.timestamp < g.deadline) return out;
        uint256 prize = g.bank * _specPrizeBps(g.started) / 10_000;
        out.bank -= prize;
        out.unclaimed += prize;
        out.winners += 1;
        out.active = false;
        out.leader = address(0);
        out.deadline = 0;
        out.qualifying = 0;
        out.escalator = SPEC_WAD;
    }

    function _afterBuy(Game memory pre, uint256 gross, uint256 fee, address trader, uint256 boundaryKind, bool mustLead)
        internal
    {
        buys++;
        Game memory exp = _specClose(pre);
        if (exp.winners != pre.winners) {
            // A buy at or after the deadline closes the dead round for its real leader first.
            uint256 prize = pre.bank * _specPrizeBps(pre.started) / 10_000;
            _recordWinner(pre.started, pre.leader, prize);
            ghostPrizeOwed[pre.leader] += prize;
            lazyCloses++;
        }

        uint256 minimum = _specMinimum(exp);
        _accrue(exp, fee);

        if (gross >= minimum) {
            if (!exp.active) {
                exp.started += 1;
                exp.active = true;
                exp.qualifying = 0;
                exp.escalator = SPEC_WAD;
                roundsOpened++;
            }
            uint256 newDeadline = block.timestamp + SPEC_TIMER;
            if (exp.started == 1 && newDeadline < launchTime + SPEC_FIRST_ROUND_FLOOR) {
                newDeadline = launchTime + SPEC_FIRST_ROUND_FLOOR;
            }
            exp.leader = trader;
            exp.deadline = uint64(newDeadline);
            exp.qualifying += 1;
            uint256 next = exp.escalator * 105 / 100;
            exp.escalator = next > SPEC_ESCALATOR_CAP ? SPEC_ESCALATOR_CAP : next;
            qualifyingBuys++;
            if (boundaryKind == 1) boundaryQualified++;
            if (mustLead) mustLeadLeads++;
            _check(boundaryKind != 2, "a buy one wei under the minimum qualified");
        } else {
            nonQualifyingBuys++;
            if (boundaryKind == 2) boundaryRejected++;
            _check(boundaryKind != 1 && boundaryKind != 3, "a buy at or above the minimum did not qualify");
            _check(!mustLead, "a must-lead buy was charged and left in the pool without the lead");
        }

        _check(_sameGame(exp, _game()), "buy: state differs from the brief");
    }

    function _afterSell(Game memory pre, uint256 fee) internal {
        sells++;
        Game memory exp = _copy(pre);
        _accrue(exp, fee);
        // Leader, deadline, round, minimum escalation and winners must be exactly as before.
        _check(_sameGame(exp, _game()), "sell: changed the game or split the fee wrongly");
    }

    function _accrue(Game memory g, uint256 fee) internal {
        uint256 feePips = specFeePips(block.timestamp);
        _check(feePips <= ghostLastFeePips, "fee rate went up over time");
        ghostLastFeePips = feePips;
        if (fee == 0) return;
        uint256 team = fee / 10;
        g.team += team;
        g.bank += fee - team;
        ghostFees += fee;
        ghostTeamIn += team;
        ghostBankIn += fee - team;
        ghostFeeBearingSwaps++;
    }

    function _recordWinner(uint64 round, address winner, uint256 prize) internal {
        uint256 index = _ledger.length;
        _ledger.push(LedgerEntry(round, uint64(block.timestamp), winner, prize));
        ghostPrizesAwarded += prize;
        if (hook.winnersCount() != index + 1) {
            _violation("past winners did not grow by exactly one");
            return;
        }
        WinGameHook.Winner memory w = hook.winnerAt(index);
        _check(
            w.round == round && w.winner == winner && w.prize == prize && w.settledAt == block.timestamp,
            "past winners entry differs from the round that just closed"
        );
    }

    // ================================================================== helpers

    function ledgerLength() external view returns (uint256) {
        return _ledger.length;
    }

    function ledgerAt(uint256 index) external view returns (LedgerEntry memory) {
        return _ledger[index];
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _buyExactIn(address actor, uint256 gross, uint256 idMode, uint256 boundaryKind) internal {
        if (gross == 0 || imd.balanceOf(actor) < gross) return;
        Identity memory id = _identity(actor, idMode);
        Before memory b = _before(actor);
        uint256 minimum = _specMinimum(_specClose(b.game));

        (bool ok, bytes memory err) = _swap(actor, id.origin, !winIsCurrency0, -int256(gross), id.hookData);
        if (ok) {
            uint256 fee = _claims() - b.claims;
            _check(
                fee == gross * specFeePips(block.timestamp) / SPEC_PIPS,
                "exact-in buy: fee is not the rate of the gross"
            );
            _check(
                b.imdBalance - imd.balanceOf(actor) == gross, "exact-in buy: buyer paid something other than the amount"
            );
            if (id.mustLead) _check(gross >= minimum, "a must-lead buy landed below the minimum");
            _afterBuy(b.game, gross, fee, id.trader, boundaryKind, id.mustLead);
        } else if (id.mustLead && gross < minimum) {
            _checkMustLeadRefused(b, actor, err, minimum, gross);
        } else {
            _violation("exact-in buy reverted");
        }
    }

    /// @dev The brief's "must lead" promise: the whole swap is undone with `NotQualifying`, so no
    /// fee is taken, no expired round is closed on the side, and the buyer keeps every wei.
    function _checkMustLeadRefused(Before memory b, address actor, bytes memory err, uint256 minimum, uint256 gross)
        internal
    {
        bytes memory expected =
            _afterSwapRevert(abi.encodeWithSelector(WinGameHook.NotQualifying.selector, minimum, gross));
        _check(_sameBytes(err, expected), "must-lead buy below the minimum: unexpected error");
        _checkUntouched(b, actor, "refused must-lead buy");
        mustLeadRefusals++;
    }

    /// @dev A reverted swap must have left nothing behind: game, claims and the actor's balances.
    function _checkUntouched(Before memory b, address actor, string memory what) internal {
        _check(_sameGame(b.game, _game()), string.concat(what, " changed state"));
        _check(_claims() == b.claims, string.concat(what, " moved claims"));
        _check(imd.balanceOf(actor) == b.imdBalance, string.concat(what, " took IMD"));
        _check(win.balanceOf(actor) == b.winBalance, string.concat(what, " moved WIN"));
    }

    struct Before {
        Game game;
        uint256 claims;
        uint256 imdBalance;
        uint256 winBalance;
    }

    /// @dev How a buy names its buyer: the hookData sent, the tx.origin to sign with, who the brief
    /// says the buyer is, and whether the buyer insisted on taking the lead.
    struct Identity {
        bytes hookData;
        address origin;
        address trader;
        bool mustLead;
    }

    function _before(address actor) internal view returns (Before memory b) {
        b.game = _game();
        b.claims = _claims();
        b.imdBalance = imd.balanceOf(actor);
        b.winBalance = win.balanceOf(actor);
    }

    /// @dev One swap through the router as `actor`, signed by `origin`. Never reverts; a failure
    /// comes back as the revert data.
    function _swap(address actor, address origin, bool zeroForOne, int256 amountSpecified, bytes memory hookData)
        internal
        returns (bool ok, bytes memory err)
    {
        SwapParams memory params = SwapParams(zeroForOne, amountSpecified, _limit(zeroForOne));
        vm.prank(actor, origin);
        try router.swap(key, params, PoolSwapTest.TestSettings(false, false), hookData) {
            ok = true;
        } catch (bytes memory reason) {
            err = reason;
        }
    }

    /// @dev The manager wraps a hook revert: WrappedError(hook, afterSwap, inner, HookCallFailed).
    function _afterSwapRevert(bytes memory inner) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.afterSwap.selector,
            inner,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _contains(bytes memory data, bytes4 selector) internal pure returns (bool) {
        for (uint256 i = 0; i + 4 <= data.length; i++) {
            if (
                data[i] == selector[0] && data[i + 1] == selector[1] && data[i + 2] == selector[2]
                    && data[i + 3] == selector[3]
            ) return true;
        }
        return false;
    }

    function _sameBytes(bytes memory a, bytes memory b) internal pure returns (bool) {
        return keccak256(a) == keccak256(b);
    }

    /// @dev Ways a router can (fail to) name the buyer. The test router has no `msgSender()`, so an
    /// empty or unusable payload falls through to the signer.
    function _identity(address actor, uint256 mode) internal view returns (Identity memory) {
        address other = actors[(uint256(uint160(actor)) % actors.length + mode % actors.length) % actors.length];
        mode = mode % 10;
        if (mode == 0) return Identity(abi.encode(actor), actor, actor, false);
        if (mode == 1) return Identity("", actor, actor, false); // nothing passed: the signer
        if (mode == 2) return Identity(abi.encodePacked(other), actor, other, false); // packed 20 bytes
        if (mode == 3) return Identity(abi.encode(other), actor, other, false); // buying on someone's behalf
        if (mode == 4) {
            return Identity(hex"00112233445566778899aabbccddeeff00112233445566778899aabbccddee", actor, actor, false);
        }
        if (mode == 5) return Identity(abi.encodePacked(uint96(1), actor), actor, actor, false); // dirty high bits
        if (mode == 6) return Identity(abi.encode(address(0)), actor, actor, false);
        if (mode == 7) return Identity("", other, other, false); // relayed: the signer is not the payer
        if (mode == 8) return Identity(abi.encode(actor, true), actor, actor, true); // the website's "must lead" form
        return Identity(abi.encode(other, false), actor, other, false); // 64-byte form without the flag
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Prefers an actor that actually holds WIN so sells are not wasted calls.
    function _actorWithWin(uint256 seed) internal view returns (address) {
        for (uint256 i = 0; i < actors.length; i++) {
            address candidate = actors[(seed % actors.length + i) % actors.length];
            if (win.balanceOf(candidate) > 0) return candidate;
        }
        return actors[seed % actors.length];
    }

    function _limit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _claims() internal view returns (uint256) {
        return manager.balanceOf(address(hook), imdId);
    }

    function _game() internal view returns (Game memory g) {
        g.bank = hook.bank();
        g.team = hook.teamOwed();
        g.unclaimed = hook.totalUnclaimedPrizes();
        g.started = hook.roundsStarted();
        g.active = hook.roundActive();
        g.leader = hook.leader();
        g.deadline = hook.deadline();
        g.qualifying = hook.qualifyingBuysInRound();
        g.escalator = hook.escalator();
        g.winners = hook.winnersCount();
    }

    function _copy(Game memory g) internal pure returns (Game memory out) {
        out = Game(
            g.bank, g.team, g.unclaimed, g.started, g.active, g.leader, g.deadline, g.qualifying, g.escalator, g.winners
        );
    }

    function _sameGame(Game memory a, Game memory b) internal pure returns (bool) {
        return keccak256(abi.encode(a)) == keccak256(abi.encode(b));
    }

    function _check(bool ok, string memory what) internal {
        if (!ok) _violation(what);
    }

    function _violation(string memory what) internal {
        if (violations == 0) firstViolation = what;
        violations++;
    }
}
