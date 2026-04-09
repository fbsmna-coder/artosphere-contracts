// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/PhiCoin.sol";
import "../src/PhiMath.sol";
import "../src/ArtosphereDiscovery.sol";
import "../src/ArtosphereConstants.sol";
import "../src/DiscoveryStaking.sol";
import "../src/DiscoveryOracle.sol";

contract DiscoveryStakingTest is Test {
    // Contracts
    PhiCoin public phiCoinImpl;
    PhiCoin public phiCoin;
    ERC1967Proxy public coinProxy;

    DiscoveryStaking public stakingImpl;
    DiscoveryStaking public staking;
    ERC1967Proxy public stakingProxy;

    ArtosphereDiscovery public discovery;
    DiscoveryOracle public oracle;

    // Actors
    address public admin = makeAddr("admin");
    address public scientist = makeAddr("scientist");
    address public treasury = makeAddr("treasury");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public validator1 = makeAddr("validator1");
    address public validator2 = makeAddr("validator2");
    address public validator3 = makeAddr("validator3");
    address public validator4 = makeAddr("validator4");

    uint256 public constant STAKE_AMOUNT = 10_000 * 1e18;
    uint256 public constant LARGE_STAKE = 100_000 * 1e18;

    function setUp() public {
        // Deploy PhiCoin (UUPS proxy)
        phiCoinImpl = new PhiCoin();
        bytes memory coinInit = abi.encodeWithSelector(PhiCoin.initialize.selector, admin);
        coinProxy = new ERC1967Proxy(address(phiCoinImpl), coinInit);
        phiCoin = PhiCoin(address(coinProxy));

        // Deploy ArtosphereDiscovery
        discovery = new ArtosphereDiscovery(scientist);

        // Deploy DiscoveryOracle
        oracle = new DiscoveryOracle(address(discovery), admin);

        // Deploy DiscoveryStaking (UUPS proxy)
        stakingImpl = new DiscoveryStaking();
        bytes memory stakingInit = abi.encodeWithSelector(
            DiscoveryStaking.initialize.selector,
            address(phiCoin),
            address(discovery),
            treasury,
            admin
        );
        stakingProxy = new ERC1967Proxy(address(stakingImpl), stakingInit);
        staking = DiscoveryStaking(address(stakingProxy));

        // Setup roles
        vm.startPrank(admin);
        // Staking needs ORACLE_ROLE to be called by oracle
        staking.grantRole(staking.ORACLE_ROLE(), address(oracle));
        // PhiCoin minting for test setup
        phiCoin.grantRole(phiCoin.MINTER_ROLE(), admin);
        vm.stopPrank();

        // Oracle: set staking contract and grant ORACLE_ROLE on discovery NFT
        vm.startPrank(admin);
        oracle.setStakingContract(address(staking));
        oracle.addValidator(validator1);
        oracle.addValidator(validator2);
        oracle.addValidator(validator3);
        oracle.addValidator(validator4);
        vm.stopPrank();

        // Grant ORACLE_ROLE on ArtosphereDiscovery to the oracle contract
        bytes32 oracleRole = discovery.ORACLE_ROLE();
        vm.prank(scientist);
        discovery.grantRole(oracleRole, address(oracle));

        // Register a test discovery
        vm.prank(scientist);
        discovery.registerDiscovery(
            "Strong Coupling from Phi",
            "alpha_s = 1/(2*phi^3)",
            "10.5281/zenodo.19464050",
            "D",
            "PREDICTED",
            keccak256("test content"),
            2 // 0.02% accuracy
        );

        // Fund test accounts
        vm.startPrank(admin);
        phiCoin.mintTo(alice, LARGE_STAKE * 10);
        phiCoin.mintTo(bob, LARGE_STAKE * 10);
        phiCoin.mintTo(charlie, LARGE_STAKE * 10);
        vm.stopPrank();

        // Approve staking contract
        vm.prank(alice);
        phiCoin.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        phiCoin.approve(address(staking), type(uint256).max);
        vm.prank(charlie);
        phiCoin.approve(address(staking), type(uint256).max);
    }

    // ========================================================================
    // STAKING TESTS
    // ========================================================================

    function test_StakeConfirm() public {
        vm.prank(alice);
        staking.stakeOnDiscovery(0, STAKE_AMOUNT, 0, 0); // CONFIRM, tier 0

        DiscoveryStaking.StakePosition memory pos = staking.getStake(0, alice);
        uint256 expectedNet = STAKE_AMOUNT - (STAKE_AMOUNT * 118 / 10000);
        assertEq(pos.amount, expectedNet);
        assertEq(pos.side, 0); // CONFIRM

        (uint256 confirmPool,,,,, ) = staking.getPool(0);
        assertEq(confirmPool, expectedNet);
    }

    function test_StakeRefute() public {
        vm.prank(bob);
        staking.stakeOnDiscovery(0, STAKE_AMOUNT, 1, 1); // REFUTE, tier 1

        DiscoveryStaking.StakePosition memory pos = staking.getStake(0, bob);
        assertEq(pos.side, 1); // REFUTE
        assertEq(pos.tier, 1);
    }

    function test_StakingFeeGoesToScientist() public {
        uint256 scientistBefore = phiCoin.balanceOf(scientist);

        vm.prank(alice);
        staking.stakeOnDiscovery(0, STAKE_AMOUNT, 0, 0);

        uint256 scientistAfter = phiCoin.balanceOf(scientist);
        uint256 expectedFee = (STAKE_AMOUNT * 118) / 10000;
        assertEq(scientistAfter - scientistBefore, expectedFee);
    }

    function test_RevertCannotHedge() public {
        vm.prank(alice);
        staking.stakeOnDiscovery(0, STAKE_AMOUNT, 0, 0); // CONFIRM

        // Alice tries to stake REFUTE on same discovery — CannotHedge fires first
        vm.expectRevert(abi.encodeWithSelector(DiscoveryStaking.CannotHedge.selector, 0));
        vm.prank(alice);
        staking.stakeOnDiscovery(0, STAKE_AMOUNT, 1, 0);
    }

    function test_RevertBelowMinimum() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DiscoveryStaking.BelowMinimumStake.selector,
                50 * 1e18,
                ArtosphereConstants.DS_MIN_STAKE
            )
        );
        vm.prank(alice);
        staking.stakeOnDiscovery(0, 50 * 1e18, 0, 0); // 50 ARTS < 100 minimum
    }

    function test_ScienceWeight() public {
        vm.prank(alice);
        staking.stakeOnDiscovery(0, STAKE_AMOUNT, 0, 0);

        vm.prank(bob);
        staking.stakeOnDiscovery(0, STAKE_AMOUNT, 1, 0);

        (,, uint256 scienceWeight,,, ) = staking.getPool(0);
        uint256 fee = (STAKE_AMOUNT * 118) / 10000;
        uint256 expectedWeight = (STAKE_AMOUNT - fee) * 2;
        assertEq(scienceWeight, expectedWeight);
    }

    // ========================================================================
    // RESOLUTION TESTS
    // ========================================================================

    function test_ResolveConfirmed() public {
        // Alice stakes CONFIRM, Bob stakes REFUTE
        vm.prank(alice);
        staking.stakeOnDiscovery(0, LARGE_STAKE, 0, 2); // CONFIRM, tier 2

        vm.prank(bob);
        staking.stakeOnDiscovery(0, LARGE_STAKE, 1, 0); // REFUTE, tier 0

        uint256 fee = (LARGE_STAKE * 118) / 10000;
        uint256 bobNet = LARGE_STAKE - fee; // Bob's losing pool

        // Oracle proposes and resolves
        vm.prank(validator1);
        oracle.propose(0, DiscoveryOracle.Outcome.CONFIRMED, "10.1038/exp", "Experiment confirmed");
        vm.prank(validator2);
        oracle.vote(0, true);

        // Wait cooldown
        vm.warp(block.timestamp + 21 days + 1);

        uint256 burnBefore = phiCoin.balanceOf(address(0xdead));
        uint256 scientistBefore = phiCoin.balanceOf(scientist);
        uint256 treasuryBefore = phiCoin.balanceOf(treasury);

        oracle.resolve(0);

        // Verify phi-cascade distribution
        uint256 burnAfter = phiCoin.balanceOf(address(0xdead));
        uint256 scientistAfter = phiCoin.balanceOf(scientist);
        uint256 treasuryAfter = phiCoin.balanceOf(treasury);

        uint256 burnCut = PhiMath.wadMul(bobNet, ArtosphereConstants.DS_BURN_WAD);
        uint256 scientistCut = PhiMath.wadMul(bobNet, ArtosphereConstants.DS_SCIENTIST_WAD);

        assertApproxEqAbs(burnAfter - burnBefore, burnCut, 1e6);
        assertApproxEqAbs(scientistAfter - scientistBefore, scientistCut, 1e6);
        assertTrue(treasuryAfter > treasuryBefore);

        // Alice claims
        vm.prank(alice);
        staking.claim(0);

        // Alice should have principal + winner reward
        // Bob gets nothing (loser)
        vm.prank(bob);
        staking.claim(0);
        // Bob's claim emits 0
    }

    function test_ResolveRefuted() public {
        vm.prank(alice);
        staking.stakeOnDiscovery(0, LARGE_STAKE, 0, 0); // CONFIRM

        vm.prank(bob);
        staking.stakeOnDiscovery(0, LARGE_STAKE, 1, 2); // REFUTE, tier 2

        // Resolve as REFUTED — Bob wins
        vm.prank(validator1);
        oracle.propose(0, DiscoveryOracle.Outcome.REFUTED, "10.1038/refute", "Experiment refuted");
        vm.prank(validator2);
        oracle.vote(0, true);
        vm.warp(block.timestamp + 21 days + 1);
        oracle.resolve(0);

        // Bob claims and gets principal + rewards
        uint256 bobBefore = phiCoin.balanceOf(bob);
        vm.prank(bob);
        staking.claim(0);
        uint256 bobAfter = phiCoin.balanceOf(bob);
        assertTrue(bobAfter > bobBefore);

        // Alice claims — gets nothing (loser)
        uint256 aliceBefore = phiCoin.balanceOf(alice);
        vm.prank(alice);
        staking.claim(0);
        assertEq(phiCoin.balanceOf(alice), aliceBefore); // No change
    }

    // ========================================================================
    // PHI-CASCADE MATH TESTS
    // ========================================================================

    function test_PhiCascadeSumsToOne() public pure {
        // Verify: DS_WINNER_WAD + DS_BURN_WAD + DS_SCIENTIST_WAD + DS_TREASURY_WAD ≈ WAD
        uint256 sum = ArtosphereConstants.DS_WINNER_WAD
            + ArtosphereConstants.DS_BURN_WAD
            + ArtosphereConstants.DS_SCIENTIST_WAD
            + ArtosphereConstants.DS_TREASURY_WAD;

        // Should be very close to 1e18 (WAD)
        // Allow 1e15 tolerance (0.1%)
        assertApproxEqAbs(sum, 1e18, 1e15);
    }

    function test_PhiCascadeBPS() public pure {
        uint256 sumBps = ArtosphereConstants.DS_WINNER_BPS
            + ArtosphereConstants.DS_BURN_BPS
            + ArtosphereConstants.DS_SCIENTIST_BPS
            + ArtosphereConstants.DS_TREASURY_BPS;

        // Should sum to ~10000 (allow ±1 for rounding)
        assertApproxEqAbs(sumBps, 10000, 1);
    }

    function test_TierMultipliers() public view {
        assertEq(staking.tierMultiplier(0), PhiMath.WAD);
        assertEq(staking.tierMultiplier(1), PhiMath.PHI);
        assertEq(staking.tierMultiplier(2), PhiMath.PHI_SQUARED);
    }

    // ========================================================================
    // SYBIL RESISTANCE TEST
    // ========================================================================

    function test_SybilHedgingUnprofitable() public {
        // Alice stakes CONFIRM, Bob (sybil) stakes REFUTE with same amount
        // Charlie provides liquidity on both sides for a realistic pool
        vm.prank(charlie);
        staking.stakeOnDiscovery(0, LARGE_STAKE, 0, 0); // CONFIRM

        vm.prank(alice);
        staking.stakeOnDiscovery(0, STAKE_AMOUNT, 0, 0); // Sybil CONFIRM

        // Register discovery 2 for sybil test — actually sybil uses different address
        // In practice, sybil would use a second address. Let's simulate:
        address sybilAddr = makeAddr("sybil");
        vm.prank(admin);
        phiCoin.mintTo(sybilAddr, LARGE_STAKE * 10);
        vm.prank(sybilAddr);
        phiCoin.approve(address(staking), type(uint256).max);

        vm.prank(sybilAddr);
        staking.stakeOnDiscovery(0, STAKE_AMOUNT, 1, 0); // Sybil REFUTE

        // Alice and sybil = same person, staked S on each side
        // Resolve CONFIRMED — alice wins, sybil loses
        vm.prank(validator1);
        oracle.propose(0, DiscoveryOracle.Outcome.CONFIRMED, "10.1038/exp", "Experiment confirmed");
        vm.prank(validator2);
        oracle.vote(0, true);
        vm.warp(block.timestamp + 21 days + 1);
        oracle.resolve(0);

        // Calculate sybil P&L
        uint256 fee = (STAKE_AMOUNT * 118) / 10000;
        uint256 invested = STAKE_AMOUNT * 2; // total put in both sides
        uint256 feePaid = fee * 2;

        // Alice (winning side) claims
        uint256 aliceBefore = phiCoin.balanceOf(alice);
        vm.prank(alice);
        staking.claim(0);
        uint256 aliceGot = phiCoin.balanceOf(alice) - aliceBefore;

        // Sybil (losing side) claims — gets 0
        vm.prank(sybilAddr);
        staking.claim(0);
        uint256 sybilGot = 0; // loser gets nothing

        // Net P&L for the sybil entity (alice + sybilAddr)
        uint256 totalReturned = aliceGot + sybilGot;
        // totalReturned should be LESS than invested (hedging is unprofitable)
        assertTrue(totalReturned < invested, "Hedging must be unprofitable");
    }

    // ========================================================================
    // EMERGENCY & EXPIRATION TESTS
    // ========================================================================

    function test_EmergencyWithdraw() public {
        vm.prank(alice);
        staking.stakeOnDiscovery(0, STAKE_AMOUNT, 0, 0);

        uint256 fee = (STAKE_AMOUNT * 118) / 10000;
        uint256 netStaked = STAKE_AMOUNT - fee;
        uint256 penalty = PhiMath.wadMul(netStaked, ArtosphereConstants.DS_EARLY_EXIT_PENALTY_WAD);
        uint256 expectedReturn = netStaked - penalty;

        uint256 aliceBefore = phiCoin.balanceOf(alice);
        uint256 deadBefore = phiCoin.balanceOf(address(0xdead));

        vm.prank(alice);
        staking.emergencyWithdraw(0);

        assertApproxEqAbs(phiCoin.balanceOf(alice) - aliceBefore, expectedReturn, 1e6);
        assertApproxEqAbs(phiCoin.balanceOf(address(0xdead)) - deadBefore, penalty, 1e6);
    }

    function test_WithdrawExpired() public {
        vm.prank(alice);
        staking.stakeOnDiscovery(0, STAKE_AMOUNT, 0, 0);

        uint256 fee = (STAKE_AMOUNT * 118) / 10000;
        uint256 netStaked = STAKE_AMOUNT - fee;

        // Not expired yet
        vm.expectRevert(abi.encodeWithSelector(DiscoveryStaking.NotExpired.selector, 0));
        vm.prank(alice);
        staking.withdrawExpired(0);

        // Warp past F(13) = 233 days
        vm.warp(block.timestamp + 233 days + 1);

        uint256 aliceBefore = phiCoin.balanceOf(alice);
        vm.prank(alice);
        staking.withdrawExpired(0);

        // Full refund, no penalty
        assertEq(phiCoin.balanceOf(alice) - aliceBefore, netStaked);
    }

    function test_RenewExpiration() public {
        vm.prank(alice);
        staking.stakeOnDiscovery(0, STAKE_AMOUNT, 0, 0);

        // Admin renews to 610 days
        vm.prank(admin);
        staking.renewExpiration(0);

        // 233 days should NOT be enough now
        vm.warp(block.timestamp + 233 days + 1);
        vm.expectRevert(abi.encodeWithSelector(DiscoveryStaking.NotExpired.selector, 0));
        vm.prank(alice);
        staking.withdrawExpired(0);

        // 610 days should work
        vm.warp(block.timestamp + 377 days); // total > 610
        vm.prank(alice);
        staking.withdrawExpired(0); // should succeed
    }

    // ========================================================================
    // STAKING FREEZE TESTS
    // ========================================================================

    function test_StakingFreezeOnProposal() public {
        vm.prank(alice);
        staking.stakeOnDiscovery(0, STAKE_AMOUNT, 0, 0);

        // Oracle proposes — should freeze
        vm.prank(validator1);
        oracle.propose(0, DiscoveryOracle.Outcome.CONFIRMED, "10.1038/exp", "Experiment confirmed");

        // Bob tries to stake — should revert
        vm.expectRevert(abi.encodeWithSelector(DiscoveryStaking.StakingIsFrozen.selector, 0));
        vm.prank(bob);
        staking.stakeOnDiscovery(0, STAKE_AMOUNT, 1, 0);
    }

    function test_StakingUnfreezeOnVeto() public {
        vm.prank(alice);
        staking.stakeOnDiscovery(0, STAKE_AMOUNT, 0, 0);

        // Freeze
        vm.prank(validator1);
        oracle.propose(0, DiscoveryOracle.Outcome.CONFIRMED, "10.1038/exp", "Experiment confirmed");

        // Veto — should unfreeze
        vm.prank(admin); // admin has VETO_ROLE
        oracle.veto(0);

        // Bob can now stake
        vm.prank(bob);
        staking.stakeOnDiscovery(0, STAKE_AMOUNT, 1, 0); // should succeed
    }

    // ========================================================================
    // EDGE CASES
    // ========================================================================

    function test_ResolveNoLosingPool() public {
        // Only CONFIRM stakers, no REFUTE
        vm.prank(alice);
        staking.stakeOnDiscovery(0, STAKE_AMOUNT, 0, 0);

        vm.prank(validator1);
        oracle.propose(0, DiscoveryOracle.Outcome.CONFIRMED, "10.1038/exp", "Experiment confirmed");
        vm.prank(validator2);
        oracle.vote(0, true);
        vm.warp(block.timestamp + 21 days + 1);

        // Should resolve cleanly with no distribution
        oracle.resolve(0);

        // Alice claims — gets just her principal back
        uint256 aliceBefore = phiCoin.balanceOf(alice);
        vm.prank(alice);
        staking.claim(0);
        uint256 fee = (STAKE_AMOUNT * 118) / 10000;
        assertEq(phiCoin.balanceOf(alice) - aliceBefore, STAKE_AMOUNT - fee);
    }

    function test_RevertInvalidDiscovery() public {
        vm.expectRevert(abi.encodeWithSelector(DiscoveryStaking.InvalidDiscovery.selector, 999));
        vm.prank(alice);
        staking.stakeOnDiscovery(999, STAKE_AMOUNT, 0, 0);
    }

    function test_ClaimBatch() public {
        // Register second discovery
        vm.prank(scientist);
        discovery.registerDiscovery("Test2", "E=mc2", "doi2", "D", "PREDICTED", keccak256("t2"), 0);

        // Stake on both discoveries
        vm.prank(alice);
        staking.stakeOnDiscovery(0, STAKE_AMOUNT, 0, 0);
        vm.prank(alice);
        staking.stakeOnDiscovery(1, STAKE_AMOUNT, 0, 0);

        // Bob stakes other side on both
        vm.prank(bob);
        staking.stakeOnDiscovery(0, STAKE_AMOUNT, 1, 0);
        vm.prank(bob);
        staking.stakeOnDiscovery(1, STAKE_AMOUNT, 1, 0);

        // Resolve both
        vm.prank(validator1);
        oracle.propose(0, DiscoveryOracle.Outcome.CONFIRMED, "10.1038/exp", "Experiment confirmed");
        vm.prank(validator2);
        oracle.vote(0, true);

        vm.prank(validator1);
        oracle.propose(1, DiscoveryOracle.Outcome.CONFIRMED, "10.1038/exp2", "Experiment 2 confirmed");
        vm.prank(validator2);
        oracle.vote(1, true);

        vm.warp(block.timestamp + 21 days + 1);
        oracle.resolve(0);
        oracle.resolve(1);

        // Batch claim
        uint256 aliceBefore = phiCoin.balanceOf(alice);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 1;
        vm.prank(alice);
        staking.claimBatch(ids);

        assertTrue(phiCoin.balanceOf(alice) > aliceBefore);
    }
}
