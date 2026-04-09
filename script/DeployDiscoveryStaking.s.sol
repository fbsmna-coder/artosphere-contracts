// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PhiCoin} from "../src/PhiCoin.sol";
import {ArtosphereDiscovery} from "../src/ArtosphereDiscovery.sol";
import {DiscoveryOracle} from "../src/DiscoveryOracle.sol";
import {DiscoveryStaking} from "../src/DiscoveryStaking.sol";

/// @title DeployDiscoveryStaking — Deploy the Discovery Staking prediction market
/// @author F.B. Sapronov
/// @notice Deploys DiscoveryOracle + DiscoveryStaking (UUPS proxy) and wires them together
/// @dev Prerequisites: PhiCoin and ArtosphereDiscovery must already be deployed
///
///      Environment variables required:
///        PRIVATE_KEY          — deployer private key (must be admin of PhiCoin & Discovery)
///        PHICOIN_PROXY        — address of the deployed PhiCoin proxy
///        DISCOVERY_NFT        — address of the deployed ArtosphereDiscovery
///        TREASURY             — address for protocol treasury
///        VALIDATOR_1..4       — addresses of initial oracle validators
contract DeployDiscoveryStaking is Script {

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address phiCoinProxy = vm.envAddress("PHICOIN_PROXY");
        address discoveryNFT = vm.envAddress("DISCOVERY_NFT");
        address treasury = vm.envAddress("TREASURY");

        console2.log("=== Discovery Staking Deployment ===");
        console2.log("Deployer:", deployer);
        console2.log("PhiCoin:", phiCoinProxy);
        console2.log("Discovery NFT:", discoveryNFT);
        console2.log("Treasury:", treasury);

        vm.startBroadcast(deployerPrivateKey);

        // ================================================================
        // 1. Deploy DiscoveryOracle
        // ================================================================
        DiscoveryOracle oracle = new DiscoveryOracle(discoveryNFT, deployer);
        console2.log("DiscoveryOracle deployed:", address(oracle));

        // ================================================================
        // 2. Deploy DiscoveryStaking (UUPS proxy)
        // ================================================================
        DiscoveryStaking stakingImpl = new DiscoveryStaking();
        console2.log("DiscoveryStaking impl:", address(stakingImpl));

        bytes memory initData = abi.encodeWithSelector(
            DiscoveryStaking.initialize.selector,
            phiCoinProxy,
            discoveryNFT,
            treasury,
            deployer
        );

        ERC1967Proxy stakingProxy = new ERC1967Proxy(address(stakingImpl), initData);
        DiscoveryStaking staking = DiscoveryStaking(address(stakingProxy));
        console2.log("DiscoveryStaking proxy:", address(stakingProxy));

        // ================================================================
        // 3. Wire Oracle <-> Staking
        // ================================================================

        // Oracle needs to know staking contract
        oracle.setStakingContract(address(stakingProxy));
        console2.log("Oracle -> Staking wired");

        // Staking needs ORACLE_ROLE for the oracle contract
        staking.grantRole(staking.ORACLE_ROLE(), address(oracle));
        console2.log("Staking ORACLE_ROLE granted to Oracle");

        // ================================================================
        // 4. Grant ORACLE_ROLE on ArtosphereDiscovery NFT
        // ================================================================
        ArtosphereDiscovery discovery = ArtosphereDiscovery(discoveryNFT);
        bytes32 discoveryOracleRole = discovery.ORACLE_ROLE();
        discovery.grantRole(discoveryOracleRole, address(oracle));
        console2.log("Discovery NFT ORACLE_ROLE granted to Oracle");

        // ================================================================
        // 5. Add initial validators (if env vars set)
        // ================================================================
        address[4] memory validators;
        validators[0] = vm.envOr("VALIDATOR_1", address(0));
        validators[1] = vm.envOr("VALIDATOR_2", address(0));
        validators[2] = vm.envOr("VALIDATOR_3", address(0));
        validators[3] = vm.envOr("VALIDATOR_4", address(0));

        uint256 validatorCount;
        for (uint256 i = 0; i < 4; i++) {
            if (validators[i] != address(0)) {
                oracle.addValidator(validators[i]);
                validatorCount++;
                console2.log("Validator added:", validators[i]);
            }
        }
        console2.log("Total validators:", validatorCount);

        vm.stopBroadcast();

        // ================================================================
        // Summary
        // ================================================================
        console2.log("");
        console2.log("=== Deployment Summary ===");
        console2.log("DiscoveryOracle:", address(oracle));
        console2.log("DiscoveryStaking (proxy):", address(stakingProxy));
        console2.log("DiscoveryStaking (impl):", address(stakingImpl));
        console2.log("Validators:", validatorCount);
        console2.log("");
        console2.log("phi-Cascade v2:");
        console2.log("  Winners:   61.80% (phi^-1)");
        console2.log("  Burn:      23.60% (phi^-3)");
        console2.log("  Scientist:  9.02% (phi^-5)");
        console2.log("  Treasury:   5.57% (phi^-6)");
    }
}
