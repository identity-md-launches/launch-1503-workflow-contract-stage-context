// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HandlerDesk} from "../src/HandlerDesk.sol";
import {HandlerArt} from "../src/HandlerArt.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {MockToken} from "./helpers/Mocks.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Local simulation of the brief's initialization-only factory guard, not a production hook.
contract InitializationHook {
    address public immutable factory;
    address public immutable manager;

    constructor(address factory_, address manager_) {
        factory = factory_;
        manager = manager_;
    }

    function beforeInitialize(address sender, PoolKey calldata, uint160) external view returns (bytes4) {
        require(msg.sender == manager && sender == factory, "only factory initialization");
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external view returns (bytes4) {
        require(msg.sender == manager);
        return IHooks.afterInitialize.selector;
    }
}

contract LiquiditySeeder is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function add(PoolKey memory key, int256 liquidity) external {
        manager.unlock(abi.encode(key, liquidity));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, int256 liquidity) = abi.decode(data, (PoolKey, int256));
        (BalanceDelta delta,) = manager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -887220, tickUpper: 887220, liquidityDelta: liquidity, salt: 0
            }),
            bytes("")
        );
        _pay(key.currency0, delta.amount0());
        _pay(key.currency1, delta.amount1());
        return bytes("");
    }

    function _pay(Currency currency, int128 delta) private {
        if (delta < 0) {
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).transfer(address(manager), uint256(-int256(delta)));
            manager.settle();
        }
    }
}

