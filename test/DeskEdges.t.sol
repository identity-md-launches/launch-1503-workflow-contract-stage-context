// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DeskFixture} from "./helpers/DeskFixture.sol";
import {HandlerDesk} from "src/HandlerDesk.sol";

contract DeskEdgesTest is DeskFixture {
    function test_everySingleByteNameHasExactlyTheSpecifiedAlphabet() public {
        uint256 id = _mint(holder);
        for (uint256 n; n < 256; ++n) {
            string memory name = string(abi.encodePacked(uint8(n)));
            bool allowed =
                (n >= 65 && n <= 90) || (n >= 97 && n <= 122) || (n >= 48 && n <= 57) || n == 32 || n == 45;
            string memory before = desk.getCard(id).name;
            vm.prank(holder);
            if (!allowed) vm.expectRevert(HandlerDesk.InvalidName.selector);
            desk.rename(id, name);
            assertEq(desk.getCard(id).name, allowed ? name : before);
            if (!allowed) {
                uint256 balance = imd.balanceOf(holder);
                vm.prank(holder);
                vm.expectRevert(HandlerDesk.InvalidName.selector);
                desk.mint(name, 1);
                assertEq(imd.balanceOf(holder), balance);
                assertEq(desk.totalCards(), 1);
            }
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_validNamesRoundTripThroughMintAndRename(bytes32 seed, uint8 rawLength) public {
        uint256 length = bound(rawLength, 1, 24);
        bytes memory alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 -";
        bytes memory name = new bytes(length);
        for (uint256 i; i < length; ++i) {
            name[i] = alphabet[uint8(seed[i]) % alphabet.length];
        }
        vm.prank(holder);
        uint256 id = desk.mint(string(name), 1);
        assertEq(desk.getCard(id).name, string(name));
        vm.prank(holder);
        desk.rename(id, string(name));
        assertEq(desk.getCard(id).name, string(name));
        assertEq(desk.getCard(id).mintedAt, block.timestamp);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_unknownCardsCannotCreateState(uint256 raw, uint8 action) public {
        _mint(holder);
        uint256 id = raw == 0 ? 0 : bound(raw, 2, type(uint256).max);
        action = uint8(bound(action, 0, 11));
        bytes memory data;
        if (action == 0) data = abi.encodeCall(desk.deposit, (id, 1));
        else if (action == 1) data = abi.encodeCall(desk.withdraw, (id, address(imd), 1));
        else if (action == 2) data = abi.encodeCall(desk.setAgent, (id, agent));
        else if (action == 3) data = abi.encodeCall(desk.setRules, (id, 1, 1));
        else if (action == 4) data = abi.encodeCall(desk.freeze, (id));
        else if (action == 5) data = abi.encodeCall(desk.unfreeze, (id));
        else if (action == 6) data = abi.encodeCall(desk.rename, (id, "Name"));
        else if (action == 7) data = abi.encodeCall(desk.buy, (id, address(coin), 1, 1));
        else if (action == 8) data = abi.encodeCall(desk.sell, (id, address(coin), 1, 1));
        else if (action == 9) data = abi.encodeCall(desk.getCard, (id));
        else if (action == 10) data = abi.encodeCall(desk.cardCoins, (id));
        else data = abi.encodeCall(desk.spentToday, (id));
        uint256 before = imd.balanceOf(holder);
        vm.prank(holder);
        (bool ok, bytes memory reason) = address(desk).call(data);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(HandlerDesk.UnknownCard.selector));
        assertEq(imd.balanceOf(holder), before);
        assertEq(desk.totalCards(), 1);
        assertEq(desk.balances(id, address(imd)), 0);
        _assertSolvent();
    }

    function test_buyInputAboveSignedDeltaLimitRollsBackBeforeCallingManager() public {
        uint256 maximum = uint256(uint128(type(int128).max));
        uint256 amount = maximum * 2;
        imd.mint(holder, amount);
        uint256 id = _setupCard(holder, amount);
        vm.prank(holder);
        desk.setRules(id, type(uint256).max, type(uint256).max);
        uint256 ownerBefore = imd.balanceOf(owner);
        vm.prank(agent);
        vm.expectRevert(HandlerDesk.InvalidAmount.selector);
        desk.buy(id, address(coin), amount, 1);
        assertEq(desk.balances(id, address(imd)), amount);
        assertEq(desk.spentToday(id), 0);
        assertEq(desk.getCard(id).trades, 0);
        assertEq(imd.balanceOf(owner), ownerBefore);
        assertEq(desk.burnImd(), 0);
        _assertSolvent();
    }

    function test_signedDeltaMaximumCanBeSoldExactly() public {
        uint256 maximum = uint256(uint128(type(int128).max));
        // maximum is 2^127 - 1. This gross debit leaves exactly maximum after the Desk fee.
        uint256 amount = maximum * 400 / 399;
        assertEq(amount - amount / 400, maximum);
        imd.mint(holder, amount);
        coin.mint(address(manager), maximum);
        uint256 id = _setupCard(holder, amount);
        vm.prank(holder);
        desk.setRules(id, type(uint256).max, type(uint256).max);
        assertEq(_buy(id, amount), maximum);
        uint256 returned = _sell(id, maximum);
        assertEq(returned, maximum - maximum / 400);
        (uint256 quantity, uint256 cost) = desk.positions(id, address(coin));
        assertEq(quantity, 0);
        assertEq(cost, 0);
        assertEq(desk.getCard(id).pnl, int256(returned) - int256(amount));
        _assertSolvent();
    }

    function test_accumulatedPositionAboveDeltaLimitRemainsFullyWithdrawable() public {
        uint256 maximum = uint256(uint128(type(int128).max));
        uint256 amount = maximum;
        imd.mint(holder, amount * 2);
        coin.mint(address(manager), amount * 2);
        uint256 id = _setupCard(holder, amount * 2);
        vm.prank(holder);
        desk.setRules(id, type(uint256).max, type(uint256).max);
        uint256 quantity = _buy(id, amount) + _buy(id, amount);
        assertGt(quantity, maximum);
        vm.prank(agent);
        vm.expectRevert(HandlerDesk.InvalidAmount.selector);
        desk.sell(id, address(coin), quantity, 1);
        (uint256 q, uint256 cost) = desk.positions(id, address(coin));
        assertEq(q, quantity);
        assertEq(cost, amount * 2);
        vm.prank(holder);
        desk.withdraw(id, address(coin), quantity);
        assertEq(coin.balanceOf(holder), quantity);
        (q, cost) = desk.positions(id, address(coin));
        assertEq(q, 0);
        assertEq(cost, 0);
        _assertSolvent();
    }

    function test_repeatedZeroFeeDustRoundTripsCannotCreateImd() public {
        uint256 id = _setupCard(holder, 399);
        for (uint256 i; i < 32; ++i) {
            assertEq(_sell(id, _buy(id, 399)), 399);
            assertEq(desk.balances(id, address(imd)), 399);
            assertEq(desk.balances(id, address(coin)), 0);
        }
        assertEq(desk.getCard(id).pnl, 0);
        assertEq(desk.getCard(id).wins, 0);
        assertEq(desk.getCard(id).losses, 32);
        assertEq(desk.spentToday(id), 32 * 399);
        assertEq(desk.burnImd(), 0);
        _assertSolvent();
    }

    function test_emptyAccountsCanBeReusedWithoutDuplicateCoinsOrStaleBasis() public {
        uint256 id = _setupCard(holder, 100 ether);
        uint256 originalMintedAt = desk.getCard(id).mintedAt;
        uint256 bought = _buy(id, 100 ether);
        vm.prank(holder);
        desk.withdraw(id, address(coin), bought);
        assertEq(desk.balances(id, address(imd)), 0);
        vm.prank(holder);
        desk.deposit(id, 1);
        assertEq(_sell(id, _buy(id, 1)), 1);
        assertEq(desk.cardCoins(id).length, 2);
        assertEq(desk.getCard(id).mintedAt, originalMintedAt);
        assertEq(desk.getCard(id).trades, 3);
        assertEq(desk.getCard(id).pnl, 0);
        (uint256 q, uint256 cost) = desk.positions(id, address(coin));
        assertEq(q, 0);
        assertEq(cost, 0);
        _assertSolvent();
    }
}
