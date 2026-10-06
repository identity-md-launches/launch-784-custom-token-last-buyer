// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {WinGameFixture} from "../utils/WinGameFixture.sol";
import {WinGameHook} from "../../src/WinGameHook.sol";
import {WinGameHandler} from "./WinGameHandler.sol";

/// @notice Invariants of the value-holding hook over random sequences of buys, sells, settlements,
/// claims, time jumps, donations, third-party liquidity and hostile direct calls, from four actors.
///
/// The campaign starts at the moment of launch: 50% fee, empty bank, round 1 with its 3-hour floor.
/// `WinGameHookLaterRoundsInvariantTest` starts after round 1 has been played and settled, so the
/// 10-minute regime and 5% prizes get the full call budget; the flipped variants put WIN on the
/// other side of the pool.
///
/// Each `invariant_` function is its own campaign, so the properties are grouped into two of them
/// (money, game) and written as named `check_` functions; both campaigns also assert the handler's
/// per-action verdict.
contract WinGameHookInvariantTest is WinGameFixture {
    uint256 internal constant FLOOR = 8.5 ether;
    uint256 internal constant WAD = 1e18;
    address internal constant TEAM = 0x611F08c7226591708B5F53F29BF53f3830D54511;

    WinGameHandler internal handler;
    address[] internal actorList;
    uint256 internal imdSupplyAtStart;

    function setUp() public virtual override {
        super.setUp();
        actorList = [alice, bob, carol, sniper];
        handler = new WinGameHandler(
            IPoolManager(address(manager)), hook, win, imd, swapRouter, lpRouter, key, launchTime, actorList
        );
        imdSupplyAtStart = imd.totalSupply();
        _prelude();

        targetContract(address(handler));
        // The mock IMD has an open mint and the routers are not the system under test: keep the
        // fuzzer on the handler so every call is a meaningful, bounded action.
        excludeContract(address(imd));
        excludeContract(address(win));
        excludeContract(address(hook));
        excludeContract(address(manager));
        excludeContract(address(swapRouter));
        excludeContract(address(lpRouter));
        excludeContract(address(handler.donor()));
    }

    /// @dev State the campaign starts from. Nothing by default: the moment of launch.
    function _prelude() internal virtual {}

    // ------------------------------------------------------------------ campaigns

    /// @notice Money: the hook holds exactly what it owes, the bank moves only by fees and prizes,
    /// and neither IMD nor WIN appears or disappears anywhere in the system.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 50
    function invariant_money() public view virtual {
        check_everyActionMatchesTheBrief();
        check_claimsEqualBankPlusTeamPlusUnclaimedPrizes();
        check_bankIsFedOnlyByFeesAndDrainedOnlyByPrizes();
        check_unclaimedPrizesAreAwardedMinusPaid();
        check_imdIsConservedAcrossTheSystem();
        check_winSupplyIsFixed();
    }

    /// @notice Game: round state machine, minimum buy, past winners, fee curve and website views.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 50
    function invariant_game() public view virtual {
        check_everyActionMatchesTheBrief();
        check_roundStateIsConsistent();
        check_minimumBuyFollowsFloorPrizeAndEscalation();
        check_pastWinnersAreAppendOnlyAndTruthful();
        check_feeAndWebsiteViewsAgree();
    }

    // ------------------------------------------------------------------ the handler's own verdict

    /// @notice No action ever disagreed with the brief's rules (fee rate, 90/10 split, who leads,
    /// the timer, the minimum and its escalation, prizes, sells leaving the game alone, access
    /// control). The message is the first disagreement the handler saw.
    function check_everyActionMatchesTheBrief() public view {
        assertEq(handler.violations(), 0, handler.firstViolation());
    }

    // ------------------------------------------------------------------ conservation

    /// @notice What the hook holds equals what it owes: bank + team share + prizes awaiting pickup.
    /// Donated claims are the only surplus and they belong to nobody.
    function check_claimsEqualBankPlusTeamPlusUnclaimedPrizes() public view {
        assertEq(
            hookImdClaims(),
            hook.bank() + hook.teamOwed() + hook.totalUnclaimedPrizes() + handler.ghostClaimsDonated(),
            "claims != bank + team + unclaimed (+ donations)"
        );
        // The claims are redeemable: the manager really holds the IMD behind them.
        assertGe(imd.balanceOf(address(manager)), hookImdClaims(), "manager cannot back the hook's claims");
        assertEq(hookWinClaims(), 0, "hook holds WIN claims");
        assertEq(win.balanceOf(address(hook)), 0, "hook holds WIN");
        assertEq(imd.balanceOf(address(hook)), handler.ghostRawDonated(), "hook holds raw IMD it was not sent");
    }

    /// @notice The bank is filled only by 90% of trading fees and emptied only by round prizes; the
    /// team's 10% only ever reaches the team wallet. Donations never show up in either.
    function check_bankIsFedOnlyByFeesAndDrainedOnlyByPrizes() public view {
        assertEq(hook.bank() + handler.ghostPrizesAwarded(), handler.ghostBankIn(), "bank != fees in - prizes out");
        assertEq(hook.teamOwed() + handler.ghostTeamPaid(), handler.ghostTeamIn(), "team != 10% of fees - paid");
        assertEq(handler.ghostBankIn() + handler.ghostTeamIn(), handler.ghostFees(), "fee split lost or made IMD");
        assertEq(imd.balanceOf(TEAM), handler.ghostTeamPaid(), "team wallet got something other than its claims");

        // 10% to the team, rounded down per swap: never more, and short by under a wei per swap.
        uint256 fees = handler.ghostFees();
        assertLe(handler.ghostTeamIn() * 10, fees, "team got more than 10%");
        assertGe(handler.ghostTeamIn() + handler.ghostFeeBearingSwaps(), fees / 10, "team got less than 10%");
    }

    /// @notice Prizes awaiting pickup are exactly the prizes awarded and not yet paid, per winner
    /// and in total, and nobody ever received more than they won.
    function check_unclaimedPrizesAreAwardedMinusPaid() public view {
        assertEq(
            hook.totalUnclaimedPrizes(), handler.ghostPrizesAwarded() - handler.ghostPrizesPaid(), "unclaimed total"
        );
        uint256 sum;
        uint256 received;
        for (uint256 i = 0; i < actorList.length; i++) {
            address a = actorList[i];
            assertEq(hook.unclaimedPrize(a), handler.ghostPrizeOwed(a), "per-winner unclaimed");
            sum += hook.unclaimedPrize(a);
            received += handler.ghostPrizeReceived(a);
        }
        assertEq(sum, hook.totalUnclaimedPrizes(), "sum of unclaimed prizes != total");
        assertEq(received, handler.ghostPrizesPaid(), "prizes paid to someone who is not a winner");
        assertEq(hook.unclaimedPrize(TEAM), 0);
        assertEq(hook.unclaimedPrize(address(swapRouter)), 0, "the router can never be a winner");
    }

    /// @notice IMD is neither created nor destroyed by the system: every unit is with an actor, in
    /// the manager, sitting in the hook as a stray donation, or with the team wallet.
    function check_imdIsConservedAcrossTheSystem() public view {
        uint256 total = imd.balanceOf(address(manager)) + imd.balanceOf(address(hook)) + imd.balanceOf(TEAM);
        for (uint256 i = 0; i < actorList.length; i++) {
            total += imd.balanceOf(actorList[i]);
        }
        assertEq(total, imdSupplyAtStart, "IMD leaked to an unknown address");
        assertEq(imd.totalSupply(), imdSupplyAtStart);
    }

    /// @notice WIN's supply is fixed and fully accounted for.
    function check_winSupplyIsFixed() public view {
        assertEq(win.totalSupply(), 1_000_000_000 ether);
        uint256 total = win.balanceOf(address(manager)) + win.balanceOf(address(this));
        for (uint256 i = 0; i < actorList.length; i++) {
            total += win.balanceOf(actorList[i]);
        }
        assertEq(total, 1_000_000_000 ether, "WIN leaked to an unknown address");
    }

    // ------------------------------------------------------------------ round state machine

    /// @notice The round flags and the data they guard always agree, and the timer never promises
    /// more than the brief allows.
    function check_roundStateIsConsistent() public view {
        uint256 winners = hook.winnersCount();
        if (hook.roundActive()) {
            assertEq(hook.roundsStarted(), winners + 1, "active round is not the one after the last winner");
            assertTrue(hook.leader() != address(0), "active round without a leader");
            assertGe(hook.qualifyingBuysInRound(), 1, "active round without a qualifying buy");
            assertGt(hook.deadline(), 0);
            // Once the timer has run out the round is spoken for: a buy would be judged against the
            // next one, and that is the number the views report until settle() runs.
            if (block.timestamp < hook.deadline()) {
                assertEq(hook.roundNumber(), hook.roundsStarted());
                assertEq(hook.pendingPrize(), 0);
            } else {
                assertEq(hook.roundNumber(), hook.roundsStarted() + 1);
                uint256 closingBps = hook.roundsStarted() == 1 ? 2_000 : 500;
                assertEq(
                    hook.pendingPrize(), hook.bank() * closingBps / 10_000, "pending prize is not the closing round's"
                );
            }
            if (hook.roundsStarted() == 1) {
                assertGe(hook.deadline(), launchTime + 3 hours, "round 1 may end before launch + 3h");
                // Either the 3-hour floor or a 10-minute timer, whichever is later.
                if (hook.deadline() > launchTime + 3 hours) {
                    assertLe(hook.timeLeft(), 10 minutes, "round 1 timer above 10 minutes past the floor");
                }
            } else {
                assertLe(hook.timeLeft(), 10 minutes, "timer above 10 minutes");
            }
        } else {
            assertEq(hook.roundsStarted(), winners, "idle but a round is unaccounted for");
            assertEq(hook.leader(), address(0), "leader outside a round");
            assertEq(hook.deadline(), 0);
            assertEq(hook.qualifyingBuysInRound(), 0);
            assertEq(hook.timeLeft(), 0);
            assertEq(hook.roundNumber(), hook.roundsStarted() + 1);
            assertFalse(hook.settleable());
            assertEq(hook.pendingPrize(), 0);
        }
        assertEq(hook.settleable(), hook.roundActive() && block.timestamp >= hook.deadline());
        assertTrue(hook.leader() != address(swapRouter), "the router became the leader");
    }

    /// @notice The minimum buy is never under 8.5 IMD, is the larger of the floor and 20% of the
    /// upcoming prize, and has risen by exactly 5% per qualifying buy of the running round. While
    /// an expired round waits for settle(), "upcoming" means the next round: its prize comes out of
    /// the bank left after the pending prize, its escalator is back at 1, and the number quoted is
    /// exactly what a buy landing now would be judged against (the handler's model says the same).
    function check_minimumBuyFollowsFloorPrizeAndEscalation() public view {
        uint256 escalator = WAD;
        for (uint256 i = 0; i < hook.qualifyingBuysInRound(); i++) {
            escalator = escalator * 105 / 100;
        }
        assertEq(hook.escalator(), escalator, "escalator is not 1.05^qualifying buys");

        bool pending = hook.settleable();
        uint256 pendingPrize = pending ? hook.bank() * (hook.roundsStarted() == 1 ? 2_000 : 500) / 10_000 : 0;
        assertEq(hook.pendingPrize(), pendingPrize, "pending prize");
        uint256 prizeBps = hook.roundNumber() == 1 ? 2_000 : 500;
        assertEq(
            hook.nextPrize(),
            (hook.bank() - pendingPrize) * prizeBps / 10_000,
            "next prize is not 20% (round 1) / 5% of the bank the next round starts from"
        );
        assertLe(hook.nextPrize() + pendingPrize, hook.bank(), "prizes promised exceed the bank");

        uint256 base = hook.nextPrize() / 5;
        if (base < FLOOR) base = FLOOR;
        assertEq(hook.minimumBuy(), base * (pending ? WAD : escalator) / WAD, "minimum buy formula");
        assertGe(hook.minimumBuy(), FLOOR, "minimum buy under the 8.5 IMD floor");
        assertEq(
            hook.minimumBuy(), handler.specMinimumNow(), "minimumBuy() differs from what a buy now is judged against"
        );
    }

    /// @notice Past winners are append-only and never rewritten; rounds are numbered 1, 2, 3, ...;
    /// round 1 never closed before launch + 3h; the list matches what the handler saw being paid.
    function check_pastWinnersAreAppendOnlyAndTruthful() public view {
        WinGameHook.Winner[] memory winners = hook.pastWinners();
        assertEq(winners.length, handler.ledgerLength(), "winners list length");
        uint256 awarded;
        for (uint256 i = 0; i < winners.length; i++) {
            WinGameHandler.LedgerEntry memory seen = handler.ledgerAt(i);
            assertEq(winners[i].round, i + 1, "round numbering");
            assertEq(winners[i].round, seen.round, "winner entry rewritten: round");
            assertEq(winners[i].winner, seen.winner, "winner entry rewritten: winner");
            assertEq(winners[i].prize, seen.prize, "winner entry rewritten: prize");
            assertEq(winners[i].settledAt, seen.settledAt, "winner entry rewritten: time");
            assertTrue(winners[i].winner != address(0), "round won by nobody");
            assertGt(winners[i].prize, 0, "a round paid nothing");
            if (i == 0) assertGe(winners[i].settledAt, launchTime + 3 hours, "round 1 closed before launch + 3h");
            if (i > 0) assertGe(winners[i].settledAt, winners[i - 1].settledAt, "winners out of order");
            awarded += winners[i].prize;
        }
        assertEq(awarded, handler.ghostPrizesAwarded(), "prizes listed != prizes awarded");
    }

    /// @notice The fee stays inside [3%, 50%], matches the brief's curve, and the one-call website
    /// view agrees with the individual getters.
    function check_feeAndWebsiteViewsAgree() public view {
        uint256 fee = hook.currentFeePips();
        assertGe(fee, 30_000);
        assertLe(fee, 500_000);
        assertEq(fee, handler.specFeePips(block.timestamp), "fee off the brief's linear curve");
        if (block.timestamp >= launchTime + 30 minutes) assertEq(fee, 30_000, "fee above base after 30 minutes");

        WinGameHook.GameState memory s = hook.gameState();
        bool pending = hook.settleable();
        assertEq(s.bank, hook.bankBalance());
        assertEq(s.bank, hook.bank());
        assertEq(s.nextPrize, hook.nextPrize());
        assertEq(s.minimumBuy, hook.minimumBuy());
        assertEq(s.timeLeft, hook.timeLeft());
        assertEq(s.roundNumber, hook.roundNumber());
        assertEq(s.feePips, fee);
        assertEq(s.teamOwed, hook.teamOwed());
        assertEq(s.winners, hook.winnersCount());
        assertEq(s.settleable, pending);
        assertEq(s.pendingPrize, hook.pendingPrize());
        if (pending) {
            // The round fields describe the round a buy would join (none yet); the closing round is
            // reported under pending*, so the website never shows a leader who can no longer be beaten.
            assertEq(s.leader, address(0), "view shows the expired round's leader as current");
            assertFalse(s.roundActive);
            assertEq(s.deadline, 0);
            assertEq(s.qualifyingBuysInRound, 0);
            assertEq(s.pendingRound, hook.roundsStarted());
            assertEq(s.pendingWinner, hook.leader());
            assertGt(s.pendingPrize, 0, "an expired round with nothing to pay");
            assertEq(s.pendingPrize, hook.bank() * (s.pendingRound == 1 ? 2_000 : 500) / 10_000);
        } else {
            assertEq(s.leader, hook.leader());
            assertEq(s.roundActive, hook.roundActive());
            assertEq(s.deadline, hook.deadline());
            assertEq(s.qualifyingBuysInRound, hook.qualifyingBuysInRound());
            assertEq(s.pendingRound, 0);
            assertEq(s.pendingWinner, address(0));
            assertEq(s.pendingPrize, 0);
        }
    }

    // ------------------------------------------------------------------ the harness is not vacuous

    /// @notice A fixed script through the handler reaches every branch the invariants rely on. If a
    /// refactor makes the handler stop trading or stop settling, this fails instead of the
    /// invariants quietly passing on an idle system.
    function test_handlerReachesEveryPath() public {
        handler.buyExactIn(0, 3 ether + 1, 0); // below the floor
        handler.buyAtThreshold(1, 1, 1); // one wei under the minimum
        handler.buyAtThreshold(1, 0, 3); // exactly the minimum, on someone else's behalf
        handler.buyAtThreshold(2, 2, 7); // above it, relayed
        handler.buyExactOut(3, 5_000_000 ether, 2);
        handler.buyAtThreshold(0, 1, 8); // one wei under, flagged must-lead: refused whole
        handler.buyAtThreshold(0, 0, 8); // exactly the minimum, flagged: leads
        handler.buyAtThreshold(1, 0, 9); // 64-byte payload without the flag, on someone's behalf
        handler.settle(0); // too early
        handler.sellExactIn(0, 30);
        handler.sellExactIn(1, 9); // flagged must-lead: a sell can never lead, refused whole
        handler.sellExactOut(1, 0.5 ether);
        handler.donateRaw(0, 10 ether);
        handler.donateClaims(1, 10 ether);
        handler.modifyLiquidity(3, 1e18, false);
        handler.modifyLiquidity(3, 1e18, true);
        handler.pokeCallbacks(2, -1 ether);
        handler.warp(2 hours, 0);
        handler.warp(2 hours, 0);
        handler.settle(3);
        handler.buyAtThreshold(0, 0, 0);
        handler.snipe(1, 0, 0); // last second
        handler.snipe(2, 1, 0); // exactly at the deadline: closes the round lazily
        handler.claimPrize(0, 1);
        handler.claimPrize(1, 1);
        handler.claimPrize(2, 1);
        handler.claimPrize(3, 1);
        handler.claimTeamFees(0);
        handler.warp(11 minutes, 1);
        handler.settle(1);

        assertEq(handler.violations(), 0, handler.firstViolation());
        assertGe(handler.buys(), 7, "handler.buys()");
        assertGe(handler.sells(), 2, "handler.sells()");
        assertGe(handler.sellExactOutFills(), 1, "handler.sellExactOutFills()");
        assertGe(handler.qualifyingBuys(), 5, "handler.qualifyingBuys()");
        assertGe(handler.nonQualifyingBuys(), 2, "handler.nonQualifyingBuys()");
        assertGe(handler.boundaryQualified(), 3, "handler.boundaryQualified()");
        assertGe(handler.boundaryRejected(), 1, "handler.boundaryRejected()");
        assertEq(handler.mustLeadRefusals(), 1, "handler.mustLeadRefusals()");
        assertGe(handler.mustLeadLeads(), 1, "handler.mustLeadLeads()");
        assertEq(handler.mustLeadSellRefusals(), 1, "handler.mustLeadSellRefusals()");
        assertGe(handler.roundsOpened(), 2, "handler.roundsOpened()");
        assertGe(handler.lazyCloses(), 1, "handler.lazyCloses()");
        assertGe(handler.settles(), 2, "handler.settles()");
        assertGe(handler.earlySettleAttempts(), 1, "handler.earlySettleAttempts()");
        assertGe(handler.prizeClaims(), 1, "handler.prizeClaims()");
        assertEq(handler.teamClaims(), 1, "handler.teamClaims()");
        assertEq(handler.donations(), 2, "handler.donations()");
        assertEq(handler.liquidityChanges(), 2, "handler.liquidityChanges()");
        assertGe(hook.winnersCount(), 3, "hook.winnersCount()");

        check_everyActionMatchesTheBrief();
        check_claimsEqualBankPlusTeamPlusUnclaimedPrizes();
        check_bankIsFedOnlyByFeesAndDrainedOnlyByPrizes();
        check_unclaimedPrizesAreAwardedMinusPaid();
        check_imdIsConservedAcrossTheSystem();
        check_winSupplyIsFixed();
        check_roundStateIsConsistent();
        check_minimumBuyFollowsFloorPrizeAndEscalation();
        check_pastWinnersAreAppendOnlyAndTruthful();
        check_feeAndWebsiteViewsAgree();
    }
}

