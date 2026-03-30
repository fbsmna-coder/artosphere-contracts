// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PhiMath} from "../src/PhiMath.sol";

/// @title PhiMath Deploy Script
/// @notice Deploys a PhiMathConsumer contract that links the PhiMath library
/// @dev Since PhiMath is an internal library (all functions are internal/pure),
///      it gets inlined by the compiler — no separate library deployment needed.
///      This script deploys a consumer contract for on-chain verification and testing.

/// @notice Minimal consumer contract that exposes PhiMath for on-chain verification
contract PhiMathConsumer {
    /// @notice Verify the golden ratio identity: φ² = φ + 1
    /// @return valid True if the identity holds within 1 wei tolerance
    function verifyGoldenIdentity() external pure returns (bool valid) {
        uint256 phiSquared = PhiMath.wadMul(PhiMath.PHI, PhiMath.PHI);
        uint256 phiPlusOne = PhiMath.PHI + PhiMath.WAD;
        // Allow 1 wei rounding
        uint256 diff = phiSquared > phiPlusOne
            ? phiSquared - phiPlusOne
            : phiPlusOne - phiSquared;
        valid = diff <= 1;
    }

    /// @notice Get Fibonacci number (WAD-scaled)
    function fibonacci(uint256 n) external pure returns (uint256) {
        return PhiMath.fibonacci(n);
    }

    /// @notice Get φ^n (WAD-scaled)
    function phiPow(uint256 n) external pure returns (uint256) {
        return PhiMath.phiPow(n);
    }

    /// @notice Get φ^(-n) (WAD-scaled)
    function phiInvPow(uint256 n) external pure returns (uint256) {
        return PhiMath.phiInvPow(n);
    }

    /// @notice Get emission for epoch
    function fibEmission(uint256 epoch) external pure returns (uint256) {
        return PhiMath.fibEmission(epoch);
    }

    /// @notice Get staking APY for epoch
    function fibStakingAPY(uint256 epoch) external pure returns (uint256) {
        return PhiMath.fibStakingAPY(epoch);
    }

    /// @notice Get Zeckendorf decomposition
    function zeckendorf(uint256 n) external pure returns (uint256[] memory) {
        return PhiMath.zeckendorf(n);
    }

    /// @notice Calculate golden fee
    function goldenFee(uint256 amount, uint256 phiLevel) external pure returns (uint256) {
        return PhiMath.goldenFee(amount, phiLevel);
    }
}

contract DeployPhiMath is Script {
    function run() external returns (PhiMathConsumer consumer) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console2.log("=== PhiMath Deployment ===");
        console2.log("Deployer:", vm.addr(deployerPrivateKey));
        console2.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        consumer = new PhiMathConsumer();

        vm.stopBroadcast();

        // Post-deploy verification
        console2.log("");
        console2.log("PhiMathConsumer deployed at:", address(consumer));
        console2.log("Golden identity valid:", consumer.verifyGoldenIdentity());
        console2.log("PHI constant:", PhiMath.PHI);
        console2.log("F(10):", consumer.fibonacci(10));
        console2.log("APY(0):", consumer.fibStakingAPY(0));
        console2.log("");
        console2.log("=== Deployment Complete ===");
    }
}
