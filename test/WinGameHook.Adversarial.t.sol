// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {WinGameFixture} from "./utils/WinGameFixture.sol";
import {WinGameHook} from "../src/WinGameHook.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ReentrantERC20} from "./mocks/ReentrantERC20.sol";

/// @notice Inputs the happy path does not visit: races inside one block, callers who are not who the
/// code hopes, claims that should fail, an exhausted pool, a long history, and money pushed at the
/// hook from outside.
contract WinGameHookAdversarialTest is WinGameFixture {
    uint256 internal constant FLOOR = 8.5 ether;

    function _finishRoundOne() internal {
        warpPastDecay();
        buyExactIn(alice, hook.minimumBuy());
        warpPastFirstRoundFloor();
        hook.settle();
    }

    // ------------------------------------------------------------------ same-block races (sequencer ordering)

    /// @dev Two bots send the same minimum in one block. Whoever the sequencer puts first leads; the
    /// second pays its fee, gets its WIN, and does not lead, because the minimum rose 5% under it.
    function test_race_twoBuysAtTheSameMinimumInOneBlock_onlyTheFirstLeads() public {
        _finishRoundOne();
        uint256 minimum = hook.minimumBuy();
        uint256 bankBefore = hook.bank();

        buyExactIn(alice, minimum);
        uint64 deadline = hook.deadline();
        BalanceDelta late = buyExactIn(bob, minimum);

        assertEq(hook.leader(), alice, "the second buy at the old minimum must not lead");
        assertEq(hook.deadline(), deadline, "and must not touch the timer");
        assertEq(hook.qualifyingBuysInRound(), 1);
        assertGt(winDeltaOf(late), 0, "it is still an ordinary buy");
        assertEq(hook.bank() - bankBefore, 2 * (minimum * 3 / 100 - (minimum * 3 / 100) / 10), "both paid the fee");
        assertAccounting();
    }

    /// @dev Several qualifying buys with one timestamp: the last one in block order leads, each one
    /// raised the price of the next by 5%, and the deadline is the same for all of them.
    function test_race_lastQualifyingBuyInTheBlockLeads_andEachOneEscalates() public {
        _finishRoundOne();
        address[4] memory order = [alice, bob, carol, sniper];
        uint256 previous;
        for (uint256 i = 0; i < order.length; i++) {
            uint256 minimum = hook.minimumBuy();
            assertGt(minimum, previous, "minimum must rise with every qualifying buy");
            previous = minimum;
            buyExactIn(order[i], minimum);
            assertEq(hook.leader(), order[i]);
            assertEq(hook.deadline(), block.timestamp + 10 minutes);
        }
        assertEq(hook.qualifyingBuysInRound(), 4);
        assertEq(hook.roundsStarted(), 2, "all in one round");
    }

    /// @notice Whenever in the round a qualifying buy lands, last second included, everyone else
    /// gets the full ten minutes and the round cannot be settled before they are up.
    function testFuzz_snipe_anyQualifyingBuyGivesTheFieldTenFullMinutes(uint256 offset, uint256 extra) public {
        _finishRoundOne();
        buyExactIn(alice, hook.minimumBuy());
        offset = bound(offset, 0, 10 minutes - 1);
        vm.warp(block.timestamp + offset);

        buyExactIn(sniper, hook.minimumBuy() + bound(extra, 0, 100 ether));
        assertEq(hook.leader(), sniper);
        assertEq(hook.timeLeft(), 10 minutes);

        vm.warp(block.timestamp + 10 minutes - 1);
        vm.expectRevert(abi.encodeWithSelector(WinGameHook.RoundNotOver.selector, hook.deadline()));
        hook.settle();

        // The previous leader answers in the very last second and is the one who gets paid.
        buyExactIn(alice, hook.minimumBuy());
        vm.warp(hook.deadline());
        uint256 before = imd.balanceOf(alice);
        hook.settle();
        assertEq(hook.winnerAt(1).winner, alice);
        assertGt(imd.balanceOf(alice), before);
        assertEq(hook.unclaimedPrize(sniper), 0, "the sniper is owed nothing");
    }

    /// @dev The boundary itself, at an arbitrary bank size and escalation level.
    function testFuzz_minimum_exactAmountQualifies_oneWeiLessDoesNot(uint256 bankFeed, uint8 priorBuys) public {
        _finishRoundOne();
        // Grow the bank so the prize-linked minimum (1% of the bank) can exceed the 8.5 IMD floor.
        buyExactIn(carol, bound(bankFeed, 1 ether, 200_000 ether));
        vm.warp(block.timestamp + 11 minutes);
        if (hook.roundActive()) hook.settle();
        for (uint256 i = 0; i < priorBuys % 6; i++) {
            buyExactIn(carol, hook.minimumBuy());
        }
        address leaderBefore = hook.leader();
        uint32 qualifying = hook.qualifyingBuysInRound();

        buyExactIn(bob, hook.minimumBuy() - 1);
        assertEq(hook.leader(), leaderBefore, "one wei under the minimum took the lead");
        assertEq(hook.qualifyingBuysInRound(), qualifying);

        // The failed attempt fed the bank; the minimum is re-read, as a real buyer would.
        buyExactIn(bob, hook.minimumBuy());
        assertEq(hook.leader(), bob, "exactly the minimum must qualify");
        assertEq(hook.qualifyingBuysInRound(), qualifying + 1);
    }

    // ------------------------------------------------------------------ identity abuse

    /// @dev A third party cannot move an existing leader's claim to themselves: the only lever is
    /// to out-buy the leader. Naming the leader in a non-qualifying buy changes nothing.
    function test_identity_namingSomeoneCannotTakeOrMoveTheLead() public {
        _finishRoundOne();
        buyExactIn(alice, hook.minimumBuy());
        uint64 deadline = hook.deadline();

        buyExactIn(sniper, hook.minimumBuy() - 1, abi.encode(sniper));
        buyExactIn(sniper, 1 ether, abi.encode(alice));
        assertEq(hook.leader(), alice);
        assertEq(hook.deadline(), deadline, "a sub-minimum buy naming the leader must not extend the timer");

        // Paying the minimum on someone's behalf gifts them the lead; the payer gets nothing.
        buyExactIn(sniper, hook.minimumBuy(), abi.encode(carol));
        assertEq(hook.leader(), carol);
        vm.warp(hook.deadline());
        uint256 sniperBefore = imd.balanceOf(sniper);
        vm.prank(sniper);
        hook.settle();
        assertEq(imd.balanceOf(sniper), sniperBefore, "the caller of settle() earns nothing");
        assertEq(hook.winnerAt(1).winner, carol);
        assertEq(hook.unclaimedPrize(sniper), 0);
    }

    /// @dev A contract buyer (multisig, smart account) named through hookData is paid like anyone else.
    function test_identity_contractBuyerNamedInHookDataIsPaid() public {
        address safe = address(new MockERC20("wallet", "W", 0));
        _finishRoundOne();
        buyExactIn(alice, hook.minimumBuy(), abi.encode(safe));
        assertEq(hook.leader(), safe);
        uint256 prize = hook.nextPrize();
        vm.warp(hook.deadline());
        hook.settle();
        assertEq(imd.balanceOf(safe), prize);
    }

    // ------------------------------------------------------------------ claims that must fail

    function test_claimPrize_revertsForSomeoneWhoNeverWon() public {
        _finishRoundOne();
        vm.expectRevert(WinGameHook.NothingToClaim.selector);
        hook.claimPrize(bob);
        vm.expectRevert(WinGameHook.NothingToClaim.selector);
        hook.claimPrize(address(0));
        // The round-1 winner was paid by settle(); nothing is left to pull a second time.
        vm.expectRevert(WinGameHook.NothingToClaim.selector);
        hook.claimPrize(alice);
    }

    function test_claimPrize_theCurrentLeaderCannotPullBeforeTheRoundCloses() public {
        _finishRoundOne();
        buyExactIn(bob, hook.minimumBuy());
        vm.warp(hook.deadline()); // expired, but neither settled nor lazily closed yet
        vm.expectRevert(WinGameHook.NothingToClaim.selector);
        hook.claimPrize(bob);
        assertTrue(hook.roundActive());
    }

    function test_claimTeamFees_revertsWhenEmptyAndOnTheSecondCall() public {
        vm.expectRevert(WinGameHook.NothingToClaim.selector);
        hook.claimTeamFees();
        warpPastDecay();
        buyExactIn(alice, 100 ether);
        hook.claimTeamFees();
        vm.expectRevert(WinGameHook.NothingToClaim.selector);
        hook.claimTeamFees();
        assertEq(hook.teamOwed(), 0);
        assertAccounting();
    }

    /// @dev The team's pull never dips into the bank or into prizes awaiting pickup.
    function test_claimTeamFees_leavesBankAndUnclaimedPrizesAlone() public {
        _finishRoundOne();
        buyExactIn(bob, hook.minimumBuy());
        vm.warp(hook.deadline());
        buyExactIn(carol, 1 ether); // closes round 2 lazily: bob's prize now waits in the hook
        uint256 bank = hook.bank();
        uint256 waiting = hook.totalUnclaimedPrizes();
        uint256 owed = hook.teamOwed();
        assertGt(waiting, 0);

        vm.prank(sniper);
        hook.claimTeamFees();

        assertEq(imd.balanceOf(hook.TEAM_WALLET()), owed);
        assertEq(hook.bank(), bank);
        assertEq(hook.totalUnclaimedPrizes(), waiting);
        assertEq(hookImdClaims(), bank + waiting);
    }

    /// @dev Prizes from several lazily closed rounds add up for the same winner and one pull pays all.
    function test_claimPrize_accumulatesAcrossLazilyClosedRounds() public {
        _finishRoundOne();
        uint256 expected;
        for (uint256 i = 0; i < 3; i++) {
            buyExactIn(bob, hook.minimumBuy()); // closes the previous round (if any), opens the next
            if (i > 0) expected += hook.winnerAt(i).prize;
            vm.warp(hook.deadline() + 5);
        }
        assertEq(hook.winnersCount(), 3);
        assertEq(hook.unclaimedPrize(bob), expected);

        // settle() for the round still open pays its prize and everything bob was already owed. The
        // expired round's prize is `pendingPrize()`; `nextPrize()` already describes the round after it.
        uint256 lastPrize = hook.pendingPrize();
        assertEq(lastPrize, hook.bank() * 5 / 100);
        assertEq(hook.nextPrize(), (hook.bank() - lastPrize) * 5 / 100, "nextPrize must exclude the pending prize");
        uint256 before = imd.balanceOf(bob);
        hook.settle();
        assertEq(imd.balanceOf(bob) - before, expected + lastPrize);
        assertEq(hook.pendingPrize(), 0);
        assertEq(hook.totalUnclaimedPrizes(), 0);
        assertAccounting();
    }

    // ------------------------------------------------------------------ settle boundaries

    function test_settle_oneSecondEarlyRevertsWithTheDeadline_thenSucceedsOnTheDeadline() public {
        _finishRoundOne();
        buyExactIn(bob, hook.minimumBuy());
        uint64 deadline = hook.deadline();

        vm.warp(deadline - 1);
        assertEq(hook.timeLeft(), 1);
        assertFalse(hook.settleable());
        vm.expectRevert(abi.encodeWithSelector(WinGameHook.RoundNotOver.selector, deadline));
        hook.settle();

        vm.warp(deadline);
        assertEq(hook.timeLeft(), 0);
        assertTrue(hook.settleable());
        uint256 bank = hook.bank();
        hook.settle();
        assertEq(hook.bank(), bank - bank * 5 / 100, "95% of the bank stays for the next round");
        assertEq(hook.winnerAt(1).settledAt, deadline);
    }

    /// @dev Round 1 with a leader from the first second: no path closes it before launch + 3h, not
    /// settle() and not a buy (which would close an expired round lazily).
    function testFuzz_firstRound_nothingClosesItBeforeThreeHours(uint256 when, uint256 size) public {
        buyExactIn(alice, FLOOR); // at launch, 50% fee
        when = bound(when, 1, 3 hours - 1);
        vm.warp(launchTime + when);

        vm.expectRevert(abi.encodeWithSelector(WinGameHook.RoundNotOver.selector, hook.deadline()));
        hook.settle();
        buyExactIn(bob, bound(size, 1, 500 ether));

        assertEq(hook.winnersCount(), 0, "round 1 closed early");
        assertEq(hook.roundsStarted(), 1);
        assertTrue(hook.roundActive());
        assertGe(hook.deadline(), launchTime + 3 hours);
        assertEq(hook.nextPrize(), hook.bank() * 20 / 100, "round 1 pays 20% of the bank");
    }

    // ------------------------------------------------------------------ nobody seeds the bank

    function test_donatedImdNeverBecomesPrizeMoney() public {
        _finishRoundOne();
        uint256 bank = hook.bank();
        uint256 minimum = hook.minimumBuy();
        vm.prank(carol);
        imd.transfer(address(hook), 1_000_000 ether);

        assertEq(hook.bank(), bank, "a transfer seeded the bank");
        assertEq(hook.bankBalance(), bank);
        assertEq(hook.nextPrize(), bank * 5 / 100);
        assertEq(hook.minimumBuy(), minimum, "a donation must not move the minimum buy");

        // And it cannot be extracted through a prize either.
        buyExactIn(bob, minimum);
        uint256 prize = hook.nextPrize();
        vm.warp(hook.deadline());
        hook.settle();
        assertEq(hook.winnerAt(1).prize, prize);
        assertEq(imd.balanceOf(address(hook)), 1_000_000 ether, "stray IMD stays put");
    }

    // ------------------------------------------------------------------ pool edge states

    /// @dev Selling more WIN than the pool can pay for is a partial fill: the seller receives what
    /// the pool had, the fee is 3% of exactly that, and the unsold WIN stays with the seller.
    function test_sell_largerThanThePoolsImd_feeOnlyOnWhatWasPaidOut() public {
        warpPastDecay();
        buyExactIn(bob, 100 ether);
        giveWin(alice, 90_000_000 ether);
        uint256 poolImd = imd.balanceOf(address(manager)) - hookImdClaims();
        uint256 claims = hookImdClaims();
        uint256 imdBefore = imd.balanceOf(alice);
        uint256 winBefore = win.balanceOf(alice);
        address leader = hook.leader();

        sellExactIn(alice, 90_000_000 ether);

        uint256 fee = hookImdClaims() - claims;
        uint256 received = imd.balanceOf(alice) - imdBefore;
        assertLe(received + fee, poolImd, "paid out more IMD than the pool held");
        assertEq(fee, (received + fee) * 3 / 100, "fee is 3% of the IMD the pool paid");
        assertLt(winBefore - win.balanceOf(alice), 90_000_000 ether, "partial fill: not all WIN was taken");
        assertEq(hook.leader(), leader);
        assertAccounting();

        // The pool is now out of IMD. Trading resumes with the next buy; nothing is stuck.
        buyExactIn(bob, 50 ether);
        assertAccounting();
    }

    /// @dev Splitting an order cannot shave the fee: ten small buys pay within ten wei of one big one.
    function test_fee_splittingAnOrderSavesAtMostOneWeiPerSwap() public {
        warpPastDecay();
        uint256 total = 10 ether + 7;
        uint256 snapshot = vm.snapshotState();
        buyExactIn(alice, total);
        uint256 single = hookImdClaims();
        vm.revertToState(snapshot);

        for (uint256 i = 0; i < 10; i++) {
            buyExactIn(alice, i == 0 ? 1 ether + 7 : 1 ether);
        }
        assertLe(single - hookImdClaims(), 10, "splitting avoided more than rounding dust");
    }

    /// @dev Dust: a one-wei buy must not revert and must not corrupt the accounting.
    function test_dustTradesDoNotRevertOrBreakAccounting() public {
        warpPastDecay();
        buyExactIn(alice, 1);
        buyExactIn(alice, 33);
        assertEq(hook.bank(), 0, "below 34 wei the 3% fee rounds to zero");
        buyExactIn(alice, 34);
        assertEq(hookImdClaims(), 1);
        assertFalse(hook.roundActive());
        assertAccounting();
    }

    /// @notice Buying and immediately selling everything back always loses at least both fees: there
    /// is no free round trip to mine the leader slot with.
    function testFuzz_roundTrip_costsAtLeastBothFees(uint256 amount) public {
        warpPastDecay();
        buyExactIn(carol, 50 ether); // some depth so the sell has IMD to draw on
        amount = bound(amount, 0.01 ether, 5_000 ether);
        uint256 before = imd.balanceOf(alice);

        BalanceDelta bought = buyExactIn(alice, amount);
        sellExactIn(alice, uint256(winDeltaOf(bought)));

        uint256 lost = before - imd.balanceOf(alice);
        uint256 afterBuyFee = amount - amount * 3 / 100;
        assertGe(lost, amount - afterBuyFee * 97 / 100, "round trip cheaper than two 3% fees");
        assertAccounting();
    }

    // ------------------------------------------------------------------ history does not slow swaps

    /// @dev `pastWinners` grows forever. A buy that closes a round must cost the same with forty
    /// winners on record as with two, or the game could be priced out of a block over time.
    function test_gas_closingARoundDoesNotGetDearerWithHistory() public {
        _finishRoundOne();
        uint256 early;
        uint256 late;
        for (uint256 i = 0; i < 40; i++) {
            uint256 minimum = hook.minimumBuy();
            uint256 gasBefore = gasleft();
            buyExactIn(i % 2 == 0 ? alice : bob, minimum);
            uint256 used = gasBefore - gasleft();
            if (i == 2) early = used;
            if (i == 39) late = used;
            vm.warp(hook.deadline());
        }
        assertEq(hook.winnersCount(), 40);
        assertLt(late, early + 15_000, "closing a round got more expensive as winners accumulated");
    }

    // ------------------------------------------------------------------ callbacks for the wrong pool

    function test_callbacks_refuseAPoolThatIsNotTheirs() public {
        PoolKey memory other = key;
        other.fee = 500;
        SwapParams memory params = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);

        vm.startPrank(address(manager));
        vm.expectRevert(WinGameHook.WrongPool.selector);
        hook.beforeSwap(alice, other, params, "");
        vm.expectRevert(WinGameHook.WrongPool.selector);
        hook.afterSwap(alice, other, params, BalanceDelta.wrap(0), "");
        vm.stopPrank();
        assertEq(hook.bank(), 0);
    }

    function test_callbacks_refuseSwapsBeforeThePoolExists() public {
        WinGameHook fresh = _freshHook();
        SwapParams memory params = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);

        vm.startPrank(address(manager));
        vm.expectRevert(WinGameHook.PoolNotInitialized.selector);
        fresh.beforeSwap(alice, key, params, "");
        vm.expectRevert(WinGameHook.PoolNotInitialized.selector);
        fresh.afterSwap(alice, key, params, BalanceDelta.wrap(0), "");
        vm.stopPrank();

        // And the game entry points are inert on a hook that never launched.
        vm.expectRevert(WinGameHook.NoActiveRound.selector);
        fresh.settle();
        vm.expectRevert(WinGameHook.NothingToClaim.selector);
        fresh.claimTeamFees();
        assertEq(fresh.minimumBuy(), FLOOR);
        assertEq(fresh.bank(), 0);
    }

    /// @dev A second hook instance for the same token: mined with a different salt range because
    /// the first one already occupies the first matching address.
    function _freshHook() internal returns (WinGameHook fresh) {
        bytes memory initCode = abi.encodePacked(type(WinGameHook).creationCode, abi.encode(manager, address(win)));
        bytes32 initHash = keccak256(initCode);
        for (uint256 i = 0; i < 600_000; i++) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), initHash))))
            );
            if (uint160(predicted) & ((1 << 14) - 1) != HOOK_FLAGS || predicted == address(hook)) continue;
            return new WinGameHook{salt: bytes32(i)}(IPoolManager(address(manager)), address(win));
        }
        revert("no second salt");
    }
}

