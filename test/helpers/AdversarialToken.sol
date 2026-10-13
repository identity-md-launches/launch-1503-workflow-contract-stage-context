// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockToken} from "./Mocks.sol";

/// @dev Same storage prefix as MockToken, so etching preserves the fixture's balances.
/// A false return deliberately follows the transfer: SafeERC20 must roll back both.
contract AdversarialToken is MockToken {
    address public rejectedRecipient;
    bool public returnFalse;
    bool public returnNothing;

    function setRejectedRecipient(address recipient) external {
        rejectedRecipient = recipient;
    }

    function setReturnMode(bool false_, bool nothing_) external {
        returnFalse = false_;
        returnNothing = nothing_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);
        return _response(to);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        return _response(to);
    }

    function _response(address to) private view returns (bool) {
        if (returnFalse || (rejectedRecipient != address(0) && to == rejectedRecipient)) return false;
        if (returnNothing) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }
}
