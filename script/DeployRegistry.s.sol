// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/ResearcherRegistry.sol";

contract DeployRegistry is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address stakingContract = vm.envAddress("STAKING_CONTRACT");

        vm.startBroadcast(pk);
        ResearcherRegistry reg = new ResearcherRegistry(deployer);
        console.log("ResearcherRegistry:", address(reg));

        // Grant STAKING_ROLE to DiscoveryStaking so it can update researcher reputation
        reg.grantRole(reg.STAKING_ROLE(), stakingContract);
        console.log("STAKING_ROLE granted to:", stakingContract);

        vm.stopBroadcast();
    }
}