/// @notice Exercises the actual vendored v4 core, with local tokens and an initialization-only hook.
contract UniswapIntegrationTest is Test {
    HandlerDesk internal desk;
    IPoolManager internal manager;
    MockToken internal imd;
    LaunchToken internal hic;
    MockToken internal lowCoin;
    MockToken internal highCoin;
    LiquiditySeeder internal seeder;
    address internal owner = makeAddr("owner");
    address internal holder = makeAddr("holder");
    address internal agent = makeAddr("agent");

    function setUp() public {
        vm.warp(1_800_000_000);
        hic = new LaunchToken();
        HandlerArt art = new HandlerArt();
        desk = new HandlerDesk(owner, address(hic), address(art));
        MockToken tokenImpl = new MockToken();
        vm.etch(desk.IMD(), address(tokenImpl).code);
        imd = MockToken(desk.IMD());
        // Fixed-address tokens guarantee both currency orderings are exercised.
        vm.etch(address(0x1000), address(tokenImpl).code);
        vm.etch(address(type(uint160).max), address(tokenImpl).code);
        lowCoin = MockToken(address(0x1000));
        highCoin = MockToken(address(type(uint160).max));
        PoolManager implementation = new PoolManager(owner);
        manager = desk.POOL_MANAGER();
        // Relocate only NoDelegateCall's immutable original-address constant. Storage starts empty;
        // pool initialization and real swaps/settlement execute the unmodified upstream implementation.
        bytes memory runtime = address(implementation).code;
        uint256 replacements = _relocate(runtime, address(implementation), address(manager));
        assertGt(replacements, 0);
        vm.etch(address(manager), runtime);
        InitializationHook hook = new InitializationHook(address(this), address(manager));
        vm.etch(desk.LAUNCH_HOOK(), address(hook).code);
        seeder = new LiquiditySeeder(manager);
        imd.mint(address(seeder), 10_000_000 ether);
        lowCoin.mint(address(seeder), 10_000_000 ether);
        highCoin.mint(address(seeder), 10_000_000 ether);
        hic.transfer(address(seeder), 10_000_000 ether);
        _initialize(address(hic));
        _initialize(address(lowCoin));
        _initialize(address(highCoin));
        imd.mint(holder, 10_000 ether);
        vm.prank(holder);
        imd.approve(address(desk), type(uint256).max);
    }

    function _relocate(bytes memory runtime, address original, address target)
        private
        pure
        returns (uint256 count)
    {
        bytes20 oldBytes = bytes20(original);
        bytes20 newBytes = bytes20(target);
        for (uint256 i; i + 20 <= runtime.length; ++i) {
            bool match_ = true;
            for (uint256 j; j < 20; ++j) {
                if (runtime[i + j] != oldBytes[j]) {
                    match_ = false;
                    break;
                }
            }
            if (!match_) continue;
            for (uint256 j; j < 20; ++j) {
                runtime[i + j] = newBytes[j];
            }
            count++;
            i += 19;
        }
    }

    function _initialize(address token) internal {
        PoolKey memory key = desk.poolKey(token);
        manager.initialize(key, uint160(1 << 96));
        seeder.add(key, 1_000_000 ether);
    }

    function _card() private returns (uint256 id) {
        vm.startPrank(holder);
        id = desk.mint("Real V4", 0.09 ether);
        desk.deposit(id, 1000 ether);
        desk.setAgent(id, agent);
        desk.setRules(id, 1000 ether, 100 ether);
        vm.stopPrank();
    }

    function _roundTrip(uint256 id, address token) private {
        uint256 before = desk.balances(id, desk.IMD());
        vm.prank(agent);
        uint256 out = desk.buy(id, token, 100 ether, 90 ether);
        assertGt(out, 90 ether);
        assertLt(out, 100 ether);
        assertEq(desk.balances(id, token), out);
        assertEq(IERC20(token).balanceOf(address(desk)), out);
        vm.prank(agent);
        uint256 proceeds = desk.sell(id, token, out, 90 ether);
        assertGt(proceeds, 90 ether);
        assertLt(proceeds, 100 ether);
        assertEq(desk.balances(id, token), 0);
        assertEq(IERC20(token).balanceOf(address(desk)), 0);
        assertEq(desk.balances(id, desk.IMD()), before - 100 ether + proceeds);
        assertEq(imd.balanceOf(address(desk)), desk.totalLiability(desk.IMD()) + desk.burnImd());
    }

    function test_realPoolMintBuysAndSellsInBothCurrencyOrderings() public {
        uint256 id = _card();
        assertGt(hic.balanceOf(desk.BURN_ADDRESS()), 0.09 ether);
        assertTrue(desk.isTradable(address(lowCoin)));
        assertTrue(desk.isTradable(address(highCoin)));
        _roundTrip(id, address(lowCoin));
        _roundTrip(id, address(highCoin));
        HandlerDesk.Card memory c = desk.getCard(id);
        assertEq(c.trades, 4);
        assertEq(c.wins, 0);
        assertEq(c.losses, 2);
        assertLt(c.pnl, 0);
        uint256 burnBefore = hic.balanceOf(desk.BURN_ADDRESS());
        uint256 burned = desk.buyAndBurn(1);
        assertEq(hic.balanceOf(desk.BURN_ADDRESS()), burnBefore + burned);
        assertEq(desk.burnImd(), 0);
        assertEq(imd.balanceOf(address(desk)), desk.totalLiability(desk.IMD()));
    }

    function test_realPoolSlippageFailureRollsBackFeesAndLimits() public {
        uint256 id = _card();
        uint256 ownerBefore = imd.balanceOf(owner);
        vm.prank(agent);
        vm.expectRevert(HandlerDesk.Slippage.selector);
        desk.buy(id, address(lowCoin), 100 ether, 100 ether);
        assertEq(desk.spentToday(id), 0);
        assertEq(desk.burnImd(), 0);
        assertEq(imd.balanceOf(owner), ownerBefore);
        assertEq(desk.balances(id, desk.IMD()), 1000 ether);
        assertEq(desk.getCard(id).trades, 0);
        _roundTrip(id, address(lowCoin));
    }

    function test_onlyExactPoolKeyQualifiesAndInitializationRequiresFactory() public {
        MockToken unsupported = new MockToken();
        PoolKey memory key = desk.poolKey(address(unsupported));
        vm.prank(holder);
        vm.expectRevert();
        manager.initialize(key, uint160(1 << 96));
        assertFalse(desk.isTradable(address(unsupported)));
        key.hooks = IHooks(address(0));
        manager.initialize(key, uint160(1 << 96));
        assertFalse(desk.isTradable(address(unsupported)));
        key = desk.poolKey(address(unsupported));
        key.fee = 3000;
        manager.initialize(key, uint160(1 << 96));
        assertFalse(desk.isTradable(address(unsupported)));
        key = desk.poolKey(address(unsupported));
        key.tickSpacing = 10;
        manager.initialize(key, uint160(1 << 96));
        assertFalse(desk.isTradable(address(unsupported)));
        manager.initialize(desk.poolKey(address(unsupported)), uint160(1 << 96));
        assertTrue(desk.isTradable(address(unsupported)));
    }

    function test_realInitializedPoolWithoutLiquidityRejectsTrade() public {
        MockToken emptyCoin = new MockToken();
        manager.initialize(desk.poolKey(address(emptyCoin)), uint160(1 << 96));
        uint256 id = _card();
        vm.prank(agent);
        vm.expectRevert(HandlerDesk.InvalidAmount.selector);
        desk.buy(id, address(emptyCoin), 1 ether, 1);
        assertEq(desk.balances(id, desk.IMD()), 1000 ether);
        assertEq(desk.spentToday(id), 0);
    }
}
