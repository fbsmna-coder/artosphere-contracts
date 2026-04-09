// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PhiGovernor, IPhiStaking} from "../src/PhiGovernor.sol";
import {PhiMath} from "../src/PhiMath.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

// Mock ERC20Votes token for testing
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

// Mock staking contract that returns configurable tiers
contract MockPhiStaking {
    struct Stake {
        uint256 amount;
        uint256 tier;
        uint256 startTimestamp;
        uint256 lockEnd;
        uint256 rewardDebt;
        uint256 earned;
    }

    mapping(address => Stake) private _stakes;

    function setStake(address user, uint256 amount, uint256 tier) external {
        _stakes[user] = Stake({
            amount: amount,
            tier: tier,
            startTimestamp: block.timestamp,
            lockEnd: block.timestamp + 5 days,
            rewardDebt: 0,
            earned: 0
        });
    }

    function getStake(address user) external view returns (Stake memory) {
        return _stakes[user];
    }
}

// Dummy target contract for proposal execution
contract DummyTarget {
    uint256 public value;

    function setValue(uint256 v) external {
        value = v;
    }
}

contract PhiGovernorTest is Test {
    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob   = makeAddr("bob");
    address public carol = makeAddr("carol");

    uint256 public constant MAX_SUPPLY = 987_000_000 * 1e18;

    MockPhiVotes public token;
    TimelockController public timelock;
    PhiGovernor public governor;
    DummyTarget public target;
    MockPhiStaking public mockStaking;

    function setUp() public {
        vm.startPrank(admin);

        token = new MockPhiVotes(admin, MAX_SUPPLY);

        token.transfer(alice, MAX_SUPPLY * 50 / 100);
        token.transfer(bob,   MAX_SUPPLY * 30 / 100);
        token.transfer(carol, MAX_SUPPLY * 20 / 100);

        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(21, proposers, executors, admin);

        governor = new PhiGovernor(IVotes(address(token)), timelock);

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));

        // Deploy mock staking
        mockStaking = new MockPhiStaking();

        vm.stopPrank();

        // Delegates must self-delegate to activate voting power
        vm.prank(alice);
        token.delegate(alice);
        vm.prank(bob);
        token.delegate(bob);
        vm.prank(carol);
        token.delegate(carol);

        target = new DummyTarget();

        vm.roll(block.number + 1);
    }

    // Helpers
    function _proposeSetValue(uint256 val, string memory desc)
        internal returns (uint256 proposalId)
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
        vm.warp(block.timestamp + 22);
        governor.execute(targets, values, calldatas, descHash);
    }

    // Tests: Constants & Configuration
    function test_votingPeriod() public view {
        assertEq(governor.votingPeriod(), 233);
    }

    function test_votingDelay() public view {
        assertEq(governor.votingDelay(), 1);
    }

    function test_proposalThreshold() public view {
        uint256 threshold = governor.proposalThreshold();
        assertGt(threshold, MAX_SUPPLY / 1000);
        assertLt(threshold, MAX_SUPPLY * 3 / 100);
    }

    function test_quorum() public view {
        uint256 q = governor.quorum(0);
        assertGt(q, MAX_SUPPLY * 10 / 100);
        assertLt(q, MAX_SUPPLY * 20 / 100);
    }

    // Tests: Create Proposal
    function test_createProposal() public {
        vm.prank(alice);
        uint256 proposalId = _proposeSetValue(42, "Set value to 42");
        assertGt(proposalId, 0);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Pending));
    }

    function test_createProposal_belowThreshold_reverts() public {
        address dustHolder = makeAddr("dustHolder");
        vm.prank(alice);
        token.transfer(dustHolder, 1e18);
        vm.prank(dustHolder);
        token.delegate(dustHolder);
        vm.roll(block.number + 1);
        vm.prank(dustHolder);
        vm.expectRevert();
        _proposeSetValue(99, "Should fail");
    }

    // Tests: Vote without staking contract (all tier 0, 1x weight)
    function test_voteNoStakingContract_noMultiplier() public {
        vm.prank(alice);
        uint256 proposalId = _proposeSetValue(10, "no tier vote");
        vm.roll(block.number + 2);
        vm.prank(bob);
        governor.castVote(proposalId, 1);
        (, uint256 forVotes,) = governor.proposalVotes(proposalId);
        uint256 bobBalance = token.balanceOf(bob);
        assertEq(forVotes, bobBalance, "Without staking contract, tier 0 = 1x weight");
    }

    // Tests: Vote with mock staking contract (phi-weighted)
    function test_voteWithPhiWeighting() public {
        // Set staking contract on governor (via timelock/executor)
        // The executor is the timelock. We prank as timelock.
        vm.prank(address(timelock));
        governor.setStakingContract(address(mockStaking));

        // Alice has tier 2 stake in mock
        mockStaking.setStake(alice, 1000e18, 2);

        vm.prank(alice);
        uint256 proposalId = _proposeSetValue(42, "phi-weighted vote");
        vm.roll(block.number + 2);

        vm.prank(alice);
        governor.castVote(proposalId, 1);

        (uint256 against, uint256 forVotes, uint256 abstain) = governor.proposalVotes(proposalId);

        uint256 aliceBalance = token.balanceOf(alice);
        uint256 expectedWeighted = PhiMath.wadMul(aliceBalance, PhiMath.phiPow(2));

        assertEq(forVotes, expectedWeighted, "Votes should be phi^2 weighted");
        assertEq(against, 0);
        assertEq(abstain, 0);
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

    // Tests: phi-Supermajority (61.8%) requirement
    function test_supermajority_passes_at_62percent() public {
        vm.prank(alice);
        uint256 proposalId = _proposeSetValue(100, "supermajority pass");
        vm.roll(block.number + 2);
        vm.prank(alice);
        governor.castVote(proposalId, 1); // FOR 50%
        vm.prank(carol);
        governor.castVote(proposalId, 0); // AGAINST 20%
        vm.roll(block.number + 234);
        // 50/(50+20) = 71.4% > 61.8%
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));
    }

    function test_supermajority_fails_at_60percent() public {
        // Use mock staking to give Bob phi^1 multiplier
        vm.prank(address(timelock));
        governor.setStakingContract(address(mockStaking));
        mockStaking.setStake(bob, 1000e18, 1);

        vm.prank(alice);
        uint256 proposalId = _proposeSetValue(200, "supermajority fail");
        vm.roll(block.number + 2);

        vm.prank(alice);
        governor.castVote(proposalId, 1); // FOR
        vm.prank(bob);
        governor.castVote(proposalId, 0); // AGAINST (phi-weighted)
        vm.prank(carol);
        governor.castVote(proposalId, 2); // ABSTAIN

        vm.roll(block.number + 234);
        // Bob's against = 30% * 1.618 = 48.5%. Alice for = 50%.
        // 50/(50+48.5) = 50.76% < 61.8% => FAILS
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));
    }

    // Tests: Quorum check
    function test_quorumNotReached_defeated() public {
        address smallVoter = makeAddr("smallVoter");
        uint256 smallAmount = MAX_SUPPLY * 5 / 100;
        vm.prank(alice);
        token.transfer(smallVoter, smallAmount);
        vm.prank(smallVoter);
        token.delegate(smallVoter);
        vm.roll(block.number + 1);

        vm.prank(smallVoter);
        uint256 proposalId = _proposeSetValue(300, "quorum fail");
        vm.roll(block.number + 2);
        vm.prank(smallVoter);
        governor.castVote(proposalId, 1);
        vm.roll(block.number + 234);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));
    }

    function test_quorumReached_withAbstain() public {
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

    // Tests: Execute after timelock delay
    function test_executeAfterDelay() public {
        string memory desc = "execute after delay";
        vm.prank(alice);
        uint256 proposalId = _proposeSetValue(42, desc);
        vm.roll(block.number + 2);
        vm.prank(alice);
        governor.castVote(proposalId, 1);
        vm.prank(bob);
        governor.castVote(proposalId, 1);
        vm.roll(block.number + 234);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));
        _queueAndExecute(42, desc);
        assertEq(target.value(), 42);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed));
    }

    function test_executeBeforeDelay_reverts() public {
        string memory desc = "premature execution";
        vm.prank(alice);
        _proposeSetValue(99, desc);
        vm.roll(block.number + 2);

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

        governor.queue(
            _targets(address(target)),
            _values(0),
            _calldatas(abi.encodeCall(DummyTarget.setValue, (99))),
            keccak256(bytes(desc))
        );

        vm.expectRevert();
        governor.execute(
            _targets(address(target)),
            _values(0),
            _calldatas(abi.encodeCall(DummyTarget.setValue, (99))),
            keccak256(bytes(desc))
        );
    }

    // Tests: Staking contract management
    function test_setStakingContract() public {
        vm.prank(address(timelock));
        vm.expectEmit(true, false, false, true);
        emit PhiGovernor.StakingContractSet(address(mockStaking));
        governor.setStakingContract(address(mockStaking));
        assertEq(address(governor.stakingContract()), address(mockStaking));
    }

    function test_setStakingContract_notExecutor_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        governor.setStakingContract(address(mockStaking));
    }

    // Array helpers
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
