// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "./MockERC20.sol";

/// @notice An ERC-20 that refuses transfers to one address, standing in for an IMD token with a
/// blocklist (or any recipient the token will not credit).
contract BlocklistERC20 is MockERC20 {
    address public blocked;

    constructor() MockERC20("Blocklisted IMD", "bIMD", 0) {}

    function setBlocked(address who) external {
        blocked = who;
    }

    function _transfer(address from, address to, uint256 value) internal override {
        require(to != blocked, "BlocklistERC20: recipient blocked");
        super._transfer(from, to, value);
    }
}