/// @notice The same campaign with WIN as currency1.
contract WinGameHookInvariantFlippedTest is WinGameHookInvariantTest {
    function wantWinIsCurrency0() internal pure override returns (bool) {
        return false;
    }

    // Inline run counts are read per contract, so each variant restates them.

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 50
    function invariant_money() public view virtual override {
        super.invariant_money();
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 50
    function invariant_game() public view virtual override {
        super.invariant_game();
    }
}

/// @notice The campaign started after round 1 has been played and settled: base fee, 10-minute
/// rounds and 5% prizes from the first fuzzed call.
contract WinGameHookLaterRoundsInvariantTest is WinGameHookInvariantTest {
    function _prelude() internal virtual override {
        handler.warp(31 minutes, 0);
        handler.buyExactIn(0, 2_000 ether - 1, 0);
        handler.buyAtThreshold(1, 0, 0);
        handler.buyExactOut(2, 10_000_000 ether, 0);
        handler.sellExactIn(2, 50);
        handler.warp(2 hours, 0);
        handler.warp(2 hours, 0);
        handler.settle(0);
        require(hook.winnersCount() == 1 && !hook.roundActive(), "prelude: round 1 not settled");
        require(handler.violations() == 0, handler.firstViolation());
    }

    // Inline run counts are read per contract, so each variant restates them.

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 50
    function invariant_money() public view virtual override {
        super.invariant_money();
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 50
    function invariant_game() public view virtual override {
        super.invariant_game();
    }
}

/// @notice Later rounds with WIN as currency1.
contract WinGameHookLaterRoundsInvariantFlippedTest is WinGameHookLaterRoundsInvariantTest {
    function wantWinIsCurrency0() internal pure override returns (bool) {
        return false;
    }

    // Inline run counts are read per contract, so each variant restates them.

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 50
    function invariant_money() public view virtual override {
        super.invariant_money();
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 50
    function invariant_game() public view virtual override {
        super.invariant_game();
    }
}
