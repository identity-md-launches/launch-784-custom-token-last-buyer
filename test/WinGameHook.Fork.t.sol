// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";

import {WinGameFixture} from "./utils/WinGameFixture.sol";
import {WinGameHook} from "../src/WinGameHook.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice The launch rehearsal: initialize and seed single-sided, the first buy at 50% with no IMD
/// in the manager, decay, a sell, round 1 after three hours at 20%, a 10-minute round at 5% closed
/// lazily, the team pull to the fixed wallet.
///
/// The same four tests run twice:
///
///  * `WinGameHookRehearsalTest` / `...FlippedTest`: on a fresh vendored PoolManager, in every
///    `forge test`, with no network. This is the control: whatever the chain-specific run below
///    finds, the sequence itself is known to pass against the v4-core these contracts were built on.
///  * `WinGameHookForkTest` / `...FlippedTest`: on a fork of the selected chain, against the
///    PoolManager deployed there and, when given, the chain's real IMD. No chain was pinned to this
///    task, so the suite skips itself (forge reports it as skipped, never as passed) unless configured:
///
///      WIN_FORK_RPC_URL=<rpc> WIN_FORK_POOL_MANAGER=<address> [WIN_FORK_IMD=<address>] \
///        forge test --match-contract WinGameHookFork
///
///    Without `WIN_FORK_IMD` a stand-in IMD is deployed on the fork, which still exercises the real
///    manager's hook dispatch, flash accounting and ERC-6909 claims. Nothing here is a chain constant.
///
/// Last run against real managers (stand-in IMD, both orientations, 8/8 passed), 2026-10-06:
///   Base      0x498581fF718922c3f8e6A244956aF099B2652b2b at block 52,220,971
///   Arbitrum  0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32 at block 512,268,243
///   Ethereum  0x000000000004444c5dc75cB358380D2e3dE08A90 at block 26,132,399
/// What that leaves open until the chain and its IMD are selected: the real IMD's decimals and
/// transfer behaviour (`test_rehearsal_imdHasEighteenDecimals` is the gate), and WIN's ordering
/// against the real IMD address (both orderings pass; the factory initializes at the price for the
/// one it gets, see README §9).
abstract contract WinLaunchRehearsal is WinGameFixture {
    using StateLibrary for IPoolManager;

    // ------------------------------------------------------------------ preconditions of the launch

    /// @dev The hook's 8.5 IMD floor is the constant 8.5e18. If the chain's IMD does not have 18
    /// decimals the floor means something else entirely and the game cannot be played as briefed.
    function test_rehearsal_imdHasEighteenDecimals() public view {
        assertEq(imd.decimals(), 18, "MIN_BUY_FLOOR = 8.5e18 assumes an 18-decimal IMD");
    }

    function test_rehearsal_hookIsBoundToTheManagerAndThePool() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertTrue(hook.poolInitialized());
        assertEq(Currency.unwrap(hook.imd()), address(imd));
        assertEq(hook.launchTime(), launchTime);
        assertEq(hook.bank(), 0, "the bank starts empty");
        (uint160 sqrtPrice,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(sqrtPrice, TickMath.getSqrtPriceAtTick(launchTick()), "pool not at the 2,500 IMD market cap price");
        // Seeded with WIN only: no IMD and no ETH behind the pool, so the first fee has nothing to
        // be transferred from and must be minted as a claim.
        assertEq(imd.balanceOf(address(manager)) - managerImdAtLaunch, 0, "seeding moved IMD");
        assertApproxEqAbs(win.balanceOf(address(manager)), POOL_SHARE, 1e6, "pool did not receive 90% of the supply");
        assertLe(win.balanceOf(address(manager)), POOL_SHARE);
    }

    // ------------------------------------------------------------------ trading and the game

    /// @dev The very first trade: 50% fee, taken in IMD as a claim although the pool itself holds
    /// no IMD yet, and the buyer leads round 1 until launch + 3h.
    function test_rehearsal_firstBuyAtLaunchPaysHalfInFeeAndLeads() public {
        uint256 before = imd.balanceOf(alice);
        BalanceDelta delta = buyExactIn(alice, 8.5 ether);

        assertEq(before - imd.balanceOf(alice), 8.5 ether);
        assertGt(winDeltaOf(delta), 0);
        assertEq(hookImdClaims(), 4.25 ether, "50% of the IMD input");
        assertEq(hook.teamOwed(), 0.425 ether);
        assertEq(hook.bank(), 3.825 ether);
        assertEq(hook.leader(), alice);
        assertEq(hook.deadline(), launchTime + 3 hours);
        assertAccounting();
    }

    /// @dev A whole life cycle with real settlement: decay, both trade directions with the fee in
    /// IMD, round 1 (3 hours, 20%), round 2 (10 minutes, 5%), a lazily closed round, the team pull.
    function test_rehearsal_fullLifecycle() public {
        vm.warp(launchTime + 15 minutes);
        assertEq(hook.currentFeePips(), 265_000, "halfway through the decay");
        buyExactIn(alice, 100 ether);
        assertEq(hookImdClaims(), 26.5 ether);

        warpPastDecay();
        BalanceDelta bought = buyExactIn(bob, 200 ether);
        assertEq(hookImdClaims(), 26.5 ether + 6 ether);
        assertEq(hook.leader(), bob);

        // A sell pays its fee out of the IMD it receives and leaves the game alone.
        uint256 claims = hookImdClaims();
        uint256 bobImd = imd.balanceOf(bob);
        sellExactIn(bob, uint256(winDeltaOf(bought)) / 2);
        uint256 fee = hookImdClaims() - claims;
        uint256 received = imd.balanceOf(bob) - bobImd;
        assertGt(fee, 0);
        assertEq(fee, (received + fee) * 3 / 100, "3% of the IMD output");
        assertEq(hook.leader(), bob);
        assertEq(hook.deadline(), launchTime + 3 hours);
        assertEq(hookWinClaims(), 0, "no fee was taken in WIN");
        assertAccounting();

        // Round 1: not before three hours, then 20% of the bank in real tokens.
        vm.warp(launchTime + 3 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(WinGameHook.RoundNotOver.selector, uint64(launchTime + 3 hours)));
        hook.settle();
        vm.warp(launchTime + 3 hours);
        uint256 bank = hook.bank();
        assertEq(hook.pendingPrize(), bank * 20 / 100, "the expired round's prize is the pending one");
        bobImd = imd.balanceOf(bob);
        vm.prank(carol);
        hook.settle();
        assertEq(imd.balanceOf(bob) - bobImd, bank * 20 / 100);
        assertEq(hook.bank(), bank - bank * 20 / 100);
        assertAccounting();

        // Round 2: ten minutes, minimum back at the floor and rising 5%, prize 5%.
        assertEq(hook.minimumBuy(), 8.5 ether);
        buyExactIn(carol, 8.5 ether);
        assertEq(hook.minimumBuy(), 8.925 ether);
        buyExactIn(alice, 8.5 ether);
        assertEq(hook.leader(), carol, "below the raised minimum");
        assertEq(hook.timeLeft(), 10 minutes);
        vm.warp(block.timestamp + 10 minutes);

        // Closed lazily by the next buy, which cannot take the finished round.
        bank = hook.bank();
        buyExactIn(alice, 8.5 ether);
        assertEq(hook.winnerAt(1).winner, carol);
        assertEq(hook.winnerAt(1).prize, bank * 5 / 100);
        assertEq(hook.leader(), alice);
        uint256 carolImd = imd.balanceOf(carol);
        hook.claimPrize(carol);
        assertEq(imd.balanceOf(carol) - carolImd, bank * 5 / 100);

        // The team pulls its 10% to the fixed wallet.
        address team = hook.TEAM_WALLET();
        uint256 teamBefore = imd.balanceOf(team);
        uint256 owed = hook.teamOwed();
        hook.claimTeamFees();
        assertEq(imd.balanceOf(team) - teamBefore, owed);
        assertAccounting();
    }

    // ------------------------------------------------------------------ shared launch steps

    /// @dev IMD the manager held before this launch (non-zero on a fork of a live chain).
    uint256 internal managerImdAtLaunch;

    /// @dev WIN-only liquidity on the side of the price that holds WIN, exactly what the factory does.
    function _seedWinOnly() internal {
        win.approve(address(lpRouter), type(uint256).max);
        int24 tick = launchTick();
        int24 lower = winIsCurrency0 ? tick + TICK_SPACING : TickMath.minUsableTick(TICK_SPACING);
        int24 upper = winIsCurrency0 ? TickMath.maxUsableTick(TICK_SPACING) : tick - TICK_SPACING;
        uint128 liquidity = winIsCurrency0
            ? LiquidityAmounts.getLiquidityForAmount0(
                TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), POOL_SHARE
            )
            : LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), POOL_SHARE
            );
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), 0), "");
    }
}

