// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/PhiCoin.sol";
import "../src/ArtosphereDiscovery.sol";
import "../src/DiscoveryOracle.sol";
import "../src/DiscoveryStaking.sol";

contract DiscoveryOracleTest is Test {
    PhiCoin public phiCoin;
    ERC1967Proxy public coinProxy;

    ArtosphereDiscovery public discovery;
    DiscoveryOracle public oracle;
    DiscoveryStaking public staking;
    ERC1967Proxy public stakingProxy;

    address public admin = makeAddr("admin");
    address public scientist = makeAddr("scientist");
    address public treasury = makeAddr("treasury");
    address public validator1 = makeAddr("validator1");
    address public validator2 = makeAddr("validator2");
    address public validator3 = makeAddr("validator3");
    address public validator4 = makeAddr("validator4");

    function setUp() public {
        // PhiCoin
        PhiCoin impl = new PhiCoin();
        coinProxy = new ERC1967Proxy(address(impl), abi.encodeWithSelector(PhiCoin.initialize.selector, admin));
        phiCoin = PhiCoin(address(coinProxy));

        // Discovery NFT
        discovery = new ArtosphereDiscovery(scientist);

        // Oracle
        oracle = new DiscoveryOracle(address(discovery), admin);

        // Staking
        DiscoveryStaking stakingImpl = new DiscoveryStaking();
        stakingProxy = new ERC1967Proxy(
            address(stakingImpl),
            abi.encodeWithSelector(
                DiscoveryStaking.initialize.selector,
                address(phiCoin), address(discovery), treasury, admin
            )
        );
        staking = DiscoveryStaking(address(stakingProxy));

        // Roles
        vm.startPrank(admin);
        staking.grantRole(staking.ORACLE_ROLE(), address(oracle));
        oracle.setStakingContract(address(staking));
        oracle.addValidator(validator1);
        oracle.addValidator(validator2);
        oracle.addValidator(validator3);
        oracle.addValidator(validator4);
        vm.stopPrank();

        bytes32 oracleRole = discovery.ORACLE_ROLE();
        vm.prank(scientist);
        discovery.grantRole(oracleRole, address(oracle));

        // Register test discovery
        vm.prank(scientist);
        discovery.registerDiscovery("Test", "phi^2=phi+1", "doi", "D", "PREDICTED", keccak256("c"), 0);
    }

    function test_Propose() public {
        vm.prank(validator1);
        oracle.propose(0, DiscoveryOracle.Outcome.CONFIRMED, "10.1038/test", "Test evidence");

        (
            DiscoveryOracle.Outcome outcome,
            DiscoveryOracle.ProposalState state,
            address proposer,
            ,
            uint256 votesFor,
            ,
            ,
        ) = oracle.getProposal(0);

        assertEq(uint8(outcome), uint8(DiscoveryOracle.Outcome.CONFIRMED));
        assertEq(uint8(state), uint8(DiscoveryOracle.ProposalState.PROPOSED));
        assertEq(proposer, validator1);
        assertEq(votesFor, 1);
    }

    function test_Vote() public {
        vm.prank(validator1);
        oracle.propose(0, DiscoveryOracle.Outcome.CONFIRMED, "10.1038/test", "Test evidence");

        vm.prank(validator2);
        oracle.vote(0, true);

        (, , , , uint256 votesFor, , , ) = oracle.getProposal(0);
        assertEq(votesFor, 2);
    }

    function test_RevertDoubleVote() public {
        vm.prank(validator1);
        oracle.propose(0, DiscoveryOracle.Outcome.CONFIRMED, "10.1038/test", "Test evidence");

        vm.expectRevert(abi.encodeWithSelector(DiscoveryOracle.AlreadyVoted.selector, validator1));
        vm.prank(validator1);
        oracle.vote(0, true);
    }

    function test_RevertCooldownNotExpired() public {
        vm.prank(validator1);
        oracle.propose(0, DiscoveryOracle.Outcome.CONFIRMED, "10.1038/test", "Test evidence");
        vm.prank(validator2);
        oracle.vote(0, true);

        // Try resolve before cooldown
        vm.expectRevert();
        oracle.resolve(0);
    }

    function test_ResolveAfterCooldown() public {
        vm.prank(validator1);
        oracle.propose(0, DiscoveryOracle.Outcome.CONFIRMED, "10.1038/test", "Test evidence");
        vm.prank(validator2);
        oracle.vote(0, true);

        vm.warp(block.timestamp + 21 days + 1);
        oracle.resolve(0);

        (, DiscoveryOracle.ProposalState state, , , , , , ) = oracle.getProposal(0);
        assertEq(uint8(state), uint8(DiscoveryOracle.ProposalState.RESOLVED));

        // Verify discovery NFT status updated
        ArtosphereDiscovery.Discovery memory d = discovery.getDiscovery(0);
        assertEq(keccak256(bytes(d.status)), keccak256("CONFIRMED"));
    }

    function test_QuorumCheck() public {
        // 4 validators, quorum = ceil(4 * 3090 / 10000) = ceil(1.236) = 2
        vm.prank(validator1);
        oracle.propose(0, DiscoveryOracle.Outcome.CONFIRMED, "10.1038/test", "Test evidence");
        // Only 1 vote (proposer) — quorum not reached

        vm.warp(block.timestamp + 21 days + 1);
        vm.expectRevert(); // QuorumNotReached
        oracle.resolve(0);

        // Add second vote
        vm.prank(validator2);
        oracle.vote(0, true);

        oracle.resolve(0); // Should succeed now
    }

    function test_Veto() public {
        vm.prank(validator1);
        oracle.propose(0, DiscoveryOracle.Outcome.CONFIRMED, "10.1038/test", "Test evidence");

        vm.prank(admin);
        oracle.veto(0);

        (, DiscoveryOracle.ProposalState state, , , , , , ) = oracle.getProposal(0);
        assertEq(uint8(state), uint8(DiscoveryOracle.ProposalState.VETOED));
    }

    function test_RevertNonValidatorPropose() public {
        address random = makeAddr("random");
        vm.expectRevert();
        vm.prank(random);
        oracle.propose(0, DiscoveryOracle.Outcome.CONFIRMED, "10.1038/test", "Test evidence");
    }

    function test_ValidatorCount() public view {
        assertEq(oracle.validatorCount(), 4);
    }

    function test_RemoveValidator() public {
        vm.prank(admin);
        oracle.removeValidator(validator4);
        assertEq(oracle.validatorCount(), 3);
        assertFalse(oracle.isValidator(validator4));
    }

    function test_RevertInvalidDiscovery() public {
        vm.expectRevert(abi.encodeWithSelector(DiscoveryOracle.InvalidDiscovery.selector, 999));
        vm.prank(validator1);
        oracle.propose(999, DiscoveryOracle.Outcome.CONFIRMED, "10.1038/test", "Test");
    }

    function test_RevertDuplicateProposal() public {
        vm.prank(validator1);
        oracle.propose(0, DiscoveryOracle.Outcome.CONFIRMED, "10.1038/test", "Test evidence");

        vm.expectRevert(abi.encodeWithSelector(DiscoveryOracle.ProposalAlreadyExists.selector, 0));
        vm.prank(validator2);
        oracle.propose(0, DiscoveryOracle.Outcome.REFUTED, "10.1038/refute", "Refutation evidence");
    }
}
