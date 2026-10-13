// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DeskFixture} from "./helpers/DeskFixture.sol";
import {DeskAccountingHandler} from "./helpers/DeskAccountingHandler.sol";

contract DeskAccountingInvariantTest is DeskFixture {
    DeskAccountingHandler internal actions;

    function setUp() public override {
        super.setUp();
        // Cards 1 and 3 share a holder; all start with distinct agents.
        actions = new DeskAccountingHandler(
            desk, address(coin), [holder, other, holder], [agent, makeAddr("second agent"), holder]
        );
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = actions.deposit.selector;
        selectors[1] = actions.buy.selector;
        selectors[2] = actions.sell.selector;
        selectors[3] = actions.withdraw.selector;
        selectors[4] = actions.depositRoundTrip.selector;
        selectors[5] = actions.configure.selector;
        selectors[6] = actions.donate.selector;
        selectors[7] = actions.changeRate.selector;
        selectors[8] = actions.advanceTime.selector;
        selectors[9] = actions.burn.selector;
        selectors[10] = actions.changeOwner.selector;
        selectors[11] = actions.unauthorized.selector;
        targetContract(address(actions));
        targetSelector(FuzzSelector({addr: address(actions), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 128
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_everyAssetAndFeeMatchesIndependentLedger() public view {
        actions.assertCustody();
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 128
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_positionsStatsLimitsAndAuthorityMatchActions() public view {
        actions.assertRecordsAndAuthority();
    }

    function afterInvariant() public {
        // Frozen/revoked cards and exhausted limits must still allow their holders to exit.
        actions.withdrawAll();
        actions.assertCustody();
        actions.assertRecordsAndAuthority();
    }

    function test_handlerReachesSuccessFailureAndWithdrawalLiveness() public {
        actions.buy(0, 40 ether, false);
        actions.buy(1, 40 ether, true);
        actions.changeRate(false, false, 2 ether);
        actions.sell(0, type(uint256).max, false);
        actions.configure(1, 1, 0, 0); // freeze second card
        actions.sell(1, 1, true); // exact CardFrozen failure
        actions.configure(2, 2, 0, 0); // revoke third card
        actions.buy(2, 1, false); // exact OnlyAgent failure
        actions.changeOwner();
        actions.donate(0, 17 ether);
        actions.donate(1, 19 ether);
        actions.depositRoundTrip(1, 1 ether);
        actions.unauthorized(0, 0);
        actions.burn();
        actions.burn(); // exact BurnTooSoon failure
        actions.advanceTime(1 days);
        actions.assertCustody();
        actions.assertRecordsAndAuthority();
        assertEq(actions.successfulBuys(), 2);
        assertEq(actions.successfulSells(), 1);
        assertEq(actions.expectedFailures(), 4);
        afterInvariant();
    }
}
