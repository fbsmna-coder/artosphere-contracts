// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {FibonacciFusion} from "../src/FibonacciFusion.sol";

/// @title DeployFibonacciFusion — Deploy the τ⊗τ = 1⊕τ deflationary mechanism
/// @author F.B. Sapronov
/// @notice Deploys FibonacciFusion pointing to the ARTS token proxy
/// @dev Prerequisites: PhiCoin proxy must already be deployed
///      Environment variables: PRIVATE_KEY, PHICOIN_PROXY
contract DeployFibonacciFusion is Script {

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address phiCoinProxy = vm.envAddress("PHICOIN_PROXY");

        console2.log("=== FibonacciFusion Deployment ===");
        console2.log("Deployer:", deployer);
        console2.log("ARTS Token:", phiCoinProxy);

        vm.startBroadcast(deployerPrivateKey);

        FibonacciFusion fusion = new FibonacciFusion(phiCoinProxy, deployer);

        vm.stopBroadcast();

        console2.log("");
        console2.log("FibonacciFusion deployed:", address(fusion));
        console2.log("  artsToken:", address(fusion.artsToken()));
        console2.log("  minFusionAmount: 100 ARTS");
        console2.log("  fusionCooldown: 1200s (20 min)");
        console2.log("  Annihilation: 38.20% (phi^-2)");
        console2.log("  Survival:     61.80% (phi^-1)");
    }
}
