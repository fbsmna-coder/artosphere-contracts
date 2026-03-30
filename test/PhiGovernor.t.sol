// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PhiGovernor} from "../src/PhiGovernor.sol";
import {PhiMath} from "../src/PhiMath.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

// ---------------------------------------------------------------------------
// Mock ERC20Votes token for testing (PhiCoin is UUPS, so we use a simple mock)
// ---------------------------------------------------------------------------
contract MockPhiVotes is ERC20, ERC20Permit, ERC20Votes {
    constructor(address holder, uint256 amount)
        ERC20("PhiCoin", "PHI")
        ERC20Permit("PhiCoin")
    {
        _mint(holder, amount);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}

// ---------------------------------------------------------------------------
// Dummy target contract for proposal execution
// ---------------------------------------------------------------------------
contract DummyTarget {
    uint256 public value;

    function setValue(uint256 v) external {
        value = v;
    }
}

// ---------------------------------------------------------------------------
// PhiGovernor Test Suite
// ---------------------------------------------------------------------------
contract PhiGovernorTest is Test {
    // Actors
    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob   = makeAddr("bob");
    address public carol = makeAddr("carol");

    uint256 public constant MAX_SUPPLY = 1_618_033_988 * 1e18;

    MockPhiVotes public token;
    TimelockController public timelock;
    PhiGovernor public governor;
    DummyTarget public target;

    // ---------------------------------------------------------------
    // Setup
    // ---------------------------------------------------------------

    function setUp() public {
        vm.startPrank(admin);

        // Deploy token — give most to alice (proposer/voter), some to bob/carol
        token = new MockPhiVotes(admin, MAX_SUPPLY);

        // Distribute tokens
        token.transfer(alice, MAX_SUPPLY * 50 / 100); // 50%
        token.transfer(bob,   MAX_SUPPLY * 30 / 100); // 30%
        token.transfer(carol, MAX_SUPPLY * 20 / 100); // 20%

        // Timelock: delay = F(8) = 21 blocks ≈ 21 seconds
        // OZ TimelockController takes minDelay in seconds
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0); // anyone can execute
        timelock = new TimelockController(21, proposers, executors, admin);

        // Deploy governor
        governor = new PhiGovernor(IVotes(address(token)), timelock);

        // Grant governor the PROPOSER_ROLE on timelock
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));

        vm.stopPrank();

        // Delegates must self-delegate to activate voting power
        vm.prank(alice);
        token.delegate(alice);
        vm.prank(bob);
        token.delegate(bob);
        vm.prank(carol);
        token.delegate(carol);

        // Deploy dummy target for proposals
        target = new DummyTarget();
        // Transfer ownership of target to timelock so governor can execute
        // (DummyTarget has no access control, so anyone can call setValue)

        // Mine one block so delegation checkpoints are valid
        vm.roll(block.number + 1);
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    function _proposeSetValue(uint256 val, string memory desc)
        internal
        returns (uint256 proposalId)
    {
        address[] memory targets = new address[](1);
        targets[0] = address(target);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(DummyTarget.setValue, (val));

        proposalId = governor.propose(targets, values, calldatas, desc);
    }

    function _queueAndExecute(uint256 val, string memory desc) internal {
        address[] memory targets = new address[](1);
        targets[0] = address(target);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(DummyTarget.setValue, (val));

        bytes32 descHash = keccak256(bytes(desc));

        governor.queue(targets, values, calldatas, descHash);

        // Warp past timelock delay
        vm.warp(block.timestamp + 22);

        governor.execute(targets, values, calldatas, descHash);
    }

    // ---------------------------------------------------------------
    // Test: Constants & Configuration
    // ---------------------------------------------------------------

    function test_votingPeriod() public view {
        assertEq(governor.votingPeriod(), 233, "Voting period should be F(13)=233");
    }

    function test_votingDelay() public view {
        assertEq(governor.votingDelay(), 1, "Voting delay should be 1 block");
    }

    function test_proposalThreshold() public view {
        // supply / phi^8 ≈ supply * 0.02128...
        uint256 threshold = governor.proposalThreshold();
        // phi^8 ≈ 46.979, so threshold ≈ MAX_SUPPLY / 46.979 ≈ 34.4M tokens
        // Rough check: should be between 0.1% and 1% of supply
        assertGt(threshold, MAX_SUPPLY / 1000, "Threshold too low");
        assertLt(threshold, MAX_SUPPLY * 3 / 100,  "Threshold too high");
    }

    function test_quorum() public view {
        // supply / phi^4 ≈ supply * 0.1459
        uint256 q = governor.quorum(0);
        // phi^4 ≈ 6.854, so quorum ≈ MAX_SUPPLY / 6.854 ≈ 236M tokens
        // Rough check: should be between 10% and 20% of supply
        assertGt(q, MAX_SUPPLY * 10 / 100, "Quorum too low");
        assertLt(q, MAX_SUPPLY * 20 / 100, "Quorum too high");
    }

    // ---------------------------------------------------------------
    // Test: Create Proposal
    // ---------------------------------------------------------------

    function test_createProposal() public {
        // Alice has 50% of supply — well above threshold
        vm.prank(alice);
        uint256 proposalId = _proposeSetValue(42, "Set value to 42");

        assertGt(proposalId, 0, "Proposal ID should be non-zero");
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Pending));
    }

    function test_createProposal_belowThreshold_reverts() public {
        // Create a user with tokens below threshold
        address dustHolder = makeAddr("dustHolder");
        vm.prank(alice);
        token.transfer(dustHolder, 1e18); // 1 token -- way below threshold

        vm.prank(dustHolder);
        token.delegate(dustHolder);
        vm.roll(block.number + 1);

        vm.prank(dustHolder);
        vm.expectRevert();
        _proposeSetValue(99, "Should fail");
    }

    // ---------------------------------------------------------------
    // Test: Vote with phi-weighted power
    // ---------------------------------------------------------------

    function test_voteWithPhiWeighting() public {
        // Alice sets tier 2, Bob sets tier 0
        vm.prank(alice);
        governor.setLockTier(2);

        vm.prank(alice);
        uint256 proposalId = _proposeSetValue(42, "phi-weighted vote");

        // Advance past voting delay
        vm.roll(block.number + 2);

        // Alice votes FOR with tier 2 (weight * phi^2 ≈ weight * 2.618)
        vm.prank(alice);
        governor.castVote(proposalId, 1); // FOR

        (uint256 against, uint256 forVotes, uint256 abstain) = governor.proposalVotes(proposalId);

        uint256 aliceBalance = token.balanceOf(alice);
        uint256 expectedWeighted = PhiMath.wadMul(aliceBalance, PhiMath.phiPow(2));

        assertEq(forVotes, expectedWeighted, "Votes should be phi^2 weighted");
        assertEq(against, 0);
        assertEq(abstain, 0);
    }

    function test_voteNoTier_noMultiplier() public {
        // Bob votes with tier 0 (default — no multiplier)
        vm.prank(alice);
        uint256 proposalId = _proposeSetValue(10, "no tier vote");

        vm.roll(block.number + 2);

        vm.prank(bob);
        governor.castVote(proposalId, 1); // FOR

        (, uint256 forVotes,) = governor.proposalVotes(proposalId);
        uint256 bobBalance = token.balanceOf(bob);
        assertEq(forVotes, bobBalance, "Tier 0 should have 1x weight");
    }

    function test_setLockTier_exceedsMax_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        governor.setLockTier(6); // MAX_LOCK_TIER = 5
    }

    function test_doubleVote_reverts() public {
        vm.prank(alice);
        uint256 proposalId = _proposeSetValue(1, "double vote");
        vm.roll(block.number + 2);

        vm.prank(alice);
        governor.castVote(proposalId, 1);

        vm.prank(alice);
        vm.expectRevert();
        governor.castVote(proposalId, 1);
    }

    // ---------------------------------------------------------------
    // Test: phi-Supermajority (61.8%) requirement
    // ---------------------------------------------------------------

    function test_supermajority_passes_at_62percent() public {
        // Setup: We need forVotes/(forVotes+againstVotes) > 61.8%
        // Alice (50%) votes FOR, Carol (20%) votes AGAINST
        // 50/(50+20) = 71.4% > 61.8% => passes

        vm.prank(alice);
        uint256 proposalId = _proposeSetValue(100, "supermajority pass");
        vm.roll(block.number + 2);

        vm.prank(alice);
        governor.castVote(proposalId, 1); // FOR  — 50%

        vm.prank(carol);
        governor.castVote(proposalId, 0); // AGAINST — 20%

        // Advance past voting period (233 blocks)
        vm.roll(block.number + 234);

        // Should be Succeeded (quorum met: 50% > 14.6%; supermajority: 71.4% > 61.8%)
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));
    }

    function test_supermajority_fails_at_60percent() public {
        // We need a scenario where forVotes/(forVotes+againstVotes) ≈ 60% < 61.8%
        // Alice=50%, Bob=30%, Carol=20%
        // If Alice(50%) FOR, Bob(30%) AGAINST, Carol abstains:
        //   50/(50+30) = 62.5% — still passes, too close
        // Let's use phi-weighting to create the right ratio.
        // Bob sets tier 1 (phi^1 ≈ 1.618), so his effective = 30% * 1.618 = 48.5%
        // Alice FOR = 50%, Bob AGAINST = 48.5%  =>  50/(50+48.5) = 50.76% < 61.8% => FAILS

        vm.prank(bob);
        governor.setLockTier(1); // phi^1 multiplier

        vm.prank(alice);
        uint256 proposalId = _proposeSetValue(200, "supermajority fail");
        vm.roll(block.number + 2);

        vm.prank(alice);
        governor.castVote(proposalId, 1); // FOR

        vm.prank(bob);
        governor.castVote(proposalId, 0); // AGAINST (phi-weighted)

        // Bob abstain to push quorum
        vm.prank(carol);
        governor.castVote(proposalId, 2); // ABSTAIN (helps quorum)

        vm.roll(block.number + 234);

        // Should be Defeated: ~50.7% < 61.8%
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));
    }

    // ---------------------------------------------------------------
    // Test: Quorum check
    // ---------------------------------------------------------------

    function test_quorumNotReached_defeated() public {
        // Only Carol (20%) votes — quorum is ~14.6%, so 20% should pass quorum.
        // But let's create a scenario with a small voter.
        // Give dustHolder just 5% of supply — below 14.6% quorum
        address smallVoter = makeAddr("smallVoter");
        uint256 smallAmount = MAX_SUPPLY * 5 / 100;

        vm.prank(alice);
        token.transfer(smallVoter, smallAmount);

        vm.prank(smallVoter);
        token.delegate(smallVoter);
        vm.roll(block.number + 1);

        // SmallVoter proposes (needs enough tokens — check threshold)
        // Threshold ≈ 0.2% of supply ≈ 3.2M tokens. 5% = 80.9M > threshold. OK.
        vm.prank(smallVoter);
        uint256 proposalId = _proposeSetValue(300, "quorum fail");
        vm.roll(block.number + 2);

        // Only smallVoter votes FOR (5% < 14.6% quorum)
        vm.prank(smallVoter);
        governor.castVote(proposalId, 1);

        vm.roll(block.number + 234);

        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));
    }

    function test_quorumReached_withAbstain() public {
        // Quorum counts forVotes + abstainVotes
        // Alice(50%) abstains, Carol(20%) votes FOR => quorum = 70% > 14.6%
        // Supermajority: 20%/(20%+0%) = 100% > 61.8% => passes
        vm.prank(alice);
        uint256 proposalId = _proposeSetValue(400, "quorum with abstain");
        vm.roll(block.number + 2);

        vm.prank(alice);
        governor.castVote(proposalId, 2); // ABSTAIN

        vm.prank(carol);
        governor.castVote(proposalId, 1); // FOR

        vm.roll(block.number + 234);

        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));
    }

    // ---------------------------------------------------------------
    // Test: Execute after timelock delay
    // ---------------------------------------------------------------

    function test_executeAfterDelay() public {
        string memory desc = "execute after delay";

        vm.prank(alice);
        uint256 proposalId = _proposeSetValue(42, desc);
        vm.roll(block.number + 2);

        // Alice and Bob vote FOR (80% of supply)
        vm.prank(alice);
        governor.castVote(proposalId, 1);
        vm.prank(bob);
        governor.castVote(proposalId, 1);

        // End voting period
        vm.roll(block.number + 234);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));

        // Queue and execute
        _queueAndExecute(42, desc);

        assertEq(target.value(), 42, "Target value should be 42 after execution");
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed));
    }

    function test_executeBeforeDelay_reverts() public {
        string memory desc = "premature execution";

        vm.prank(alice);
        _proposeSetValue(99, desc);
        vm.roll(block.number + 2);

        // Pre-compute proposalId to avoid consuming vm.prank on hashProposal
        uint256 proposalId = governor.hashProposal(
            _targets(address(target)),
            _values(0),
            _calldatas(abi.encodeCall(DummyTarget.setValue, (99))),
            keccak256(bytes(desc))
        );

        vm.prank(alice);
        governor.castVote(proposalId, 1);
        vm.prank(bob);
        governor.castVote(proposalId, 1);

        vm.roll(block.number + 234);

        // Queue
        governor.queue(
            _targets(address(target)),
            _values(0),
            _calldatas(abi.encodeCall(DummyTarget.setValue, (99))),
            keccak256(bytes(desc))
        );

        // Try to execute immediately (before timelock delay)
        vm.expectRevert();
        governor.execute(
            _targets(address(target)),
            _values(0),
            _calldatas(abi.encodeCall(DummyTarget.setValue, (99))),
            keccak256(bytes(desc))
        );
    }

    // ---------------------------------------------------------------
    // Test: Lock tier events
    // ---------------------------------------------------------------

    function test_lockTierEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit PhiGovernor.LockTierSet(alice, 3);
        governor.setLockTier(3);

        assertEq(governor.lockTier(alice), 3);
    }

    // ---------------------------------------------------------------
    // Array helpers (avoid stack-too-deep)
    // ---------------------------------------------------------------

    function _targets(address t) internal pure returns (address[] memory) {
        address[] memory arr = new address[](1);
        arr[0] = t;
        return arr;
    }

    function _values(uint256 v) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](1);
        arr[0] = v;
        return arr;
    }

    function _calldatas(bytes memory cd) internal pure returns (bytes[] memory) {
        bytes[] memory arr = new bytes[](1);
        arr[0] = cd;
        return arr;
    }
}
