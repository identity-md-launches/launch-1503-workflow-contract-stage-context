// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HandlerDesk} from "src/HandlerDesk.sol";
import {HandlerCards} from "src/HandlerCards.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockToken, MockPoolManager} from "./Mocks.sol";

/// @dev Reference ledger built from requested actions, never refreshed from Desk balances/positions.
/// Mock exchange rates describe external execution; Desk return values must agree with them.
contract DeskAccountingHandler is Test {
    struct Ledger {
        address holder;
        address agent;
        bool frozen;
        uint256 cap;
        uint256 perTrade;
        uint256 spentDay;
        uint256 spent;
        uint256 deposits;
        uint256 imdWithdrawn;
        uint256 buyCost;
        uint256 netSales;
        uint256 buys;
        uint256 sells;
        uint256 wins;
        uint256 volume;
        int256 pnl;
    }

    struct CoinLedger {
        uint256 quantity;
        uint256 cost;
        uint256 boughtCost;
        uint256 soldCost;
        uint256 withdrawnCost;
        bool everBought;
    }

    HandlerDesk public immutable desk;
    MockPoolManager public immutable manager;
    address[3] public tokens; // IMD, application coin, HIC
    address[2] public feeRecipients;
    address[3] public initialAgents;
    address public immutable outsider;
    uint256 public immutable mintedAt;
    mapping(uint256 => Ledger) internal ledgers;
    mapping(uint256 => mapping(address => CoinLedger)) internal positions;
    mapping(address => uint256) public donations;
    mapping(address => uint256) public feeReceipts;
    mapping(address => uint256) public buyRates;
    mapping(address => uint256) public sellRates;
    uint256 public reserve;
    uint256 public hicBurned;
    uint256 public lastBurn;
    bool public burned;
    address public currentOwner;
    uint256 public successfulBuys;
    uint256 public successfulSells;
    uint256 public expectedFailures;

    constructor(HandlerDesk desk_, address coin_, address[3] memory holders, address[3] memory agents) {
        desk = desk_;
        manager = MockPoolManager(address(desk_.POOL_MANAGER()));
        tokens = [desk_.IMD(), coin_, desk_.hic()];
        feeRecipients = [desk_.owner(), makeAddr("model successor owner")];
        currentOwner = feeRecipients[0];
        outsider = makeAddr("model outsider");
        initialAgents = agents;
        mintedAt = block.timestamp;
        buyRates[coin_] = 1 ether;
        buyRates[tokens[2]] = 1 ether;
        sellRates[coin_] = 1 ether;
        sellRates[tokens[2]] = 1 ether;
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(holders[i]);
            uint256 id = desk_.mint("Ledger Agent", 0.1 ether);
            assertEq(id, i + 1);
            desk_.deposit(id, 1000 ether);
            desk_.setRules(id, 250 ether, 100 ether);
            desk_.setAgent(id, agents[i]);
            vm.stopPrank();
            Ledger storage m = ledgers[id];
            m.holder = holders[i];
            m.agent = agents[i];
            m.cap = 250 ether;
            m.perTrade = 100 ether;
            m.deposits = 1000 ether;
            feeReceipts[currentOwner] += 0.1 ether;
            hicBurned += 0.1 ether;
        }
    }

    function _id(uint256 seed) internal pure returns (uint256) {
        return seed % 3 + 1;
    }

    function _imdBalance(Ledger storage m) internal view returns (uint256) {
        return m.deposits + m.netSales - m.buyCost - m.imdWithdrawn;
    }

    function _spent(Ledger storage m) internal view returns (uint256) {
        return m.spentDay == block.timestamp / 1 days ? m.spent : 0;
    }

    /// @dev Reverts and unexpected successes both fail the harness; no catch-and-ignore paths.
    function _call(address actor, address target, bytes memory data, bytes memory expected)
        internal
        returns (bytes memory result)
    {
        vm.prank(actor);
        (bool success, bytes memory returned) = target.call(data);
        if (expected.length == 0) {
            assertTrue(success, "valid action unexpectedly reverted");
            return returned;
        }
        assertFalse(success, "forbidden action unexpectedly succeeded");
        assertEq(returned, expected, "action reverted for an unexpected reason");
        expectedFailures++;
    }

    function deposit(uint256 which, uint256 raw) external {
        uint256 id = _id(which);
        Ledger storage m = ledgers[id];
        uint256 amount = bound(raw, 1, 100 ether);
        uint256 before = MockToken(tokens[0]).balanceOf(m.holder);
        _call(m.holder, address(desk), abi.encodeCall(desk.deposit, (id, amount)), "");
        assertEq(MockToken(tokens[0]).balanceOf(m.holder), before - amount);
        m.deposits += amount;
    }

    function buy(uint256 which, uint256 raw, bool useHic) external {
        uint256 id = _id(which);
        Ledger storage m = ledgers[id];
        address token = tokens[useHic ? 2 : 1];
        uint256 spent = _spent(m);
        uint256 remaining = m.cap > spent ? m.cap - spent : 0;
        uint256 maximum = _imdBalance(m);
        if (maximum > m.perTrade) maximum = m.perTrade;
        if (maximum > remaining) maximum = remaining;
        if (maximum > 100 ether) maximum = 100 ether;
        uint256 amount = maximum == 0 ? 1 : bound(raw, 1, maximum);
        uint256 fee = amount * 25 / 10_000;
        uint256 output = (amount - fee) * buyRates[token] / 1 ether;
        bytes memory error_;
        if (m.agent == address(0)) {
            error_ = abi.encodeWithSelector(HandlerDesk.OnlyAgent.selector);
        } else if (m.frozen) {
            error_ = abi.encodeWithSelector(HandlerDesk.CardFrozen.selector);
        } else if (amount > m.perTrade) {
            error_ = abi.encodeWithSelector(HandlerDesk.PerTradeLimit.selector);
        } else if (amount + spent > m.cap) {
            error_ = abi.encodeWithSelector(HandlerDesk.DailyLimit.selector);
        } else if (amount > _imdBalance(m)) {
            error_ = abi.encodeWithSelector(HandlerDesk.InsufficientBalance.selector);
        } else if (output == 0) {
            error_ = abi.encodeWithSelector(HandlerDesk.InvalidAmount.selector);
        }
        bytes memory result = _call(
            m.agent == address(0) ? initialAgents[id - 1] : m.agent,
            address(desk),
            abi.encodeCall(desk.buy, (id, token, amount, 1)),
            error_
        );
        if (error_.length != 0) return;
        assertEq(abi.decode(result, (uint256)), output, "buy must return measured output");
        m.buyCost += amount;
        m.buys++;
        m.volume += amount;
        m.spentDay = block.timestamp / 1 days;
        m.spent = spent + amount;
        CoinLedger storage p = positions[id][token];
        p.quantity += output;
        p.cost += amount;
        p.boughtCost += amount;
        p.everBought = true;
        _fee(fee);
        successfulBuys++;
    }

    function sell(uint256 which, uint256 raw, bool useHic) external {
        uint256 id = _id(which);
        Ledger storage m = ledgers[id];
        address token = tokens[useHic ? 2 : 1];
        CoinLedger storage p = positions[id][token];
        uint256 amount = p.quantity == 0 ? 1 : bound(raw, 1, p.quantity);
        uint256 gross = amount * sellRates[token] / 1 ether;
        bytes memory error_;
        if (m.agent == address(0)) error_ = abi.encodeWithSelector(HandlerDesk.OnlyAgent.selector);
        else if (m.frozen) error_ = abi.encodeWithSelector(HandlerDesk.CardFrozen.selector);
        else if (amount > p.quantity) error_ = abi.encodeWithSelector(
            HandlerDesk.InsufficientBalance.selector
        );
        else if (gross == 0) error_ = abi.encodeWithSelector(HandlerDesk.InvalidAmount.selector);
        bytes memory result = _call(
            m.agent == address(0) ? initialAgents[id - 1] : m.agent,
            address(desk),
            abi.encodeCall(desk.sell, (id, token, amount, 1)),
            error_
        );
        if (error_.length != 0) return;
        uint256 fee = gross * 25 / 10_000;
        uint256 proceeds = gross - fee;
        assertEq(abi.decode(result, (uint256)), proceeds, "sell must return output after fees");
        uint256 cost = p.cost * amount / p.quantity;
        p.quantity -= amount;
        p.cost -= cost;
        p.soldCost += cost;
        m.netSales += proceeds;
        m.sells++;
        if (proceeds > cost) m.wins++;
        m.pnl += int256(proceeds) - int256(cost);
        m.volume += gross;
        _fee(fee);
        successfulSells++;
    }

    function withdraw(uint256 which, uint256 raw, uint256 currency) external {
        uint256 id = _id(which);
        address token = tokens[currency % 3];
        uint256 available = token == tokens[0] ? _imdBalance(ledgers[id]) : positions[id][token].quantity;
        if (available == 0) {
            _call(
                ledgers[id].holder,
                address(desk),
                abi.encodeCall(desk.withdraw, (id, token, 1)),
                abi.encodeWithSelector(HandlerDesk.InsufficientBalance.selector)
            );
            return;
        }
        _withdraw(id, token, bound(raw, 1, available));
    }

    function _withdraw(uint256 id, address token, uint256 amount) internal {
        Ledger storage m = ledgers[id];
        uint256 before = MockToken(token).balanceOf(m.holder);
        _call(m.holder, address(desk), abi.encodeCall(desk.withdraw, (id, token, amount)), "");
        assertEq(MockToken(token).balanceOf(m.holder), before + amount, "only holder receives withdrawal");
        if (token == tokens[0]) {
            m.imdWithdrawn += amount;
        } else {
            CoinLedger storage p = positions[id][token];
            uint256 cost = p.cost * amount / p.quantity;
            p.quantity -= amount;
            p.cost -= cost;
            p.withdrawnCost += cost;
        }
    }

    function depositRoundTrip(uint256 which, uint256 raw) external {
        uint256 id = _id(which);
        Ledger storage m = ledgers[id];
        uint256 amount = bound(raw, 1, 100 ether);
        uint256 before = MockToken(tokens[0]).balanceOf(m.holder);
        _call(m.holder, address(desk), abi.encodeCall(desk.deposit, (id, amount)), "");
        _call(m.holder, address(desk), abi.encodeCall(desk.withdraw, (id, tokens[0], amount)), "");
        assertEq(MockToken(tokens[0]).balanceOf(m.holder), before, "custody round trip must be lossless");
        // Net zero: the independent ledger intentionally remains unchanged.
    }

    function configure(uint256 which, uint256 action, uint256 a, uint256 b) external {
        uint256 id = _id(which);
        Ledger storage m = ledgers[id];
        action %= 3;
        if (action == 0) {
            uint256 cap = bound(a, 0, 500 ether);
            uint256 perTrade = bound(b, 0, 100 ether);
            _call(m.holder, address(desk), abi.encodeCall(desk.setRules, (id, cap, perTrade)), "");
            m.cap = cap;
            m.perTrade = perTrade;
        } else if (action == 1) {
            _call(
                m.holder,
                address(desk),
                m.frozen ? abi.encodeCall(desk.unfreeze, (id)) : abi.encodeCall(desk.freeze, (id)),
                ""
            );
            m.frozen = !m.frozen;
        } else {
            address newAgent = a % 3 == 0 ? address(0) : (a % 3 == 1 ? initialAgents[id - 1] : m.holder);
            _call(m.holder, address(desk), abi.encodeCall(desk.setAgent, (id, newAgent)), "");
            m.agent = newAgent;
        }
    }

    function donate(uint256 currency, uint256 raw) external {
        address token = tokens[currency % 3];
        uint256 amount = bound(raw, 1, 100 ether);
        MockToken(token).mint(address(this), amount);
        MockToken(token).transfer(address(desk), amount);
        donations[token] += amount;
    }

    function changeRate(bool useHic, bool buySide, uint256 raw) external {
        address token = tokens[useHic ? 2 : 1];
        uint256 rate = bound(raw, 0.25 ether, 4 ether);
        if (buySide) {
            buyRates[token] = rate;
            manager.setRate(tokens[0], token, rate);
        } else {
            sellRates[token] = rate;
            manager.setRate(token, tokens[0], rate);
        }
    }

    function advanceTime(uint256 raw) external {
        vm.warp(block.timestamp + bound(raw, 0, 2 days));
    }

    function burn() external {
        bytes memory error_;
        uint256 output = reserve * buyRates[tokens[2]] / 1 ether;
        if (burned && block.timestamp < lastBurn + 1 hours) {
            error_ = abi.encodeWithSelector(HandlerDesk.BurnTooSoon.selector);
        } else if (reserve == 0) {
            error_ = abi.encodeWithSelector(HandlerDesk.NothingToBurn.selector);
        } else if (output == 0) {
            error_ = abi.encodeWithSelector(HandlerDesk.InvalidAmount.selector);
        }
        bytes memory result = _call(outsider, address(desk), abi.encodeCall(desk.buyAndBurn, (1)), error_);
        if (error_.length != 0) return;
        assertEq(abi.decode(result, (uint256)), output);
        reserve = 0;
        hicBurned += output;
        burned = true;
        lastBurn = block.timestamp;
    }

    function changeOwner() external {
        address next = currentOwner == feeRecipients[0] ? feeRecipients[1] : feeRecipients[0];
        _call(currentOwner, address(desk), abi.encodeCall(desk.transferOwnership, (next)), "");
        assertEq(desk.owner(), currentOwner, "nomination must not change fee authority");
        _call(next, address(desk), abi.encodeCall(desk.acceptOwnership, ()), "");
        currentOwner = next;
    }

    function unauthorized(uint256 which, uint256 action) external {
        uint256 id = _id(which);
        action %= 9;
        bytes memory data;
        bytes memory error_ = abi.encodeWithSelector(HandlerDesk.OnlyHolder.selector);
        address target = address(desk);
        if (action == 0) {
            data = abi.encodeCall(desk.withdraw, (id, tokens[0], 1));
        } else if (action == 1) {
            data = abi.encodeCall(desk.deposit, (id, 1));
        } else if (action == 2) {
            data = abi.encodeCall(desk.setAgent, (id, outsider));
        } else if (action == 3) {
            data = abi.encodeCall(desk.setRules, (id, type(uint256).max, type(uint256).max));
        } else if (action == 4) {
            data = abi.encodeCall(desk.buy, (id, tokens[1], 1, 1));
            error_ = abi.encodeWithSelector(HandlerDesk.OnlyAgent.selector);
        } else if (action == 5) {
            data = abi.encodeCall(desk.sell, (id, tokens[1], 1, 1));
            error_ = abi.encodeWithSelector(HandlerDesk.OnlyAgent.selector);
        } else if (action == 6) {
            data = abi.encodeCall(desk.setMintPrice, (1 ether));
            error_ = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider);
        } else if (action == 7) {
            data = abi.encodeCall(desk.unlockCallback, (abi.encode(tokens[0], tokens[1], uint256(1))));
            error_ = abi.encodeWithSelector(HandlerDesk.UnexpectedCallback.selector);
        } else {
            target = address(desk.cards());
            data = abi.encodeWithSignature(
                "transferFrom(address,address,uint256)", ledgers[id].holder, outsider, id
            );
            error_ = abi.encodeWithSelector(HandlerCards.Soulbound.selector);
        }
        _call(outsider, target, data, error_);
    }

    function _fee(uint256 fee) internal {
        feeReceipts[currentOwner] += fee / 2;
        reserve += fee - fee / 2;
    }

    function assertCustody() external view {
        for (uint256 t; t < 3; ++t) {
            address token = tokens[t];
            uint256 total;
            for (uint256 id = 1; id <= 3; ++id) {
                uint256 expected = t == 0 ? _imdBalance(ledgers[id]) : positions[id][token].quantity;
                assertEq(desk.balances(id, token), expected, "card balance must match action ledger");
                total += expected;
            }
            assertEq(desk.totalLiability(token), total, "aggregate liability must match all cards");
            assertEq(
                MockToken(token).balanceOf(address(desk)),
                total + donations[token] + (t == 0 ? reserve : 0),
                "actual custody must back balances, donations and burn reserve"
            );
            assertEq(
                MockToken(token).allowance(address(desk), address(manager)), 0, "manager has no allowance"
            );
        }
        assertEq(desk.burnImd(), reserve);
        assertEq(desk.hasBurned(), burned);
        assertEq(desk.lastBurnTime(), lastBurn);
        assertEq(MockToken(tokens[2]).balanceOf(desk.BURN_ADDRESS()), hicBurned);
        for (uint256 i; i < 2; ++i) {
            assertEq(MockToken(tokens[0]).balanceOf(feeRecipients[i]), feeReceipts[feeRecipients[i]]);
        }
    }

    function assertRecordsAndAuthority() external view {
        assertEq(desk.totalCards(), 3);
        assertEq(desk.owner(), currentOwner);
        assertEq(desk.pendingOwner(), address(0));
        for (uint256 id = 1; id <= 3; ++id) {
            Ledger storage m = ledgers[id];
            HandlerDesk.Card memory c = desk.getCard(id);
            assertEq(c.agent, m.agent);
            assertEq(c.frozen, m.frozen);
            assertEq(c.dailyCap, m.cap);
            assertEq(c.maxPerTrade, m.perTrade);
            assertEq(desk.spentToday(id), _spent(m));
            assertEq(c.trades, m.buys + m.sells);
            assertEq(c.wins, m.wins);
            assertEq(c.losses, m.sells - m.wins);
            assertEq(c.pnl, m.pnl);
            assertEq(c.volume, m.volume);
            assertEq(c.mintedAt, mintedAt);
            assertEq(c.name, "Ledger Agent");
            assertEq(desk.cards().ownerOf(id), m.holder);
            assertTrue(desk.cards().locked(id));
            assertEq(desk.cards().getApproved(id), address(0));
            uint256 soldCost;
            uint256 coinCount = 1;
            for (uint256 t = 1; t < 3; ++t) {
                CoinLedger storage p = positions[id][tokens[t]];
                (uint256 quantity, uint256 cost) = desk.positions(id, tokens[t]);
                assertEq(quantity, p.quantity);
                assertEq(cost, p.cost);
                assertEq(
                    cost + p.soldCost + p.withdrawnCost, p.boughtCost, "all invested basis is accounted for"
                );
                if (quantity == 0) assertEq(cost, 0, "closed position has no residual basis");
                soldCost += p.soldCost;
                if (p.everBought) coinCount++;
            }
            assertEq(m.pnl, int256(m.netSales) - int256(soldCost), "P&L uses only realized sales");
            address[] memory known = desk.cardCoins(id);
            assertEq(known.length, coinCount, "coin history must be deduplicated and ignore donations");
            assertEq(known[0], tokens[0]);
            for (uint256 i = 1; i < known.length; ++i) {
                assertTrue(positions[id][known[i]].everBought);
                for (uint256 j; j < i; ++j) {
                    assertNotEq(known[i], known[j]);
                }
            }
        }
    }

    /// @dev Not a fuzz target: used at the end of every sequence to prove withdrawal liveness.
    function withdrawAll() external {
        for (uint256 id = 1; id <= 3; ++id) {
            for (uint256 t; t < 3; ++t) {
                uint256 amount = t == 0 ? _imdBalance(ledgers[id]) : positions[id][tokens[t]].quantity;
                if (amount != 0) _withdraw(id, tokens[t], amount);
                assertEq(desk.balances(id, tokens[t]), 0);
            }
        }
        for (uint256 t; t < 3; ++t) {
            assertEq(desk.totalLiability(tokens[t]), 0);
        }
    }
}
