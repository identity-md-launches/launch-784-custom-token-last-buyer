// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WinToken} from "../src/WinToken.sol";

contract WinTokenTest is Test {
    WinToken token;
    address other = makeAddr("other");

    function setUp() public {
        token = new WinToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "WIN");
        assertEq(token.symbol(), "WIN");
        assertEq(token.decimals(), 18);
    }

    function test_mintsExactlyOneBillionToDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function test_transferMovesExactAmount() public {
        uint256 amount = 123_456 ether;
        assertTrue(token.transfer(other, amount));
        assertEq(token.balanceOf(other), amount);
        assertEq(token.balanceOf(address(this)), token.totalSupply() - amount);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_transferFromRespectsAllowance() public {
        token.approve(other, 10 ether);
        vm.prank(other);
        assertTrue(token.transferFrom(address(this), other, 4 ether));
        assertEq(token.allowance(address(this), other), 6 ether);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(WinToken.InsufficientAllowance.selector, 6 ether, 7 ether));
        token.transferFrom(address(this), other, 7 ether);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        token.approve(other, type(uint256).max);
        vm.prank(other);
        token.transferFrom(address(this), other, 1 ether);
        assertEq(token.allowance(address(this), other), type(uint256).max);
    }

    function test_revertsOnInsufficientBalance() public {
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(WinToken.InsufficientBalance.selector, 0, 1));
        token.transfer(address(this), 1);
    }

    function test_revertsOnTransferToZero() public {
        vm.expectRevert(WinToken.TransferToZeroAddress.selector);
        token.transfer(address(0), 1);
    }

    function test_noMintOrAdminEntryPoints() public {
        string[8] memory sigs = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(address,uint256)",
            "transferOwnership(address)",
            "setOwner(address)",
            "pause()",
            "upgradeTo(address)",
            "initialize(address)"
        ];
        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(sigs[i], other, type(uint128).max));
            assertFalse(ok, sigs[i]);
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(other), 0);
    }

    function test_runtimeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory code = address(token).code;
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }

    function testFuzz_transfer(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(this));
        amount = bound(amount, 0, token.totalSupply());
        token.transfer(to, amount);
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(address(this)) + amount, token.totalSupply());
    }
}
