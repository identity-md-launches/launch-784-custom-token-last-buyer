// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {DeployWin} from "../script/DeployWin.s.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {WinToken} from "../src/WinToken.sol";
import {WinGameHook} from "../src/WinGameHook.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DeployWinTest is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function test_deployProducesTokenAndHookBoundToThePoolManager() public {
        PoolManager manager = new PoolManager(address(this));
        DeployWin script = new DeployWin();

        (WinToken token, WinGameHook hook, bytes32 salt) = script.deploy(
            DeployWin.Config({poolManager: IPoolManager(address(manager)), create2Deployer: address(script)})
        );

        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(script)), token.totalSupply(), "minted to whoever deployed it");
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.winToken(), address(token));
        assertTrue(HookFlags.matches(address(hook), script.HOOK_FLAGS()));
        assertEq(
            address(hook),
            HookFlags.computeAddress(
                address(script),
                salt,
                keccak256(
                    abi.encodePacked(type(WinGameHook).creationCode, abi.encode(address(manager), address(token)))
                )
            )
        );

        // The deployed pair is usable: its pool initializes against any other currency.
        MockERC20 imd = new MockERC20("IdentityMD", "IMD", 0);
        (address c0, address c1) =
            address(token) < address(imd) ? (address(token), address(imd)) : (address(imd), address(token));
        PoolKey memory key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3_000, 60, IHooks(address(hook)));
        manager.initialize(key, SQRT_PRICE_1_1);
        assertTrue(hook.poolInitialized());
        assertEq(Currency.unwrap(hook.imd()), address(imd));
    }

    function test_mineSaltIsDeterministicAndFindsTheFlags() public pure {
        bytes memory initCode = hex"600a600c600039600a6000f3602a60005260206000f3";
        (bytes32 s1, address a1) = HookFlags.mineSalt(address(0xBEEF), initCode, HookFlags.BEFORE_SWAP, 1_000_000);
        (bytes32 s2, address a2) = HookFlags.mineSalt(address(0xBEEF), initCode, HookFlags.BEFORE_SWAP, 1_000_000);
        assertEq(s1, s2);
        assertEq(a1, a2);
        assertTrue(HookFlags.matches(a1, HookFlags.BEFORE_SWAP));
        assertEq(HookFlags.flagsOf(a1), HookFlags.BEFORE_SWAP);
    }
}
