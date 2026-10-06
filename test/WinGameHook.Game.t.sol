// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {WinGameFixture} from "./utils/WinGameFixture.sol";
import {WinGameHook} from "../src/WinGameHook.sol";
import {MsgSenderRouter} from "./mocks/MsgSenderRouter.sol";

/// @notice Rounds, minimum buy, settlement, sniping defences, buyer identity and the website views.
contract WinGameHookGameTest is WinGameFixture {
    uint256 constant FLOOR = 8.5 ether;

    /// @dev What the PoolManager reports when `afterSwap` reverts with `inner`.
    function _afterSwapRevert(bytes memory inner) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.afterSwap.selector,
            inner,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _mustLead(address buyer) internal pure returns (bytes memory) {
        return abi.encode(buyer, true);
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Plays and settles round 1 so later tests start in the "normal" 10-minute regime.
    function _finishRoundOne() internal {
        warpPastDecay();
        buyExactIn(alice, hook.minimumBuy());
        warpPastFirstRoundFloor();
        hook.settle();
        assertFalse(hook.roundActive());
        assertEq(hook.roundsStarted(), 1);
    }

    function _expectedMinAfter(uint256 buys) internal view returns (uint256) {
        uint256 base = hook.nextPrize() * 2_000 / 10_000;
        if (base < FLOOR) base = FLOOR;
        uint256 esc = 1e18;
        for (uint256 i = 0; i < buys; i++) {
            esc = esc * 10_500 / 10_000;
        }
        return base * esc / 1e18;
    }

    // ------------------------------------------------------------------ before the first round

    function test_initialState() public view {
        assertEq(hook.bank(), 0, "bank starts empty");
        assertEq(hook.nextPrize(), 0);
        assertEq(hook.minimumBuy(), FLOOR);
        assertEq(hook.leader(), address(0));
        assertEq(hook.timeLeft(), 0);
        assertEq(hook.roundNumber(), 1);
        assertFalse(hook.roundActive());
        assertEq(hook.winnersCount(), 0);
        assertEq(hook.launchTime(), launchTime);
    }

    function test_settle_revertsWithoutActiveRound() public {
        vm.expectRevert(WinGameHook.NoActiveRound.selector);
        hook.settle();
    }

    function test_nonQualifyingBuyFeedsBankButStartsNoRound() public {
        warpPastDecay();
        buyExactIn(alice, FLOOR - 1);
        assertGt(hook.bank(), 0);
        assertFalse(hook.roundActive());
        assertEq(hook.leader(), address(0));
        assertEq(hook.minimumBuy(), FLOOR, "escalator untouched");
    }

    function test_sellsNeverStartARound() public {
        warpPastDecay();
        giveWin(alice, 50_000_000 ether);
        buyExactIn(bob, 5 ether); // below the floor: puts IMD in the pool without starting a round
        uint256 bankBefore = hook.bank();
        sellExactIn(alice, 100_000 ether);
        assertGt(hook.bank(), bankBefore);
        assertFalse(hook.roundActive());
        assertEq(hook.leader(), address(0));
    }

    // ------------------------------------------------------------------ round one

    function test_firstQualifyingBuyStartsRoundOne() public {
        warpPastDecay();
        vm.expectEmit(true, true, false, true, address(hook));
        emit WinGameHook.RoundStarted(1, alice, uint64(launchTime + 3 hours));
        buyExactIn(alice, FLOOR);

        assertTrue(hook.roundActive());
        assertEq(hook.roundsStarted(), 1);
        assertEq(hook.roundNumber(), 1);
        assertEq(hook.leader(), alice);
        assertEq(hook.deadline(), launchTime + 3 hours, "first round cannot end before 3h after launch");
        assertEq(hook.timeLeft(), launchTime + 3 hours - block.timestamp);
        assertEq(hook.qualifyingBuysInRound(), 1);
        assertEq(hook.minimumBuy(), 8.925 ether, "8.5 * 1.05");
    }

    function test_firstRound_qualifyingBuyAtLaunchPays50PercentFeeAndLeads() public {
        buyExactIn(alice, FLOOR); // at launch, 50% fee
        assertEq(hook.leader(), alice);
        assertEq(hook.bank(), 4.25 ether * 9 / 10);
    }

    function test_firstRound_cannotSettleBeforeThreeHours() public {
        warpPastDecay();
        buyExactIn(alice, FLOOR);

        vm.warp(launchTime + 3 hours - 1);
        assertEq(hook.timeLeft(), 1);
        vm.expectRevert(abi.encodeWithSelector(WinGameHook.RoundNotOver.selector, uint64(launchTime + 3 hours)));
        hook.settle();

        vm.warp(launchTime + 3 hours);
        assertEq(hook.timeLeft(), 0);
        assertTrue(hook.settleable());
        hook.settle();
        assertFalse(hook.roundActive());
    }

    function test_firstRound_resetsRespectTheThreeHourFloor() public {
        warpPastDecay();
        buyExactIn(alice, hook.minimumBuy());
        assertEq(hook.deadline(), launchTime + 3 hours);

        vm.warp(launchTime + 2 hours);
        buyExactIn(bob, hook.minimumBuy());
        assertEq(hook.deadline(), launchTime + 3 hours, "still the floor");
        assertEq(hook.leader(), bob);

        vm.warp(launchTime + 3 hours - 5 minutes);
        buyExactIn(carol, hook.minimumBuy());
        assertEq(hook.deadline(), launchTime + 3 hours + 5 minutes, "now + 10 minutes once past the floor");
        assertEq(hook.leader(), carol);
    }

    function test_firstRound_prizeIsTwentyPercentOfBank() public {
        warpPastDecay();
        buyExactIn(alice, hook.minimumBuy());
        buyExactIn(bob, hook.minimumBuy());
        buyExactIn(alice, hook.minimumBuy());
        uint256 bankBefore = hook.bank();
        uint256 expectedPrize = bankBefore * 2_000 / 10_000;
        assertEq(hook.nextPrize(), expectedPrize);

        warpPastFirstRoundFloor();
        uint256 aliceBefore = imd.balanceOf(alice);
        vm.expectEmit(true, true, false, true, address(hook));
        emit WinGameHook.RoundSettled(1, alice, expectedPrize, bankBefore - expectedPrize);
        vm.prank(carol); // anyone
        hook.settle();

        assertEq(imd.balanceOf(alice) - aliceBefore, expectedPrize, "leader paid 20%");
        assertEq(hook.bank(), bankBefore - expectedPrize, "the rest stays for the next round");
        assertEq(hook.winnersCount(), 1);
        WinGameHook.Winner memory w = hook.winnerAt(0);
        assertEq(w.round, 1);
        assertEq(w.winner, alice);
        assertEq(w.prize, expectedPrize);
        assertEq(w.settledAt, block.timestamp);
        assertEq(hook.roundNumber(), 2);
        assertEq(hook.leader(), address(0));
        assertEq(hook.timeLeft(), 0);
        assertAccounting();
    }

    // ------------------------------------------------------------------ later rounds

    function test_laterRounds_tenMinuteTimerAndResets() public {
        _finishRoundOne();
        uint256 t = block.timestamp + 1 hours;
        vm.warp(t);
        assertEq(hook.roundNumber(), 2);
        assertFalse(hook.roundActive());

        buyExactIn(alice, hook.minimumBuy());
        assertTrue(hook.roundActive());
        assertEq(hook.roundsStarted(), 2);
        assertEq(hook.deadline(), t + 10 minutes);
        assertEq(hook.timeLeft(), 10 minutes);

        vm.warp(t + 5 minutes);
        assertEq(hook.timeLeft(), 5 minutes);
        buyExactIn(bob, hook.minimumBuy());
        assertEq(hook.deadline(), t + 15 minutes, "timer restarted to 10 minutes");
        assertEq(hook.leader(), bob);
        assertEq(hook.qualifyingBuysInRound(), 2);

        vm.warp(t + 15 minutes - 1);
        vm.expectRevert(abi.encodeWithSelector(WinGameHook.RoundNotOver.selector, uint64(t + 15 minutes)));
        hook.settle();
    }

    function test_laterRounds_prizeIsFivePercent() public {
        _finishRoundOne();
        buyExactIn(alice, hook.minimumBuy());
        buyExactIn(bob, hook.minimumBuy());
        uint256 bankBefore = hook.bank();
        uint256 prize = bankBefore * 500 / 10_000;
        assertEq(hook.nextPrize(), prize);

        vm.warp(block.timestamp + 10 minutes);
        uint256 bobBefore = imd.balanceOf(bob);
        hook.settle();
        assertEq(imd.balanceOf(bob) - bobBefore, prize);
        assertEq(hook.bank(), bankBefore - prize);
        assertEq(hook.winnerAt(1).round, 2);
        assertEq(hook.winnerAt(1).winner, bob);
        assertAccounting();
    }

    function test_settle_twiceReverts() public {
        _finishRoundOne();
        vm.expectRevert(WinGameHook.NoActiveRound.selector);
        hook.settle();
    }

    function test_multipleRoundsAccumulateWinners() public {
        _finishRoundOne();
        address[3] memory players = [alice, bob, carol];
        for (uint256 r = 0; r < 3; r++) {
            buyExactIn(players[r], hook.minimumBuy());
            vm.warp(block.timestamp + 10 minutes);
            hook.settle();
        }
        WinGameHook.Winner[] memory ws = hook.pastWinners();
        assertEq(ws.length, 4);
        for (uint256 r = 0; r < 3; r++) {
            assertEq(ws[r + 1].round, uint64(r + 2));
            assertEq(ws[r + 1].winner, players[r]);
        }
        assertEq(hook.roundNumber(), 5);
        assertAccounting();
    }

    // ------------------------------------------------------------------ minimum buy

    function test_minimumBuy_floorIsEightAndAHalfImd() public {
        warpPastDecay();
        assertEq(hook.minimumBuy(), FLOOR);
        buyExactIn(alice, FLOOR - 1);
        assertFalse(hook.roundActive(), "just under the floor does not qualify");
        buyExactIn(alice, FLOOR);
        assertTrue(hook.roundActive(), "exactly the floor qualifies");
    }

    function test_minimumBuy_risesFivePercentPerQualifyingBuy() public {
        warpPastDecay();
        address[2] memory players = [alice, bob];
        for (uint256 i = 0; i < 6; i++) {
            uint256 expected = _expectedMinAfter(i);
            assertEq(hook.minimumBuy(), expected, "minimum before buy");
            buyExactIn(players[i % 2], expected);
            assertEq(hook.leader(), players[i % 2]);
            assertEq(hook.qualifyingBuysInRound(), i + 1);
        }
        assertEq(hook.minimumBuy(), _expectedMinAfter(6));
        // 8.5 * 1.05^6 = 11.390813 IMD
        assertApproxEqAbs(hook.minimumBuy(), 11.390813 ether, 1e12);
    }

    function test_minimumBuy_escalatorIsCapped() public {
        warpPastDecay();
        buyExactIn(alice, FLOOR);
        // Force the escalator just under the cap and make one more qualifying buy.
        vm.store(address(hook), bytes32(_escalatorSlot()), bytes32(hook.MAX_ESCALATOR() - 1));
        assertEq(hook.escalator(), hook.MAX_ESCALATOR() - 1);
        uint256 minimum = hook.minimumBuy();
        imd.mint(bob, minimum);
        buyExactIn(bob, minimum);
        assertEq(hook.escalator(), hook.MAX_ESCALATOR(), "capped, no overflow");
        assertEq(hook.leader(), bob);
        hook.minimumBuy(); // still computable
    }

    function _escalatorSlot() internal view returns (uint256 slot) {
        // Locate the escalator slot by probing: the only slot holding exactly 1.05e18 after one buy.
        for (slot = 0; slot < 40; slot++) {
            if (uint256(vm.load(address(hook), bytes32(slot))) == 1.05e18) return slot;
        }
        revert("escalator slot not found");
    }

    function test_minimumBuy_belowMinimumChangesNothingButTheBank() public {
        warpPastDecay();
        buyExactIn(alice, FLOOR);
        uint256 minimum = hook.minimumBuy();
        uint64 deadline = hook.deadline();
        uint256 bankBefore = hook.bank();

        vm.warp(block.timestamp + 1 minutes);
        buyExactIn(bob, minimum - 1);

        assertEq(hook.leader(), alice, "leader unchanged");
        assertEq(hook.deadline(), deadline, "timer unchanged");
        assertEq(hook.qualifyingBuysInRound(), 1);
        assertEq(hook.minimumBuy(), minimum, "escalator unchanged");
        assertGt(hook.bank(), bankBefore, "but the fee still went to the bank");
    }

    function test_minimumBuy_followsTwentyPercentOfPrizeWhenLarger() public {
        warpPastDecay();
        // A big buy fills the bank: 20,000 IMD -> 600 fee -> 540 to the bank -> round-1 prize 108 -> 20% = 21.6
        buyExactIn(carol, 20_000 ether);
        assertEq(hook.bank(), 540 ether);
        assertEq(hook.nextPrize(), 108 ether);
        uint256 expected = 21.6 ether * 10_500 / 10_000; // one qualifying buy already escalated it
        assertEq(hook.minimumBuy(), expected);
        assertGt(expected, FLOOR);

        buyExactIn(alice, expected - 1);
        assertEq(hook.leader(), carol, "below the prize-linked minimum");
        // Alice's fee grew the bank, so the minimum moved up with the prize.
        uint256 nowMin = hook.minimumBuy();
        assertEq(nowMin, hook.nextPrize() * 2_000 / 10_000 * 10_500 / 10_000);
        buyExactIn(alice, nowMin);
        assertEq(hook.leader(), alice);
    }

    function test_minimumBuy_resetsWhenNewRoundStarts() public {
        warpPastDecay();
        for (uint256 i = 0; i < 4; i++) {
            buyExactIn(alice, hook.minimumBuy());
        }
        assertGt(hook.minimumBuy(), FLOOR * 12 / 10);
        warpPastFirstRoundFloor();
        hook.settle();

        uint256 base = hook.nextPrize() * 2_000 / 10_000;
        if (base < FLOOR) base = FLOOR;
        assertEq(hook.minimumBuy(), base, "escalator back to 1x");
        assertEq(hook.escalator(), 1e18);
    }

    function test_minimumBuy_resetsEvenWhenRoundClosesLazily() public {
        _finishRoundOne();
        buyExactIn(alice, hook.minimumBuy());
        buyExactIn(bob, hook.minimumBuy());
        buyExactIn(alice, hook.minimumBuy());
        vm.warp(block.timestamp + 10 minutes);
        // The next buy closes round 2 and is judged against round 3's fresh minimum.
        buyExactIn(carol, FLOOR);
        assertEq(hook.roundsStarted(), 3);
        assertEq(hook.leader(), carol);
        assertEq(hook.qualifyingBuysInRound(), 1);
    }

    // ------------------------------------------------------------------ sells

    function test_sells_neverResetTimerOrChangeLeader() public {
        _finishRoundOne();
        giveWin(bob, 50_000_000 ether);
        buyExactIn(carol, 500 ether); // carol leads and the pool now holds IMD to sell into
        buyExactIn(alice, hook.minimumBuy());
        assertEq(hook.leader(), alice);
        uint64 deadline = hook.deadline();
        uint256 minimum = hook.minimumBuy();
        uint256 bankBefore = hook.bank();

        vm.warp(block.timestamp + 3 minutes);
        sellExactIn(bob, 1_000_000 ether);
        sellExactOut(bob, 5 ether);

        assertEq(hook.leader(), alice);
        assertEq(hook.deadline(), deadline);
        assertEq(hook.qualifyingBuysInRound(), 2);
        assertEq(hook.escalator(), 1.1025e18);
        assertGt(hook.bank(), bankBefore, "sell fees still feed the bank");
        // The prize-linked part of the minimum may rise with the bank; the escalator must not move.
        assertGe(hook.minimumBuy(), minimum);
    }

    function test_sells_afterExpiryDoNotCloseTheRound() public {
        _finishRoundOne();
        giveWin(bob, 50_000_000 ether);
        buyExactIn(alice, hook.minimumBuy());
        vm.warp(block.timestamp + 11 minutes);
        sellExactIn(bob, 100_000 ether);
        assertTrue(hook.roundActive(), "a sell leaves the finished round for settle()");
        assertTrue(hook.settleable());
        assertEq(hook.leader(), alice);
    }

    // ------------------------------------------------------------------ end-of-round sniping

    function test_snipe_buyAfterDeadlineCannotStealTheRound() public {
        _finishRoundOne();
        buyExactIn(alice, hook.minimumBuy());
        buyExactIn(bob, hook.minimumBuy());
        uint64 deadline = hook.deadline();
        uint256 bankAtExpiry = hook.bank();
        uint256 prize = bankAtExpiry * 500 / 10_000;

        // Timer ran out, nobody called settle() yet, a bot buys above the minimum.
        vm.warp(deadline + 1);
        buyExactIn(sniper, hook.minimumBuy() * 2);

        assertEq(hook.winnersCount(), 2);
        assertEq(hook.winnerAt(1).winner, bob, "the real leader won round 2");
        assertEq(hook.winnerAt(1).prize, prize, "prize measured before the sniper's fee entered");
        assertEq(hook.unclaimedPrize(bob), prize);
        assertEq(hook.roundsStarted(), 3);
        assertEq(hook.leader(), sniper, "the sniper merely opened round 3");
        assertEq(hook.deadline(), deadline + 1 + 10 minutes);
        assertAccounting();

        uint256 bobBefore = imd.balanceOf(bob);
        vm.prank(carol);
        hook.claimPrize(bob);
        assertEq(imd.balanceOf(bob) - bobBefore, prize);
        assertEq(hook.unclaimedPrize(bob), 0);
        vm.expectRevert(WinGameHook.NothingToClaim.selector);
        hook.claimPrize(bob);
        assertAccounting();
    }

    function test_snipe_buyExactlyAtDeadlineBelongsToNextRound() public {
        _finishRoundOne();
        buyExactIn(alice, hook.minimumBuy());
        vm.warp(hook.deadline());
        buyExactIn(sniper, hook.minimumBuy());
        assertEq(hook.winnerAt(1).winner, alice);
        assertEq(hook.roundsStarted(), 3);
        assertEq(hook.leader(), sniper);
    }

    function test_snipe_buyOneSecondBeforeDeadlineRestartsTheFullTimer() public {
        _finishRoundOne();
        buyExactIn(alice, hook.minimumBuy());
        vm.warp(hook.deadline() - 1);
        buyExactIn(sniper, hook.minimumBuy());
        assertEq(hook.leader(), sniper);
        assertEq(hook.timeLeft(), 10 minutes, "everyone gets a full ten minutes to answer");
        assertEq(hook.roundsStarted(), 2);

        vm.warp(block.timestamp + 9 minutes);
        buyExactIn(alice, hook.minimumBuy());
        assertEq(hook.leader(), alice, "and the answer takes the lead back");
    }

    function test_snipe_tinyBuyAfterDeadlineStillClosesTheRoundForTheLeader() public {
        _finishRoundOne();
        buyExactIn(alice, hook.minimumBuy());
        vm.warp(hook.deadline() + 30);
        buyExactIn(sniper, 1 ether);
        assertFalse(hook.roundActive());
        assertEq(hook.winnerAt(1).winner, alice);
        assertGt(hook.unclaimedPrize(alice), 0);
        assertEq(hook.leader(), address(0));
    }

    function test_snipe_settleAndLazyCloseAgreeOnThePrize() public {
        _finishRoundOne();
        buyExactIn(alice, hook.minimumBuy());
        uint256 expected = hook.bank() * 500 / 10_000;
        vm.warp(hook.deadline());
        uint256 snapshot = vm.snapshotState();

        hook.settle();
        assertEq(hook.winnerAt(1).prize, expected);

        vm.revertToState(snapshot);
        buyExactIn(sniper, 1 ether);
        assertEq(hook.winnerAt(1).prize, expected);
    }

    // ------------------------------------------------------------------ buyer identity

    function test_identity_hookDataNamesTheBuyer() public {
        warpPastDecay();
        buyExactIn(alice, FLOOR, abi.encode(bob));
        assertEq(hook.leader(), bob);
    }

    function test_identity_emptyHookDataFallsBackToTxOrigin() public {
        warpPastDecay();
        buyExactIn(alice, FLOOR, "");
        assertEq(hook.leader(), alice);
    }

    function test_identity_zeroAddressFallsBackToTxOrigin() public {
        warpPastDecay();
        buyExactIn(alice, FLOOR, abi.encode(address(0)));
        assertEq(hook.leader(), alice);
    }

    function test_identity_malformedHookDataFallsBackToTxOrigin() public {
        warpPastDecay();
        buyExactIn(alice, FLOOR, abi.encode(bytes32(uint256(1) << 200 | uint256(uint160(bob)))));
        assertEq(hook.leader(), alice, "dirty upper bits");
        buyExactIn(carol, hook.minimumBuy(), hex"deadbeef");
        assertEq(hook.leader(), carol, "wrong length");
    }

    function test_identity_packedTwentyByteAddressIsAccepted() public {
        warpPastDecay();
        buyExactIn(alice, FLOOR, abi.encodePacked(bob));
        assertEq(hook.leader(), bob);
    }

    function test_identity_routerIsNeverTheLeader() public {
        warpPastDecay();
        buyExactIn(alice, FLOOR, "");
        assertTrue(hook.leader() != address(swapRouter));
        assertTrue(hook.leader() != address(manager));
    }

    function test_identity_sixtyFourBytePayloadNamesTheBuyerWithoutTheFlag() public {
        warpPastDecay();
        buyExactIn(alice, FLOOR, abi.encode(bob, false));
        assertEq(hook.leader(), bob);
    }

    function test_identity_malformedSixtyFourBytePayloadReverts() public {
        warpPastDecay();
        bytes[3] memory bad = [
            abi.encode(bob, uint256(2)), // flag that is not a bool
            abi.encode(address(0), true), // nobody named
            abi.encode(uint256(1) << 200 | uint256(uint160(bob)), true) // dirty upper bits
        ];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.expectRevert(_afterSwapRevert(abi.encodeWithSelector(WinGameHook.MalformedHookData.selector)));
            buyExactIn(alice, FLOOR, bad[i]);
        }
        assertFalse(hook.roundActive());
    }

    // ------------------------------------------------------------------ identity through the router

    function _msgSenderRouter() internal returns (MsgSenderRouter r, address account, address bundler) {
        r = new MsgSenderRouter(manager);
        account = makeAddr("smartAccount");
        bundler = makeAddr("bundler");
        imd.mint(account, 1_000 ether);
        vm.prank(account);
        imd.approve(address(r), type(uint256).max);
    }

    function _buyParams(uint256 imdAmount) internal view returns (SwapParams memory) {
        bool zeroForOne = !winIsCurrency0;
        return SwapParams(zeroForOne, -int256(imdAmount), _limit(zeroForOne));
    }

    /// @dev A 4337-style trade: the paying account calls the router, the bundler signed the
    /// transaction. Without hookData the hook asks the router who called it.
    function test_identity_routerMsgSenderIsUsedBeforeTxOrigin() public {
        warpPastDecay();
        (MsgSenderRouter r, address account, address bundler) = _msgSenderRouter();
        vm.prank(account, bundler);
        r.swap(key, _buyParams(FLOOR), "");
        assertEq(hook.leader(), account, "the paying account leads, not the bundler");
        assertTrue(hook.leader() != bundler);
    }

    function test_identity_hookDataBeatsRouterMsgSender() public {
        warpPastDecay();
        (MsgSenderRouter r, address account, address bundler) = _msgSenderRouter();
        vm.prank(account, bundler);
        r.swap(key, _buyParams(FLOOR), abi.encode(carol));
        assertEq(hook.leader(), carol);
    }

    function test_identity_routerThatRevertsOrReturnsGarbageFallsBackToTxOrigin() public {
        warpPastDecay();
        (MsgSenderRouter r, address account, address bundler) = _msgSenderRouter();

        r.setMode(MsgSenderRouter.Mode.Reverts, address(0));
        vm.prank(account, bundler);
        r.swap(key, _buyParams(FLOOR), "");
        assertEq(hook.leader(), bundler, "reverting msgSender: signer is credited");

        r.setMode(MsgSenderRouter.Mode.Garbage, address(0));
        SwapParams memory next = _buyParams(hook.minimumBuy());
        vm.prank(account, alice);
        r.swap(key, next, "");
        assertEq(hook.leader(), alice, "garbage msgSender: signer is credited");
    }

    function test_identity_lyingRouterCanOnlyGiftTheLead() public {
        warpPastDecay();
        (MsgSenderRouter r, address account, address bundler) = _msgSenderRouter();
        r.setMode(MsgSenderRouter.Mode.Lies, carol);
        vm.prank(account, bundler);
        r.swap(key, _buyParams(FLOOR), "");
        assertEq(hook.leader(), carol);
        // Nothing else moved: the fee was charged and the bank grew exactly as for an honest trade.
        assertEq(hook.bank(), FLOOR * 30_000 / 1_000_000 * 9 / 10);
    }

    /// @dev The documented residual: a router without `msgSender()` and a swap without hookData
    /// credit the transaction signer. Smart accounts must use the website (hookData) or a router
    /// that reports its caller.
    function test_identity_routerWithoutMsgSenderCreditsTheSigner() public {
        warpPastDecay();
        address account = makeAddr("smartAccount");
        address bundler = makeAddr("bundler");
        _fund(account);
        vm.prank(account, bundler);
        swapRouter.swap(key, _buyParams(FLOOR), PoolSwapTest.TestSettings(false, false), "");
        assertEq(hook.leader(), bundler);
    }

    // ------------------------------------------------------------------ must-lead flag

    function test_mustLead_qualifyingBuyLeads() public {
        warpPastDecay();
        buyExactIn(alice, FLOOR, _mustLead(alice));
        assertEq(hook.leader(), alice);
        assertEq(hook.qualifyingBuysInRound(), 1);
    }

    function test_mustLead_buyBelowTheMinimumRevertsAndCostsNoFee() public {
        warpPastDecay();
        uint256 minimum = hook.minimumBuy();
        uint256 imdBefore = imd.balanceOf(alice);
        vm.expectRevert(
            _afterSwapRevert(abi.encodeWithSelector(WinGameHook.NotQualifying.selector, minimum, minimum - 1))
        );
        buyExactIn(alice, minimum - 1, _mustLead(alice));
        assertEq(imd.balanceOf(alice), imdBefore, "nothing spent");
        assertEq(hook.bank(), 0, "no fee taken");
        assertFalse(hook.roundActive());
    }

    /// @dev The reviewer's case A: in the prize-linked regime any fee (here a dust buy) raises the
    /// minimum, so a challenger who pays exactly the displayed minimum lands short by a few wei.
    function test_mustLead_dustBuyThatRaisesTheMinimumVoidsTheChallengeWithoutAFee() public {
        _finishRoundOne();
        buyExactIn(carol, 50_000 ether); // carol leads round 2 with a large bank
        buyExactIn(alice, hook.minimumBuy());
        assertEq(hook.leader(), alice);
        uint256 shown = hook.minimumBuy();
        assertGt(shown, FLOOR, "prize-linked regime");
        uint64 deadline = hook.deadline();

        buyExactIn(alice, 1_000_000); // 1e-12 IMD of dust
        uint256 moved = hook.minimumBuy();
        assertGt(moved, shown, "the dust fee moved the minimum");

        // Flagged: the whole swap reverts, bob keeps his IMD and alice keeps her deadline.
        uint256 bobBefore = imd.balanceOf(bob);
        vm.expectRevert(_afterSwapRevert(abi.encodeWithSelector(WinGameHook.NotQualifying.selector, moved, shown)));
        buyExactIn(bob, shown, _mustLead(bob));
        assertEq(imd.balanceOf(bob), bobBefore);
        assertEq(hook.leader(), alice);
        assertEq(hook.deadline(), deadline);

        // Unflagged: the same buy executes as an ordinary (fee-paying) buy, as the rules say.
        buyExactIn(bob, shown, abi.encode(bob));
        assertLt(imd.balanceOf(bob), bobBefore);
        assertEq(hook.leader(), alice);

        // Flagged at the live minimum: takes the lead.
        buyExactIn(bob, hook.minimumBuy(), _mustLead(bob));
        assertEq(hook.leader(), bob);
        assertEq(hook.deadline(), block.timestamp + 10 minutes);
    }

    /// @dev The reviewer's case B: in the floor regime the leader re-qualifies (and sells back)
    /// ahead of a challenger who priced in one 5% step but not two.
    function test_mustLead_leaderRequalifyingAheadVoidsTheChallengeWithoutAFee() public {
        _finishRoundOne();
        buyExactIn(alice, hook.minimumBuy());
        uint256 shown = hook.minimumBuy(); // 8.925
        uint256 bobBid = shown * 104 / 100; // bob allows 4% slippage on the minimum
        BalanceDelta d = buyExactIn(alice, shown); // alice re-qualifies first
        sellExactIn(alice, uint256(winDeltaOf(d)));
        assertGt(hook.minimumBuy(), bobBid);

        uint256 bobBefore = imd.balanceOf(bob);
        vm.expectRevert(
            _afterSwapRevert(abi.encodeWithSelector(WinGameHook.NotQualifying.selector, hook.minimumBuy(), bobBid))
        );
        buyExactIn(bob, bobBid, _mustLead(bob));
        assertEq(imd.balanceOf(bob), bobBefore);
        assertEq(hook.leader(), alice);
    }

    /// @dev The reviewer's case C: an exact-output buy's gross IMD depends on the pool price, so
    /// a sell placed in front lowers it below the minimum.
    function test_mustLead_exactOutputBuyUndercutByASellRevertsWithoutAFee() public {
        warpPastDecay();
        buyExactIn(alice, 500 ether);
        assertEq(hook.leader(), alice);
        uint256 minimum = hook.minimumBuy();

        // How much WIN the minimum plus a 1% margin buys right now.
        uint256 snapshot = vm.snapshotState();
        BalanceDelta probe = buyExactIn(carol, minimum * 101 / 100);
        uint256 winOut = uint256(winDeltaOf(probe));
        vm.revertToState(snapshot);

        // Control: without interference the exact-output buy leads.
        snapshot = vm.snapshotState();
        buyExactOut(carol, winOut, _mustLead(carol));
        assertEq(hook.leader(), carol);
        vm.revertToState(snapshot);

        // Alice sells 5% of her WIN first; carol's identical buy is now cheaper than the minimum.
        sellExactIn(alice, win.balanceOf(alice) / 20);
        uint256 carolBefore = imd.balanceOf(carol);
        bool zeroForOne = !winIsCurrency0;
        vm.prank(carol, carol);
        (bool ok, bytes memory err) = address(swapRouter)
            .call(
                abi.encodeCall(
                    PoolSwapTest.swap,
                    (
                        key,
                        SwapParams(zeroForOne, int256(winOut), _limit(zeroForOne)),
                        PoolSwapTest.TestSettings(false, false),
                        _mustLead(carol)
                    )
                )
            );
        assertFalse(ok, "flagged buy must revert");
        assertTrue(_contains(err, WinGameHook.NotQualifying.selector), "with NotQualifying");
        assertEq(imd.balanceOf(carol), carolBefore, "no fee paid");
        assertEq(hook.leader(), alice);

        // Unflagged, the same buy goes through as an ordinary buy and alice stays leader.
        buyExactOut(carol, winOut, abi.encode(carol));
        assertEq(hook.leader(), alice);
        assertLt(imd.balanceOf(carol), carolBefore);
    }

    function test_mustLead_flagOnASellReverts() public {
        warpPastDecay();
        giveWin(bob, 50_000_000 ether);
        buyExactIn(alice, 100 ether);
        bool zeroForOne = winIsCurrency0;
        vm.expectRevert(_afterSwapRevert(abi.encodeWithSelector(WinGameHook.MustLeadOnlyOnBuys.selector)));
        _swap(bob, SwapParams(zeroForOne, -int256(1_000 ether), _limit(zeroForOne)), _mustLead(bob));
    }

    function test_mustLead_buyAfterExpiryIsJudgedAgainstTheNextRound() public {
        _finishRoundOne();
        for (uint256 i = 0; i < 4; i++) {
            buyExactIn(alice, hook.minimumBuy());
        }
        vm.warp(hook.deadline());
        uint256 shown = hook.minimumBuy(); // the next round's minimum, escalator reset
        assertEq(shown, FLOOR);
        buyExactIn(bob, shown, _mustLead(bob));
        assertEq(hook.winnerAt(1).winner, alice, "round 2 closed for alice");
        assertEq(hook.leader(), bob, "bob opened round 3");
        assertEq(hook.roundsStarted(), 3);
    }

    function _contains(bytes memory data, bytes4 selector) internal pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i = 0; i + 4 <= data.length; i++) {
            if (
                data[i] == selector[0] && data[i + 1] == selector[1] && data[i + 2] == selector[2]
                    && data[i + 3] == selector[3]
            ) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------ views while a round waits for settle()

    function test_views_describeTheNextRoundOnceTheTimerHasRunOut() public {
        _finishRoundOne();
        for (uint256 i = 0; i < 5; i++) {
            buyExactIn(alice, hook.minimumBuy());
        }
        uint256 bankAtExpiry = hook.bank();
        uint256 prize = bankAtExpiry * 500 / 10_000;
        uint256 escalatedMinimum = hook.minimumBuy();
        assertGt(escalatedMinimum, FLOOR);

        vm.warp(hook.deadline());
        assertTrue(hook.settleable());
        assertEq(hook.timeLeft(), 0);
        assertEq(hook.pendingPrize(), prize, "the expired round's prize");
        assertEq(hook.roundNumber(), 3, "a buy now joins round 3");
        assertEq(hook.nextPrize(), (bankAtExpiry - prize) * 500 / 10_000, "round 3's prize from the remaining bank");
        uint256 shown = hook.minimumBuy();
        uint256 base = hook.nextPrize() * 2_000 / 10_000;
        assertEq(shown, base < FLOOR ? FLOOR : base, "escalator reset for round 3");
        assertLt(shown, escalatedMinimum);

        WinGameHook.GameState memory s = hook.gameState();
        assertTrue(s.settleable);
        assertFalse(s.roundActive);
        assertEq(s.leader, address(0));
        assertEq(s.roundNumber, 3);
        assertEq(s.minimumBuy, shown);
        assertEq(s.nextPrize, hook.nextPrize());
        assertEq(s.qualifyingBuysInRound, 0);
        assertEq(s.deadline, 0);
        assertEq(s.pendingRound, 2);
        assertEq(s.pendingWinner, alice);
        assertEq(s.pendingPrize, prize);

        // The displayed minimum is exactly what the next buy is judged against.
        buyExactIn(bob, shown - 1);
        assertEq(hook.winnerAt(1).winner, alice, "round 2 closed for alice");
        assertEq(hook.winnerAt(1).prize, prize);
        assertFalse(hook.roundActive(), "one wei short does not open round 3");
        buyExactIn(carol, hook.minimumBuy());
        assertEq(hook.leader(), carol);
        assertEq(hook.roundsStarted(), 3);
    }

    function test_views_firstRoundWaitingForSettleShowsSecondRoundTerms() public {
        warpPastDecay();
        buyExactIn(alice, hook.minimumBuy());
        buyExactIn(bob, hook.minimumBuy());
        uint256 bankAtExpiry = hook.bank();
        uint256 prize = bankAtExpiry * 2_000 / 10_000;

        warpPastFirstRoundFloor();
        assertEq(hook.pendingPrize(), prize, "20% for round 1");
        assertEq(hook.roundNumber(), 2);
        assertEq(hook.nextPrize(), (bankAtExpiry - prize) * 500 / 10_000, "5% from round 2 on");
        uint256 shown = hook.minimumBuy();
        assertEq(shown, FLOOR, "escalator reset, floor regime");

        buyExactIn(carol, shown - 1);
        assertEq(hook.winnerAt(0).winner, bob);
        assertFalse(hook.roundActive());
        assertEq(hook.leader(), address(0));
    }

    function test_views_matchSettleOutcome() public {
        _finishRoundOne();
        buyExactIn(alice, hook.minimumBuy());
        buyExactIn(bob, hook.minimumBuy());
        vm.warp(hook.deadline() + 1);
        uint256 shownMinimum = hook.minimumBuy();
        uint256 shownPrize = hook.nextPrize();
        uint64 shownRound = hook.roundNumber();
        uint256 pending = hook.pendingPrize();

        hook.settle();
        assertEq(hook.winnerAt(1).prize, pending);
        assertEq(hook.minimumBuy(), shownMinimum);
        assertEq(hook.nextPrize(), shownPrize);
        assertEq(hook.roundNumber(), shownRound);
        assertEq(hook.pendingPrize(), 0);
        assertFalse(hook.settleable());
    }

    // ------------------------------------------------------------------ views

    function test_gameState_matchesIndividualViews() public {
        warpPastDecay();
        buyExactIn(alice, FLOOR);
        WinGameHook.GameState memory s = hook.gameState();
        assertEq(s.bank, hook.bank());
        assertEq(s.nextPrize, hook.nextPrize());
        assertEq(s.minimumBuy, hook.minimumBuy());
        assertEq(s.leader, alice);
        assertEq(s.timeLeft, hook.timeLeft());
        assertEq(s.roundNumber, 1);
        assertTrue(s.roundActive);
        assertEq(s.deadline, hook.deadline());
        assertEq(s.qualifyingBuysInRound, 1);
        assertEq(s.feePips, 30_000);
        assertEq(s.teamOwed, hook.teamOwed());
        assertEq(s.winners, 0);
        assertFalse(s.settleable);
        assertEq(s.pendingRound, 0);
        assertEq(s.pendingWinner, address(0));
        assertEq(s.pendingPrize, 0);
    }

    function test_poolViews() public view {
        assertEq(address(hook.poolKey().hooks), address(hook));
        assertEq(hook.poolKey().fee, 3_000);
        assertEq(hook.winIsCurrency0(), winIsCurrency0);
        assertEq(address(hook.winToken()), address(win));
    }

    // ------------------------------------------------------------------ conservation

    /// @dev Random buys, sells, waits and settlements: every IMD the hook ever took is either in
    /// the bank, owed to the team, awaiting a winner, or already paid out, and nothing else moves.
    function testFuzz_fundsAreConserved(uint256 seed) public {
        giveWin(alice, 40_000_000 ether);
        giveWin(bob, 40_000_000 ether);
        address[3] memory players = [alice, bob, carol];
        uint256 feesTaken;
        uint256 paidOut;

        for (uint256 i = 0; i < 24; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address who = players[r % 3];
            uint256 kind = (r >> 8) % 5;
            vm.warp(block.timestamp + ((r >> 16) % 7 minutes));
            uint256 claimsBefore = hookImdClaims();

            if (kind == 0) {
                buyExactIn(who, bound(r >> 32, 0.01 ether, 60 ether));
            } else if (kind == 1) {
                buyExactOut(who, bound(r >> 32, 1 ether, 3_000_000 ether), abi.encode(who));
            } else if (kind == 2 && who != carol && imd.balanceOf(address(manager)) > 5 ether) {
                sellExactIn(who, bound(r >> 32, 1 ether, 100_000 ether));
            } else if (kind == 3 && who != carol && imd.balanceOf(address(manager)) > 5 ether) {
                sellExactOut(who, bound(r >> 32, 0.001 ether, 0.05 ether));
            } else if (hook.roundActive() && block.timestamp >= hook.deadline()) {
                address winner = hook.leader();
                uint256 before = imd.balanceOf(winner);
                hook.settle();
                uint256 paid = imd.balanceOf(winner) - before;
                paidOut += paid;
                assertEq(claimsBefore - hookImdClaims(), paid, "settle moves exactly the prize");
                claimsBefore = hookImdClaims();
            }
            feesTaken += hookImdClaims() - claimsBefore;
            assertAccounting();
        }

        // Drain everything claimable and check the ledger closes.
        if (hook.teamOwed() > 0) {
            uint256 owed = hook.teamOwed();
            hook.claimTeamFees();
            paidOut += owed;
        }
        for (uint256 p = 0; p < 3; p++) {
            uint256 u = hook.unclaimedPrize(players[p]);
            if (u > 0) {
                hook.claimPrize(players[p]);
                paidOut += u;
            }
        }
        assertEq(hookImdClaims(), hook.bank(), "only the bank remains");
        assertEq(feesTaken, hook.bank() + paidOut, "fees in == bank + everything paid out");
    }
}

/// @notice The same game suite with WIN as currency1.
contract WinGameHookGameFlippedTest is WinGameHookGameTest {
    function wantWinIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