/// @notice The same adversarial suite with WIN as currency1.
contract WinGameHookAdversarialFlippedTest is WinGameHookAdversarialTest {
    function wantWinIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}

/// @notice A prize winner that, from the token's transfer callback, trades on the pool while the
/// hook's own payout unlock is still open. The manager is unlocked at that moment, so the swap
/// goes through and the hook's `afterSwap` runs in the middle of `settle()`.
contract SwappingWinner {
    IPoolManager internal immutable manager;
    PoolKey internal key;
    MockERC20 internal immutable imd;
    bool internal immutable imdIsCurrency0;
    uint256 public buyAmount;
    bool public swapped;
    bytes public failure;

    constructor(IPoolManager manager_, PoolKey memory key_, MockERC20 imd_) {
        manager = manager_;
        key = key_;
        imd = imd_;
        imdIsCurrency0 = Currency.unwrap(key_.currency0) == address(imd_);
    }

    function arm(uint256 amount) external {
        buyAmount = amount;
    }

    function onTokenReceived(address, uint256) external {
        if (buyAmount == 0 || swapped || msg.sender != address(imd)) return;
        swapped = true;
        try this.buyInsideTheOpenUnlock() {}
        catch (bytes memory err) {
            failure = err;
            swapped = false;
        }
    }

    function buyInsideTheOpenUnlock() external {
        require(msg.sender == address(this));
        bool zeroForOne = imdIsCurrency0;
        BalanceDelta delta = manager.swap(
            key,
            SwapParams(
                zeroForOne, -int256(buyAmount), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            abi.encode(address(this))
        );
        (int128 imdDelta, int128 winDelta, Currency winCurrency) = imdIsCurrency0
            ? (delta.amount0(), delta.amount1(), key.currency1)
            : (delta.amount1(), delta.amount0(), key.currency0);
        manager.sync(Currency.wrap(address(imd)));
        imd.transfer(address(manager), uint256(uint128(-imdDelta)));
        manager.settle();
        manager.take(winCurrency, address(this), uint256(uint128(winDelta)));
    }
}

/// @notice Reentrancy the guard does not cover by itself: `afterSwap` reached from inside a payout.
contract WinGameHookSwapDuringPayoutTest is WinGameFixture {
    SwappingWinner internal attacker;

    function newImd() internal override returns (MockERC20) {
        return MockERC20(address(new ReentrantERC20()));
    }

    function setUp() public override {
        super.setUp();
        attacker = new SwappingWinner(IPoolManager(address(manager)), key, imd);
        imd.mint(address(attacker), 10_000 ether);
    }

    /// @dev The winner buys a qualifying amount from inside its own prize transfer. It is paid its
    /// prize once, the nested buy is charged like any other and merely opens the next round, and
    /// every unit the hook holds is still accounted for.
    function test_swapFromInsideThePrizePayout_isJustAnotherBuy() public {
        warpPastDecay();
        buyExactIn(alice, hook.minimumBuy(), abi.encode(address(attacker)));
        warpPastFirstRoundFloor();
        uint256 bankBefore = hook.bank();
        // Round 1 has expired and waits for settle(): its prize is the pending one, 20% of the bank.
        uint256 prize = hook.pendingPrize();
        assertEq(prize, bankBefore * 20 / 100);
        attacker.arm(1_000 ether);
        uint256 balanceBefore = imd.balanceOf(address(attacker));

        hook.settle();

        assertTrue(attacker.swapped(), string(attacker.failure()));
        uint256 fee = 1_000 ether * 3 / 100;
        assertEq(imd.balanceOf(address(attacker)), balanceBefore + prize - 1_000 ether, "prize paid exactly once");
        assertEq(hook.winnersCount(), 1);
        assertEq(hook.winnerAt(0).prize, prize, "the nested buy's fee did not inflate the prize being paid");
        assertEq(hook.bank(), bankBefore - prize + fee - fee / 10);
        assertEq(hook.roundsStarted(), 2, "the nested buy opened round 2 like any qualifying buy");
        assertEq(hook.leader(), address(attacker));
        assertEq(hook.unclaimedPrize(address(attacker)), 0);
        assertEq(hook.totalUnclaimedPrizes(), 0);
        assertAccounting();

        // The guard is released and the game goes on.
        vm.warp(hook.deadline());
        hook.settle();
        assertEq(hook.winnersCount(), 2);
        assertAccounting();
    }

    /// @dev Same from the team's payout, with the callback sitting at the team wallet.
    function test_swapFromInsideTheTeamPayout_cannotTouchTheTeamShareTwice() public {
        warpPastDecay();
        buyExactIn(alice, 500 ether);
        uint256 owed = hook.teamOwed();
        address team = hook.TEAM_WALLET();
        vm.etch(team, address(attacker).code);
        // Immutables travel with the code; storage does not, so the key is absent and the nested
        // swap fails inside the callback. The payout itself must still complete exactly once.
        hook.claimTeamFees();
        assertEq(imd.balanceOf(team), owed);
        assertEq(hook.teamOwed(), 0);
        vm.expectRevert(WinGameHook.NothingToClaim.selector);
        hook.claimTeamFees();
        assertAccounting();
    }
}
