// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract MockToken is ERC20 {
    address public reenterTarget;
    bytes public reenterData;
    bool public reentrySucceeded;
    uint256 public taxBps;
    bool public failTransfer;

    constructor() ERC20("Mock Coin", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTax(uint256 bps) external {
        taxBps = bps;
    }

    function setFail(bool fail) external {
        failTransfer = fail;
    }

    function setReentry(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterData = data;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            require(!failTransfer, "token transfer failed");
            if (reenterTarget != address(0)) {
                address target = reenterTarget;
                reenterTarget = address(0);
                (reentrySucceeded,) = target.call(reenterData);
            }
            uint256 tax = amount * taxBps / 10_000;
            if (tax != 0) super._update(from, address(0), tax);
            amount -= tax;
        }
        super._update(from, to, amount);
    }
}

/// @dev Exact v4 ABI with controllable outcomes. Implements settlement obligations and pool slot reads.
contract MockPoolManager {
    using PoolIdLibrary for PoolKey;
    mapping(bytes32 => bytes32) private _slots;
    mapping(address => mapping(address => uint256)) public rates; // 1e18 = one to one.
    bool private _unlocked;
    address private _locker;
    address private _input;
    address private _output;
    uint256 private _debt;
    uint256 private _credit;
    address private _synced;
    uint256 private _snapshot;
    uint256 public fillBps = 10_000;
    uint256 public takeBps = 10_000;
    bool public shortSettlement;
    uint256 public callbackMode; // 1=skip, 2=wrong data, 3=attempt replay
    bool public replaySucceeded;
    address public reenterTarget;
    bytes public reenterData;
    bool public reentrySucceeded;

    function configure() external {
        fillBps = 10_000;
        takeBps = 10_000;
    }

    function initializeMock(PoolKey calldata key, bool initialized) external {
        bytes32 slot = keccak256(abi.encode(key.toId(), uint256(6)));
        _slots[slot] = initialized ? bytes32(uint256(1 << 96)) : bytes32(0);
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return _slots[slot];
    }

    function setRate(address input, address output, uint256 rate) external {
        rates[input][output] = rate;
    }

    function setFill(uint256 bps) external {
        fillBps = bps;
    }

    function setTake(uint256 bps) external {
        takeBps = bps;
    }

    function setShortSettlement(bool value) external {
        shortSettlement = value;
    }

    function setCallbackMode(uint256 mode) external {
        callbackMode = mode;
    }

    function setReentry(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterData = data;
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(!_unlocked, "already unlocked");
        _unlocked = true;
        _locker = msg.sender;
        if (callbackMode == 1) {
            _unlocked = false;
            return bytes("");
        }
        if (callbackMode == 2) result = IUnlockCallback(msg.sender).unlockCallback(abi.encode(uint256(17)));
        else result = IUnlockCallback(msg.sender).unlockCallback(data);
        if (callbackMode == 3) {
            (replaySucceeded,) = msg.sender.call(abi.encodeCall(IUnlockCallback.unlockCallback, (data)));
        }
        require(_debt == 0 && _credit == 0, "unsettled obligations");
        _unlocked = false;
        _locker = address(0);
    }

    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (BalanceDelta)
    {
        require(_unlocked && msg.sender == _locker, "not locker");
        require(params.amountSpecified < 0 && hookData.length == 0, "not exact input");
        require(key.fee == 12_500 && key.tickSpacing == 60, "wrong fee or spacing");
        require(address(key.hooks) == 0x784FF9a3ac5d88A30bfff6F7f2a270161FBE6000, "wrong hook");
        _input = Currency.unwrap(params.zeroForOne ? key.currency0 : key.currency1);
        _output = Currency.unwrap(params.zeroForOne ? key.currency1 : key.currency0);
        require(
            params.sqrtPriceLimitX96
                == (params.zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341),
            "wrong price limit"
        );
        _debt = uint256(-params.amountSpecified) * fillBps / 10_000;
        uint256 rate = rates[_input][_output];
        if (rate == 0) rate = 1 ether;
        _credit = _debt * rate / 1 ether;
        if (reenterTarget != address(0)) {
            (reentrySucceeded,) = reenterTarget.call(reenterData);
        }
        return params.zeroForOne
            ? toBalanceDelta(-int128(int256(_debt)), int128(int256(_credit)))
            : toBalanceDelta(int128(int256(_credit)), -int128(int256(_debt)));
    }

    function sync(Currency currency) external {
        require(_unlocked && msg.sender == _locker, "not locker");
        _synced = Currency.unwrap(currency);
        _snapshot = IERC20(_synced).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        require(_unlocked && msg.sender == _locker && _synced == _input, "not synced");
        paid = IERC20(_synced).balanceOf(address(this)) - _snapshot;
        require(paid <= _debt, "overpaid");
        _debt -= paid;
        if (shortSettlement) paid--;
    }

    function take(Currency currency, address to, uint256 amount) external {
        require(_unlocked && msg.sender == _locker && Currency.unwrap(currency) == _output, "not locker");
        require(amount == _credit, "wrong credit");
        _credit = 0;
        require(IERC20(_output).transfer(to, amount * takeBps / 10_000));
    }
}
