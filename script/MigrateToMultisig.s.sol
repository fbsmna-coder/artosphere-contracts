// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title MigrateToMultisig — Transfer admin roles from EOA to Gnosis Safe
/// @author F.B. Sapronov
/// @notice Grants DEFAULT_ADMIN_ROLE and UPGRADER_ROLE to a Gnosis Safe multisig,
///         then renounces them from the deployer EOA. This is a one-way migration.
///
/// @dev Usage:
///   1. Set SAFE_ADDRESS in .env (the Gnosis Safe address)
///   2. Set all contract proxy addresses in .env
///   3. Run: forge script script/MigrateToMultisig.s.sol --rpc-url $BASE_MAINNET_RPC --broadcast
///
///   IMPORTANT: Before running with --broadcast, do a dry run first (without --broadcast)
///   to verify all transactions succeed. After renouncing, there is NO rollback.
contract MigrateToMultisig is Script {
    // Role constants (must match the deployed contracts)
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    function run() external {
        // =====================================================================
        // Load configuration from environment
        // =====================================================================
        address safe = vm.envAddress("SAFE_ADDRESS");
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        // UUPS proxies (have DEFAULT_ADMIN_ROLE + UPGRADER_ROLE)
        address phiCoinProxy = vm.envAddress("PHICOIN_PROXY");
        address phiStakingProxy = vm.envAddress("PHISTAKING_PROXY");
        address discoveryStakingProxy = vm.envAddress("DISCOVERY_STAKING_PROXY");

        // Non-upgradeable contracts
        address discoveryNFT = vm.envAddress("DISCOVERY_NFT");
        address convictionNFT = vm.envAddress("CONVICTION_NFT");
        address fibonacciFusion = vm.envAddress("FIBONACCI_FUSION");

        // =====================================================================
        // Sanity checks
        // =====================================================================
        require(safe != address(0), "SAFE_ADDRESS not set");
        require(safe != deployer, "Safe cannot be the deployer EOA");
        require(safe.code.length > 0, "SAFE_ADDRESS has no code - not a deployed Safe");

        console2.log("=== Artosphere Multisig Migration ===");
        console2.log("Safe address:    ", safe);
        console2.log("Deployer EOA:    ", deployer);
        console2.log("");

        vm.startBroadcast(deployerKey);

        // =====================================================================
        // 1. PhiCoin (UUPS) — DEFAULT_ADMIN_ROLE + UPGRADER_ROLE
        // =====================================================================
        console2.log("--- PhiCoin (proxy: %s) ---", phiCoinProxy);
        _migrateUUPS(phiCoinProxy, safe, deployer);

        // =====================================================================
        // 2. PhiStaking (UUPS) — DEFAULT_ADMIN_ROLE + UPGRADER_ROLE
        // =====================================================================
        console2.log("--- PhiStaking (proxy: %s) ---", phiStakingProxy);
        _migrateUUPS(phiStakingProxy, safe, deployer);

        // =====================================================================
        // 3. DiscoveryStaking (UUPS) — DEFAULT_ADMIN_ROLE + UPGRADER_ROLE
        // =====================================================================
        console2.log("--- DiscoveryStaking (proxy: %s) ---", discoveryStakingProxy);
        _migrateUUPS(discoveryStakingProxy, safe, deployer);

        // =====================================================================
        // 4. ArtosphereDiscovery — ADMIN_ROLE (custom, not DEFAULT_ADMIN_ROLE)
        // =====================================================================
        console2.log("--- ArtosphereDiscovery (addr: %s) ---", discoveryNFT);
        IAccessControl discovery = IAccessControl(discoveryNFT);

        // ArtosphereDiscovery uses ADMIN_ROLE with DEFAULT_ADMIN_ROLE as its admin
        discovery.grantRole(ADMIN_ROLE, safe);
        console2.log("  [+] Granted ADMIN_ROLE to Safe");

        // Also grant DEFAULT_ADMIN_ROLE so Safe can manage roles
        discovery.grantRole(DEFAULT_ADMIN_ROLE, safe);
        console2.log("  [+] Granted DEFAULT_ADMIN_ROLE to Safe");

        discovery.renounceRole(ADMIN_ROLE, deployer);
        console2.log("  [-] Renounced ADMIN_ROLE from deployer");

        discovery.renounceRole(DEFAULT_ADMIN_ROLE, deployer);
        console2.log("  [-] Renounced DEFAULT_ADMIN_ROLE from deployer");

        // =====================================================================
        // 5. ConvictionNFT — DEFAULT_ADMIN_ROLE
        // =====================================================================
        console2.log("--- ConvictionNFT (addr: %s) ---", convictionNFT);
        IAccessControl conviction = IAccessControl(convictionNFT);

        conviction.grantRole(DEFAULT_ADMIN_ROLE, safe);
        console2.log("  [+] Granted DEFAULT_ADMIN_ROLE to Safe");

        conviction.renounceRole(DEFAULT_ADMIN_ROLE, deployer);
        console2.log("  [-] Renounced DEFAULT_ADMIN_ROLE from deployer");

        // =====================================================================
        // 6. FibonacciFusion — DEFAULT_ADMIN_ROLE
        // =====================================================================
        console2.log("--- FibonacciFusion (addr: %s) ---", fibonacciFusion);
        IAccessControl fusion = IAccessControl(fibonacciFusion);

        fusion.grantRole(DEFAULT_ADMIN_ROLE, safe);
        console2.log("  [+] Granted DEFAULT_ADMIN_ROLE to Safe");

        fusion.renounceRole(DEFAULT_ADMIN_ROLE, deployer);
        console2.log("  [-] Renounced DEFAULT_ADMIN_ROLE from deployer");

        vm.stopBroadcast();

        // =====================================================================
        // Summary
        // =====================================================================
        console2.log("");
        console2.log("=== Migration Complete ===");
        console2.log("All admin roles transferred to Safe: ", safe);
        console2.log("");
        console2.log("VERIFY with cast:");
        console2.log("  cast call <CONTRACT> 'hasRole(bytes32,address)(bool)' 0x00 <SAFE>");
        console2.log("  cast call <CONTRACT> 'hasRole(bytes32,address)(bool)' 0x00 <DEPLOYER>");
    }

    /// @dev Migrates a UUPS contract: grants roles to Safe, renounces from deployer.
    ///      Order matters: grant first, renounce second. If grant fails, deployer keeps access.
    function _migrateUUPS(address proxy, address safe, address deployer) internal {
        IAccessControl ac = IAccessControl(proxy);

        // Step 1: Grant roles to Safe
        ac.grantRole(DEFAULT_ADMIN_ROLE, safe);
        console2.log("  [+] Granted DEFAULT_ADMIN_ROLE to Safe");

        ac.grantRole(UPGRADER_ROLE, safe);
        console2.log("  [+] Granted UPGRADER_ROLE to Safe");

        // Step 2: Renounce roles from deployer
        // NOTE: renounceRole requires msg.sender == account, which is the deployer here
        ac.renounceRole(DEFAULT_ADMIN_ROLE, deployer);
        console2.log("  [-] Renounced DEFAULT_ADMIN_ROLE from deployer");

        ac.renounceRole(UPGRADER_ROLE, deployer);
        console2.log("  [-] Renounced UPGRADER_ROLE from deployer");
    }
}
