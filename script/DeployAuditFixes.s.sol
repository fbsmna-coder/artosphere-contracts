// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PhiCoin} from "../src/PhiCoin.sol";
import {PhiStaking} from "../src/PhiStaking.sol";
import {KillSwitch} from "../src/KillSwitch.sol";

/// @title DeployAuditFixes — Deploy audit fix upgrades and new contracts
/// @author F.B. Sapronov
/// @notice Upgrades PhiCoin + PhiStaking UUPS proxies and deploys KillSwitch
/// @dev Run after full audit. FibonacciFusionV2 deployed separately (needs Chainlink VRF subscription)
contract DeployAuditFixes is Script {

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address phiCoinProxy = vm.envAddress("PHICOIN_PROXY");
        address phiStakingProxy = vm.envOr("PHISTAKING_PROXY", address(0));
        address treasury = vm.envAddress("TREASURY");
        address artsToken = phiCoinProxy;

        console2.log("=== Audit Fix Deployment ===");
        console2.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // ================================================================
        // 1. Upgrade PhiCoin implementation (C1: allowance fix, C4: spiralBurnExempt)
        // ================================================================
        PhiCoin newPhiCoinImpl = new PhiCoin();
        console2.log("PhiCoin new impl:", address(newPhiCoinImpl));

        PhiCoin phiCoin = PhiCoin(phiCoinProxy);
        phiCoin.upgradeToAndCall(address(newPhiCoinImpl), "");
        console2.log("PhiCoin proxy upgraded");

        // Exempt staking contracts from spiral burn
        if (phiStakingProxy != address(0)) {
            phiCoin.setSpiralBurnExempt(phiStakingProxy, true);
            console2.log("PhiStaking exempted from spiral burn");
        }

        // ================================================================
        // 2. Upgrade PhiStaking implementation (H4: epoch 1200s -> 604800s)
        // ================================================================
        if (phiStakingProxy != address(0)) {
            PhiStaking newStakingImpl = new PhiStaking();
            console2.log("PhiStaking new impl:", address(newStakingImpl));

            PhiStaking staking = PhiStaking(phiStakingProxy);
            staking.upgradeToAndCall(address(newStakingImpl), "");
            console2.log("PhiStaking proxy upgraded (weekly epochs)");
        }

        // ================================================================
        // 3. Deploy KillSwitch (H8: on-chain kill conditions)
        // ================================================================
        KillSwitch killSwitch = new KillSwitch(artsToken, treasury, deployer);
        console2.log("KillSwitch deployed:", address(killSwitch));

        // Add the 6 kill conditions from the whitepaper
        // threshold is WAD-scaled where applicable (1e18 = 1.0)
        killSwitch.addCondition(
            "sin2_theta12 > 3sigma from 1/(2phi) = 0.30902",
            309020000000000000, // 0.30902 in WAD
            "JUNO",
            block.timestamp + 730 days // ~2028
        );

        killSwitch.addCondition(
            "No chi-boson at 50-70 GeV by 2032",
            58_100000000000000000, // 58.1 GeV in WAD
            "HL-LHC + DARWIN",
            block.timestamp + 2190 days // ~2032
        );

        killSwitch.addCondition(
            "delta_CP > 1.96sigma from arctan(sqrt5) = 65.91 deg",
            65_910000000000000000, // 65.91 in WAD
            "DUNE",
            block.timestamp + 1095 days // ~2029
        );

        killSwitch.addCondition(
            "w0 > 3sigma from -1+1/phi^8 = -0.977",
            977000000000000000, // 0.977 in WAD (absolute value)
            "DESI 5yr",
            block.timestamp + 730 days // ~2028
        );

        killSwitch.addCondition(
            "Axion discovered (theta_QCD != 0)",
            0,
            "ADMX/CASPEr",
            block.timestamp + 1825 days // ~2031
        );

        killSwitch.addCondition(
            "M_H precision > 5sigma from 125.251 GeV",
            125_251000000000000000, // 125.251 in WAD
            "FCC-ee",
            block.timestamp + 3650 days // ~2036
        );

        console2.log("6 kill conditions added");

        vm.stopBroadcast();

        // ================================================================
        // Summary
        // ================================================================
        console2.log("");
        console2.log("=== Deployment Summary ===");
        console2.log("PhiCoin impl (upgraded):", address(newPhiCoinImpl));
        console2.log("KillSwitch:", address(killSwitch));
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Deploy FibonacciFusionV2 (needs Chainlink VRF subscription)");
        console2.log("  2. Create Gnosis Safe and run MigrateToMultisig.s.sol");
        console2.log("  3. Treasury must approve KillSwitch for ARTS spending");
    }
}
