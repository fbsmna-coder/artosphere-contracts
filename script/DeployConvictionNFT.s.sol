// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {ConvictionNFT} from "../src/ConvictionNFT.sol";
import {DiscoveryStaking} from "../src/DiscoveryStaking.sol";

/// @title DeployConvictionNFT — Deploy ConvictionNFT + Wire to DiscoveryStaking
/// @author F.B. Sapronov
/// @notice Deploys ConvictionNFT (non-upgradeable ERC-721 + ERC-2981) and wires it
///         to the existing DiscoveryStaking proxy:
///         - MINTER_ROLE on ConvictionNFT → DiscoveryStaking proxy
///         - CLAIMER_ROLE on ConvictionNFT → DiscoveryStaking proxy
///
/// @dev Prerequisites: DiscoveryStaking proxy must already be deployed.
///      Deployer must hold DEFAULT_ADMIN_ROLE on DiscoveryStaking.
///
///      Environment variables required:
///        PRIVATE_KEY             — deployer private key (must be admin)
///        DISCOVERY_STAKING_PROXY — address of the deployed DiscoveryStaking proxy
///        SCIENTIST_ADDRESS       — address of the scientist (royalty recipient)
contract DeployConvictionNFT is Script {

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address stakingProxy = vm.envAddress("DISCOVERY_STAKING_PROXY");
        address scientist = vm.envAddress("SCIENTIST_ADDRESS");

        console2.log("=== ConvictionNFT Deployment ===");
        console2.log("Deployer:", deployer);
        console2.log("DiscoveryStaking proxy:", stakingProxy);
        console2.log("Scientist:", scientist);

        vm.startBroadcast(deployerPrivateKey);

        // ================================================================
        // 1. Deploy ConvictionNFT (non-upgradeable, constructor-based)
        // ================================================================
        ConvictionNFT conviction = new ConvictionNFT(scientist, deployer);
        console2.log("ConvictionNFT deployed:", address(conviction));

        // ================================================================
        // 2. Grant MINTER_ROLE on ConvictionNFT to DiscoveryStaking proxy
        // ================================================================
        conviction.grantRole(conviction.MINTER_ROLE(), stakingProxy);
        console2.log("MINTER_ROLE granted to DiscoveryStaking proxy");

        // ================================================================
        // 3. Grant CLAIMER_ROLE on ConvictionNFT to DiscoveryStaking proxy
        // ================================================================
        conviction.grantRole(conviction.CLAIMER_ROLE(), stakingProxy);
        console2.log("CLAIMER_ROLE granted to DiscoveryStaking proxy");

        vm.stopBroadcast();

        // ================================================================
        // Summary
        // ================================================================
        console2.log("");
        console2.log("=== Deployment Summary ===");
        console2.log("ConvictionNFT:", address(conviction));
        console2.log("Scientist (royalties):", scientist);
        console2.log("DiscoveryStaking (proxy):", stakingProxy);
        console2.log("ERC-2981 royalty: 2.13% (1/phi^8) to scientist");
        console2.log("");
        console2.log("Wiring:");
        console2.log("  ConvictionNFT MINTER_ROLE  -> DiscoveryStaking proxy");
        console2.log("  ConvictionNFT CLAIMER_ROLE -> DiscoveryStaking proxy");
        console2.log("  ConvictionNFT admin        -> Deployer");
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Integrate ConvictionNFT into DiscoveryStaking (mint on stake, burn on claim)");
        console2.log("  2. Export ConvictionNFT ABI to artosphere-dapp");
        console2.log("  3. Verify contract on BaseScan");
    }
}
