// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

interface IHandlerArt {
    function tokenURI(address desk, uint256 id) external view returns (string memory);
}

/// @notice Permanent handler badges. Approvals are disabled along with all transfers and burns.
contract HandlerCards is ERC721 {
    address public immutable desk;
    IHandlerArt public immutable art;

    error OnlyDesk();
    error Soulbound();
    error InvalidAddress();
    event Locked(uint256 tokenId);

    constructor(address desk_, address art_) ERC721("Handler Cards", "CARD") {
        if (desk_ == address(0) || art_ == address(0)) revert InvalidAddress();
        desk = desk_;
        art = IHandlerArt(art_);
    }

    function mint(address holder, uint256 id) external {
        if (msg.sender != desk) revert OnlyDesk();
        _safeMint(holder, id);
        emit Locked(id);
    }

    function locked(uint256 id) external view returns (bool) {
        _requireOwned(id);
        return true;
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == 0xb45a3c0e || super.supportsInterface(interfaceId);
    }

    function approve(address, uint256) public pure override {
        revert Soulbound();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert Soulbound();
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        return art.tokenURI(desk, id);
    }

    function _update(address to, uint256 id, address auth) internal override returns (address) {
        if (_ownerOf(id) != address(0) || to == address(0)) revert Soulbound();
        return super._update(to, id, auth);
    }
}
