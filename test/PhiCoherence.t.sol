// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PhiCoherence} from "../src/PhiCoherence.sol";
import {PhiMath} from "../src/PhiMath.sol";

/// @title PhiCoherenceTest — Comprehensive tests for the PhiCoherence cascade coordinator
/// @dev 15 tests covering deployment, registration, propagation, damping, ring buffer, and views
contract PhiCoherenceTest is Test {
    PhiCoherence public coherence;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");

    // Contracts at each level
    address public tokenContract = makeAddr("tokenContract"); // Level 0
    address public stakingContract = makeAddr("stakingContract"); // Level 1
    address public fusionContract = makeAddr("fusionContract"); // Level 2
    address public reputationContract = makeAddr("reputationContract"); // Level 3

    uint256 constant WAD = 1e18;
    uint256 constant PHI_INV = 618033988749894848;

    bytes32 constant FEE_CHANGE = keccak256("FEE_CHANGE");
    bytes32 constant RATE_CHANGE = keccak256("RATE_CHANGE");

    function setUp() public {
        coherence = new PhiCoherence(admin);

        // Register contracts at each level
        vm.startPrank(admin);
        coherence.registerContract(tokenContract, 0);
        coherence.registerContract(stakingContract, 1);
        coherence.registerContract(fusionContract, 2);
        coherence.registerContract(reputationContract, 3);
        vm.stopPrank();
    }

    // ====================================================================
    // 1. DEPLOYMENT
    // ====================================================================

    function test_deployment_adminRolesSet() public view {
        assertTrue(coherence.hasRole(coherence.DEFAULT_ADMIN_ROLE(), admin), "admin should have DEFAULT_ADMIN_ROLE");
        assertTrue(coherence.hasRole(coherence.ADMIN_ROLE(), admin), "admin should have ADMIN_ROLE");
    }

    function test_deployment_revertsOnZeroAddress() public {
        vm.expectRevert(PhiCoherence.ZeroAddress.selector);
        new PhiCoherence(address(0));
    }

    // ====================================================================
    // 2-3. REGISTER CONTRACT — success at each level + revert level > 3
    // ====================================================================

    function test_registerContract_allLevels() public view {
        // Verify all 4 contracts registered in setUp
        assertTrue(coherence.registeredContracts(tokenContract), "token should be registered");
        assertTrue(coherence.registeredContracts(stakingContract), "staking should be registered");
        assertTrue(coherence.registeredContracts(fusionContract), "fusion should be registered");
        assertTrue(coherence.registeredContracts(reputationContract), "reputation should be registered");

        assertEq(coherence.contractLevel(tokenContract), 0);
        assertEq(coherence.contractLevel(stakingContract), 1);
        assertEq(coherence.contractLevel(fusionContract), 2);
        assertEq(coherence.contractLevel(reputationContract), 3);
    }

    function test_registerContract_revertsInvalidLevel() public {
        address newContract = makeAddr("newContract");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PhiCoherence.InvalidLevel.selector, 4));
        coherence.registerContract(newContract, 4);
    }

    // ====================================================================
    // 4. REGISTER CONTRACT — revert without admin role
    // ====================================================================

    function test_registerContract_revertsWithoutAdminRole() public {
        address newContract = makeAddr("newContract");
        vm.prank(alice);
        vm.expectRevert(); // AccessControl revert
        coherence.registerContract(newContract, 0);
    }

    function test_registerContract_revertsAlreadyRegistered() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PhiCoherence.AlreadyRegistered.selector, tokenContract));
        coherence.registerContract(tokenContract, 0);
    }

    // ====================================================================
    // 5-6. PROPAGATE — success + revert unregistered
    // ====================================================================

    function test_propagate_success() public {
        vm.prank(tokenContract);
        coherence.propagate(WAD, FEE_CHANGE);

        assertEq(coherence.totalCascades(), 1, "totalCascades should be 1");
        assertEq(coherence.cascadeLogHead(), 1, "head should advance to 1");

        PhiCoherence.CascadeEvent memory evt = coherence.cascadeLog(0);
        assertEq(evt.source, tokenContract);
        assertEq(evt.magnitude, WAD);
        assertEq(evt.sourceLevel, 0);
        assertEq(evt.eventType, FEE_CHANGE);
        // dampedMagnitude = WAD * PHI_INV / WAD = PHI_INV
        assertEq(evt.dampedMagnitude, PhiMath.wadMul(WAD, PHI_INV));
    }

    function test_propagate_revertsUnregistered() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PhiCoherence.NotRegistered.selector, alice));
        coherence.propagate(WAD, FEE_CHANGE);
    }

    function test_propagate_revertsZeroMagnitude() public {
        vm.prank(tokenContract);
        vm.expectRevert(PhiCoherence.ZeroMagnitude.selector);
        coherence.propagate(0, FEE_CHANGE);
    }

    // ====================================================================
    // 7-10. GET DAMPED EFFECT — same level, 1/2/3 apart
    // ====================================================================

    function test_getDampedEffect_sameLevel() public {
        vm.prank(tokenContract);
        coherence.propagate(WAD, FEE_CHANGE);

        // tokenContract is level 0, query from tokenContract (level 0) => dist=0 => full magnitude
        uint256 effect = coherence.getDampedEffect(tokenContract, 0);
        assertEq(effect, WAD, "same level should return full magnitude");
    }

    function test_getDampedEffect_oneLevelApart() public {
        vm.prank(tokenContract);
        coherence.propagate(WAD, FEE_CHANGE);

        // tokenContract level 0, stakingContract level 1 => dist=1 => PHI_INV
        uint256 effect = coherence.getDampedEffect(stakingContract, 0);
        assertEq(effect, PhiMath.phiInvPow(1), "1 level apart should return phi^-1");
        assertEq(effect, PHI_INV, "phi^-1 should equal PHI_INV constant");
    }

    function test_getDampedEffect_twoLevelsApart() public {
        vm.prank(tokenContract);
        coherence.propagate(WAD, FEE_CHANGE);

        // tokenContract level 0, fusionContract level 2 => dist=2 => phi^-2
        uint256 effect = coherence.getDampedEffect(fusionContract, 0);
        uint256 expected = PhiMath.phiInvPow(2);
        assertEq(effect, expected, "2 levels apart should return phi^-2");
        // phi^-2 ~= 0.382e18
        assertApproxEqAbs(effect, 381966011250105152, 1e12, "phi^-2 ~ 0.382");
    }

    function test_getDampedEffect_threeLevelsApart() public {
        vm.prank(tokenContract);
        coherence.propagate(WAD, FEE_CHANGE);

        // tokenContract level 0, reputationContract level 3 => dist=3 => phi^-3
        uint256 effect = coherence.getDampedEffect(reputationContract, 0);
        uint256 expected = PhiMath.phiInvPow(3);
        assertEq(effect, expected, "3 levels apart should return phi^-3");
        // phi^-3 ~= 0.236e18
        assertApproxEqAbs(effect, 236067977499789696, 1e12, "phi^-3 ~ 0.236");
    }

    // ====================================================================
    // 11. TOTAL CASCADE EFFECT < phi^2 * magnitude
    // ====================================================================

    function test_getTotalCascadeEffect_boundedByPhiSquared() public {
        vm.prank(tokenContract);
        coherence.propagate(WAD, FEE_CHANGE);

        uint256 total = coherence.getTotalCascadeEffect(0);
        uint256 phiSquaredBound = PhiMath.PHI_SQUARED;

        assertTrue(total < phiSquaredBound, "total cascade should be < phi^2 * magnitude");
        // For level-0 source: sum = 1 + phi^-1 + phi^-2 + phi^-3 ~ 2.236
        assertApproxEqAbs(total, 2_236067977499789696, 1e12, "sum ~ 2.236 for level-0 source");
    }

    // ====================================================================
    // 12. RING BUFFER — wraps around after 1000 entries
    // ====================================================================

    function test_ringBuffer_wrapsAfter1000() public {
        // Fill 1001 entries to trigger wrap
        bytes32 evtType = keccak256("WRAP_TEST");
        for (uint256 i = 0; i < 1001; i++) {
            vm.prank(tokenContract);
            coherence.propagate(WAD, evtType);
        }

        assertEq(coherence.totalCascades(), 1001, "totalCascades should be 1001");
        // head should wrap: 1001 % 1000 = 1
        assertEq(coherence.cascadeLogHead(), 1, "head should wrap to slot 1");

        // Event at index 0 has been overwritten — should revert
        vm.expectRevert(abi.encodeWithSelector(PhiCoherence.EventIndexOutOfBounds.selector, 0, 1001));
        coherence.cascadeLog(0);

        // Event at index 1 (oldest surviving) should still be accessible
        PhiCoherence.CascadeEvent memory evt = coherence.cascadeLog(1);
        assertEq(evt.source, tokenContract);
    }

    // ====================================================================
    // 13. GET RECENT CASCADES — correct count and order
    // ====================================================================

    function test_getRecentCascades_returnsCorrectOrder() public {
        // Propagate 3 events from different contracts
        vm.prank(tokenContract);
        coherence.propagate(1 * WAD, FEE_CHANGE);

        vm.prank(stakingContract);
        coherence.propagate(2 * WAD, RATE_CHANGE);

        vm.prank(fusionContract);
        coherence.propagate(3 * WAD, FEE_CHANGE);

        PhiCoherence.CascadeEvent[] memory recent = coherence.getRecentCascades(3);
        assertEq(recent.length, 3, "should return 3 events");

        // Most recent first
        assertEq(recent[0].magnitude, 3 * WAD, "first should be most recent (3 WAD)");
        assertEq(recent[1].magnitude, 2 * WAD, "second should be 2 WAD");
        assertEq(recent[2].magnitude, 1 * WAD, "third should be oldest (1 WAD)");
    }

    function test_getRecentCascades_capsAtTotal() public {
        vm.prank(tokenContract);
        coherence.propagate(WAD, FEE_CHANGE);

        // Request more than available
        PhiCoherence.CascadeEvent[] memory recent = coherence.getRecentCascades(100);
        assertEq(recent.length, 1, "should cap at totalCascades");
    }

    // ====================================================================
    // 14. MULTIPLE CONTRACTS AT SAME LEVEL
    // ====================================================================

    function test_multipleContractsAtSameLevel() public {
        address staking2 = makeAddr("staking2");
        address staking3 = makeAddr("staking3");

        vm.startPrank(admin);
        coherence.registerContract(staking2, 1);
        coherence.registerContract(staking3, 1);
        vm.stopPrank();

        assertEq(coherence.getLevelContractCount(1), 3, "level 1 should have 3 contracts");

        address[] memory level1 = coherence.getContractsAtLevel(1);
        assertEq(level1[0], stakingContract);
        assertEq(level1[1], staking2);
        assertEq(level1[2], staking3);
    }

    // ====================================================================
    // 15. CASCADE COUNT INCREMENTS CORRECTLY
    // ====================================================================

    function test_cascadeCount_incrementsCorrectly() public {
        assertEq(coherence.getCascadeCount(), 0, "initial count should be 0");

        vm.prank(tokenContract);
        coherence.propagate(WAD, FEE_CHANGE);
        assertEq(coherence.getCascadeCount(), 1, "count after first propagate");

        vm.prank(stakingContract);
        coherence.propagate(WAD, RATE_CHANGE);
        assertEq(coherence.getCascadeCount(), 2, "count after second propagate");

        vm.prank(fusionContract);
        coherence.propagate(WAD, FEE_CHANGE);
        assertEq(coherence.getCascadeCount(), 3, "count after third propagate");
    }
}
