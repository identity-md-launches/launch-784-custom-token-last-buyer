// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {WinGameFixture} from "./utils/WinGameFixture.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {WinToken} from "../src/WinToken.sol";
import {WinGameHook} from "../src/WinGameHook.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ReentrantERC20} from "./mocks/ReentrantERC20.sol";

/// @notice A router that tries to settle the game from inside its own unlock callback, i.e. in the
/// same manager lock as a swap would run in.
contract SettleInsideUnlockRouter is IUnlockCallback {
    IPoolManager immutable manager;
    WinGameHook immutable hook;

    constructor(IPoolManager m, WinGameHook h) {
        manager = m;
        hook = h;
    }

    function attack() external {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        hook.settle();
        return "";
    }
}

/// @notice A prize recipient that re-enters the hook from the token transfer callback.
contract ReentrantWinner {
    WinGameHook public hook;
    uint256 public attempts;
    uint256 public failures;

    function setHook(WinGameHook h) external {
        hook = h;
    }

    function onTokenReceived(address, uint256) external {
        attempts++;
        try hook.settle() {}
        catch {
            failures++;
        }
        try hook.claimPrize(address(this)) {}
        catch {
            failures++;
        }
        try hook.claimTeamFees() {}
        catch {
            failures++;
        }
    }
}

