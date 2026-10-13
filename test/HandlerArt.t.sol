// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DeskFixture} from "./helpers/DeskFixture.sol";
import {HandlerDesk} from "../src/HandlerDesk.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

contract ArtDataDesk {
    HandlerDesk.Card private _data;

    function set(HandlerDesk.Card calldata data) external {
        _data = data;
    }

    function getCard(uint256) external view returns (HandlerDesk.Card memory) {
        return _data;
    }
}

contract HandlerArtTest is DeskFixture {
    function _decode(bytes memory source, uint256 prefix) internal pure returns (bytes memory out) {
        uint256 length = source.length - prefix;
        require(length % 4 == 0);
        uint256 size = length / 4 * 3;
        if (source[source.length - 1] == "=") size--;
        if (source[source.length - 2] == "=") size--;
        out = new bytes(size);
        uint256 cursor;
        for (uint256 i = prefix; i < source.length; i += 4) {
            uint256 packed = _digit(source[i]) << 18 | _digit(source[i + 1]) << 12 | _digit(source[i + 2])
                << 6 | _digit(source[i + 3]);
            if (cursor < size) out[cursor++] = bytes1(uint8(packed >> 16));
            if (cursor < size) out[cursor++] = bytes1(uint8(packed >> 8));
            if (cursor < size) out[cursor++] = bytes1(uint8(packed));
        }
    }

    function _digit(bytes1 c) private pure returns (uint256) {
        uint256 x = uint8(c);
        if (x >= 65 && x <= 90) return x - 65;
        if (x >= 97 && x <= 122) return x - 71;
        if (x >= 48 && x <= 57) return x + 4;
        if (c == "+") return 62;
        if (c == "/") return 63;
        require(c == "=");
        return 0;
    }

    function _contains(string memory haystack, string memory needle) private pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (h.length < n.length) return false;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool found = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }

    function _json(address dataDesk, uint256 id) private view returns (string memory) {
        return
            string(_decode(bytes(art.tokenURI(dataDesk, id)), bytes("data:application/json;base64,").length));
    }

    function test_tokenUriValidJsonSvgLiveStatsAndRename() public {
        uint256 id = _setupCard(holder, 100 ether);
        assertEq(cards.tokenURI(id), art.tokenURI(address(desk), id));
        string memory json = _json(address(desk), id);
        assertEq(vm.parseJsonString(json, ".name"), "HIC / AGENT #0001 - Agent-42");
        assertEq(vm.parseJsonUint(json, ".attributes[0].value"), 1);
        assertEq(vm.parseJsonUint(json, ".attributes[1].value"), 0);
        assertEq(vm.parseJsonUint(json, ".attributes[7].value"), block.timestamp);
        string memory image = vm.parseJsonString(json, ".image");
        string memory svg = string(_decode(bytes(image), bytes("data:image/svg+xml;base64,").length));
        assertEq(svg, art.svg(address(desk), id));
        assertTrue(_contains(svg, "HIC / AGENT #0001"));
        assertTrue(_contains(svg, "#F2F1EC"));
        assertTrue(_contains(svg, "2027-01-15"));
        assertFalse(_contains(svg, "<script"));
        uint256 out = _buy(id, 40 ether);
        manager.setRate(address(coin), address(imd), 2 ether);
        _sell(id, out);
        json = _json(address(desk), id);
        assertEq(vm.parseJsonUint(json, ".attributes[1].value"), 100);
        assertEq(vm.parseJsonUint(json, ".attributes[2].value"), 1);
        assertEq(vm.parseJsonUint(json, ".attributes[6].value"), 2);
        vm.prank(holder);
        desk.rename(id, "New Name");
        assertEq(vm.parseJsonString(_json(address(desk), id), ".name"), "HIC / AGENT #0001 - New Name");
    }

    function test_rendererEscapesAllStringsEvenFromAnotherDesk() public {
        ArtDataDesk dataDesk = new ArtDataDesk();
        HandlerDesk.Card memory c;
        c.name = "\"<&>'\\\n\t";
        c.wins = 16;
        c.losses = 9;
        c.pnl = -12.3456 ether;
        c.volume = 456 ether;
        c.trades = 50;
        c.mintedAt = 1_709_164_800; // 2024-02-29
        dataDesk.set(c);
        string memory json = _json(address(dataDesk), 42);
        assertEq(vm.parseJsonString(json, ".name"), string.concat("HIC / AGENT #0042 - ", c.name));
        assertEq(vm.parseJsonUint(json, ".attributes[1].value"), 64);
        assertEq(vm.parseJsonInt(json, ".attributes[4].value"), c.pnl);
        string memory svg = art.svg(address(dataDesk), 42);
        assertTrue(_contains(svg, "&quot;&lt;&amp;&gt;&apos;"));
        assertTrue(_contains(svg, "16 W &#183; 9 L"));
        assertTrue(_contains(svg, "-12.3456"));
        assertTrue(_contains(svg, "#E0362C"));
        assertTrue(_contains(svg, "2024-02-29"));
        assertTrue(_contains(svg, "64%"));
    }

    function test_dateEpochCenturyLeapAndMinimumSignedValue() public {
        ArtDataDesk dataDesk = new ArtDataDesk();
        HandlerDesk.Card memory c;
        c.name = "Calendar";
        dataDesk.set(c);
        assertTrue(_contains(art.svg(address(dataDesk), 1), "1970-01-01"));
        c.mintedAt = 951_782_400;
        c.pnl = type(int256).min;
        dataDesk.set(c);
        string memory svg = art.svg(address(dataDesk), 10_000);
        assertTrue(_contains(svg, "2000-02-29"));
        assertTrue(_contains(svg, "AGENT #10000"));
        assertEq(vm.parseJsonInt(_json(address(dataDesk), 10_000), ".attributes[4].value"), c.pnl);
        assertEq(art.svg(address(dataDesk), 10_000), svg);
        assertNotEq(art.svg(address(dataDesk), 10_001), svg);
    }

    function test_artRejectsUnknownRealCards() public {
        vm.expectRevert(HandlerDesk.UnknownCard.selector);
        art.tokenURI(address(desk), 1);
        vm.expectRevert(HandlerDesk.UnknownCard.selector);
        art.svg(address(desk), 0);
    }
}
