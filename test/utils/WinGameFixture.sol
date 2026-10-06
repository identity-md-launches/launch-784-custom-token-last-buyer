// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";

import {HookFlags} from "../../src/HookFlags.sol";
import {WinToken} from "../../src/WinToken.sol";
import {WinGameHook} from "../../src/WinGameHook.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Shared setup: a fresh PoolManager, a mock IMD, the WIN token, the hook at a mined
/// address, and the WIN/IMD pool seeded single-sided with 90% of the supply at a 2,500 IMD market
/// cap, exactly as the launch does. Nothing here depends on chain state, so the same suite runs
/// unchanged under `forge test --fork-url <rpc>` for the selected chain.
abstract contract WinGameFixture is Test {
    uint160 internal constant HOOK_FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;

    uint24 internal constant LP_FEE = 3_000;
    int24 internal constant TICK_SPACING = 60;
    /// @dev 2,500 IMD / 1e9 WIN = 2.5e-6 IMD per WIN; log_1.0001(2.5e-6) ~ -128,992, rounded to spacing.
    int24 internal constant LAUNCH_TICK_ABS = 129_000;
    uint256 internal constant POOL_SHARE = 900_000_000 ether;
    uint256 internal constant IMD_FUNDING = 10_000_000 ether;

    PoolManager internal manager;
    WinToken internal win;
    MockERC20 internal imd;
    WinGameHook internal hook;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    PoolKey internal key;
    bool internal winIsCurrency0;
    uint256 internal launchTime;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal sniper = makeAddr("sniper");

    /// @dev Which side of the pool WIN sits on. Both orientations are exercised by the suites.
    function wantWinIsCurrency0() internal pure virtual returns (bool) {
        return true;
    }

    function newImd() internal virtual returns (MockERC20) {
        return new MockERC20("IdentityMD", "IMD", 0);
    }

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        manager = new PoolManager(address(this));
        imd = newImd();
        win = _deployWinOrdered(address(imd), wantWinIsCurrency0());
        winIsCurrency0 = address(win) < address(imd);
        assertEq(winIsCurrency0, wantWinIsCurrency0(), "orientation");

        hook = deployHook(manager, address(win));

        (Currency c0, Currency c1) = winIsCurrency0
            ? (Currency.wrap(address(win)), Currency.wrap(address(imd)))
            : (Currency.wrap(address(imd)), Currency.wrap(address(win)));
        key = PoolKey({
            currency0: c0, currency1: c1, fee: LP_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(hook))
        });

        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);

        launchTime = block.timestamp;
        manager.initialize(key, TickMath.getSqrtPriceAtTick(launchTick()));
        _seedSingleSided();

        _fund(alice);
        _fund(bob);
        _fund(carol);
        _fund(sniper);
    }

    // ------------------------------------------------------------------ deployment helpers

    function deployHook(IPoolManager pm, address token) internal returns (WinGameHook deployed) {
        bytes memory initCode = abi.encodePacked(type(WinGameHook).creationCode, abi.encode(pm, token));
        (bytes32 salt, address predicted) = HookFlags.mineSalt(address(this), initCode, HOOK_FLAGS, 300_000);
        deployed = new WinGameHook{salt: salt}(pm, token);
        assertEq(address(deployed), predicted, "hook address");
        assertTrue(HookFlags.matches(address(deployed), HOOK_FLAGS), "hook flags");
    }

    /// @dev Deploys WIN with a CREATE2 salt chosen so that it sorts before (or after) `other`.
    function _deployWinOrdered(address other, bool before) internal returns (WinToken token) {
        bytes32 initHash = keccak256(type(WinToken).creationCode);
        for (uint256 i = 0; i < 1_000; i++) {
            address predicted = HookFlags.computeAddress(address(this), bytes32(i), initHash);
            if ((predicted < other) == before) {
                token = new WinToken{salt: bytes32(i)}();
                assertEq(address(token), predicted, "win address");
                return token;
            }
        }
        revert("no ordering salt");
    }

    function launchTick() internal view returns (int24) {
        return winIsCurrency0 ? -LAUNCH_TICK_ABS : LAUNCH_TICK_ABS;
    }

    /// @dev WIN-only liquidity on the side of the price that holds WIN: above it when WIN is
    /// currency0, below it when WIN is currency1. No IMD enters the pool.
    function _seedSingleSided() internal {
        win.approve(address(lpRouter), type(uint256).max);
        int24 tick = launchTick();
        int24 lower;
        int24 upper;
        uint128 liquidity;
        if (winIsCurrency0) {
            lower = tick + TICK_SPACING;
            upper = TickMath.maxUsableTick(TICK_SPACING);
            liquidity = LiquidityAmounts.getLiquidityForAmount0(
                TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), POOL_SHARE
            );
        } else {
            lower = TickMath.minUsableTick(TICK_SPACING);
            upper = tick - TICK_SPACING;
            liquidity = LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), POOL_SHARE
            );
        }
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), 0), "");
        assertEq(imd.balanceOf(address(manager)), 0, "pool must hold no IMD after seeding");
    }

    function _fund(address who) internal {
        imd.mint(who, IMD_FUNDING);
        vm.startPrank(who);
        imd.approve(address(swapRouter), type(uint256).max);
        win.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ trading helpers

    function _swap(address actor, SwapParams memory params, bytes memory hookData) internal returns (BalanceDelta) {
        vm.prank(actor, actor);
        return swapRouter.swap(key, params, PoolSwapTest.TestSettings(false, false), hookData);
    }

    function _limit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    /// @notice Buy WIN spending exactly `imdAmount` IMD (fee included). `hookData` names the buyer.
    function buyExactIn(address actor, uint256 imdAmount, bytes memory hookData) internal returns (BalanceDelta) {
        bool zeroForOne = !winIsCurrency0;
        return _swap(actor, SwapParams(zeroForOne, -int256(imdAmount), _limit(zeroForOne)), hookData);
    }

    function buyExactIn(address actor, uint256 imdAmount) internal returns (BalanceDelta) {
        return buyExactIn(actor, imdAmount, abi.encode(actor));
    }

    /// @notice Buy exactly `winAmount` WIN, paying whatever IMD it costs plus the fee.
    function buyExactOut(address actor, uint256 winAmount, bytes memory hookData) internal returns (BalanceDelta) {
        bool zeroForOne = !winIsCurrency0;
        return _swap(actor, SwapParams(zeroForOne, int256(winAmount), _limit(zeroForOne)), hookData);
    }

    /// @notice Sell exactly `winAmount` WIN for IMD.
    function sellExactIn(address actor, uint256 winAmount) internal returns (BalanceDelta) {
        bool zeroForOne = winIsCurrency0;
        return _swap(actor, SwapParams(zeroForOne, -int256(winAmount), _limit(zeroForOne)), abi.encode(actor));
    }

    /// @notice Sell WIN to receive exactly `imdAmount` IMD after the fee.
    function sellExactOut(address actor, uint256 imdAmount) internal returns (BalanceDelta) {
        bool zeroForOne = winIsCurrency0;
        return _swap(actor, SwapParams(zeroForOne, int256(imdAmount), _limit(zeroForOne)), abi.encode(actor));
    }

    function imdDeltaOf(BalanceDelta delta) internal view returns (int256) {
        return winIsCurrency0 ? int256(delta.amount1()) : int256(delta.amount0());
    }

    function winDeltaOf(BalanceDelta delta) internal view returns (int256) {
        return winIsCurrency0 ? int256(delta.amount0()) : int256(delta.amount1());
    }

    // ------------------------------------------------------------------ state helpers

    function hookImdClaims() internal view returns (uint256) {
        return manager.balanceOf(address(hook), Currency.wrap(address(imd)).toId());
    }

    function hookWinClaims() internal view returns (uint256) {
        return manager.balanceOf(address(hook), Currency.wrap(address(win)).toId());
    }

    /// @dev Every IMD the hook controls is accounted for: bank + team share + prizes awaiting pickup.
    function assertAccounting() internal view {
        assertEq(
            hookImdClaims(),
            hook.bank() + hook.teamOwed() + hook.totalUnclaimedPrizes(),
            "claims != bank+team+unclaimed"
        );
        assertEq(hookWinClaims(), 0, "hook must never hold WIN");
        assertEq(imd.balanceOf(address(hook)), 0, "hook must hold no raw IMD");
    }

    function warpPastDecay() internal {
        vm.warp(launchTime + hook.FEE_DECAY_DURATION());
    }

    function warpPastFirstRoundFloor() internal {
        vm.warp(launchTime + hook.FIRST_ROUND_MIN_DURATION());
    }

    function giveWin(address who, uint256 amount) internal {
        win.transfer(who, amount);
    }
}
