// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WinGameFixture} from "./utils/WinGameFixture.sol";
import {WinGameHook} from "../src/WinGameHook.sol";

/// @notice Rounds, minimum buy, settlement, sniping defences, buyer identity and the website views.
contract WinGameHookGameTest is WinGameFixture {
    uint256 constant FLOOR = 8.5 ether;

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
