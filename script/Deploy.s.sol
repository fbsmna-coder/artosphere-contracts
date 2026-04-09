// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PhiCoin} from "../src/PhiCoin.sol";
import {PhiStaking} from "../src/PhiStaking.sol";
import {PhiGovernor} from "../src/PhiGovernor.sol";
import {PhiVesting} from "../src/PhiVesting.sol";
import {MatryoshkaStaking} from "../src/MatryoshkaStaking.sol";
import {ArtosphereQuests} from "../src/ArtosphereQuests.sol";
import {PhiCertificate} from "../src/PhiCertificate.sol";
import {GoldenMirror} from "../src/GoldenMirror.sol";
import {PhiAMM} from "../src/PhiAMM.sol";
import {NashFee} from "../src/NashFee.sol";
import {ZeckendorfTreasury} from "../src/ZeckendorfTreasury.sol";

/// @title DeployArtosphere — Full Protocol Deployment Script
/// @author F.B. Sapronov
/// @notice Deploys all Artosphere (ARTS) protocol contracts with correct dependency ordering
contract DeployArtosphere is Script {
    // Placeholder for paired token in AMM (use WETH on mainnet)
    address constant WETH_PLACEHOLDER = address(0xdead);

    // Deployed addresses stored as state to avoid stack-too-deep
    address public phiCoinProxy;
    address public phiCoinImpl;
    address public phiStakingProxy;
    address public phiStakingImpl;
    address public timelockAddr;
    address public governorAddr;
    address public vestingAddr;
    address public matryoshkaAddr;
    address public questsAddr;
    address public certificateAddr;
    address public goldenMirrorAddr;
    address public ammAddr;
    address public nashFeeAddr;
    address public treasuryAddr;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("=== Artosphere Protocol Deployment ===");
        console2.log("Deployer:", deployer);
        console2.log("Chain ID:", block.chainid);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        _deployCore(deployer);
        _deployGovernance(deployer);
        _deployEcosystem(deployer);

        vm.stopBroadcast();

        _logSummary();
    }

    /// @dev Deploys PhiCoin proxy, PhiStaking proxy, grants MINTER_ROLE
    function _deployCore(address deployer) internal {
        // 1. PhiCoin — UUPS Proxy
        PhiCoin impl = new PhiCoin();
        phiCoinImpl = address(impl);
        bytes memory initData = abi.encodeCall(PhiCoin.initialize, (deployer));
        ERC1967Proxy proxy = new ERC1967Proxy(phiCoinImpl, initData);
        phiCoinProxy = address(proxy);

        console2.log("[1] PhiCoin impl:", phiCoinImpl);
        console2.log("[1] PhiCoin proxy:", phiCoinProxy);

        // 2. PhiStaking — UUPS Proxy
        PhiStaking stakingImpl = new PhiStaking();
        phiStakingImpl = address(stakingImpl);
        bytes memory stakingInitData = abi.encodeCall(
            PhiStaking.initialize,
            (PhiCoin(phiCoinProxy), deployer)
        );
        ERC1967Proxy stakingProxy = new ERC1967Proxy(phiStakingImpl, stakingInitData);
        phiStakingProxy = address(stakingProxy);

        console2.log("[2] PhiStaking impl:", phiStakingImpl);
        console2.log("[2] PhiStaking proxy:", phiStakingProxy);

        // 3. Grant MINTER_ROLE to PhiStaking
        PhiCoin(phiCoinProxy).grantRole(
            PhiCoin(phiCoinProxy).MINTER_ROLE(),
            phiStakingProxy
        );
        console2.log("[3] MINTER_ROLE granted to PhiStaking");
    }

    /// @dev Deploys TimelockController + PhiGovernor
    function _deployGovernance(address deployer) internal {
        // 4. TimelockController + PhiGovernor
        address[] memory empty = new address[](0);
        TimelockController timelock = new TimelockController(
            233,     // minDelay = F(13) seconds
            empty,   // proposers (empty, granted below)
            empty,   // executors (empty, granted below)
            deployer // admin
        );
        timelockAddr = address(timelock);

        PhiGovernor governor = new PhiGovernor(
            IVotes(phiCoinProxy),
            timelock
        );
        governorAddr = address(governor);

        // Grant proposer, executor, canceller roles to governor
        timelock.grantRole(timelock.PROPOSER_ROLE(), governorAddr);
        timelock.grantRole(timelock.EXECUTOR_ROLE(), governorAddr);
        timelock.grantRole(timelock.CANCELLER_ROLE(), governorAddr);

        console2.log("[4] TimelockController:", timelockAddr);
        console2.log("[4] PhiGovernor:", governorAddr);
    }

    /// @dev Deploys Vesting, MatryoshkaStaking, Quests, Certificate, GoldenMirror, AMM, NashFee, Treasury
    function _deployEcosystem(address deployer) internal {
        // 5. PhiVesting
        vestingAddr = address(new PhiVesting(IERC20(phiCoinProxy), deployer));
        console2.log("[5] PhiVesting:", vestingAddr);

        // 6. MatryoshkaStaking
        matryoshkaAddr = address(new MatryoshkaStaking(phiCoinProxy));
        console2.log("[6] MatryoshkaStaking:", matryoshkaAddr);

        // 7. ArtosphereQuests (maxRewards = 54_000e18 for ~1000 users x 54 ARTS)
        questsAddr = address(new ArtosphereQuests(phiCoinProxy, 54_000e18));
        console2.log("[7] ArtosphereQuests:", questsAddr);

        // 8. PhiCertificate — authorize quests and staking as minters
        PhiCertificate cert = new PhiCertificate();
        certificateAddr = address(cert);
        cert.setAuthorizedMinter(questsAddr, true);
        cert.setAuthorizedMinter(phiStakingProxy, true);
        cert.setAuthorizedMinter(matryoshkaAddr, true);
        console2.log("[8] PhiCertificate:", certificateAddr);

        // 9. GoldenMirror (gARTS)
        goldenMirrorAddr = address(new GoldenMirror(phiCoinProxy));
        console2.log("[9] GoldenMirror:", goldenMirrorAddr);

        // 10. PhiAMM (paired token = placeholder)
        ammAddr = address(new PhiAMM(phiCoinProxy, WETH_PLACEHOLDER));
        console2.log("[10] PhiAMM:", ammAddr);

        // 11. NashFee
        nashFeeAddr = address(new NashFee());
        console2.log("[11] NashFee:", nashFeeAddr);

        // 12. ZeckendorfTreasury
        treasuryAddr = address(new ZeckendorfTreasury(phiCoinProxy));
        console2.log("[12] ZeckendorfTreasury:", treasuryAddr);
    }

    function _logSummary() internal view {
        console2.log("");
        console2.log("========================================");
        console2.log("=== Artosphere Protocol Deployed ===");
        console2.log("========================================");
        console2.log("");
        console2.log("PhiCoin (proxy):      ", phiCoinProxy);
        console2.log("PhiCoin (impl):       ", phiCoinImpl);
        console2.log("PhiStaking (proxy):   ", phiStakingProxy);
        console2.log("PhiStaking (impl):    ", phiStakingImpl);
        console2.log("TimelockController:   ", timelockAddr);
        console2.log("PhiGovernor:          ", governorAddr);
        console2.log("PhiVesting:           ", vestingAddr);
        console2.log("MatryoshkaStaking:    ", matryoshkaAddr);
        console2.log("ArtosphereQuests:     ", questsAddr);
        console2.log("PhiCertificate:       ", certificateAddr);
        console2.log("GoldenMirror (gARTS): ", goldenMirrorAddr);
        console2.log("PhiAMM:               ", ammAddr);
        console2.log("NashFee:              ", nashFeeAddr);
        console2.log("ZeckendorfTreasury:   ", treasuryAddr);
        console2.log("");
        console2.log("Total contracts: 16 (12 unique + 2 impls + 2 proxies)");
        console2.log("========================================");
    }
}
