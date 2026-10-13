// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HandlerDesk} from "../../src/HandlerDesk.sol";
import {HandlerCards} from "../../src/HandlerCards.sol";
import {HandlerArt} from "../../src/HandlerArt.sol";
import {MockToken, MockPoolManager} from "./Mocks.sol";

abstract contract DeskFixture is Test {
    HandlerDesk internal desk;
    HandlerCards internal cards;
    HandlerArt internal art;
    MockToken internal imd;
    MockToken internal hic;
    MockToken internal coin;
    MockPoolManager internal manager;
    address internal owner = makeAddr("launchOwner");
    address internal holder = makeAddr("handler");
    address internal other = makeAddr("otherHandler");
    address internal agent = makeAddr("agent");
    address internal stranger = makeAddr("stranger");

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        art = new HandlerArt();
        hic = new MockToken();
        coin = new MockToken();
        desk = new HandlerDesk(owner, address(hic), address(art));
        cards = desk.cards();
        MockToken tokenImpl = new MockToken();
        vm.etch(desk.IMD(), address(tokenImpl).code);
        imd = MockToken(desk.IMD());
        MockPoolManager managerImpl = new MockPoolManager();
        vm.etch(address(desk.POOL_MANAGER()), address(managerImpl).code);
        manager = MockPoolManager(address(desk.POOL_MANAGER()));
        manager.configure();
        manager.initializeMock(desk.poolKey(address(hic)), true);
        manager.initializeMock(desk.poolKey(address(coin)), true);
        imd.mint(holder, 1_000_000 ether);
        imd.mint(other, 1_000_000 ether);
        imd.mint(address(manager), 1_000_000 ether);
        hic.mint(address(manager), 1_000_000 ether);
        coin.mint(address(manager), 1_000_000 ether);
        vm.prank(holder);
        imd.approve(address(desk), type(uint256).max);
        vm.prank(other);
        imd.approve(address(desk), type(uint256).max);
    }

    function _mint(address who) internal returns (uint256 id) {
        vm.prank(who);
        id = desk.mint("Agent-42", 1);
    }

    function _setupCard(address who, uint256 amount) internal returns (uint256 id) {
        id = _mint(who);
        vm.startPrank(who);
        desk.deposit(id, amount);
        desk.setAgent(id, agent);
        desk.setRules(id, 1_000_000 ether, 1_000_000 ether);
        vm.stopPrank();
    }

    function _buy(uint256 id, uint256 amount) internal returns (uint256) {
        vm.prank(agent);
        return desk.buy(id, address(coin), amount, 1);
    }

    function _sell(uint256 id, uint256 amount) internal returns (uint256) {
        vm.prank(agent);
        return desk.sell(id, address(coin), amount, 1);
    }

    function _assertSolvent() internal view {
        assertEq(imd.balanceOf(address(desk)), desk.totalLiability(address(imd)) + desk.burnImd());
        assertEq(coin.balanceOf(address(desk)), desk.totalLiability(address(coin)));
        assertEq(hic.balanceOf(address(desk)), desk.totalLiability(address(hic)));
    }
}
