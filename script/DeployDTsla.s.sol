// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {dTsla} from "../src/dTsla.sol";
import {console2} from "forge-std/console2.sol";

contract DeployDTsla is Script {
    string constant alpacaMintSource = "./functions/sources/alpacaBalance.js";
    string constant alpacaRedeemSource =
        "./functions/sources/sellTslaAndSendUsdc.js";
    uint64 constant subId = 2670;

    function run() public {
        string memory mintSource = vm.readFile(alpacaMintSource);
        string memory redeemSource = vm.readFile(alpacaRedeemSource);
        vm.startBroadcast();
        dTsla dTSLA = new dTsla(mintSource, subId, redeemSource);
        vm.stopBroadcast();
        console2.log(address(dTSLA));
    }
}