/// @notice Access control, initialization guards, reentrancy and the absence of escape hatches.
contract WinGameHookSecurityTest is WinGameFixture {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    // ------------------------------------------------------------------ callbacks and permissions

    function test_permissionsMatchTheMinedAddress() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize);
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta);
        assertTrue(p.afterSwapReturnDelta);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity || p.afterRemoveLiquidity);
        assertFalse(p.beforeDonate || p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta);
        assertEq(HookFlags.flagsOf(address(hook)), HOOK_FLAGS);
    }

    function test_constructorRefusesAddressWithoutTheFlags() public {
        vm.expectRevert();
        new WinGameHook(manager, address(win)); // plain CREATE: wrong low bits
    }

    function test_constructorRefusesZeroOrCodelessToken() public {
        bytes memory initCode = abi.encodePacked(type(WinGameHook).creationCode, abi.encode(manager, address(0)));
        (bytes32 salt,) = HookFlags.mineSalt(address(this), initCode, HOOK_FLAGS, 300_000);
        vm.expectRevert(WinGameHook.ZeroAddress.selector);
        new WinGameHook{salt: salt}(manager, address(0));

        address noCode = makeAddr("nocode");
        initCode = abi.encodePacked(type(WinGameHook).creationCode, abi.encode(manager, noCode));
        (salt,) = HookFlags.mineSalt(address(this), initCode, HOOK_FLAGS, 300_000);
        vm.expectRevert(WinGameHook.TokenHasNoCode.selector);
        new WinGameHook{salt: salt}(manager, noCode);
    }

    function test_enabledCallbacksRefuseCallersOtherThanThePoolManager() public {
        vm.expectRevert(WinGameHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);

        vm.expectRevert(WinGameHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2), "");

        vm.expectRevert(WinGameHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2), BalanceDelta.wrap(0), "");

        vm.expectRevert(WinGameHook.NotPoolManager.selector);
        hook.unlockCallback("");
    }

    function test_disabledCallbacksRevert() public {
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1 ether, 0);
        vm.startPrank(address(manager));
        vm.expectRevert(WinGameHook.HookNotImplemented.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(WinGameHook.HookNotImplemented.selector);
        hook.beforeAddLiquidity(address(this), key, lp, "");
        vm.expectRevert(WinGameHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(address(this), key, lp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
        vm.expectRevert(WinGameHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(this), key, lp, "");
        vm.expectRevert(WinGameHook.HookNotImplemented.selector);
        hook.afterRemoveLiquidity(address(this), key, lp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
        vm.expectRevert(WinGameHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
        vm.expectRevert(WinGameHook.HookNotImplemented.selector);
        hook.afterDonate(address(this), key, 1, 1, "");
        vm.stopPrank();
    }

    function test_managerCannotBeMadeToCallUnlockCallbackOutsideAPayout() public {
        // Even the manager cannot push a payout: with no payout in progress the callback refuses.
        vm.prank(address(manager));
        vm.expectRevert(WinGameHook.UnexpectedUnlock.selector);
        hook.unlockCallback("");
    }

    function test_runtimeCodeHasNoEscapeHatch() public view {
        bytes memory code = address(hook).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576, "EIP-170");
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff, "SELFDESTRUCT");
            assertTrue(op != 0xf4, "DELEGATECALL");
            assertTrue(op != 0xf2, "CALLCODE");
        }
    }

    function test_noAdminEntryPoints() public {
        string[10] memory sigs = [
            "withdraw(uint256)",
            "withdraw(address,uint256)",
            "sweep(address)",
            "setTeamWallet(address)",
            "setFee(uint256)",
            "pause()",
            "transferOwnership(address)",
            "owner()",
            "upgradeTo(address)",
            "initialize(address)"
        ];
        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = address(hook).call(abi.encodeWithSignature(sigs[i], address(this), uint256(1)));
            assertFalse(ok, sigs[i]);
        }
    }

    // ------------------------------------------------------------------ initialization guards

    function test_initialize_recordsLaunch() public view {
        assertTrue(hook.poolInitialized());
        assertEq(hook.launchTime(), launchTime);
        assertEq(Currency.unwrap(hook.imd()), address(imd));
        assertEq(hook.winIsCurrency0(), winIsCurrency0);
    }

    function test_initialize_secondPoolWithThisHookIsRefused() public {
        PoolKey memory other = key;
        other.fee = 500;
        other.tickSpacing = 10;
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(WinGameHook.PoolAlreadyInitialized.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(other, TickMath.getSqrtPriceAtTick(launchTick()));
    }

    function _freshHookAndToken() internal returns (WinGameHook fresh, WinToken token) {
        token = new WinToken();
        fresh = deployHook(manager, address(token));
    }

    function _keyFor(address a, address b, uint24 fee, int24 spacing, WinGameHook h)
        internal
        pure
        returns (PoolKey memory)
    {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, spacing, IHooks(address(h)));
    }

    function test_initialize_refusesFeesOutsideTheLaunchTiers() public {
        (WinGameHook fresh, WinToken token) = _freshHookAndToken();
        uint24[4] memory bad = [uint24(0), uint24(100), uint24(2_500), uint24(0x800000)];
        for (uint256 i = 0; i < bad.length; i++) {
            PoolKey memory k = _keyFor(address(token), address(imd), bad[i], 60, fresh);
            vm.expectRevert();
            manager.initialize(k, SQRT_PRICE_1_1);
        }
        assertFalse(fresh.poolInitialized());
    }

    function test_initialize_acceptsEveryLaunchTier() public {
        uint24[3] memory tiers = [uint24(500), uint24(3_000), uint24(10_000)];
        int24[3] memory spacings = [int24(10), int24(60), int24(200)];
        for (uint256 i = 0; i < tiers.length; i++) {
            (WinGameHook fresh, WinToken token) = _freshHookAndToken();
            PoolKey memory k = _keyFor(address(token), address(imd), tiers[i], spacings[i], fresh);
            manager.initialize(k, SQRT_PRICE_1_1);
            assertTrue(fresh.poolInitialized());
            assertEq(Currency.unwrap(fresh.imd()), address(imd));
        }
    }

    function test_initialize_refusesPoolWithoutWin() public {
        (WinGameHook fresh,) = _freshHookAndToken();
        MockERC20 other = new MockERC20("Other", "OTH", 0);
        PoolKey memory k = _keyFor(address(other), address(imd), 3_000, 60, fresh);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(fresh),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(WinGameHook.PoolMustPairWinToken.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    function test_initialize_acceptsNativePairAndReadsItAsTheOtherCurrency() public {
        (WinGameHook fresh, WinToken token) = _freshHookAndToken();
        PoolKey memory k = _keyFor(address(token), address(0), 3_000, 60, fresh);
        manager.initialize(k, SQRT_PRICE_1_1);
        assertEq(Currency.unwrap(fresh.imd()), address(0));
        assertFalse(fresh.winIsCurrency0());
    }

    // ------------------------------------------------------------------ reentrancy and lock misuse

    function test_settleCannotRunInsideAManagerLock() public {
        warpPastDecay();
        buyExactIn(alice, hook.minimumBuy());
        warpPastFirstRoundFloor();
        SettleInsideUnlockRouter router = new SettleInsideUnlockRouter(manager, hook);
        vm.expectRevert();
        router.attack();
        assertTrue(hook.roundActive(), "nothing settled");
        hook.settle(); // and the plain path still works afterwards
    }
}

/// @notice Reentrancy through a token with transfer callbacks standing in for IMD.
contract WinGameHookReentrancyTest is WinGameFixture {
    ReentrantWinner attacker;

    function newImd() internal override returns (MockERC20) {
        return MockERC20(address(new ReentrantERC20()));
    }

    function setUp() public override {
        super.setUp();
        attacker = new ReentrantWinner();
        attacker.setHook(hook);
    }

    function test_prizePayoutCannotBeReentered() public {
        warpPastDecay();
        buyExactIn(alice, hook.minimumBuy(), abi.encode(address(attacker)));
        assertEq(hook.leader(), address(attacker));
        warpPastFirstRoundFloor();
        uint256 prize = hook.nextPrize();

        hook.settle();

        assertEq(attacker.attempts(), 1, "callback ran");
        assertEq(attacker.failures(), 3, "settle, claimPrize and claimTeamFees all refused");
        assertEq(imd.balanceOf(address(attacker)), prize, "paid exactly once");
        assertEq(hook.unclaimedPrize(address(attacker)), 0);
        assertAccounting();
    }

    function test_lazyPrizeClaimCannotBeReentered() public {
        warpPastDecay();
        buyExactIn(alice, hook.minimumBuy(), abi.encode(address(attacker)));
        warpPastFirstRoundFloor();
        buyExactIn(bob, 1 ether); // closes round 1 lazily
        uint256 prize = hook.unclaimedPrize(address(attacker));
        assertGt(prize, 0);

        hook.claimPrize(address(attacker));
        assertEq(attacker.failures(), 3);
        assertEq(imd.balanceOf(address(attacker)), prize);
        assertAccounting();
    }

    function test_teamPayoutCannotBeReentered() public {
        warpPastDecay();
        buyExactIn(alice, 100 ether);
        uint256 owed = hook.teamOwed();
        // Put the attacker's code at the team wallet so the transfer callback fires there.
        vm.etch(hook.TEAM_WALLET(), address(attacker).code);
        ReentrantWinner(hook.TEAM_WALLET()).setHook(hook);

        hook.claimTeamFees();

        assertEq(ReentrantWinner(hook.TEAM_WALLET()).failures(), 3);
        assertEq(imd.balanceOf(hook.TEAM_WALLET()), owed);
        assertEq(hook.teamOwed(), 0);
        assertAccounting();
    }
}
