// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";

/// @notice A swap router that, like Uniswap's Universal Router and the v4-periphery routers,
/// exposes `msgSender()`: the account that called it. Tokens are pulled from and paid to that
/// account. Modes let a test make the router lie, revert or return garbage.
contract MsgSenderRouter is IUnlockCallback {
    using CurrencySettler for Currency;
    using TransientStateLibrary for IPoolManager;

    enum Mode {
        Honest,
        Reverts,
        Garbage,
        Lies
    }

    IPoolManager public immutable manager;
    Mode public mode;
    address public liesAs;
    address internal _user;

    constructor(IPoolManager m) {
        manager = m;
    }

    function setMode(Mode m, address liar) external {
        mode = m;
        liesAs = liar;
    }

    /// @notice The account that opened this router's lock, in the shape the Universal Router uses.
    function msgSender() external view returns (address) {
        if (mode == Mode.Reverts) revert("msgSender unavailable");
        if (mode == Mode.Garbage) {
            assembly {
                mstore(0, not(0)) // a 32-byte word with dirty upper bits
                return(0, 32)
            }
        }
        if (mode == Mode.Lies) return liesAs;
        return _user;
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData)
        external
        returns (BalanceDelta delta)
    {
        _user = msg.sender;
        delta = abi.decode(manager.unlock(abi.encode(key, params, hookData)), (BalanceDelta));
        _user = address(0);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (PoolKey memory key, SwapParams memory params, bytes memory hookData) =
            abi.decode(rawData, (PoolKey, SwapParams, bytes));
        BalanceDelta delta = manager.swap(key, params, hookData);
        _settle(key.currency0);
        _settle(key.currency1);
        return abi.encode(delta);
    }

    function _settle(Currency currency) internal {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta < 0) currency.settle(manager, _user, uint256(-delta), false);
        if (delta > 0) currency.take(manager, _user, uint256(delta), false);
    }
}
