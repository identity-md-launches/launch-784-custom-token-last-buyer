// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "./MockERC20.sol";

interface ITransferHook {
    function onTokenReceived(address from, uint256 amount) external;
}

/// @notice An ERC-20 that calls the recipient on every transfer (ERC-777 style), so a test can try
/// to re-enter the hook from inside a prize or team payout.
contract ReentrantERC20 is MockERC20 {
    constructor() MockERC20("Reentrant IMD", "rIMD", 0) {}

    function _transfer(address from, address to, uint256 value) internal override {
        super._transfer(from, to, value);
        if (to.code.length > 0) {
            // Ignore the result: a recipient that reverts should not block an unrelated transfer.
            (bool ok,) = to.call(abi.encodeCall(ITransferHook.onTokenReceived, (from, value)));
            ok;
        }
    }
}
