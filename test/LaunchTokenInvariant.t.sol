// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract LaunchTokenActions is Test {
    LaunchToken public immutable token;
    address[4] public actors;
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    constructor(LaunchToken token_, address deployer) {
        token = token_;
        actors = [deployer, makeAddr("token alice"), makeAddr("token bob"), makeAddr("token carol")];
        balances[deployer] = 1e27;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 raw) external {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        uint256 amount = bound(raw, 0, balances[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        balances[from] -= amount;
        balances[to] += amount;
    }

    function approve(uint256 fromSeed, uint256 spenderSeed, uint256 raw, bool infinite) external {
        address from = actors[fromSeed % 4];
        address spender = actors[spenderSeed % 4];
        uint256 amount = infinite ? type(uint256).max : bound(raw, 0, 1e27);
        vm.prank(from);
        assertTrue(token.approve(spender, amount));
        allowances[from][spender] = amount;
    }

    function transferFrom(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 raw, bool exceed)
        external
    {
        address from = actors[fromSeed % 4];
        address spender = actors[spenderSeed % 4];
        address to = actors[toSeed % 4];
        uint256 allowance = allowances[from][spender];
        uint256 maximum = balances[from] < allowance ? balances[from] : allowance;
        uint256 amount = exceed ? maximum + 1 : bound(raw, 0, maximum);
        bytes memory expected;
        if (amount > allowance) {
            expected = abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowance, amount
            );
        } else if (amount > balances[from]) {
            expected = abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, from, balances[from], amount
            );
        }
        vm.prank(spender);
        (bool success, bytes memory result) =
            address(token).call(abi.encodeCall(token.transferFrom, (from, to, amount)));
        if (expected.length != 0) {
            assertFalse(success, "overspending must fail");
            assertEq(result, expected);
            return;
        }
        assertTrue(success, "authorized transfer must succeed");
        assertTrue(abi.decode(result, (bool)));
        balances[from] -= amount;
        balances[to] += amount;
        if (allowance != type(uint256).max) allowances[from][spender] -= amount;
    }

    function invalidDestination(uint256 fromSeed, bool approval) external {
        address from = actors[fromSeed % 4];
        bytes memory data = approval
            ? abi.encodeCall(token.approve, (address(0), 1))
            : abi.encodeCall(token.transfer, (address(0), 0));
        bytes4 selector =
            approval ? IERC20Errors.ERC20InvalidSpender.selector : IERC20Errors.ERC20InvalidReceiver.selector;
        vm.prank(from);
        (bool success, bytes memory result) = address(token).call(data);
        assertFalse(success);
        assertEq(result, abi.encodeWithSelector(selector, address(0)));
    }

    function assertLedger() external view {
        uint256 total;
        for (uint256 i; i < 4; ++i) {
            assertEq(
                token.balanceOf(actors[i]), balances[actors[i]], "balances follow only authorized transfers"
            );
            total += token.balanceOf(actors[i]);
            for (uint256 j; j < 4; ++j) {
                assertEq(
                    token.allowance(actors[i], actors[j]),
                    allowances[actors[i]][actors[j]],
                    "finite approvals are spent exactly; infinite approvals remain infinite"
                );
            }
        }
        assertEq(total, 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(0)), 0);
    }
}

contract LaunchTokenInvariantTest is Test {
    LaunchToken internal token;
    LaunchTokenActions internal actions;

    function setUp() public {
        token = new LaunchToken();
        actions = new LaunchTokenActions(token, address(this));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = actions.transfer.selector;
        selectors[1] = actions.approve.selector;
        selectors[2] = actions.transferFrom.selector;
        selectors[3] = actions.invalidDestination.selector;
        targetContract(address(actions));
        targetSelector(FuzzSelector({addr: address(actions), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 128
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_fixedSupplyBalancesAndAuthorizations() public view {
        actions.assertLedger();
    }

    function test_fullSupplyAndInfiniteAllowanceSurviveSelfTransfersAndRevocation() public {
        actions.approve(0, 1, 0, true);
        actions.transferFrom(0, 1, 0, 1e27, false); // full supply, self transfer
        actions.assertLedger();
        actions.transferFrom(0, 1, 2, 1e27, false); // all supply moves
        actions.approve(2, 1, 1e27, false);
        actions.transferFrom(2, 1, 0, 1e27, false); // finite allowance exhausted
        actions.approve(0, 1, 0, false); // revoke the original infinite approval
        actions.transferFrom(0, 1, 2, 1, true); // cannot reuse it
        actions.assertLedger();
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.allowance(address(this), actions.actors(1)), 0);
    }
}
