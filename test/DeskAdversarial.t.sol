// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DeskFixture} from "./helpers/DeskFixture.sol";
import {AdversarialToken} from "./helpers/AdversarialToken.sol";
import {HandlerDesk} from "src/HandlerDesk.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DeskAdversarialTest is DeskFixture {
    function _state(uint256 id) internal view returns (bytes32) {
        bytes32 accounts = keccak256(
            abi.encode(
                imd.balanceOf(holder),
                imd.balanceOf(owner),
                imd.balanceOf(address(manager)),
                imd.balanceOf(address(desk)),
                coin.balanceOf(holder),
                coin.balanceOf(address(manager)),
                coin.balanceOf(address(desk)),
                hic.balanceOf(address(manager)),
                hic.balanceOf(address(desk)),
                hic.balanceOf(desk.BURN_ADDRESS()),
                imd.allowance(holder, address(desk))
            )
        );
        (uint256 quantity, uint256 cost) = desk.positions(id, address(coin));
        return keccak256(
            abi.encode(
                accounts,
                desk.getCard(id),
                desk.cardCoins(id),
                quantity,
                cost,
                desk.balances(id, address(imd)),
                desk.balances(id, address(coin)),
                desk.totalLiability(address(imd)),
                desk.totalLiability(address(coin)),
                desk.burnImd(),
                desk.hasBurned(),
                desk.lastBurnTime(),
                desk.totalCards()
            )
        );
    }

    function _adversarialImd() internal returns (AdversarialToken token) {
        AdversarialToken implementation = new AdversarialToken();
        vm.etch(address(imd), address(implementation).code);
        token = AdversarialToken(address(imd));
    }

    function test_falseReturnAtFinalBuyFeeRollsBackSwapLimitsAndRecord() public {
        uint256 id = _setupCard(holder, 100 ether);
        AdversarialToken token = _adversarialImd();
        token.setRejectedRecipient(owner);
        bytes32 before = _state(id);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(imd)));
        desk.buy(id, address(coin), 40 ether, 1);
        assertEq(_state(id), before, "late fee failure must roll back the entire buy");
        token.setRejectedRecipient(address(0));
        assertEq(_buy(id, 40 ether), 39.9 ether, "callback authorization must recover after revert");
    }

    function test_falseReturnAtFinalSellFeeRollsBackPositionAndProfit() public {
        uint256 id = _setupCard(holder, 100 ether);
        uint256 out = _buy(id, 40 ether);
        manager.setRate(address(coin), address(imd), 2 ether);
        AdversarialToken token = _adversarialImd();
        token.setRejectedRecipient(owner);
        bytes32 before = _state(id);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(imd)));
        desk.sell(id, address(coin), out, 1);
        assertEq(_state(id), before, "late fee failure must restore cost, quantity, stats and tokens");
        token.setRejectedRecipient(address(0));
        assertGt(_sell(id, out), 40 ether);
        _assertSolvent();
    }

    function test_falseReturnOnWithdrawalRestoresBalanceCostAndRecipient() public {
        uint256 id = _setupCard(holder, 100 ether);
        uint256 out = _buy(id, 40 ether);
        AdversarialToken implementation = new AdversarialToken();
        vm.etch(address(coin), address(implementation).code);
        AdversarialToken(address(coin)).setReturnMode(true, false);
        bytes32 before = _state(id);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(coin)));
        desk.withdraw(id, address(coin), out);
        assertEq(_state(id), before);
        AdversarialToken(address(coin)).setReturnMode(false, false);
        vm.prank(holder);
        desk.withdraw(id, address(coin), out);
        assertEq(coin.balanceOf(holder), out);
        _assertSolvent();
    }

    function test_falseReturnOnDepositRollsBackTransferAndFiniteAllowance() public {
        uint256 id = _mint(holder);
        vm.prank(holder);
        imd.approve(address(desk), 7 ether);
        _adversarialImd().setReturnMode(true, false);
        bytes32 before = _state(id);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(imd)));
        desk.deposit(id, 7 ether);
        assertEq(_state(id), before);
    }

    function test_noReturnImdSupportsPullSettlementFeesAndWithdrawal() public {
        _adversarialImd().setReturnMode(false, true);
        uint256 id = _setupCard(holder, 100 ether);
        assertEq(_buy(id, 40 ether), 39.9 ether);
        uint256 before = imd.balanceOf(holder);
        vm.prank(holder);
        desk.withdraw(id, address(imd), 60 ether);
        assertEq(imd.balanceOf(holder) - before, 60 ether);
        assertEq(desk.buyAndBurn(1), 0.05 ether);
        assertEq(imd.balanceOf(owner), 0.15 ether);
        _assertSolvent();
    }

    function test_failedBurnTransferRestoresReserveAndCooldown() public {
        uint256 id = _setupCard(holder, 100 ether);
        _buy(id, 40 ether);
        AdversarialToken implementation = new AdversarialToken();
        vm.etch(address(hic), address(implementation).code);
        AdversarialToken(address(hic)).setRejectedRecipient(desk.BURN_ADDRESS());
        bytes32 before = _state(id);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(hic)));
        desk.buyAndBurn(1);
        assertEq(_state(id), before);
        AdversarialToken(address(hic)).setRejectedRecipient(address(0));
        assertEq(desk.buyAndBurn(1), 0.05 ether);
        assertEq(desk.lastBurnTime(), block.timestamp);
    }

    function test_failedMintBurnDoesNotConsumeAnIdOrFiniteAllowance() public {
        AdversarialToken implementation = new AdversarialToken();
        vm.etch(address(hic), address(implementation).code);
        AdversarialToken(address(hic)).setRejectedRecipient(desk.BURN_ADDRESS());
        vm.prank(holder);
        imd.approve(address(desk), 0.2 ether);
        uint256 holderBefore = imd.balanceOf(holder);
        uint256 poolBefore = imd.balanceOf(address(manager));
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(hic)));
        desk.mint("Retry", 1);
        assertEq(desk.totalCards(), 0);
        assertEq(cards.balanceOf(holder), 0);
        assertEq(imd.balanceOf(holder), holderBefore);
        assertEq(imd.balanceOf(address(manager)), poolBefore);
        assertEq(imd.balanceOf(owner), 0);
        assertEq(imd.allowance(holder, address(desk)), 0.2 ether);
        assertEq(hic.balanceOf(desk.BURN_ADDRESS()), 0);
        AdversarialToken(address(hic)).setRejectedRecipient(address(0));
        assertEq(_mint(holder), 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_sellFailureRestoresEveryObservableAccount(uint8 mode, uint256 raw) public {
        uint256 id = _setupCard(holder, 100 ether);
        uint256 out = _buy(id, 40 ether);
        uint256 amount = bound(raw, 2, out);
        mode = uint8(bound(mode, 0, 5));
        bytes4 reason;
        uint256 minOut = 1;
        if (mode == 0) {
            manager.setFill(5000);
            reason = HandlerDesk.PartialFill.selector;
        } else if (mode == 1) {
            manager.setShortSettlement(true);
            reason = HandlerDesk.UnsupportedToken.selector;
        } else if (mode == 2) {
            manager.setCallbackMode(1);
            reason = HandlerDesk.UnexpectedCallback.selector;
        } else if (mode == 3) {
            manager.setCallbackMode(2);
            reason = HandlerDesk.UnexpectedCallback.selector;
        } else if (mode == 4) {
            minOut = 0;
            reason = HandlerDesk.Slippage.selector;
        } else {
            minOut = amount + 1;
            reason = HandlerDesk.Slippage.selector;
        }
        bytes32 before = _state(id);
        vm.prank(agent);
        vm.expectRevert(reason);
        desk.sell(id, address(coin), amount, minOut);
        assertEq(_state(id), before);
        manager.setFill(10_000);
        manager.setShortSettlement(false);
        manager.setCallbackMode(0);
        assertGt(_sell(id, amount), 0);
    }

    function test_taxedInputSaleCannotLeaveUnpaidPoolDebtOrRemoveCost() public {
        uint256 id = _setupCard(holder, 100 ether);
        uint256 out = _buy(id, 40 ether);
        coin.setTax(100);
        bytes32 before = _state(id);
        vm.prank(agent);
        vm.expectRevert(HandlerDesk.UnsupportedToken.selector);
        desk.sell(id, address(coin), out, 1);
        assertEq(_state(id), before);
    }

    function test_taxedOutputUsesMeasuredQuantityAndExactMinimum() public {
        uint256 id = _setupCard(holder, 100 ether);
        coin.setTax(100);
        uint256 expected = 39.501 ether;
        bytes32 before = _state(id);
        vm.prank(agent);
        vm.expectRevert(HandlerDesk.Slippage.selector);
        desk.buy(id, address(coin), 40 ether, expected + 1);
        assertEq(_state(id), before);
        vm.prank(agent);
        assertEq(desk.buy(id, address(coin), 40 ether, expected), expected);
        (uint256 quantity, uint256 cost) = desk.positions(id, address(coin));
        assertEq(quantity, expected);
        assertEq(cost, 40 ether);
        _assertSolvent();
    }

    function test_sellMinimumIsNetAndExactBoundarySucceeds() public {
        uint256 id = _setupCard(holder, 100 ether);
        uint256 out = _buy(id, 40 ether);
        uint256 expected = 39.80025 ether;
        bytes32 before = _state(id);
        vm.prank(agent);
        vm.expectRevert(HandlerDesk.Slippage.selector);
        desk.sell(id, address(coin), out, expected + 1);
        assertEq(_state(id), before);
        vm.expectEmit(true, true, false, true, address(desk));
        emit HandlerDesk.Traded(id, address(coin), false, expected, out, -int256(0.19975 ether), false);
        vm.prank(agent);
        assertEq(desk.sell(id, address(coin), out, expected), expected);
    }

    function test_depositInsufficientAllowanceOrFundsPreservesState() public {
        uint256 id = _mint(holder);
        vm.prank(holder);
        imd.approve(address(desk), 3);
        bytes32 before = _state(id);
        vm.prank(holder);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(desk), 3, 4)
        );
        desk.deposit(id, 4);
        assertEq(_state(id), before);
        uint256 balance = imd.balanceOf(holder);
        vm.prank(holder);
        imd.approve(address(desk), balance + 1);
        before = _state(id);
        vm.prank(holder);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, holder, balance, balance + 1
            )
        );
        desk.deposit(id, balance + 1);
        assertEq(_state(id), before);
    }

    function test_donationsCannotBeWithdrawnOrUsedAsBurnReserve() public {
        uint256 id = _setupCard(holder, 100 ether);
        vm.prank(other);
        imd.transfer(address(desk), 17 ether);
        coin.mint(address(desk), 19 ether);
        hic.mint(address(desk), 23 ether);
        assertEq(desk.cardCoins(id).length, 1);
        vm.prank(holder);
        vm.expectRevert(HandlerDesk.InsufficientBalance.selector);
        desk.withdraw(id, address(coin), 1);
        vm.expectRevert(HandlerDesk.NothingToBurn.selector);
        desk.buyAndBurn(1);
        _buy(id, 40 ether);
        vm.prank(holder);
        desk.withdraw(id, address(coin), 39.9 ether);
        vm.prank(holder);
        desk.withdraw(id, address(imd), 60 ether);
        desk.buyAndBurn(1);
        assertEq(imd.balanceOf(address(desk)), 17 ether);
        assertEq(coin.balanceOf(address(desk)), 19 ether);
        assertEq(hic.balanceOf(address(desk)), 23 ether);
        assertEq(desk.totalLiability(address(imd)), 0);
        assertEq(desk.totalLiability(address(coin)), 0);
        assertEq(desk.burnImd(), 0);
    }

    function test_burningHicDoesNotSpendHicHeldByCards() public {
        uint256 id = _setupCard(holder, 100 ether);
        vm.prank(agent);
        uint256 held = desk.buy(id, address(hic), 40 ether, 1);
        uint256 liability = desk.totalLiability(address(hic));
        (uint256 q, uint256 cost) = desk.positions(id, address(hic));
        uint256 before = hic.balanceOf(desk.BURN_ADDRESS());
        desk.buyAndBurn(1);
        assertEq(hic.balanceOf(desk.BURN_ADDRESS()) - before, 0.05 ether);
        assertEq(hic.balanceOf(address(desk)), held);
        assertEq(desk.balances(id, address(hic)), held);
        assertEq(desk.totalLiability(address(hic)), liability);
        (uint256 afterQ, uint256 afterCost) = desk.positions(id, address(hic));
        assertEq(afterQ, q);
        assertEq(afterCost, cost);
        vm.prank(holder);
        desk.withdraw(id, address(hic), held);
        assertEq(hic.balanceOf(holder), held);
        _assertSolvent();
    }

    function test_feeRoundingAtOneWeiAndDivisorBoundaries() public {
        uint256[9] memory amounts = [uint256(1), 399, 400, 401, 799, 800, 801, 1199, 1200];
        uint256[9] memory fees = [uint256(0), 0, 1, 1, 1, 2, 2, 2, 3];
        uint256 id = _setupCard(holder, 10_000);
        for (uint256 i; i < amounts.length; ++i) {
            uint256 ownerBefore = imd.balanceOf(owner);
            uint256 burnBefore = desk.burnImd();
            uint256 result = _buy(id, amounts[i]);
            assertEq(result, amounts[i] - fees[i]);
            assertEq(imd.balanceOf(owner) - ownerBefore, fees[i] / 2);
            assertEq(desk.burnImd() - burnBefore, fees[i] - fees[i] / 2);
            _assertSolvent();
        }
    }

    function test_loweringCapBelowSpentDoesNotUnderflowOrRefundOnSell() public {
        uint256 id = _setupCard(holder, 100 ether);
        uint256 out = _buy(id, 40 ether);
        vm.prank(holder);
        desk.setRules(id, 1 ether, type(uint256).max);
        _sell(id, out);
        assertEq(desk.spentToday(id), 40 ether);
        bytes32 before = _state(id);
        vm.prank(agent);
        vm.expectRevert(HandlerDesk.DailyLimit.selector);
        desk.buy(id, address(coin), 1, 1);
        assertEq(_state(id), before);
        vm.prank(holder);
        desk.setRules(id, type(uint256).max, type(uint256).max);
        _buy(id, 1);
        assertEq(desk.spentToday(id), 40 ether + 1);
    }

    function test_failedFirstBuyOnNewDayDoesNotCommitReset() public {
        uint256 id = _setupCard(holder, 100 ether);
        _buy(id, 40 ether);
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days);
        bytes32 before = _state(id);
        assertEq(desk.spentToday(id), 0);
        vm.prank(agent);
        vm.expectRevert(HandlerDesk.Slippage.selector);
        desk.buy(id, address(coin), 10 ether, 10 ether);
        assertEq(_state(id), before);
        _buy(id, 10 ether);
        assertEq(desk.spentToday(id), 10 ether);
    }

    function test_twoCardsOfOneHolderHaveIndependentCapsAgentsAndPositions() public {
        uint256 a = _setupCard(holder, 100 ether);
        uint256 b = _setupCard(holder, 100 ether);
        vm.startPrank(holder);
        desk.setRules(a, 10 ether, 10 ether);
        desk.setRules(b, 10 ether, 10 ether);
        desk.setAgent(b, other);
        vm.stopPrank();
        _buy(a, 10 ether);
        vm.prank(agent);
        vm.expectRevert(HandlerDesk.OnlyAgent.selector);
        desk.buy(b, address(coin), 1, 1);
        vm.prank(other);
        desk.buy(b, address(coin), 10 ether, 1);
        vm.prank(holder);
        desk.freeze(a);
        vm.prank(other);
        desk.sell(b, address(coin), 9.975 ether, 1);
        assertEq(desk.spentToday(a), 10 ether);
        assertEq(desk.spentToday(b), 10 ether);
        assertEq(desk.balances(a, address(coin)), 9.975 ether);
        assertEq(desk.getCard(a).trades, 1);
        assertEq(desk.getCard(b).trades, 2);
        _assertSolvent();
    }

    function test_pendingOwnerReceivesNoFeesUntilAcceptanceAndOldOwnerLosesPower() public {
        uint256 id = _setupCard(holder, 100 ether);
        vm.prank(owner);
        desk.transferOwnership(stranger);
        uint256 oldBefore = imd.balanceOf(owner);
        _buy(id, 40 ether);
        assertEq(imd.balanceOf(owner) - oldBefore, 0.05 ether);
        assertEq(imd.balanceOf(stranger), 0);
        vm.prank(stranger);
        desk.acceptOwnership();
        oldBefore = imd.balanceOf(owner);
        _sell(id, 39.9 ether);
        assertEq(imd.balanceOf(owner), oldBefore);
        assertEq(imd.balanceOf(stranger), 0.049875 ether);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        desk.setMintPrice(1 ether);
        assertEq(desk.pendingOwner(), address(0));
        _assertSolvent();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_depositWithdrawRoundTripPreservesOtherCardAndBurn(uint256 raw) public {
        uint256 id = _setupCard(holder, 100 ether);
        _buy(id, 40 ether);
        uint256 second = _mint(other);
        uint256 amount = bound(raw, 1, imd.balanceOf(other));
        bytes32 first = _state(id);
        uint256 before = imd.balanceOf(other);
        vm.startPrank(other);
        desk.deposit(second, amount);
        desk.freeze(second);
        desk.withdraw(second, address(imd), amount);
        vm.stopPrank();
        assertEq(imd.balanceOf(other), before);
        assertEq(_state(id), first);
        assertEq(desk.balances(second, address(imd)), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_costBasisIsConservedAcrossBuySellAndWithdrawal(
        uint256 a,
        uint256 b,
        uint256 saleSeed,
        uint256 withdrawSeed,
        uint256 rateSeed
    ) public {
        a = bound(a, 1, 100 ether);
        b = bound(b, 1, 100 ether);
        uint256 rate = bound(rateSeed, 1 ether, 3 ether);
        uint256 id = _setupCard(holder, a + b);
        uint256 first = _buy(id, a);
        manager.setRate(address(imd), address(coin), rate);
        uint256 second = _buy(id, b);
        uint256 quantity = first + second;
        uint256 sale = bound(saleSeed, 1, quantity - 1);
        uint256 removedBySale = (a + b) * sale / quantity;
        uint256 proceeds = _sell(id, sale);
        uint256 withdrawal = bound(withdrawSeed, 1, quantity - sale);
        uint256 removedByWithdrawal = (a + b - removedBySale) * withdrawal / (quantity - sale);
        vm.prank(holder);
        desk.withdraw(id, address(coin), withdrawal);
        (uint256 q, uint256 cost) = desk.positions(id, address(coin));
        assertEq(q + sale + withdrawal, quantity);
        assertEq(cost + removedBySale + removedByWithdrawal, a + b);
        assertEq(desk.getCard(id).pnl, int256(proceeds) - int256(removedBySale));
        assertEq(desk.getCard(id).trades, 3);
        if (q != 0) {
            proceeds += _sell(id, q);
            assertEq(desk.getCard(id).pnl, int256(proceeds) - int256(a + b - removedByWithdrawal));
        }
        (q, cost) = desk.positions(id, address(coin));
        assertEq(q, 0);
        assertEq(cost, 0, "full exit must remove all rounding residue");
        _assertSolvent();
    }
}
