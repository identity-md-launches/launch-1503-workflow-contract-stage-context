// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {HandlerArt} from "../src/HandlerArt.sol";
import {HandlerDesk} from "../src/HandlerDesk.sol";

contract LocalFactory {
    LaunchToken public token;
    HandlerArt public art;
    HandlerDesk public desk;

    constructor(address owner) {
        token = new LaunchToken();
        art = new HandlerArt();
        desk = new HandlerDesk(owner, address(token), address(art));
    }
}

contract DeploymentTest is Test {
    function test_factoryDeploymentOnEmptyChainPreservesSupplyAndExplicitOwner() public {
        address owner = makeAddr("explicitLaunchOwner");
        LocalFactory factory = new LocalFactory(owner);
        HandlerDesk desk = factory.desk();
        assertEq(factory.token().balanceOf(address(factory)), 1e27);
        assertEq(factory.token().totalSupply(), 1e27);
        assertEq(desk.owner(), owner);
        assertNotEq(desk.owner(), address(factory));
        assertEq(desk.hic(), address(factory.token()));
        assertEq(desk.cards().desk(), address(desk));
        assertEq(address(desk.cards().art()), address(factory.art()));
        assertEq(desk.totalCards(), 0);
        assertEq(desk.IMD().code.length, 0);
        assertEq(address(desk.POOL_MANAGER()).code.length, 0);
        assertEq(desk.LAUNCH_HOOK().code.length, 0);
    }

    function test_launchRuntimeIsBoundedAndContainsNoEscapeOpcodes() public {
        LocalFactory factory = new LocalFactory(makeAddr("owner"));
        address[4] memory contracts_ = [
            address(factory.token()),
            address(factory.art()),
            address(factory.desk()),
            address(factory.desk().cards())
        ];
        for (uint256 i; i < contracts_.length; ++i) {
            bytes memory runtime = contracts_[i].code;
            assertGt(runtime.length, 0);
            assertLe(runtime.length, 24_576);
            for (uint256 j; j < runtime.length; ++j) {
                uint8 op = uint8(runtime[j]);
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                    continue;
                }
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
            }
        }
    }
}
