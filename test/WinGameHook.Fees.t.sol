// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {WinGameFixture} from "./utils/WinGameFixture.sol";
import {WinGameHook} from "../src/WinGameHook.sol";

/// @notice Trading fee: anti-snipe decay, always in IMD on both sides, 90/10 split, team pull.
contract WinGameHookFeesTest is WinGameFixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 constant PIPS = 1_000_000;

    // ------------------------------------------------------------------ decay curve

    function test_feeDecay_isLinearFrom50To3PercentOver30Minutes() public view {
        assertEq(hook.feePipsAt(launchTime), 500_000, "launch");
        assertEq(hook.feePipsAt(launchTime - 1), 500_000, "before launch clamps");
        assertEq(hook.feePipsAt(launchTime + 900), 265_000, "half way");
        assertEq(hook.feePipsAt(launchTime + 600), 500_000 - uint256(470_000) * 600 / 1800, "ten minutes");
        assertEq(hook.feePipsAt(launchTime + 1799), 500_000 - uint256(470_000) * 1799 / 1800, "last second");
        assertEq(hook.feePipsAt(launchTime + 1800), 30_000, "end of window");
        assertEq(hook.feePipsAt(launchTime + 30 days), 30_000, "long after");
    }

    function test_feeDecay_appliesToTrades() public {
        buyExactIn(alice, 10 ether);
        assertEq(hookImdClaims(), 5 ether, "50% at launch");

        vm.warp(launchTime + 900);
        uint256 before = hookImdClaims();
        buyExactIn(bob, 10 ether);
        assertEq(hookImdClaims() - before, 2.65 ether, "26.5% half way");

        vm.warp(launchTime + 1800);
        before = hookImdClaims();
        buyExactIn(carol, 10 ether);
        assertEq(hookImdClaims() - before, 0.3 ether, "3% after the window");
        assertAccounting();
    }

    function testFuzz_feeDecay_neverOutsideBounds(uint256 elapsed) public view {
        elapsed = bound(elapsed, 0, 365 days);
        uint256 fee = hook.feePipsAt(launchTime + elapsed);
        assertLe(fee, 500_000);
        assertGe(fee, 30_000);
        if (elapsed > 0 && elapsed < 1800) assertLt(fee, 500_000);
    }

    // ------------------------------------------------------------------ fee always in IMD

    function test_buyExactIn_feeTakenFromImdInput() public {
        warpPastDecay();
        uint256 winBefore = win.balanceOf(alice);
        BalanceDelta d = buyExactIn(alice, 100 ether);

        assertEq(imdDeltaOf(d), -100 ether, "spends exactly the IMD asked");
        assertGt(winDeltaOf(d), 0);
        assertEq(win.balanceOf(alice) - winBefore, uint256(winDeltaOf(d)), "WIN received in full");
        assertEq(hookImdClaims(), 3 ether, "3% of the IMD input");
        assertEq(hookWinClaims(), 0, "no WIN fee");
        assertAccounting();
    }

    function test_buyExactOut_feeChargedOnTopInImd() public {
        warpPastDecay();
        BalanceDelta d = buyExactOut(alice, 1_000_000 ether, abi.encode(alice));

        assertEq(winDeltaOf(d), 1_000_000 ether, "receives exactly the WIN asked");
        uint256 paid = uint256(-imdDeltaOf(d));
        uint256 fee = hookImdClaims();
        uint256 poolIn = paid - fee;
        assertEq(fee, poolIn * 30_000 / (PIPS - 30_000), "fee is 3% of gross, charged on top of the pool input");
        assertApproxEqRel(fee * PIPS / paid, 30_000, 0.001e18, "effective rate on gross");
        assertEq(hookWinClaims(), 0);
        assertAccounting();
    }

    function test_sellExactIn_feeTakenFromImdOutput() public {
        warpPastDecay();
        giveWin(alice, 5_000_000 ether);
        buyExactIn(bob, 100 ether); // the pool starts with WIN only; a buy puts IMD in to sell into
        uint256 claimsBefore = hookImdClaims();
        uint256 imdBefore = imd.balanceOf(alice);
        BalanceDelta d = sellExactIn(alice, 1_000_000 ether);

        assertEq(winDeltaOf(d), -1_000_000 ether);
        uint256 received = uint256(imdDeltaOf(d));
        assertEq(imd.balanceOf(alice) - imdBefore, received);
        uint256 fee = hookImdClaims() - claimsBefore;
        uint256 poolOut = received + fee;
        assertEq(fee, poolOut * 30_000 / PIPS, "fee is 3% of the IMD the pool paid out");
        assertEq(hookWinClaims(), 0);
        assertAccounting();
    }

    function test_sellExactOut_feeChargedOnTopInImd() public {
        warpPastDecay();
        giveWin(alice, 5_000_000 ether);
        buyExactIn(bob, 100 ether);
        uint256 claimsBefore = hookImdClaims();
        BalanceDelta d = sellExactOut(alice, 1 ether);

        assertEq(imdDeltaOf(d), 1 ether, "receives exactly the IMD asked");
        assertLt(winDeltaOf(d), 0);
        assertEq(hookImdClaims() - claimsBefore, 1 ether * 30_000 / (PIPS - 30_000), "fee is 3% of the gross output");
        assertEq(hookWinClaims(), 0);
        assertAccounting();
    }

    function test_feesAtLaunchRateOnBothSides() public {
        giveWin(bob, 5_000_000 ether);
        buyExactIn(alice, 10 ether);
        assertEq(hookImdClaims(), 5 ether, "buy at 50%");

        uint256 before = hookImdClaims();
        BalanceDelta d = sellExactIn(bob, 1_000_000 ether);
        uint256 fee = hookImdClaims() - before;
        uint256 poolOut = uint256(imdDeltaOf(d)) + fee;
        assertEq(fee, poolOut / 2, "sell at 50%");
        assertAccounting();
    }

    function testFuzz_buyExactIn_feeIsRateOfGross(uint256 amount, uint256 elapsed) public {
        amount = bound(amount, 1e12, 1_000_000 ether);
        elapsed = bound(elapsed, 0, 3 hours);
        vm.warp(launchTime + elapsed);
        uint256 rate = hook.currentFeePips();
        buyExactIn(alice, amount);
        assertEq(hookImdClaims(), amount * rate / PIPS);
        assertAccounting();
    }

    function testFuzz_sellExactOut_userGetsExactlyWhatWasAsked(uint256 amount) public {
        warpPastDecay();
        giveWin(alice, 50_000_000 ether);
        buyExactIn(bob, 200 ether);
        uint256 claimsBefore = hookImdClaims();
        amount = bound(amount, 1e12, 50 ether);
        BalanceDelta d = sellExactOut(alice, amount);
        assertEq(imdDeltaOf(d), int256(amount));
        assertEq(hookImdClaims() - claimsBefore, amount * 30_000 / (PIPS - 30_000));
    }

    // ------------------------------------------------------------------ fresh manager

    function test_firstBuyWorksWhenManagerHoldsNoImd() public {
        // The pool was seeded with WIN only and the router settles after the swap, so the manager
        // has zero IMD while afterSwap runs. The fee is minted as a claim, never transferred.
        assertEq(imd.balanceOf(address(manager)), 0);
        buyExactIn(alice, 8.5 ether);
        assertEq(hookImdClaims(), 4.25 ether);
        assertEq(imd.balanceOf(address(manager)), 8.5 ether, "router settled the full gross afterwards");
        assertAccounting();
    }

    // ------------------------------------------------------------------ 90 / 10 split

    function test_feeSplit_90PercentBank_10PercentTeam() public {
        warpPastDecay();
        buyExactIn(alice, 100 ether);
        assertEq(hook.bank(), 2.7 ether);
        assertEq(hook.teamOwed(), 0.3 ether);
        assertEq(hook.bankBalance(), hook.bank());

        giveWin(bob, 5_000_000 ether);
        uint256 before = hookImdClaims();
        sellExactIn(bob, 1_000_000 ether);
        uint256 fee = hookImdClaims() - before;
        assertEq(hook.teamOwed(), 0.3 ether + fee / 10);
        assertEq(hook.bank(), 2.7 ether + fee - fee / 10);
        assertAccounting();
    }

    function test_teamFees_arePullBasedToFixedWallet() public {
        warpPastDecay();
        buyExactIn(alice, 100 ether);
        uint256 owed = hook.teamOwed();
        assertEq(owed, 0.3 ether);

        vm.prank(carol); // anyone may trigger, the money only ever goes to the team wallet
        hook.claimTeamFees();

        assertEq(imd.balanceOf(hook.TEAM_WALLET()), owed);
        assertEq(hook.teamOwed(), 0);
        assertEq(hook.bank(), 2.7 ether, "bank untouched");
        assertAccounting();

        vm.expectRevert(WinGameHook.NothingToClaim.selector);
        hook.claimTeamFees();
    }

    function test_teamWalletIsTheBriefsAddress() public view {
        assertEq(hook.TEAM_WALLET(), 0x611F08c7226591708B5F53F29BF53f3830D54511);
    }

    // ------------------------------------------------------------------ partial fills

    function test_partialFill_exactInBuyReverts() public {
        warpPastDecay();
        bool zeroForOne = !winIsCurrency0;
        // A price limit right at the current price: the pool cannot consume the full input.
        uint160 limit = TickMath.getSqrtPriceAtTick(winIsCurrency0 ? launchTick() + 1 : launchTick() - 1);
        vm.expectRevert();
        _swap(alice, SwapParams(zeroForOne, -int256(10 ether), limit), abi.encode(alice));
    }

    function test_partialFill_exactOutSellReverts() public {
        warpPastDecay();
        giveWin(alice, 5_000_000 ether);
        buyExactIn(bob, 50 ether); // move the price into the liquidity so a sell is possible at all
        bool zeroForOne = winIsCurrency0;
        (uint160 sqrtPrice,,,) = _slot0();
        // Limit a hair away from the current price so the requested output cannot be reached.
        uint160 limit = zeroForOne ? sqrtPrice - sqrtPrice / 100_000 : sqrtPrice + sqrtPrice / 100_000;
        vm.expectRevert();
        _swap(alice, SwapParams(zeroForOne, int256(5 ether), limit), abi.encode(alice));
    }

    function _slot0() internal view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) {
        return IPoolManager(address(manager)).getSlot0(key.toId());
    }
}

/// @notice The same suite with WIN as currency1, so the buy/sell orientation logic is covered both ways.
contract WinGameHookFeesFlippedTest is WinGameHookFeesTest {
    function wantWinIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
