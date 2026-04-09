// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/ArtosphereDiscovery.sol";

/// @title MintNewDiscoveries — Add Paper VIII + Master Action v2.0
/// @notice Mints 2 new Discovery NFTs on existing contract
///         Also marks #12 (Master Lagrangian v1.2) as SUPERSEDED
contract MintNewDiscoveries is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        ArtosphereDiscovery discovery = ArtosphereDiscovery(0xA345C41e74Afc16f9071C0EAa5Ac71b0BDfe1D49);

        // Mark #12 (Master Lagrangian v1.2) as superseded by v2.0
        discovery.updateStatus(12, "SUPERSEDED");
        console.log("Discovery #12 marked SUPERSEDED");

        // #13 -- Paper VIII: Artosphere Cosmology
        discovery.registerDiscovery(
            "Paper VIII: Artosphere Cosmology -- Inflation, CP Violation, Strong CP",
            "V_inf = V_Art(s_inf), delta_CP = arctan(sqrt(5)), theta_QCD = 0",
            "10.5281/zenodo.19482718",
            "S",
            "PROVEN",
            keccak256("Paper VIII - Artosphere Cosmology - Sapronov 2026-04-09"),
            0 // exact (Strong CP = 0)
        );
        console.log("Discovery #13 minted: Paper VIII Cosmology");

        // #14 -- Master Action v2.0: 36 Parameters
        discovery.registerDiscovery(
            "Master Action v2.0: 36 Parameters from M_Pl and phi",
            "S_Art[g,A,psi,s] -> 36 observables (SM+DM+DE+cosmo), 0 free params",
            "10.5281/zenodo.19482719",
            "S",
            "PROVEN",
            keccak256("Master Action v2.0 - 36/36 COMPLETE - Sapronov 2026-04-09"),
            58 // mean 0.58%
        );
        console.log("Discovery #14 minted: Master Action v2.0 (MASTER NFT)");

        console.log("Total discoveries:", discovery.totalDiscoveries());

        vm.stopBroadcast();
    }
}
