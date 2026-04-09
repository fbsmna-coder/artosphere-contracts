// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Script, console2} from "forge-std/Script.sol";
import {FibonacciFusionV2} from "../src/FibonacciFusionV2.sol";

contract DeployFusionV2 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address artsToken = vm.envAddress("PHICOIN_PROXY");
        address vrfCoord = 0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634;
        
        vm.startBroadcast(pk);
        FibonacciFusionV2 fusion = new FibonacciFusionV2(artsToken, deployer, vrfCoord);
        
        // Configure VRF
        uint256 subId = 67270942096806911943245115177549204890314025757658665541754752224467152956804;
        bytes32 keyHash = 0x9e1344a1247c8a1785d0a4681a27152bffdb43666ae5bf7d14d24a5efd44bf71;
        fusion.setVRFConfig(subId, keyHash, 200000);
        
        vm.stopBroadcast();
        
        console2.log("FibonacciFusionV2:", address(fusion));
        console2.log("VRF configured: sub", subId);
    }
}
