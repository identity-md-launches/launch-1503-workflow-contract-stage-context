// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeskFixture} from "./helpers/DeskFixture.sol";
import {HandlerDesk} from "../src/HandlerDesk.sol";
import {MockToken} from "./helpers/Mocks.sol";

/// @dev Models arbitrary interleavings across two independently held cards.
contract DeskActions is Test {
    HandlerDesk public immutable desk;
    address public immutable imd;
    address public immutable coin;
    address public immutable hic;
    address public immutable agent;
    address[2] private _holders;
    uint256[2] private _ids;
    mapping(uint256 => uint256) public buys;
    mapping(uint256 => uint256) public sells;
    mapping(uint256 => int256) public realized;

    constructor(
        HandlerDesk desk_,
        address coin_,
        address agent_,
        address a,
        address b,
        uint256 idA,
        uint256 idB
    ) {
        desk = desk_;
        imd = desk_.IMD();
        hic = desk_.hic();
        coin = coin_;
        agent = agent_;
        _holders = [a, b];
        _ids = [idA, idB];
    }

    function deposit(uint256 which, uint256 raw) external {
        uint256 i = which % 2;
        uint256 amount = bound(raw, 1, 100 ether);
        vm.prank(_holders[i]);
        desk.deposit(_ids[i], amount);
    }

    function tradeBuy(uint256 which, uint256 raw, bool useHic) external {
        uint256 id = _ids[which % 2];
        uint256 available = desk.balances(id, imd);
        if (available < 400) return;
        uint256 amount = bound(raw, 400, available > 100 ether ? 100 ether : available);
        vm.prank(agent);
        try desk.buy(id, useHic ? hic : coin, amount, 1) {
            buys[id]++;
        } catch {}
    }

    function tradeSell(uint256 which, uint256 raw, bool useHic) external {
        uint256 id = _ids[which % 2];
        address token = useHic ? hic : coin;
        uint256 available = desk.balances(id, token);
        if (available == 0) return;
        uint256 amount = bound(raw, 1, available);
        (, uint256 cost) = desk.positions(id, token);
        uint256 removedCost = cost * amount / available; // Bounds keep this reference calculation below overflow.
        vm.prank(agent);
        try desk.sell(id, token, amount, 1) returns (uint256 proceeds) {
            sells[id]++;
            realized[id] += int256(proceeds) - int256(removedCost);
        } catch {}
    }

    function withdraw(uint256 which, uint256 raw, uint256 currency) external {
        uint256 i = which % 2;
        uint256 id = _ids[i];
        address token = currency % 3 == 0 ? imd : (currency % 3 == 1 ? coin : hic);
        uint256 available = desk.balances(id, token);
        if (available == 0) return;
        uint256 amount = bound(raw, 1, available);
        vm.prank(_holders[i]);
        desk.withdraw(id, token, amount);
    }

    function flipFreeze(uint256 which) external {
        uint256 i = which % 2;
        bool frozen = desk.getCard(_ids[i]).frozen;
        vm.prank(_holders[i]);
        if (frozen) desk.unfreeze(_ids[i]);
        else desk.freeze(_ids[i]);
    }

    function changeRules(uint256 which, uint256 cap, uint256 max) external {
        uint256 i = which % 2;
        cap = bound(cap, 0, 2000 ether);
        max = bound(max, 0, 200 ether);
        vm.prank(_holders[i]);
        desk.setRules(_ids[i], cap, max);
    }

    function revokeOrRestore(uint256 which, bool enabled) external {
        uint256 i = which % 2;
        vm.prank(_holders[i]);
        desk.setAgent(_ids[i], enabled ? agent : address(0));
    }

    function burn() external {
        try desk.buyAndBurn(1) {} catch {}
    }

    function advanceTime(uint256 raw) external {
        vm.warp(block.timestamp + bound(raw, 0, 2 days));
    }
}

contract DeskInvariantTest is DeskFixture {
    DeskActions internal actions;

    function setUp() public override {
        super.setUp();
        uint256 a = _setupCard(holder, 1000 ether);
        uint256 b = _setupCard(other, 1000 ether);
        actions = new DeskActions(desk, address(coin), agent, holder, other, a, b);
        targetContract(address(actions));
    }

    function invariant_cardBalancesAndBurnReserveAreFullyBacked() public view {
        _assertSolvent();
        assertEq(
            desk.balances(1, address(imd)) + desk.balances(2, address(imd)), desk.totalLiability(address(imd))
        );
        assertEq(
            desk.balances(1, address(coin)) + desk.balances(2, address(coin)),
            desk.totalLiability(address(coin))
        );
        assertEq(
            desk.balances(1, address(hic)) + desk.balances(2, address(hic)), desk.totalLiability(address(hic))
        );
    }

    function invariant_positionsAndStatsMatchActualActions() public view {
        for (uint256 id = 1; id <= 2; ++id) {
            (uint256 q, uint256 cost) = desk.positions(id, address(coin));
            assertEq(q, desk.balances(id, address(coin)));
            if (q == 0) assertEq(cost, 0);
            (q, cost) = desk.positions(id, address(hic));
            assertEq(q, desk.balances(id, address(hic)));
            if (q == 0) assertEq(cost, 0);
            HandlerDesk.Card memory c = desk.getCard(id);
            assertEq(c.trades, actions.buys(id) + actions.sells(id));
            assertEq(c.wins + c.losses, actions.sells(id));
            assertEq(c.pnl, actions.realized(id));
            assertEq(cards.ownerOf(id), id == 1 ? holder : other);
        }
    }
}
