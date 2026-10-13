// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeskFixture} from "./helpers/DeskFixture.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {HandlerCards} from "../src/HandlerCards.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;

    function setUp() public {
        token = new LaunchToken();
    }

    function test_policySupplyMetadataAndPlainTransfer() public {
        assertEq(token.name(), "Handlers In Control");
        assertEq(token.symbol(), "HIC");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        address recipient = makeAddr("recipient");
        assertTrue(token.transfer(recipient, 123 ether));
        assertEq(token.balanceOf(recipient), 123 ether);
        assertEq(token.balanceOf(address(this)), 1e27 - 123 ether);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_allowanceAndInsufficientBalance() public {
        address spender = makeAddr("spender");
        address recipient = makeAddr("recipient");
        token.approve(spender, 100);
        vm.prank(spender);
        token.transferFrom(address(this), recipient, 75);
        assertEq(token.allowance(address(this), spender), 25);
        assertEq(token.balanceOf(recipient), 75);
        vm.prank(spender);
        vm.expectRevert();
        token.transferFrom(address(this), recipient, 26);
        vm.prank(recipient);
        vm.expectRevert();
        token.transfer(spender, 76);
    }

    function test_neitherDeployerNorStrangerHasAdminOrMintPaths() public {
        string[8] memory selectors = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "setMinter(address)",
            "pause()",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)"
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(selectors[i], address(this), 1 ether));
            assertFalse(ok);
            vm.prank(makeAddr("attacker"));
            (ok,) = address(token).call(abi.encodeWithSignature(selectors[i], address(this), 1 ether));
            assertFalse(ok);
            assertEq(token.totalSupply(), 1e27);
        }
    }

    function testFuzz_transferConservesFixedSupply(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        address recipient = makeAddr("recipient");
        token.transfer(recipient, amount);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(recipient), 1e27);
        assertEq(token.totalSupply(), 1e27);
    }
}

contract HandlerCardsTest is DeskFixture {
    function test_soulboundAndRequiredInterfaces() public {
        uint256 id = _mint(holder);
        assertEq(cards.name(), "Handler Cards");
        assertEq(cards.symbol(), "CARD");
        assertTrue(cards.locked(id));
        assertTrue(cards.supportsInterface(0x01ffc9a7));
        assertTrue(cards.supportsInterface(0x80ac58cd));
        assertTrue(cards.supportsInterface(0x5b5e139f));
        assertTrue(cards.supportsInterface(0xb45a3c0e));
        assertFalse(cards.supportsInterface(0xffffffff));
        assertEq(cards.desk(), address(desk));
        assertEq(address(cards.art()), address(art));
        vm.startPrank(holder);
        vm.expectRevert(HandlerCards.Soulbound.selector);
        cards.transferFrom(holder, other, id);
        vm.expectRevert(HandlerCards.Soulbound.selector);
        cards.safeTransferFrom(holder, other, id);
        vm.expectRevert(HandlerCards.Soulbound.selector);
        cards.safeTransferFrom(holder, other, id, bytes(""));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        cards.transferFrom(holder, address(0), id);
        vm.expectRevert(HandlerCards.Soulbound.selector);
        cards.approve(agent, id);
        vm.expectRevert(HandlerCards.Soulbound.selector);
        cards.setApprovalForAll(agent, true);
        vm.stopPrank();
        assertEq(cards.ownerOf(id), holder);
        assertEq(cards.getApproved(id), address(0));
        assertFalse(cards.isApprovedForAll(holder, agent));
    }

    function test_onlyDeskMintsAndNoDuplicateOrNonexistentCards() public {
        vm.expectRevert(HandlerCards.OnlyDesk.selector);
        cards.mint(holder, 1);
        uint256 id = _mint(holder);
        vm.prank(address(desk));
        vm.expectRevert(HandlerCards.Soulbound.selector);
        cards.mint(other, id);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 2));
        cards.locked(2);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 2));
        cards.tokenURI(2);
    }
}
