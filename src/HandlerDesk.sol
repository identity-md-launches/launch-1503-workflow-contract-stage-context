// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HandlerCards} from "./HandlerCards.sol";

/// @notice Segregated card custody with narrowly authorized, exact-input IMD launch-pool swaps.
contract HandlerDesk is Ownable2Step, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    IPoolManager public constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address public constant LAUNCH_HOOK = 0x784FF9a3ac5d88A30bfff6F7f2a270161FBE6000;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint24 public constant POOL_FEE = 12_500;
    int24 public constant TICK_SPACING = 60;
    uint256 public constant MIN_MINT_PRICE = 0.05 ether;
    uint256 public constant MAX_MINT_PRICE = 2 ether;
    uint256 public constant BURN_INTERVAL = 1 hours;
    uint256 public constant FEE_DENOMINATOR = 400; // 0.25% of the IMD side, rounded down.

    address public immutable hic;
    HandlerCards public immutable cards;
    uint256 public mintPrice = 0.2 ether;
    uint256 public totalCards;
    uint256 public burnImd;
    uint256 public lastBurnTime;
    bool public hasBurned;

    struct Card {
        string name;
        address agent;
        bool frozen;
        uint256 dailyCap;
        uint256 maxPerTrade;
        uint256 day;
        uint256 spentToday;
        uint256 mintedAt;
        uint256 trades;
        uint256 wins;
        uint256 losses;
        int256 pnl;
        uint256 volume;
    }

    struct Position {
        uint256 quantity;
        uint256 cost;
    }

    mapping(uint256 => Card) private _cards;
    mapping(uint256 => mapping(address => uint256)) public balances;
    mapping(uint256 => mapping(address => Position)) public positions;
    // Aggregate obligations let integrations check solvency without enumerating cards.
    mapping(address => uint256) public totalLiability;
    mapping(uint256 => address[]) private _coins;
    mapping(uint256 => mapping(address => bool)) private _knownCoin;
    bool private _callbackPending;
    bytes32 private _callbackHash;

    error InvalidAddress();
    error InvalidName();
    error InvalidAmount();
    error UnknownCard();
    error OnlyHolder();
    error OnlyAgent();
    error CardFrozen();
    error FreezeUnchanged();
    error PerTradeLimit();
    error DailyLimit();
    error InsufficientBalance();
    error InvalidToken();
    error PoolNotInitialized();
    error Slippage();
    error PartialFill();
    error UnexpectedCallback();
    error UnsupportedToken();
    error BurnTooSoon();
    error NothingToBurn();
    error MintPriceOutOfRange();
    error RenounceDisabled();

    event Minted(uint256 indexed id, address indexed holder, string name, uint256 price, uint256 hicBurned);
    event Deposited(uint256 indexed id, uint256 imd);
    event Withdrawn(uint256 indexed id, address indexed token, uint256 amount);
    event RulesSet(uint256 indexed id, uint256 dailyCap, uint256 maxPerTrade);
    event AgentSet(uint256 indexed id, address indexed agent);
    event Frozen(uint256 indexed id, bool frozen);
    event Renamed(uint256 indexed id, string name);
    event Traded(
        uint256 indexed id,
        address indexed token,
        bool isBuy,
        uint256 imdAmount,
        uint256 tokenAmount,
        int256 pnl,
        bool win
    );
    event Burned(uint256 imd, uint256 hic);
    event MintPriceSet(uint256 price);

    /// @dev Does not query external contracts. Cards is created locally, permanently bound to this Desk.
    constructor(address owner_, address hic_, address art_) Ownable(owner_) {
        if (hic_ == address(0) || hic_ == IMD || art_ == address(0)) revert InvalidAddress();
        hic = hic_;
        cards = new HandlerCards(address(this), art_);
    }

    function getCard(uint256 id) external view returns (Card memory) {
        _exists(id);
        return _cards[id];
    }

    /// @notice Coins ever credited to the card, including IMD. A coin may now have a zero balance.
    function cardCoins(uint256 id) external view returns (address[] memory) {
        _exists(id);
        return _coins[id];
    }

    function spentToday(uint256 id) external view returns (uint256) {
        _exists(id);
        Card storage c = _cards[id];
        return c.day == block.timestamp / 1 days ? c.spentToday : 0;
    }

    function poolKey(address token) public pure returns (PoolKey memory key) {
        if (token == address(0) || token == IMD) revert InvalidToken();
        (address a, address b) = IMD < token ? (IMD, token) : (token, IMD);
        key = PoolKey(Currency.wrap(a), Currency.wrap(b), POOL_FEE, TICK_SPACING, IHooks(LAUNCH_HOOK));
    }

    function isTradable(address token) public view returns (bool) {
        if (token == address(0) || token == IMD || token.code.length == 0) return false;
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolKey(token).toId());
        return sqrtPriceX96 != 0;
    }

    function mint(string calldata name, uint256 minHicOut) external nonReentrant returns (uint256 id) {
        _validateName(name);
        uint256 price = mintPrice;
        _pullImd(msg.sender, price);
        uint256 ownerShare = price / 2;
        IERC20(IMD).safeTransfer(owner(), ownerShare);
        uint256 burned = _swap(IMD, hic, price - ownerShare, minHicOut);
        IERC20(hic).safeTransfer(BURN_ADDRESS, burned);
        id = ++totalCards;
        Card storage c = _cards[id];
        c.name = name;
        c.mintedAt = block.timestamp;
        _rememberCoin(id, IMD);
        cards.mint(msg.sender, id);
        emit Minted(id, msg.sender, name, price, burned);
    }

    function deposit(uint256 id, uint256 imd) external nonReentrant {
        _holder(id);
        if (imd == 0) revert InvalidAmount();
        _pullImd(msg.sender, imd);
        _credit(id, IMD, imd);
        emit Deposited(id, imd);
    }

    function withdraw(uint256 id, address token, uint256 amount) external nonReentrant {
        _holder(id);
        if (amount == 0) revert InvalidAmount();
        _debit(id, token, amount);
        if (token != IMD) {
            Position storage p = positions[id][token];
            uint256 removedCost = Math.mulDiv(p.cost, amount, p.quantity);
            p.quantity -= amount;
            p.cost -= removedCost;
        }
        // The destination is always the permanent card holder, never a supplied recipient or agent.
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Withdrawn(id, token, amount);
    }

    function setAgent(uint256 id, address agent) external nonReentrant {
        _holder(id);
        _cards[id].agent = agent; // address(0) revokes an agent.
        emit AgentSet(id, agent);
    }

    function setRules(uint256 id, uint256 dailyCap, uint256 maxPerTrade) external nonReentrant {
        _holder(id);
        _cards[id].dailyCap = dailyCap;
        _cards[id].maxPerTrade = maxPerTrade;
        emit RulesSet(id, dailyCap, maxPerTrade);
    }

    function freeze(uint256 id) external nonReentrant {
        _setFrozen(id, true);
    }

    function unfreeze(uint256 id) external nonReentrant {
        _setFrozen(id, false);
    }

    function rename(uint256 id, string calldata name) external nonReentrant {
        _holder(id);
        _validateName(name);
        _cards[id].name = name;
        emit Renamed(id, name);
    }

    /// @param imdIn Total card debit, inclusive of the Desk fee. The remaining IMD is swapped.
    function buy(uint256 id, address token, uint256 imdIn, uint256 minOut)
        external
        nonReentrant
        returns (uint256 tokenOut)
    {
        Card storage c = _agent(id);
        if (imdIn == 0) revert InvalidAmount();
        if (imdIn > c.maxPerTrade) revert PerTradeLimit();
        uint256 day = block.timestamp / 1 days;
        if (c.day != day) {
            c.day = day;
            c.spentToday = 0;
        }
        if (imdIn > c.dailyCap || c.spentToday > c.dailyCap - imdIn) revert DailyLimit();
        c.spentToday += imdIn;
        _debit(id, IMD, imdIn);
        uint256 fee = imdIn / FEE_DENOMINATOR;
        tokenOut = _swap(IMD, token, imdIn - fee, minOut);
        _credit(id, token, tokenOut);
        Position storage p = positions[id][token];
        p.quantity += tokenOut;
        p.cost += imdIn;
        c.trades++;
        c.volume += imdIn;
        _chargeFee(fee);
        emit Traded(id, token, true, imdIn, tokenOut, 0, false);
    }

    /// @param minImdOut Minimum net IMD credited after the Desk fee.
    function sell(uint256 id, address token, uint256 amountIn, uint256 minImdOut)
        external
        nonReentrant
        returns (uint256 proceeds)
    {
        Card storage c = _agent(id);
        if (amountIn == 0) revert InvalidAmount();
        if (token == IMD) revert InvalidToken();
        _debit(id, token, amountIn);
        Position storage p = positions[id][token];
        uint256 costPart = Math.mulDiv(p.cost, amountIn, p.quantity);
        p.quantity -= amountIn;
        p.cost -= costPart;
        uint256 gross = _swap(token, IMD, amountIn, 1);
        uint256 fee = gross / FEE_DENOMINATOR;
        proceeds = gross - fee;
        if (minImdOut == 0 || proceeds < minImdOut) revert Slippage();
        _credit(id, IMD, proceeds);
        int256 pnl = proceeds.toInt256() - costPart.toInt256();
        bool win = proceeds > costPart;
        c.pnl += pnl;
        c.trades++;
        if (win) c.wins++;
        else c.losses++;
        c.volume += gross;
        _chargeFee(fee);
        emit Traded(id, token, false, proceeds, amountIn, pnl, win);
    }

    function buyAndBurn(uint256 minOut) external nonReentrant returns (uint256 burned) {
        if (hasBurned && block.timestamp < lastBurnTime + BURN_INTERVAL) revert BurnTooSoon();
        uint256 amount = burnImd;
        if (amount == 0) revert NothingToBurn();
        burnImd = 0;
        hasBurned = true;
        lastBurnTime = block.timestamp;
        burned = _swap(IMD, hic, amount, minOut);
        IERC20(hic).safeTransfer(BURN_ADDRESS, burned);
        emit Burned(amount, burned);
    }

    function setMintPrice(uint256 price) external onlyOwner nonReentrant {
        if (price < MIN_MINT_PRICE || price > MAX_MINT_PRICE) revert MintPriceOutOfRange();
        mintPrice = price;
        emit MintPriceSet(price);
    }

    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @dev One authenticated callback per Desk-initiated unlock; rejects replay and nested callbacks.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER) || !_callbackPending || keccak256(data) != _callbackHash) {
            revert UnexpectedCallback();
        }
        _callbackPending = false;
        (address input, address output, uint256 amount) = abi.decode(data, (address, address, uint256));
        address token = input == IMD ? output : input;
        PoolKey memory key = poolKey(token);
        bool zeroForOne = input < output;
        BalanceDelta delta = POOL_MANAGER.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            bytes("")
        );
        int128 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta >= 0 || outputDelta <= 0) revert InvalidAmount();
        uint256 owed = uint256(-int256(inputDelta));
        if (owed != amount) revert PartialFill();
        POOL_MANAGER.sync(Currency.wrap(input));
        IERC20(input).safeTransfer(address(POOL_MANAGER), owed);
        if (POOL_MANAGER.settle() != owed) revert UnsupportedToken();
        POOL_MANAGER.take(Currency.wrap(output), address(this), uint256(uint128(outputDelta)));
        return bytes("");
    }

    function _swap(address input, address output, uint256 amount, uint256 minOut)
        private
        returns (uint256 received)
    {
        if (minOut == 0) revert Slippage();
        if (amount == 0 || amount > uint256(uint128(type(int128).max))) revert InvalidAmount();
        address token = input == IMD ? output : input;
        if (!isTradable(token)) revert PoolNotInitialized();
        uint256 beforeIn = IERC20(input).balanceOf(address(this));
        uint256 beforeOut = IERC20(output).balanceOf(address(this));
        bytes memory data = abi.encode(input, output, amount);
        _callbackHash = keccak256(data);
        _callbackPending = true;
        POOL_MANAGER.unlock(data);
        if (_callbackPending) revert UnexpectedCallback();
        delete _callbackHash;
        uint256 afterIn = IERC20(input).balanceOf(address(this));
        if (afterIn > beforeIn || beforeIn - afterIn != amount) revert UnsupportedToken();
        received = IERC20(output).balanceOf(address(this)) - beforeOut;
        if (received < minOut) revert Slippage();
    }

    function _pullImd(address from, uint256 amount) private {
        uint256 beforeBalance = IERC20(IMD).balanceOf(address(this));
        IERC20(IMD).safeTransferFrom(from, address(this), amount);
        if (IERC20(IMD).balanceOf(address(this)) - beforeBalance != amount) revert UnsupportedToken();
    }

    function _chargeFee(uint256 fee) private {
        uint256 ownerShare = fee / 2;
        burnImd += fee - ownerShare;
        if (ownerShare != 0) IERC20(IMD).safeTransfer(owner(), ownerShare);
    }

    function _credit(uint256 id, address token, uint256 amount) private {
        balances[id][token] += amount;
        totalLiability[token] += amount;
        _rememberCoin(id, token);
    }

    function _debit(uint256 id, address token, uint256 amount) private {
        if (amount > balances[id][token]) revert InsufficientBalance();
        balances[id][token] -= amount;
        totalLiability[token] -= amount;
    }

    function _rememberCoin(uint256 id, address token) private {
        if (!_knownCoin[id][token]) {
            _knownCoin[id][token] = true;
            _coins[id].push(token);
        }
    }

    function _exists(uint256 id) private view {
        if (id == 0 || id > totalCards) revert UnknownCard();
    }

    function _holder(uint256 id) private view {
        _exists(id);
        if (cards.ownerOf(id) != msg.sender) revert OnlyHolder();
    }

    function _agent(uint256 id) private view returns (Card storage c) {
        _exists(id);
        c = _cards[id];
        if (c.agent != msg.sender) revert OnlyAgent();
        if (c.frozen) revert CardFrozen();
    }

    function _setFrozen(uint256 id, bool frozen_) private {
        _holder(id);
        if (_cards[id].frozen == frozen_) revert FreezeUnchanged();
        _cards[id].frozen = frozen_;
        emit Frozen(id, frozen_);
    }

    function _validateName(string calldata name) private pure {
        bytes calldata b = bytes(name);
        if (b.length == 0 || b.length > 24) revert InvalidName();
        for (uint256 i; i < b.length; ++i) {
            uint8 c = uint8(b[i]);
            if (!((c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 32
                        || c == 45)) revert InvalidName();
        }
    }
}