/// @notice The rehearsal on a fresh vendored PoolManager: runs in every `forge test`, no network.
/// The fixture's own setUp is the launch (initialize at the briefed price, seed WIN only).
contract WinGameHookRehearsalTest is WinLaunchRehearsal {}

/// @notice The local rehearsal with WIN sorting after IMD.
contract WinGameHookRehearsalFlippedTest is WinGameHookRehearsalTest {
    function wantWinIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}

/// @notice The rehearsal on a fork of the selected chain, against the PoolManager deployed there.
contract WinGameHookForkTest is WinLaunchRehearsal {
    bool internal realImd;

    function setUp() public override {
        string memory rpc = vm.envOr("WIN_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            // A skip and not a return: forge counts it apart from passes, so "did not run" cannot
            // be read as "passed".
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        address managerAddress = vm.envAddress("WIN_FORK_POOL_MANAGER");
        require(managerAddress.code.length > 0, "WIN_FORK_POOL_MANAGER has no code on this chain");
        manager = PoolManager(managerAddress);

        address imdAddress = vm.envOr("WIN_FORK_IMD", address(0));
        realImd = imdAddress != address(0);
        if (realImd) require(imdAddress.code.length > 0, "WIN_FORK_IMD has no code on this chain");
        imd = realImd ? MockERC20(imdAddress) : new MockERC20("IdentityMD", "IMD", 0);

        win = _deployWinOrdered(address(imd), wantWinIsCurrency0());
        winIsCurrency0 = address(win) < address(imd);
        hook = deployHook(IPoolManager(address(manager)), address(win));

        (Currency c0, Currency c1) = winIsCurrency0
            ? (Currency.wrap(address(win)), Currency.wrap(address(imd)))
            : (Currency.wrap(address(imd)), Currency.wrap(address(win)));
        key = PoolKey({
            currency0: c0, currency1: c1, fee: LP_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(hook))
        });
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));

        // Launch: initialize and seed single-sided with 90% of the supply, no IMD and no ETH.
        managerImdAtLaunch = imd.balanceOf(address(manager));
        launchTime = block.timestamp;
        manager.initialize(key, TickMath.getSqrtPriceAtTick(launchTick()));
        _seedWinOnly();

        _fundOnFork(alice);
        _fundOnFork(bob);
        _fundOnFork(carol);
    }

    function _fundOnFork(address who) internal {
        if (realImd) deal(address(imd), who, 100_000 ether);
        else imd.mint(who, 100_000 ether);
        vm.startPrank(who);
        // Low-level approve: some real tokens return nothing.
        (bool ok,) =
            address(imd).call(abi.encodeWithSignature("approve(address,uint256)", swapRouter, type(uint256).max));
        require(ok, "IMD approve failed");
        win.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }
}

/// @notice The fork rehearsal with WIN sorting after IMD, as it may on the real chain.
contract WinGameHookForkFlippedTest is WinGameHookForkTest {
    function wantWinIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
