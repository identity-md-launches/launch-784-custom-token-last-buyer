// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {HookFlags} from "../src/HookFlags.sol";
import {WinToken} from "../src/WinToken.sol";
import {WinGameHook} from "../src/WinGameHook.sol";

/// @notice Reference deployment of the WIN token and the game hook.
/// @dev The IdentityMD launch factory performs the real launch: it deploys the token, then the hook
/// at a mined address with `$poolManager` and `$token`, initializes the pool and seeds it, all in
/// one transaction. This script reproduces the same steps for a local chain or a rehearsal and is
/// what the tests exercise through `deploy`. `run` only reads the environment and forwards the
/// config. With `initializePool` set, `deploy` also initializes the WIN/paired pool at the briefed
/// starting price for the ordering the addresses give, in the same call, so the hook is never left
/// deployed-but-unbound for a stranger to initialize against another pool.
contract DeployWin is Script {
    uint160 public constant HOOK_FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;

    /// @dev Foundry routes `new X{salt: s}` through this factory while broadcasting.
    address public constant DETERMINISTIC_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev The launch policy's 0.3% tier and its tick spacing.
    uint24 public constant POOL_FEE = 3_000;
    int24 public constant TICK_SPACING = 60;

    struct Config {
        IPoolManager poolManager;
        /// @dev Address that executes the CREATE2: the script contract in tests, the factory when broadcasting.
        address create2Deployer;
        /// @dev The chain's IMD token (the pool's other currency). Only read when `initializePool` is set.
        address pairedCurrency;
        /// @dev Initialize the WIN/paired pool at the briefed starting price in the same call.
        bool initializePool;
    }

    function run() external {
        Config memory cfg = Config({
            poolManager: IPoolManager(vm.envAddress("POOL_MANAGER")),
            create2Deployer: DETERMINISTIC_DEPLOYER,
            pairedCurrency: vm.envOr("IMD_TOKEN", address(0)),
            initializePool: vm.envOr("INITIALIZE_POOL", false)
        });
        vm.startBroadcast();
        deploy(cfg);
        vm.stopBroadcast();
    }

    function deploy(Config memory cfg) public returns (WinToken token, WinGameHook hook, bytes32 salt) {
        token = new WinToken();
        bytes memory initCode =
            abi.encodePacked(type(WinGameHook).creationCode, abi.encode(cfg.poolManager, address(token)));
        address predicted;
        (salt, predicted) = HookFlags.mineSalt(cfg.create2Deployer, initCode, HOOK_FLAGS, 1_000_000);
        hook = new WinGameHook{salt: salt}(cfg.poolManager, address(token));
        require(address(hook) == predicted, "hook landed on an unexpected address");

        if (cfg.initializePool) {
            bool winIsCurrency0 = address(token) < cfg.pairedCurrency;
            (address c0, address c1) =
                winIsCurrency0 ? (address(token), cfg.pairedCurrency) : (cfg.pairedCurrency, address(token));
            PoolKey memory key =
                PoolKey(Currency.wrap(c0), Currency.wrap(c1), POOL_FEE, TICK_SPACING, IHooks(address(hook)));
            cfg.poolManager.initialize(key, hook.launchSqrtPriceX96(winIsCurrency0));
        }
    }
}
