// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DeskFixture} from "./helpers/DeskFixture.sol";
import {HandlerDesk} from "../src/HandlerDesk.sol";
import {HandlerCards} from "../src/HandlerCards.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {MockToken} from "./helpers/Mocks.sol";

contract ReentrantHolder is IERC721Receiver {
    HandlerDesk internal desk;
    MockToken internal imd;
    bool public reentrySucceeded;

    constructor(HandlerDesk desk_, MockToken imd_) {
        desk = desk_;
        imd = imd_;
    }

    function mint() external {
        imd.approve(address(desk), 1 ether);
        desk.mint("Receiver", 1);
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        (reentrySucceeded,) = address(desk).call(abi.encodeCall(desk.setAgent, (id, address(this))));
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract RejectingHolder is IERC721Receiver {
    function mint(HandlerDesk desk, MockToken imd) external {
        imd.approve(address(desk), 1 ether);
        desk.mint("Rejector", 1);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert("reject badge");
    }
}

contract HandlerDeskTest is DeskFixture {
    function test_mintSplitsPaymentAndBurnsHicAtomically() public {
        uint256 before = imd.balanceOf(holder);
        vm.expectEmit(true, true, false, true);
        emit HandlerDesk.Minted(1, holder, "Agent-42", 0.2 ether, 0.1 ether);
        uint256 id = _mint(holder);
        assertEq(id, 1);
        assertEq(cards.ownerOf(id), holder);
        assertEq(cards.balanceOf(holder), 1);
        assertEq(imd.balanceOf(owner), 0.1 ether);
        assertEq(hic.balanceOf(desk.BURN_ADDRESS()), 0.1 ether);
        assertEq(imd.balanceOf(holder), before - 0.2 ether);
        HandlerDesk.Card memory c = desk.getCard(id);
        assertEq(c.name, "Agent-42");
        assertEq(c.agent, address(0));
        assertEq(c.dailyCap, 0);
        assertEq(c.maxPerTrade, 0);
        assertFalse(c.frozen);
        assertEq(c.mintedAt, block.timestamp);
        assertEq(c.trades, 0);
        _assertSolvent();
    }

    function test_mintSlippageRollsBackOwnerPaymentAndCard() public {
        uint256 before = imd.balanceOf(holder);
        vm.prank(holder);
        vm.expectRevert(HandlerDesk.Slippage.selector);
        desk.mint("Agent", 0.1 ether + 1);
        assertEq(desk.totalCards(), 0);
        assertEq(imd.balanceOf(owner), 0);
        assertEq(imd.balanceOf(holder), before);
        assertEq(hic.balanceOf(desk.BURN_ADDRESS()), 0);
    }

    function test_rejectedNftReceiverRollsBackAllPayments() public {
        RejectingHolder receiver = new RejectingHolder();
        imd.mint(address(receiver), 1 ether);
        vm.expectRevert("reject badge");
        receiver.mint(desk, imd);
        assertEq(desk.totalCards(), 0);
        assertEq(imd.balanceOf(owner), 0);
        assertEq(hic.balanceOf(desk.BURN_ADDRESS()), 0);
        assertEq(imd.balanceOf(address(receiver)), 1 ether);
    }

    function test_receiverCannotReenterMintOrConfigureCard() public {
        ReentrantHolder receiver = new ReentrantHolder(desk, imd);
        imd.mint(address(receiver), 1 ether);
        receiver.mint();
        assertFalse(receiver.reentrySucceeded());
        assertEq(cards.ownerOf(1), address(receiver));
        assertEq(desk.getCard(1).agent, address(0));
    }

    function test_nameValidationAndRename() public {
        string[7] memory invalid =
            ["", "1234567890123456789012345", "<script>", "quote\"", "slash\\", "line\n", unicode"é"];
        for (uint256 i; i < invalid.length; ++i) {
            vm.prank(holder);
            vm.expectRevert(HandlerDesk.InvalidName.selector);
            desk.mint(invalid[i], 1);
        }
        vm.prank(holder);
        uint256 id = desk.mint("AZ az 09 -", 1);
        vm.prank(holder);
        desk.rename(id, "123456789012345678901234");
        assertEq(desk.getCard(id).name, "123456789012345678901234");
        vm.prank(holder);
        vm.expectRevert(HandlerDesk.InvalidName.selector);
        desk.rename(id, "name_with_underscore");
        vm.prank(stranger);
        vm.expectRevert(HandlerDesk.OnlyHolder.selector);
        desk.rename(id, "Valid");
    }

    function test_holderDepositsAndWithdrawsEvenWhenFrozen() public {
        uint256 id = _setupCard(holder, 100 ether);
        vm.startPrank(holder);
        desk.freeze(id);
        uint256 before = imd.balanceOf(holder);
        desk.withdraw(id, address(imd), 40 ether);
        desk.deposit(id, 10 ether);
        vm.stopPrank();
        assertEq(imd.balanceOf(holder), before + 30 ether);
        assertEq(desk.balances(id, address(imd)), 70 ether);
        _assertSolvent();
    }

    function test_agentAndOwnerCannotWithdrawOrConfigure() public {
        uint256 id = _setupCard(holder, 10 ether);
        address[3] memory attackers = [agent, owner, stranger];
        for (uint256 i; i < attackers.length; ++i) {
            vm.startPrank(attackers[i]);
            vm.expectRevert(HandlerDesk.OnlyHolder.selector);
            desk.withdraw(id, address(imd), 1);
            vm.expectRevert(HandlerDesk.OnlyHolder.selector);
            desk.deposit(id, 1);
            vm.expectRevert(HandlerDesk.OnlyHolder.selector);
            desk.setAgent(id, attackers[i]);
            vm.expectRevert(HandlerDesk.OnlyHolder.selector);
            desk.setRules(id, 999 ether, 999 ether);
            vm.expectRevert(HandlerDesk.OnlyHolder.selector);
            desk.freeze(id);
            vm.expectRevert(HandlerDesk.OnlyHolder.selector);
            desk.unfreeze(id);
            vm.expectRevert(HandlerDesk.OnlyHolder.selector);
            desk.rename(id, "Valid");
            vm.stopPrank();
        }
    }

    function test_balancesOfTwoCardsNeverMix() public {
        uint256 a = _setupCard(holder, 100 ether);
        uint256 b = _setupCard(other, 1 ether);
        uint256 out = _buy(a, 40 ether);
        vm.prank(agent);
        vm.expectRevert(HandlerDesk.InsufficientBalance.selector);
        desk.sell(b, address(coin), out, 1);
        vm.prank(other);
        vm.expectRevert(HandlerDesk.OnlyHolder.selector);
        desk.withdraw(a, address(coin), out);
        vm.prank(other);
        desk.withdraw(b, address(imd), 1 ether);
        assertEq(desk.balances(a, address(coin)), out);
        assertEq(desk.balances(a, address(imd)), 60 ether);
        _assertSolvent();
    }

    function test_buyFeeCostBasisAndEvent() public {
        uint256 id = _setupCard(holder, 100 ether);
        uint256 ownerBefore = imd.balanceOf(owner);
        vm.expectEmit(true, true, false, true);
        emit HandlerDesk.Traded(id, address(coin), true, 40 ether, 39.9 ether, 0, false);
        uint256 out = _buy(id, 40 ether);
        assertEq(out, 39.9 ether);
        assertEq(imd.balanceOf(owner) - ownerBefore, 0.05 ether);
        assertEq(desk.burnImd(), 0.05 ether);
        assertEq(desk.balances(id, address(imd)), 60 ether);
        assertEq(desk.balances(id, address(coin)), out);
        (uint256 quantity, uint256 cost) = desk.positions(id, address(coin));
        assertEq(quantity, out);
        assertEq(cost, 40 ether);
        HandlerDesk.Card memory c = desk.getCard(id);
        assertEq(c.trades, 1);
        assertEq(c.volume, 40 ether);
        assertEq(c.wins + c.losses, 0);
        assertEq(c.pnl, 0);
        assertEq(desk.spentToday(id), 40 ether);
        address[] memory coins = desk.cardCoins(id);
        assertEq(coins.length, 2);
        assertEq(coins[0], address(imd));
        assertEq(coins[1], address(coin));
        _assertSolvent();
    }

    function test_partialAndFullSaleRecordsWinAndLoss() public {
        uint256 id = _setupCard(holder, 100 ether);
        uint256 out = _buy(id, 40 ether);
        manager.setRate(address(coin), address(imd), 2 ether);
        uint256 half = out / 2;
        uint256 proceeds = _sell(id, half);
        assertEq(proceeds, 39.80025 ether);
        (uint256 quantity, uint256 cost) = desk.positions(id, address(coin));
        assertEq(quantity, half);
        assertEq(cost, 20 ether);
        HandlerDesk.Card memory c = desk.getCard(id);
        assertEq(c.pnl, int256(proceeds) - 20 ether);
        assertEq(c.wins, 1);
        assertEq(c.losses, 0);
        manager.setRate(address(coin), address(imd), 0.5 ether);
        uint256 finalProceeds = _sell(id, half);
        c = desk.getCard(id);
        assertEq(c.pnl, int256(proceeds + finalProceeds) - 40 ether);
        assertEq(c.wins, 1);
        assertEq(c.losses, 1);
        assertEq(c.trades, 3);
        assertEq(c.volume, 40 ether + 39.9 ether + 9.975 ether);
        (quantity, cost) = desk.positions(id, address(coin));
        assertEq(quantity, 0);
        assertEq(cost, 0);
        _assertSolvent();
    }

    function test_sellBreakEvenCountsAsLoss() public {
        uint256 id = _setupCard(holder, 1000);
        uint256 out = _buy(id, 100); // Fee rounds to zero at this scale.
        assertEq(_sell(id, out), 100);
        HandlerDesk.Card memory c = desk.getCard(id);
        assertEq(c.pnl, 0);
        assertEq(c.wins, 0);
        assertEq(c.losses, 1);
    }

    function test_withdrawingCoinRemovesProportionalBasisWithoutFakingTrade() public {
        uint256 id = _setupCard(holder, 100 ether);
        uint256 out = _buy(id, 40 ether);
        vm.prank(holder);
        desk.withdraw(id, address(coin), out / 2);
        (uint256 quantity, uint256 cost) = desk.positions(id, address(coin));
        assertEq(quantity, out / 2);
        assertEq(cost, 20 ether);
        assertEq(desk.getCard(id).trades, 1);
        assertEq(desk.getCard(id).pnl, 0);
        _sell(id, quantity);
        (quantity, cost) = desk.positions(id, address(coin));
        assertEq(quantity, 0);
        assertEq(cost, 0);
        assertEq(desk.getCard(id).losses, 1);
        _assertSolvent();
    }

    function test_rulesDefaultDisabledAndAgentRevocationImmediate() public {
        uint256 id = _mint(holder);
        vm.prank(holder);
        desk.deposit(id, 10 ether);
        vm.prank(agent);
        vm.expectRevert(HandlerDesk.OnlyAgent.selector);
        desk.buy(id, address(coin), 1 ether, 1);
        vm.prank(holder);
        desk.setAgent(id, agent);
        vm.prank(agent);
        vm.expectRevert(HandlerDesk.PerTradeLimit.selector);
        desk.buy(id, address(coin), 1 ether, 1);
        vm.prank(holder);
        desk.setRules(id, 0, 1 ether);
        vm.prank(agent);
        vm.expectRevert(HandlerDesk.DailyLimit.selector);
        desk.buy(id, address(coin), 1 ether, 1);
        vm.prank(holder);
        desk.setAgent(id, address(0));
        vm.prank(agent);
        vm.expectRevert(HandlerDesk.OnlyAgent.selector);
        desk.sell(id, address(coin), 1, 1);
    }

    function test_dailyLimitsResetAtUtcMidnightAndCannotResetByChangingRules() public {
        uint256 id = _setupCard(holder, 100 ether);
        vm.prank(holder);
        desk.setRules(id, 20 ether, 10 ether);
        _buy(id, 10 ether);
        _buy(id, 10 ether);
        vm.prank(holder);
        desk.setRules(id, 20 ether, 10 ether);
        vm.prank(agent);
        vm.expectRevert(HandlerDesk.DailyLimit.selector);
        desk.buy(id, address(coin), 1, 1);
        vm.prank(agent);
        vm.expectRevert(HandlerDesk.PerTradeLimit.selector);
        desk.buy(id, address(coin), 10 ether + 1, 1);
        vm.warp((block.timestamp / 1 days + 1) * 1 days);
        assertEq(desk.spentToday(id), 0);
        _buy(id, 10 ether);
        assertEq(desk.spentToday(id), 10 ether);
    }

    function test_salesDoNotUseDailyCapAndFreezeStopsBothTradeDirections() public {
        uint256 id = _setupCard(holder, 100 ether);
        uint256 out = _buy(id, 10 ether);
        vm.startPrank(holder);
        desk.setRules(id, 0, 0);
        desk.freeze(id);
        vm.expectRevert(HandlerDesk.FreezeUnchanged.selector);
        desk.freeze(id);
        vm.stopPrank();
        vm.startPrank(agent);
        vm.expectRevert(HandlerDesk.CardFrozen.selector);
        desk.buy(id, address(coin), 1, 1);
        vm.expectRevert(HandlerDesk.CardFrozen.selector);
        desk.sell(id, address(coin), out, 1);
        vm.stopPrank();
        vm.startPrank(holder);
        desk.unfreeze(id);
        vm.expectRevert(HandlerDesk.FreezeUnchanged.selector);
        desk.unfreeze(id);
        vm.stopPrank();
        _sell(id, out);
        _assertSolvent();
    }

    function test_uninitializedPoolAndInvalidCurrenciesCannotTrade() public {
        uint256 id = _setupCard(holder, 100 ether);
        manager.initializeMock(desk.poolKey(address(coin)), false);
        assertFalse(desk.isTradable(address(coin)));
        vm.startPrank(agent);
        vm.expectRevert(HandlerDesk.PoolNotInitialized.selector);
        desk.buy(id, address(coin), 1 ether, 1);
        vm.expectRevert(HandlerDesk.PoolNotInitialized.selector);
        desk.buy(id, address(imd), 1 ether, 1);
        vm.expectRevert(HandlerDesk.PoolNotInitialized.selector);
        desk.buy(id, address(0), 1 ether, 1);
        vm.expectRevert(HandlerDesk.PoolNotInitialized.selector);
        desk.buy(id, stranger, 1 ether, 1);
        vm.stopPrank();
        assertEq(desk.spentToday(id), 0);
        assertEq(desk.balances(id, address(imd)), 100 ether);
        _assertSolvent();
    }

    function test_uninitializedHicPoolMakesMintRevert() public {
        manager.initializeMock(desk.poolKey(address(hic)), false);
        vm.prank(holder);
        vm.expectRevert(HandlerDesk.PoolNotInitialized.selector);
        desk.mint("No Pool", 1);
        assertEq(imd.balanceOf(owner), 0);
        assertEq(desk.totalCards(), 0);
    }

    function test_buyAndSellSlippageUseMeasuredNetOutputAndRollback() public {
        uint256 id = _setupCard(holder, 100 ether);
        vm.prank(agent);
        vm.expectRevert(HandlerDesk.Slippage.selector);
        desk.buy(id, address(coin), 40 ether, 40 ether);
        assertEq(desk.spentToday(id), 0);
        uint256 out = _buy(id, 40 ether);
        vm.prank(agent);
        vm.expectRevert(HandlerDesk.Slippage.selector);
        desk.sell(id, address(coin), out, out); // The net return is smaller than gross.
        assertEq(desk.balances(id, address(coin)), out);
        assertEq(desk.getCard(id).trades, 1);
        _assertSolvent();
    }

    function test_partialFillAndSettlementFailureRevertWithoutChangingAccounts() public {
        uint256 id = _setupCard(holder, 100 ether);
        manager.setFill(5000);
        vm.prank(agent);
        vm.expectRevert(HandlerDesk.PartialFill.selector);
        desk.buy(id, address(coin), 10 ether, 1);
        manager.setFill(10_000);
        manager.setShortSettlement(true);
        vm.prank(agent);
        vm.expectRevert(HandlerDesk.UnsupportedToken.selector);
        desk.buy(id, address(coin), 10 ether, 1);
        assertEq(desk.balances(id, address(imd)), 100 ether);
        assertEq(desk.spentToday(id), 0);
        assertEq(desk.burnImd(), 0);
        _assertSolvent();
    }

    function test_outputBalanceMeasurementNotReturnedPoolDeltaDeterminesCredit() public {
        uint256 id = _setupCard(holder, 100 ether);
        manager.setTake(9000);
        uint256 out = _buy(id, 40 ether);
        assertEq(out, 35.91 ether);
        assertEq(desk.balances(id, address(coin)), out);
        (uint256 quantity,) = desk.positions(id, address(coin));
        assertEq(quantity, out);
        _assertSolvent();
    }

    function test_missingWrongAndUnauthorizedCallbacksRejected() public {
        uint256 id = _setupCard(holder, 100 ether);
        vm.expectRevert(HandlerDesk.UnexpectedCallback.selector);
        desk.unlockCallback(bytes(""));
        vm.prank(address(manager));
        vm.expectRevert(HandlerDesk.UnexpectedCallback.selector);
        desk.unlockCallback(abi.encode(address(imd), address(coin), 10 ether));
        manager.setCallbackMode(1);
        vm.prank(agent);
        vm.expectRevert(HandlerDesk.UnexpectedCallback.selector);
        desk.buy(id, address(coin), 10 ether, 1);
        manager.setCallbackMode(2);
        vm.prank(agent);
        vm.expectRevert(HandlerDesk.UnexpectedCallback.selector);
        desk.buy(id, address(coin), 10 ether, 1);
        manager.setCallbackMode(3);
        _buy(id, 10 ether);
        assertFalse(manager.replaySucceeded());
        _assertSolvent();
    }

    function test_poolAndTokenReentryCannotSpendOrReconfigure() public {
        uint256 id = _setupCard(holder, 100 ether);
        // Authorize the PoolManager as agent to prove the guard, rather than only access checks.
        vm.prank(holder);
        desk.setAgent(id, address(manager));
        manager.setReentry(address(desk), abi.encodeCall(desk.buy, (id, address(coin), 10 ether, 1)));
        vm.prank(address(manager));
        desk.buy(id, address(coin), 10 ether, 1);
        assertFalse(manager.reentrySucceeded());
        vm.prank(holder);
        desk.setAgent(id, address(coin));
        coin.setReentry(address(desk), abi.encodeCall(desk.sell, (id, address(coin), 1, 1)));
        vm.prank(address(coin));
        desk.buy(id, address(coin), 10 ether, 1);
        assertFalse(coin.reentrySucceeded());
        assertEq(desk.getCard(id).trades, 2);
        _assertSolvent();
    }

    function test_taxedImdDepositRejectedAndTokenFailureRollsBackWithdraw() public {
        uint256 id = _setupCard(holder, 100 ether);
        imd.setTax(100);
        vm.prank(holder);
        vm.expectRevert(HandlerDesk.UnsupportedToken.selector);
        desk.deposit(id, 10 ether);
        imd.setTax(0);
        imd.setFail(true);
        vm.prank(holder);
        vm.expectRevert("token transfer failed");
        desk.withdraw(id, address(imd), 10 ether);
        imd.setFail(false);
        assertEq(desk.balances(id, address(imd)), 100 ether);
        _assertSolvent();
    }

    function test_burnPermissionIntervalAndSlippageRollback() public {
        uint256 id = _setupCard(holder, 100 ether);
        vm.expectRevert(HandlerDesk.NothingToBurn.selector);
        desk.buyAndBurn(1);
        _buy(id, 40 ether);
        vm.prank(stranger);
        vm.expectRevert(HandlerDesk.Slippage.selector);
        desk.buyAndBurn(0.05 ether + 1);
        assertEq(desk.burnImd(), 0.05 ether);
        assertFalse(desk.hasBurned());
        uint256 before = hic.balanceOf(desk.BURN_ADDRESS());
        vm.prank(stranger);
        assertEq(desk.buyAndBurn(1), 0.05 ether);
        assertEq(hic.balanceOf(desk.BURN_ADDRESS()) - before, 0.05 ether);
        _buy(id, 40 ether);
        vm.expectRevert(HandlerDesk.BurnTooSoon.selector);
        desk.buyAndBurn(1);
        vm.warp(vm.getBlockTimestamp() + 1 hours - 1);
        vm.expectRevert(HandlerDesk.BurnTooSoon.selector);
        desk.buyAndBurn(1);
        vm.warp(vm.getBlockTimestamp() + 1);
        desk.buyAndBurn(1);
        assertEq(desk.burnImd(), 0);
        _assertSolvent();
    }

    function test_ownerPriceBoundsTwoStepTransferAndNoRenounce() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        desk.setMintPrice(1 ether);
        vm.startPrank(owner);
        vm.expectRevert(HandlerDesk.MintPriceOutOfRange.selector);
        desk.setMintPrice(0.05 ether - 1);
        vm.expectRevert(HandlerDesk.MintPriceOutOfRange.selector);
        desk.setMintPrice(2 ether + 1);
        desk.setMintPrice(0.05 ether);
        desk.setMintPrice(2 ether);
        vm.expectRevert(HandlerDesk.RenounceDisabled.selector);
        desk.renounceOwnership();
        desk.transferOwnership(other);
        vm.stopPrank();
        assertEq(desk.owner(), owner);
        assertEq(desk.pendingOwner(), other);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        desk.acceptOwnership();
        vm.prank(other);
        desk.acceptOwnership();
        assertEq(desk.owner(), other);
        uint256 before = imd.balanceOf(other);
        _mint(holder);
        assertEq(imd.balanceOf(other) - before, 1 ether);
    }

    function test_unknownCardZeroAmountAndOverspendFailures() public {
        vm.expectRevert(HandlerDesk.UnknownCard.selector);
        desk.getCard(0);
        vm.expectRevert(HandlerDesk.UnknownCard.selector);
        desk.cardCoins(1);
        vm.prank(holder);
        vm.expectRevert(HandlerDesk.UnknownCard.selector);
        desk.deposit(1, 1);
        uint256 id = _setupCard(holder, 1 ether);
        vm.startPrank(holder);
        vm.expectRevert(HandlerDesk.InvalidAmount.selector);
        desk.deposit(id, 0);
        vm.expectRevert(HandlerDesk.InvalidAmount.selector);
        desk.withdraw(id, address(imd), 0);
        vm.expectRevert(HandlerDesk.InsufficientBalance.selector);
        desk.withdraw(id, address(imd), 1 ether + 1);
        vm.stopPrank();
        vm.startPrank(agent);
        vm.expectRevert(HandlerDesk.InvalidAmount.selector);
        desk.buy(id, address(coin), 0, 1);
        vm.expectRevert(HandlerDesk.InvalidAmount.selector);
        desk.sell(id, address(coin), 0, 1);
        vm.expectRevert(HandlerDesk.InvalidToken.selector);
        desk.sell(id, address(imd), 1, 1);
        vm.expectRevert(HandlerDesk.Slippage.selector);
        desk.buy(id, address(coin), 1, 0);
        vm.expectRevert(HandlerDesk.InsufficientBalance.selector);
        desk.buy(id, address(coin), 2 ether, 1);
        vm.stopPrank();
        _assertSolvent();
    }

    function test_constructorRejectsMissingOrConflictingParameters() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new HandlerDesk(address(0), address(hic), address(art));
        vm.expectRevert(HandlerDesk.InvalidAddress.selector);
        new HandlerDesk(owner, address(0), address(art));
        vm.expectRevert(HandlerDesk.InvalidAddress.selector);
        new HandlerDesk(owner, address(imd), address(art));
        vm.expectRevert(HandlerDesk.InvalidAddress.selector);
        new HandlerDesk(owner, address(hic), address(0));
    }

    function testFuzz_conservationPartialSalesAndWithdraw(uint256 amount, uint256 split) public {
        amount = bound(amount, 400, 10_000 ether);
        uint256 id = _setupCard(holder, amount);
        uint256 out = _buy(id, amount);
        split = bound(split, 1, out - 1);
        _sell(id, split);
        vm.prank(holder);
        desk.withdraw(id, address(coin), out - split);
        (uint256 quantity, uint256 cost) = desk.positions(id, address(coin));
        assertEq(quantity, 0);
        assertEq(cost, 0);
        uint256 remainingImd = desk.balances(id, address(imd));
        vm.prank(holder);
        desk.withdraw(id, address(imd), remainingImd);
        if (desk.burnImd() != 0) desk.buyAndBurn(1);
        assertEq(imd.balanceOf(address(desk)), 0);
        assertEq(coin.balanceOf(address(desk)), 0);
        assertEq(desk.totalLiability(address(imd)), 0);
        _assertSolvent();
    }
}
