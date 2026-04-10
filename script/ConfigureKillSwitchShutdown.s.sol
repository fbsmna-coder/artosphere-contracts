// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ShutdownVault} from "../src/ShutdownVault.sol";

/// @title ConfigureKillSwitchShutdown — Wire KillSwitch graceful-shutdown pool
/// @author F.B. Sapronov
/// @notice Deploys ShutdownVault, mints 8M ARTS (= F(6)×10⁶, the "Insurance Fund"
///         allocation) directly into it via a Safe-gated MINTER_ROLE grant,
///         approves KillSwitch, points KillSwitch at the vault, and migrates
///         both KillSwitch and ShutdownVault admin to the Gnosis Safe.
///
/// @dev State entering this script (Base mainnet):
///        - PhiCoin (proxy) DEFAULT_ADMIN_ROLE = Safe (migrated already)
///        - Nobody holds MINTER_ROLE (totalSupply = 0, emission never started)
///        - ZeckendorfTreasury holds 0 ARTS (not funded yet)
///        - KillSwitch DEFAULT_ADMIN_ROLE = deployer EOA (not yet migrated)
///        - Safe is 1-of-1 with deployer as sole owner
///
///      Because PhiCoin admin = Safe, we must use Safe.execTransaction to grant
///      MINTER_ROLE. We use the "pre-validated" signature format (v=1), which
///      is honored when msg.sender is a Safe owner — here that's the deployer
///      EOA sending the tx.
contract ConfigureKillSwitchShutdown is Script {
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 constant TRIGGER_ROLE = keccak256("TRIGGER_ROLE");
    bytes32 constant MINTER_ROLE = keccak256("MINTER_ROLE");

    uint256 constant INSURANCE_AMOUNT = 8_000_000 ether;

    struct Cfg {
        address deployer;
        address artsToken;
        address killSwitch;
        address safe;
    }

    function run() external {
        Cfg memory c = _loadConfig();
        _printHeader(c);
        _preflightChecks(c);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        ShutdownVault vault = new ShutdownVault(c.artsToken, c.killSwitch, c.deployer);
        console2.log("ShutdownVault deployed:", address(vault));

        _grantMinterViaSafe(c);
        _mintToVault(c, address(vault));
        _revokeMinterViaSafe(c);
        _approveAndWire(c, vault);
        _migrateAdmin(c, vault);

        vm.stopBroadcast();

        _printSummary(c, address(vault));
    }

    // --- config ---

    function _loadConfig() internal view returns (Cfg memory c) {
        c.deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        c.artsToken = vm.envAddress("PHICOIN_PROXY");
        c.killSwitch = vm.envAddress("KILLSWITCH");
        c.safe = vm.envAddress("SAFE_ADDRESS");
    }

    function _printHeader(Cfg memory c) internal pure {
        console2.log("=== Configure KillSwitch Shutdown Pool ===");
        console2.log("Deployer:  ", c.deployer);
        console2.log("ARTS:      ", c.artsToken);
        console2.log("KillSwitch:", c.killSwitch);
        console2.log("Safe:      ", c.safe);
        console2.log("Amount:    8,000,000 ARTS (F(6) x 10^6)");
        console2.log("");
    }

    function _preflightChecks(Cfg memory c) internal view {
        require(c.safe != address(0), "SAFE_ADDRESS required");
        require(c.safe.code.length > 0, "Safe has no code");

        // Verify Safe recognizes deployer as owner (required for pre-validated sig)
        (bool ok, bytes memory ret) = c.safe.staticcall(
            abi.encodeWithSignature("isOwner(address)", c.deployer)
        );
        require(ok && abi.decode(ret, (bool)), "Deployer is not a Safe owner");

        // Verify Safe holds DEFAULT_ADMIN_ROLE on PhiCoin
        bool safeIsAdmin = IAccessControl(c.artsToken).hasRole(DEFAULT_ADMIN_ROLE, c.safe);
        require(safeIsAdmin, "Safe is not PhiCoin DEFAULT_ADMIN");

        // Verify remaining mint capacity
        uint256 supply = IERC20(c.artsToken).totalSupply();
        console2.log("PhiCoin totalSupply:", supply / 1e18);
        require(supply + INSURANCE_AMOUNT <= 987_000_000 ether, "Would exceed MAX_SUPPLY");
    }

    // --- Safe-gated MINTER_ROLE lifecycle ---

    function _grantMinterViaSafe(Cfg memory c) internal {
        bytes memory grantCall = abi.encodeWithSignature(
            "grantRole(bytes32,address)",
            MINTER_ROLE,
            c.deployer
        );
        _safeExec(c.safe, c.artsToken, grantCall);
        console2.log("  [+] MINTER_ROLE granted to deployer (via Safe)");

        // Verify
        bool has = IAccessControl(c.artsToken).hasRole(MINTER_ROLE, c.deployer);
        require(has, "MINTER_ROLE grant failed");
    }

    function _revokeMinterViaSafe(Cfg memory c) internal {
        bytes memory revokeCall = abi.encodeWithSignature(
            "revokeRole(bytes32,address)",
            MINTER_ROLE,
            c.deployer
        );
        _safeExec(c.safe, c.artsToken, revokeCall);
        console2.log("  [+] MINTER_ROLE revoked from deployer (via Safe)");

        bool has = IAccessControl(c.artsToken).hasRole(MINTER_ROLE, c.deployer);
        require(!has, "MINTER_ROLE revoke failed");
    }

    function _mintToVault(Cfg memory c, address vault) internal {
        bytes memory mintCall = abi.encodeWithSignature(
            "mintTo(address,uint256)",
            vault,
            INSURANCE_AMOUNT
        );
        (bool ok, bytes memory err) = c.artsToken.call(mintCall);
        require(ok, _decodeRevert(err));

        uint256 bal = IERC20(c.artsToken).balanceOf(vault);
        require(bal == INSURANCE_AMOUNT, "Mint amount mismatch");
        console2.log("  [+] Minted 8M ARTS -> ShutdownVault");
    }

    function _approveAndWire(Cfg memory c, ShutdownVault vault) internal {
        vault.approveSpender(c.killSwitch, type(uint256).max);
        console2.log("  [+] ShutdownVault approved KillSwitch (max)");

        // KillSwitch DEFAULT_ADMIN_ROLE is still deployer — direct call works
        (bool ok, bytes memory err) = c.killSwitch.call(
            abi.encodeWithSignature("setTreasury(address)", address(vault))
        );
        require(ok, _decodeRevert(err));
        console2.log("  [+] KillSwitch.treasury -> ShutdownVault");
    }

    function _migrateAdmin(Cfg memory c, ShutdownVault vault) internal {
        console2.log("");
        console2.log("--- Admin migration to Safe ---");

        // ShutdownVault
        vault.grantRole(DEFAULT_ADMIN_ROLE, c.safe);
        vault.grantRole(ADMIN_ROLE, c.safe);
        vault.renounceRole(ADMIN_ROLE, c.deployer);
        vault.renounceRole(DEFAULT_ADMIN_ROLE, c.deployer);
        console2.log("  [+] ShutdownVault admin migrated to Safe");

        // KillSwitch (was not in initial multisig migration)
        IAccessControl ks = IAccessControl(c.killSwitch);
        ks.grantRole(DEFAULT_ADMIN_ROLE, c.safe);
        ks.grantRole(TRIGGER_ROLE, c.safe);
        ks.renounceRole(TRIGGER_ROLE, c.deployer);
        ks.renounceRole(DEFAULT_ADMIN_ROLE, c.deployer);
        console2.log("  [+] KillSwitch admin migrated to Safe");
    }

    // --- Safe execTransaction with pre-validated signature (v=1) ---
    //
    // Format of pre-validated signature:
    //     r = left-padded signer address (bytes32)
    //     s = 0
    //     v = 1
    // Honored when msg.sender == signer AND signer is an owner of the Safe.
    //
    // Safe.execTransaction params (Safe v1.3):
    //     to, value, data, operation(Call=0), safeTxGas, baseGas, gasPrice,
    //     gasToken, refundReceiver, signatures
    function _safeExec(address safe, address to, bytes memory data) internal {
        address signer = vm.addr(vm.envUint("PRIVATE_KEY"));
        bytes memory sig = abi.encodePacked(
            bytes32(uint256(uint160(signer))), // r
            bytes32(0),                         // s
            uint8(1)                            // v
        );

        bytes memory execCall = abi.encodeWithSignature(
            "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)",
            to,
            uint256(0),
            data,
            uint8(0),
            uint256(0),
            uint256(0),
            uint256(0),
            address(0),
            address(0),
            sig
        );

        (bool ok, bytes memory err) = safe.call(execCall);
        require(ok, _decodeRevert(err));
    }

    function _printSummary(Cfg memory c, address vault) internal view {
        console2.log("");
        console2.log("=== Complete ===");
        console2.log("ShutdownVault:      ", vault);
        console2.log("Reserve:            ", IERC20(c.artsToken).balanceOf(vault) / 1e18, "ARTS");
        console2.log("KillSwitch treasury:", vault);
        console2.log("");
        console2.log("Verify:");
        console2.log("  cast call", c.killSwitch, "'treasury()(address)'");
    }

    function _decodeRevert(bytes memory err) internal pure returns (string memory) {
        if (err.length < 68) return "Silent revert from external call";
        assembly {
            err := add(err, 0x04)
        }
        return abi.decode(err, (string));
    }
}
