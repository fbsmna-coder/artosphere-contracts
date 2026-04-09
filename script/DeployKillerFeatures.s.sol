// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/SpectralNFT.sol";
import "../src/PeerReviewDAO.sol";
import "../src/ReviewRewards.sol";
import "../src/FalsificationMarket.sol";
import "../src/PhiCoherence.sol";

/// @title DeployKillerFeatures — Deploy SpectralNFT, PeerReviewDAO, FalsificationMarket, PhiCoherence
/// @author F.B. Sapronov
/// @notice Deploys four killer-feature contracts on Base Mainnet (chain 8453),
///         registers them in the PhiCoherence cascade, and grants initial roles.
///
/// @dev Environment variables required:
///      PRIVATE_KEY          — deployer private key (also used as SCIENTIST)
///      ARTS_TOKEN           — existing PhiCoin proxy address
///      DISCOVERY_NFT        — existing ArtosphereDiscovery address
///      RESEARCHER_REGISTRY  — existing ResearcherRegistry address
///      TREASURY             — existing ZeckendorfTreasury address
contract DeployKillerFeatures is Script {
    function run() external {
        // ================================================================
        // LOAD ENVIRONMENT
        // ================================================================
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address artsToken          = vm.envAddress("ARTS_TOKEN");
        address discoveryNFT       = vm.envAddress("DISCOVERY_NFT");
        address researcherRegistry = vm.envAddress("RESEARCHER_REGISTRY");
        address treasury           = vm.envAddress("TREASURY");

        // Scientist = deployer
        address scientist = deployer;

        console.log("=== DeployKillerFeatures ===");
        console.log("Deployer / Scientist:", deployer);
        console.log("ARTS Token:", artsToken);
        console.log("Discovery NFT:", discoveryNFT);
        console.log("Researcher Registry:", researcherRegistry);
        console.log("Treasury:", treasury);

        vm.startBroadcast(deployerPrivateKey);

        // ================================================================
        // 1. DEPLOY SpectralNFT
        // ================================================================
        SpectralNFT spectralNFT = new SpectralNFT(scientist, deployer);
        console.log("SpectralNFT deployed:", address(spectralNFT));

        // ================================================================
        // 2. DEPLOY ReviewRewards + PeerReviewDAO
        // ================================================================
        ReviewRewards reviewRewards = new ReviewRewards(
            artsToken,
            treasury,
            deployer
        );
        console.log("ReviewRewards deployed:", address(reviewRewards));

        PeerReviewDAO peerReviewDAO = new PeerReviewDAO(
            artsToken,
            researcherRegistry,
            address(reviewRewards),
            treasury,
            deployer
        );
        console.log("PeerReviewDAO deployed:", address(peerReviewDAO));

        // Grant DAO_ROLE on ReviewRewards to PeerReviewDAO
        reviewRewards.grantRole(reviewRewards.DAO_ROLE(), address(peerReviewDAO));
        console.log("DAO_ROLE granted to PeerReviewDAO on ReviewRewards");

        // ================================================================
        // 3. DEPLOY FalsificationMarket
        // ================================================================
        FalsificationMarket falsificationMarket = new FalsificationMarket(
            artsToken,
            discoveryNFT,
            scientist,
            treasury,
            deployer
        );
        console.log("FalsificationMarket deployed:", address(falsificationMarket));

        // ================================================================
        // 4. DEPLOY PhiCoherence
        // ================================================================
        PhiCoherence phiCoherence = new PhiCoherence(deployer);
        console.log("PhiCoherence deployed:", address(phiCoherence));

        // ================================================================
        // 5. REGISTER CONTRACTS IN PhiCoherence
        //    Level 2: SpectralNFT, FalsificationMarket
        //    Level 3: PeerReviewDAO, PhiCoherence itself
        // ================================================================
        phiCoherence.registerContract(address(spectralNFT), 2);
        phiCoherence.registerContract(address(falsificationMarket), 2);
        phiCoherence.registerContract(address(peerReviewDAO), 3);
        phiCoherence.registerContract(address(phiCoherence), 3);
        console.log("All contracts registered in PhiCoherence");

        // ================================================================
        // 6. GRANT MINTER_ROLE on SpectralNFT to deployer (initial minting)
        // ================================================================
        spectralNFT.grantRole(spectralNFT.MINTER_ROLE(), deployer);
        console.log("MINTER_ROLE granted to deployer on SpectralNFT");

        // ================================================================
        // 7. GRANT ORACLE_ROLE on SpectralNFT and FalsificationMarket to deployer
        // ================================================================
        spectralNFT.grantRole(spectralNFT.ORACLE_ROLE(), deployer);
        falsificationMarket.grantRole(falsificationMarket.ORACLE_ROLE(), deployer);
        console.log("ORACLE_ROLE granted to deployer on SpectralNFT and FalsificationMarket");

        vm.stopBroadcast();

        // ================================================================
        // SUMMARY
        // ================================================================
        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("SpectralNFT:", address(spectralNFT));
        console.log("ReviewRewards:", address(reviewRewards));
        console.log("PeerReviewDAO:", address(peerReviewDAO));
        console.log("FalsificationMarket:", address(falsificationMarket));
        console.log("PhiCoherence:", address(phiCoherence));
    }
}
