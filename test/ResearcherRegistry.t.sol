// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ResearcherRegistry.sol";

contract ResearcherRegistryTest is Test {
    ResearcherRegistry public registry;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public attestor = makeAddr("attestor");
    address public stakingContract = makeAddr("staking");

    string constant ALICE_ORCID = "0000-0002-1234-5678";
    string constant BOB_ORCID = "0000-0003-9876-5432";

    function setUp() public {
        registry = new ResearcherRegistry(admin);

        vm.startPrank(admin);
        registry.grantRole(registry.ATTESTOR_ROLE(), attestor);
        registry.grantRole(registry.STAKING_ROLE(), stakingContract);
        vm.stopPrank();
    }

    function test_Register() public {
        vm.prank(alice);
        registry.register(ALICE_ORCID, "Dr. Alice", "CERN");

        assertTrue(registry.isRegistered(alice));
        assertEq(registry.totalResearchers(), 1);

        ResearcherRegistry.Researcher memory r = registry.getResearcher(alice);
        assertEq(r.orcid, ALICE_ORCID);
        assertEq(r.name, "Dr. Alice");
        assertEq(r.institution, "CERN");
        assertFalse(r.orcidVerified);
        assertEq(r.correctPredictions, 0);
    }

    function test_RegisterMultiple() public {
        vm.prank(alice);
        registry.register(ALICE_ORCID, "Alice", "MIT");

        vm.prank(bob);
        registry.register(BOB_ORCID, "Bob", "Stanford");

        assertEq(registry.totalResearchers(), 2);
    }

    function test_RevertDuplicateRegistration() public {
        vm.prank(alice);
        registry.register(ALICE_ORCID, "Alice", "");

        vm.expectRevert(abi.encodeWithSelector(ResearcherRegistry.AlreadyRegistered.selector));
        vm.prank(alice);
        registry.register("0000-0002-0000-0000", "Alice2", "");
    }

    function test_RevertDuplicateOrcid() public {
        vm.prank(alice);
        registry.register(ALICE_ORCID, "Alice", "");

        vm.expectRevert(abi.encodeWithSelector(ResearcherRegistry.OrcidAlreadyClaimed.selector, ALICE_ORCID));
        vm.prank(bob);
        registry.register(ALICE_ORCID, "Bob", "");
    }

    function test_RevertInvalidOrcid() public {
        vm.expectRevert(abi.encodeWithSelector(ResearcherRegistry.InvalidOrcid.selector));
        vm.prank(alice);
        registry.register("1234", "Alice", ""); // Too short
    }

    function test_RevertEmptyOrcid() public {
        vm.expectRevert(abi.encodeWithSelector(ResearcherRegistry.EmptyOrcid.selector));
        vm.prank(alice);
        registry.register("", "Alice", "");
    }

    function test_VerifyOrcid() public {
        vm.prank(alice);
        registry.register(ALICE_ORCID, "Alice", "");

        assertFalse(registry.getResearcher(alice).orcidVerified);

        vm.prank(attestor);
        registry.verifyOrcid(alice);

        assertTrue(registry.getResearcher(alice).orcidVerified);
    }

    function test_UpdateProfile() public {
        vm.prank(alice);
        registry.register(ALICE_ORCID, "Alice", "MIT");

        vm.prank(alice);
        registry.updateProfile("Dr. Alice Smith", "CERN");

        ResearcherRegistry.Researcher memory r = registry.getResearcher(alice);
        assertEq(r.name, "Dr. Alice Smith");
        assertEq(r.institution, "CERN");
    }

    function test_ReputationAndTiers() public {
        vm.prank(alice);
        registry.register(ALICE_ORCID, "Alice", "");

        // Start: Novice (tier 0)
        assertEq(registry.getTier(alice), 0);

        // 2 correct predictions → Scholar (tier 1)
        vm.startPrank(stakingContract);
        registry.recordPrediction(alice, true, 1000e18, 200e18);
        registry.recordPrediction(alice, true, 1000e18, 200e18);
        vm.stopPrank();

        assertEq(registry.getTier(alice), 1); // Scholar
        assertEq(registry.getResearcher(alice).correctPredictions, 2);

        // 3 more correct → Expert (tier 2, needs 5)
        vm.startPrank(stakingContract);
        registry.recordPrediction(alice, true, 1000e18, 200e18);
        registry.recordPrediction(alice, true, 1000e18, 200e18);
        registry.recordPrediction(alice, true, 1000e18, 200e18);
        vm.stopPrank();

        assertEq(registry.getTier(alice), 2); // Expert

        // 8 more correct → Oracle (tier 3, needs 13)
        vm.startPrank(stakingContract);
        for (uint i = 0; i < 8; i++) {
            registry.recordPrediction(alice, true, 1000e18, 200e18);
        }
        vm.stopPrank();

        assertEq(registry.getTier(alice), 3); // Oracle!
    }

    function test_WinRate() public {
        vm.prank(alice);
        registry.register(ALICE_ORCID, "Alice", "");

        vm.startPrank(stakingContract);
        registry.recordPrediction(alice, true, 1000e18, 200e18);  // win
        registry.recordPrediction(alice, false, 1000e18, 0);       // loss
        registry.recordPrediction(alice, true, 1000e18, 200e18);  // win
        vm.stopPrank();

        // 2 wins out of 3 = 66.66%
        uint256 rate = registry.winRate(alice);
        assertEq(rate, 6666); // 66.66% in basis points
    }

    function test_OrcidReverseLookup() public {
        vm.prank(alice);
        registry.register(ALICE_ORCID, "Alice", "");

        assertEq(registry.getAddressByOrcid(ALICE_ORCID), alice);
    }

    function test_TierNames() public {
        vm.prank(alice);
        registry.register(ALICE_ORCID, "Alice", "");

        assertEq(registry.getTierName(alice), "Novice");
    }

    function test_UnregisteredSkipped() public {
        // recordPrediction for unregistered address should not revert
        vm.prank(stakingContract);
        registry.recordPrediction(bob, true, 1000e18, 200e18);

        // Bob is still not registered
        assertFalse(registry.isRegistered(bob));
    }
}
