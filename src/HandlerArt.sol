// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {HandlerDesk} from "./HandlerDesk.sol";

/// @notice Stateless on-chain JSON/SVG renderer. No remote images, scripts, fonts, or metadata server.
contract HandlerArt {
    using Strings for uint256;
    using Strings for int256;

    function tokenURI(address desk, uint256 id) external view returns (string memory) {
        HandlerDesk.Card memory c = HandlerDesk(desk).getCard(id);
        bytes memory json = abi.encodePacked(
            '{"name":"HIC / AGENT #',
            _pad(id, 4),
            " - ",
            _escapeJson(c.name),
            '","description":"You are the handler. Your AI is the agent. Soulbound Handler Card; stats track realized sells, not total portfolio returns.","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(_svg(c, id))),
            '","attributes":[',
            _attribute("Agent ID", id.toString()),
            ",",
            _attribute("Win Rate Percent", _winRate(c).toString()),
            ",",
            _attribute("Wins", c.wins.toString()),
            ",",
            _attribute("Losses", c.losses.toString()),
            ",",
            _attribute("Realized PnL IMD Minor Units", c.pnl.toStringSigned()),
            ",",
            _attribute("Volume IMD Minor Units", c.volume.toString()),
            ",",
            _attribute("Trades", c.trades.toString()),
            ",",
            _attribute("Mint Time Unix", c.mintedAt.toString()),
            "]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }

    function svg(address desk, uint256 id) external view returns (string memory) {
        return _svg(HandlerDesk(desk).getCard(id), id);
    }

    function _svg(HandlerDesk.Card memory c, uint256 id) private pure returns (string memory) {
        string memory color = c.pnl < 0 ? "#E0362C" : "#10A957";
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 390 560" role="img" aria-label="Handler agent badge">',
            '<rect x="1" y="1" width="388" height="558" rx="8" fill="#F2F1EC" stroke="#101010" stroke-width="2"/>',
            '<rect x="155" y="16" width="80" height="9" rx="4" fill="#101010"/>',
            '<g fill="#101010" font-family="monospace"><text x="24" y="58" font-size="18" font-weight="bold">HIC / AGENT #',
            _pad(id, 4),
            '</text><path d="M24 76H366" stroke="#101010"/><text x="24" y="108" font-size="16">',
            _escapeXml(c.name),
            "</text>",
            _sigil(id),
            '<text x="24" y="186" font-size="13">WIN RATE</text><text x="20" y="258" font-size="72" font-weight="bold">',
            _winRate(c).toString(),
            '%</text><text x="24" y="296" font-size="18">',
            c.wins.toString(),
            " W &#183; ",
            c.losses.toString(),
            ' L</text><path d="M24 318H366" stroke="#101010"/>',
            '<text x="24" y="348" font-size="12">REALIZED P&amp;L / IMD</text><text x="24" y="382" font-size="24" fill="',
            color,
            '">',
            _signedImd(c.pnl),
            '</text><text x="24" y="424" font-size="12">VOLUME / IMD</text><text x="24" y="448" font-size="18">',
            _imd(c.volume),
            '</text><text x="260" y="424" font-size="12">TRADES</text><text x="260" y="448" font-size="18">',
            c.trades.toString(),
            '</text><path d="M24 472H366" stroke="#101010"/><text x="24" y="499" font-size="12">MINTED ',
            _date(c.mintedAt),
            '</text><text x="24" y="535" font-size="11">YOU\'RE THE HANDLER. YOUR AI IS THE AGENT.</text></g></svg>'
        );
    }

    function _winRate(HandlerDesk.Card memory c) private pure returns (uint256) {
        uint256 closed = c.wins + c.losses;
        return closed == 0 ? 0 : c.wins * 100 / closed;
    }

    function _attribute(string memory trait, string memory value) private pure returns (string memory) {
        return string.concat('{"trait_type":"', trait, '","value":', value, "}");
    }

    function _sigil(uint256 id) private pure returns (string memory result) {
        uint256 seed = uint256(keccak256(abi.encode(id)));
        result = '<g fill="#101010">';
        for (uint256 y; y < 5; ++y) {
            for (uint256 x; x < 5; ++x) {
                uint256 mirrored = x < 3 ? x : 4 - x;
                if ((seed >> (y * 3 + mirrored)) & 1 == 1) {
                    result = string.concat(
                        result,
                        '<rect x="',
                        (286 + x * 14).toString(),
                        '" y="',
                        (138 + y * 14).toString(),
                        '" width="12" height="12"/>'
                    );
                }
            }
        }
        return string.concat(result, "</g>");
    }

    function _imd(uint256 amount) private pure returns (string memory) {
        return string.concat((amount / 1 ether).toString(), ".", _pad((amount % 1 ether) / 1e14, 4));
    }

    function _signedImd(int256 amount) private pure returns (string memory) {
        // Safe even for type(int256).min.
        uint256 magnitude = amount < 0 ? uint256(-(amount + 1)) + 1 : uint256(amount);
        return string.concat(amount < 0 ? "-" : "+", _imd(magnitude));
    }

    function _pad(uint256 value, uint256 width) private pure returns (string memory) {
        string memory digits = value.toString();
        while (bytes(digits).length < width) digits = string.concat("0", digits);
        return digits;
    }

    /// @dev Gregorian civil date from Unix days (Howard Hinnant's civil_from_days algorithm).
    function _date(uint256 timestamp) private pure returns (string memory) {
        uint256 z = timestamp / 1 days + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 d = doy - (153 * mp + 2) / 5 + 1;
        uint256 m = mp < 10 ? mp + 3 : mp - 9;
        if (m <= 2) y++;
        return string.concat(_pad(y, 4), "-", _pad(m, 2), "-", _pad(d, 2));
    }

    function _escapeXml(string memory value) private pure returns (string memory out) {
        bytes memory b = bytes(value);
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c == "&") out = string.concat(out, "&amp;");
            else if (c == "<") out = string.concat(out, "&lt;");
            else if (c == ">") out = string.concat(out, "&gt;");
            else if (c == '"') out = string.concat(out, "&quot;");
            else if (c == "'") out = string.concat(out, "&apos;");
            else out = string.concat(out, string(abi.encodePacked(c)));
        }
    }

    function _escapeJson(string memory value) private pure returns (string memory out) {
        bytes memory b = bytes(value);
        bytes16 hexDigits = "0123456789abcdef";
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c == '"' || c == "\\") {
                out = string.concat(out, "\\", string(abi.encodePacked(c)));
            } else if (uint8(c) < 32) {
                out = string.concat(
                    out, "\\u00", string(abi.encodePacked(hexDigits[uint8(c) >> 4], hexDigits[uint8(c) & 15]))
                );
            } else {
                out = string.concat(out, string(abi.encodePacked(c)));
            }
        }
    }
}
