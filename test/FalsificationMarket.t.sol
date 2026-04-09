// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/PhiCoin.sol";
import "../src/PhiMath.sol";
import "../src/ArtosphereDiscovery.sol";
import "../src/ArtosphereConstants.sol";
import "../src/FalsificationMarket.sol";

contract FalsificationMarketTest is Test {
    // Contracts
    PhiCoin public phiCoinImpl;
    PhiCoin public phiCoin;
    ERC1967Proxy public coinProxy;

    ArtosphereDiscovery public discovery;
    FalsificationMarket public market;

    // Actors
    address public admin = makeAddr("admin");
    address public scientist = makeAddr("scientist");
    address public treasury = makeAddr("treasury");
    address public oracle = makeAddr("oracle");
    address public author = makeAddr("author");
    address public falsifier = makeAddr("falsifier");
    address public outsider = makeAddr("outsider");

    uint256 public constant STAKE_AMOUNT = 1_000 * 1e18;
    uint256 public constant MIN_STAKE = 100 * 1e18; // ArtosphereConstants.DS_MIN_STAKE
    uint256 public constant TOKENS_PER_ACTOR = 1_000_000 * 1e18;

    // Helpers
    bytes32 constant CONTENT_HASH = keccak256("hypothesis content");
    bytes32 constant METHOD_HASH = keccak256("falsification method");

    function setUp() public {
        // Deploy PhiCoin (UUPS proxy)
        phiCoinImpl = new PhiCoin();
        bytes memory coinInit = abi.encodeWithSelector(PhiCoin.initialize.selector, admin);
        coinProxy = new ERC1967Proxy(address(phiCoinImpl), coinInit);
        phiCoin = PhiCoin(address(coinProxy));

        // Deploy ArtosphereDiscovery (scientist is admin)
        discovery = new ArtosphereDiscovery(scientist);

        // Deploy FalsificationMarket
        market = new FalsificationMarket(
            address(phiCoin),
            address(discovery),
            scientist,
            treasury,
            admin
        );

        // Grant roles
        vm.startPrank(admin);
        phiCoin.grantRole(phiCoin.MINTER_ROLE(), admin);
        market.grantRole(market.ORACLE_ROLE(), oracle);
        vm.stopPrank();

        // Exempt market and key addresses from spiral burn for clean accounting
        vm.startPrank(admin);
        phiCoin.setSpiralBurnExempt(address(market), true);
        phiCoin.setSpiralBurnExempt(author, true);
        phiCoin.setSpiralBurnExempt(falsifier, true);
        phiCoin.setSpiralBurnExempt(scientist, true);
        phiCoin.setSpiralBurnExempt(treasury, true);
        phiCoin.setSpiralBurnExempt(address(0xdead), true);
        vm.stopPrank();

        // Mint tokens to actors
        vm.startPrank(admin);
        phiCoin.mintTo(author, TOKENS_PER_ACTOR);
        phiCoin.mintTo(falsifier, TOKENS_PER_ACTOR);
        phiCoin.mintTo(address(market), TOKENS_PER_ACTOR); // extra liquidity for phi-bonus
        vm.stopPrank();

        // Approve market to spend tokens
        vm.prank(author);
        phiCoin.approve(address(market), type(uint256).max);
        vm.prank(falsifier);
        phiCoin.approve(address(market), type(uint256).max);

        // Register a discovery so discoveryId=0 exists
        vm.prank(scientist);
        discovery.registerDiscovery(
            "Test Discovery",
            "E=mc^2",
            "10.5281/test",
            "D",
            "PROVEN",
            keccak256("discovery content"),
            100
        );
    }

    // ========================================================================
    // HELPERS
    // ========================================================================

    /// @dev Create a hypothesis as `author` with the given stake, returns hypothesisId
    function _createHypothesis(uint256 stake) internal returns (uint256) {
        vm.prank(author);
        return market.createHypothesis(0, CONTENT_HASH, "Test Hypothesis", stake);
    }

    /// @dev Submit a falsification attempt as `falsifier`, returns attemptId
    function _submitFalsification(uint256 hypothesisId, uint256 stake) internal returns (uint256) {
        vm.prank(falsifier);
        return market.submitFalsification(hypothesisId, METHOD_HASH, "Method", stake);
    }

    // ========================================================================
    // TEST 1: createHypothesis — success, takes stake, 1.18% fee
    // ========================================================================

    function test_createHypothesis_success() public {
        uint256 balBefore = phiCoin.balanceOf(author);
        uint256 scientistBefore = phiCoin.balanceOf(scientist);

        uint256 hId = _createHypothesis(STAKE_AMOUNT);

        // Full stake deducted from author
        assertEq(phiCoin.balanceOf(author), balBefore - STAKE_AMOUNT, "author balance");

        // Fee = 1.18% to scientist
        uint256 expectedFee = (STAKE_AMOUNT * ArtosphereConstants.FEE_BPS) / 10000;
        uint256 expectedNet = STAKE_AMOUNT - expectedFee;
        assertEq(phiCoin.balanceOf(scientist), scientistBefore + expectedFee, "scientist fee");

        // Hypothesis stored correctly
        FalsificationMarket.Hypothesis memory h = market.getHypothesis(hId);
        assertEq(h.author, author);
        assertEq(h.authorStake, expectedNet);
        assertEq(h.discoveryId, 0);
        assertEq(uint8(h.status), uint8(FalsificationMarket.HypothesisStatus.ACTIVE));
        assertEq(h.survivals, 0);

        // totalStaked updated
        assertEq(market.totalStaked(), expectedNet);
    }

    // ========================================================================
    // TEST 2: createHypothesis — revert with insufficient stake
    // ========================================================================

    function test_createHypothesis_revert_belowMinStake() public {
        uint256 tooLow = MIN_STAKE - 1;
        vm.prank(author);
        vm.expectRevert(
            abi.encodeWithSelector(FalsificationMarket.BelowMinimumStake.selector, tooLow, MIN_STAKE)
        );
        market.createHypothesis(0, CONTENT_HASH, "Test", tooLow);
    }

    // ========================================================================
    // TEST 3: submitFalsification — success, takes stake
    // ========================================================================

    function test_submitFalsification_success() public {
        uint256 hId = _createHypothesis(STAKE_AMOUNT);

        uint256 falsifierBefore = phiCoin.balanceOf(falsifier);
        uint256 treasuryBefore = phiCoin.balanceOf(treasury);

        uint256 aId = _submitFalsification(hId, STAKE_AMOUNT);

        // Stake taken from falsifier
        assertEq(phiCoin.balanceOf(falsifier), falsifierBefore - STAKE_AMOUNT, "falsifier balance");

        // Fee = 1.18% to treasury (not scientist)
        uint256 expectedFee = (STAKE_AMOUNT * ArtosphereConstants.FEE_BPS) / 10000;
        assertEq(phiCoin.balanceOf(treasury), treasuryBefore + expectedFee, "treasury fee");

        // Attempt stored correctly
        FalsificationMarket.FalsificationAttempt memory a = market.getAttempt(hId, aId);
        assertEq(a.falsifier, falsifier);
        assertEq(a.stake, STAKE_AMOUNT - expectedFee);
        assertEq(uint8(a.status), uint8(FalsificationMarket.AttemptStatus.PENDING));

        // Pending count incremented
        assertEq(market.pendingAttemptCount(hId), 1);
    }

    // ========================================================================
    // TEST 4: submitFalsification — revert on self-falsification
    // ========================================================================

    function test_submitFalsification_revert_selfFalsify() public {
        uint256 hId = _createHypothesis(STAKE_AMOUNT);

        // Author tries to falsify own hypothesis
        vm.prank(author);
        vm.expectRevert(
            abi.encodeWithSelector(FalsificationMarket.CannotFalsifyOwnHypothesis.selector, hId)
        );
        market.submitFalsification(hId, METHOD_HASH, "Method", STAKE_AMOUNT);
    }

    // ========================================================================
    // TEST 5: resolveAttempt(falsified=true) — FALSIFIED, phi-Cascade
    // ========================================================================

    function test_resolveAttempt_falsified() public {
        uint256 hId = _createHypothesis(STAKE_AMOUNT);
        uint256 aId = _submitFalsification(hId, STAKE_AMOUNT);

        FalsificationMarket.Hypothesis memory hBefore = market.getHypothesis(hId);
        uint256 authorStake = hBefore.authorStake;
        FalsificationMarket.FalsificationAttempt memory aBefore = market.getAttempt(hId, aId);
        uint256 falsifierStake = aBefore.stake;

        uint256 deadBefore = phiCoin.balanceOf(address(0xdead));
        uint256 scientistBefore = phiCoin.balanceOf(scientist);
        uint256 treasuryBefore = phiCoin.balanceOf(treasury);

        // Oracle resolves: FALSIFIED
        vm.prank(oracle);
        market.resolveAttempt(hId, aId, true);

        // Hypothesis status is FALSIFIED
        FalsificationMarket.Hypothesis memory hAfter = market.getHypothesis(hId);
        assertEq(uint8(hAfter.status), uint8(FalsificationMarket.HypothesisStatus.FALSIFIED));
        assertEq(hAfter.authorStake, 0);

        // phi-Cascade on author's stake
        uint256 falsifierCut = PhiMath.wadMul(authorStake, ArtosphereConstants.DS_WINNER_WAD);
        uint256 burnCut = PhiMath.wadMul(authorStake, ArtosphereConstants.DS_BURN_WAD);
        uint256 scientistCut = PhiMath.wadMul(authorStake, ArtosphereConstants.DS_SCIENTIST_WAD);
        uint256 treasuryCut = authorStake - falsifierCut - burnCut - scientistCut;

        // Falsifier bonus: own stake * phi
        uint256 falsifierBonus = PhiMath.wadMul(falsifierStake, PhiMath.PHI);
        uint256 totalFalsifierReward = falsifierCut + falsifierBonus;

        // Check distributions happened
        assertEq(phiCoin.balanceOf(address(0xdead)), deadBefore + burnCut, "burn");
        assertEq(phiCoin.balanceOf(scientist), scientistBefore + scientistCut, "scientist");
        assertEq(phiCoin.balanceOf(treasury), treasuryBefore + treasuryCut, "treasury");

        // Reward stored for falsifier (pull-based)
        (uint256 rewardAmt, bool claimed) = market.getReward(hId, aId, falsifier);
        assertEq(rewardAmt, totalFalsifierReward, "falsifier reward amount");
        assertFalse(claimed, "not yet claimed");
    }

    // ========================================================================
    // TEST 6: resolveAttempt(falsified=false) — SURVIVED, survivals++
    // ========================================================================

    function test_resolveAttempt_survived() public {
        uint256 hId = _createHypothesis(STAKE_AMOUNT);
        uint256 aId = _submitFalsification(hId, STAKE_AMOUNT);

        FalsificationMarket.FalsificationAttempt memory aBefore = market.getAttempt(hId, aId);
        uint256 falsifierStake = aBefore.stake;

        uint256 deadBefore = phiCoin.balanceOf(address(0xdead));
        uint256 scientistBefore = phiCoin.balanceOf(scientist);
        uint256 treasuryBefore = phiCoin.balanceOf(treasury);

        // Oracle resolves: SURVIVED
        vm.prank(oracle);
        market.resolveAttempt(hId, aId, false);

        // Hypothesis still ACTIVE, survivals = 1
        FalsificationMarket.Hypothesis memory hAfter = market.getHypothesis(hId);
        assertEq(uint8(hAfter.status), uint8(FalsificationMarket.HypothesisStatus.ACTIVE));
        assertEq(hAfter.survivals, 1);

        // phi-Cascade on falsifier's stake
        uint256 authorCut = PhiMath.wadMul(falsifierStake, ArtosphereConstants.DS_WINNER_WAD);
        uint256 burnCut = PhiMath.wadMul(falsifierStake, ArtosphereConstants.DS_BURN_WAD);
        uint256 scientistCut = PhiMath.wadMul(falsifierStake, ArtosphereConstants.DS_SCIENTIST_WAD);
        uint256 treasuryCut = falsifierStake - authorCut - burnCut - scientistCut;

        assertEq(phiCoin.balanceOf(address(0xdead)), deadBefore + burnCut, "burn");
        assertEq(phiCoin.balanceOf(scientist), scientistBefore + scientistCut, "scientist");
        assertEq(phiCoin.balanceOf(treasury), treasuryBefore + treasuryCut, "treasury");

        // Author reward stored
        (uint256 rewardAmt,) = market.getReward(hId, aId, author);
        assertEq(rewardAmt, authorCut, "author reward");
    }

    // ========================================================================
    // TEST 7: Multiple survivals increase survival count
    // ========================================================================

    function test_multipleSurvivals_hardnessIncreases() public {
        uint256 hId = _createHypothesis(STAKE_AMOUNT);

        // Submit and resolve 5 falsification attempts, all surviving
        for (uint256 i = 0; i < 5; i++) {
            uint256 aId = _submitFalsification(hId, MIN_STAKE);
            vm.prank(oracle);
            market.resolveAttempt(hId, aId, false);
        }

        FalsificationMarket.Hypothesis memory h = market.getHypothesis(hId);
        assertEq(h.survivals, 5, "5 survivals");

        // Hardness at 5 should be > hardness at 0
        uint256 hardness5 = market.getHardnessMultiplier(hId);
        assertTrue(hardness5 > PhiMath.WAD, "hardness > 1.0 after 5 survivals");
    }

    // ========================================================================
    // TEST 8: getHardnessMultiplier at 0 survivals = WAD (1.0)
    // ========================================================================

    function test_hardnessMultiplier_zero_survivals() public {
        uint256 hId = _createHypothesis(STAKE_AMOUNT);
        uint256 hardness = market.getHardnessMultiplier(hId);
        assertEq(hardness, PhiMath.WAD, "hardness = 1.0 WAD at 0 survivals");
    }

    // ========================================================================
    // TEST 9: getHardnessMultiplier at 5 survivals ~= PHI
    // ========================================================================

    function test_hardnessMultiplier_five_survivals() public {
        uint256 hId = _createHypothesis(STAKE_AMOUNT);

        for (uint256 i = 0; i < 5; i++) {
            uint256 aId = _submitFalsification(hId, MIN_STAKE);
            vm.prank(oracle);
            market.resolveAttempt(hId, aId, false);
        }

        uint256 hardness = market.getHardnessMultiplier(hId);
        // At 5 survivals: floor(5/5)=1, remainder=0 => phiPow(1) = PHI
        assertEq(hardness, PhiMath.PHI, "hardness = PHI at 5 survivals");
    }

    // ========================================================================
    // TEST 10: claimReward — pull-based claim works
    // ========================================================================

    function test_claimReward_success() public {
        uint256 hId = _createHypothesis(STAKE_AMOUNT);
        uint256 aId = _submitFalsification(hId, STAKE_AMOUNT);

        // Resolve survived => author gets reward
        vm.prank(oracle);
        market.resolveAttempt(hId, aId, false);

        (uint256 rewardAmt,) = market.getReward(hId, aId, author);
        assertTrue(rewardAmt > 0, "reward exists");

        uint256 authorBefore = phiCoin.balanceOf(author);

        vm.prank(author);
        market.claimReward(hId, aId);

        assertEq(phiCoin.balanceOf(author), authorBefore + rewardAmt, "author received reward");

        // Cannot claim again
        (, bool claimed) = market.getReward(hId, aId, author);
        assertTrue(claimed, "marked claimed");

        vm.prank(author);
        vm.expectRevert(
            abi.encodeWithSelector(FalsificationMarket.AlreadyClaimed.selector, hId, aId)
        );
        market.claimReward(hId, aId);
    }

    // ========================================================================
    // TEST 11: retireHypothesis — author can retire, gets stake minus fee
    // ========================================================================

    function test_retireHypothesis_success() public {
        uint256 hId = _createHypothesis(STAKE_AMOUNT);

        FalsificationMarket.Hypothesis memory h = market.getHypothesis(hId);
        uint256 netStake = h.authorStake;

        uint256 authorBefore = phiCoin.balanceOf(author);
        uint256 treasuryBefore = phiCoin.balanceOf(treasury);

        vm.prank(author);
        market.retireHypothesis(hId);

        // Treasury fee: phi^-6 (5.57%)
        uint256 treasuryFee = PhiMath.wadMul(netStake, ArtosphereConstants.DS_TREASURY_WAD);
        uint256 returnAmount = netStake - treasuryFee;

        assertEq(phiCoin.balanceOf(author), authorBefore + returnAmount, "author refund");
        assertEq(phiCoin.balanceOf(treasury), treasuryBefore + treasuryFee, "treasury fee");

        // Status is RETIRED
        FalsificationMarket.Hypothesis memory hAfter = market.getHypothesis(hId);
        assertEq(uint8(hAfter.status), uint8(FalsificationMarket.HypothesisStatus.RETIRED));
    }

    // ========================================================================
    // TEST 12: retireHypothesis — revert with pending attempts
    // ========================================================================

    function test_retireHypothesis_revert_pendingAttempts() public {
        uint256 hId = _createHypothesis(STAKE_AMOUNT);
        _submitFalsification(hId, STAKE_AMOUNT);

        vm.prank(author);
        vm.expectRevert(
            abi.encodeWithSelector(FalsificationMarket.PendingAttemptsExist.selector, hId, 1)
        );
        market.retireHypothesis(hId);
    }

    // ========================================================================
    // TEST 13: Oracle role required for resolution
    // ========================================================================

    function test_resolveAttempt_revert_notOracle() public {
        uint256 hId = _createHypothesis(STAKE_AMOUNT);
        uint256 aId = _submitFalsification(hId, STAKE_AMOUNT);

        // outsider (no ORACLE_ROLE) tries to resolve
        vm.prank(outsider);
        vm.expectRevert();
        market.resolveAttempt(hId, aId, true);
    }

    // ========================================================================
    // TEST 14: Falsifier bonus on successful falsification (stake * phi)
    // ========================================================================

    function test_falsifierBonus_stakeTimesPhi() public {
        uint256 hId = _createHypothesis(STAKE_AMOUNT);
        uint256 aId = _submitFalsification(hId, STAKE_AMOUNT);

        FalsificationMarket.Hypothesis memory h = market.getHypothesis(hId);
        FalsificationMarket.FalsificationAttempt memory a = market.getAttempt(hId, aId);

        uint256 authorStake = h.authorStake;
        uint256 falsifierStake = a.stake;

        // Resolve as FALSIFIED
        vm.prank(oracle);
        market.resolveAttempt(hId, aId, true);

        // Verify the bonus: falsifier gets cascade share + own stake * phi
        uint256 cascadeShare = PhiMath.wadMul(authorStake, ArtosphereConstants.DS_WINNER_WAD);
        uint256 phiBonus = PhiMath.wadMul(falsifierStake, PhiMath.PHI);
        uint256 expectedTotal = cascadeShare + phiBonus;

        (uint256 rewardAmt,) = market.getReward(hId, aId, falsifier);
        assertEq(rewardAmt, expectedTotal, "total = cascade + phi bonus");

        // The phi bonus is strictly greater than the original stake (phi > 1)
        assertTrue(phiBonus > falsifierStake, "phi bonus > original stake");
    }

    // ========================================================================
    // TEST 15: NothingToClaim revert for non-beneficiary
    // ========================================================================

    function test_claimReward_revert_nothingToClaim() public {
        uint256 hId = _createHypothesis(STAKE_AMOUNT);
        uint256 aId = _submitFalsification(hId, STAKE_AMOUNT);

        vm.prank(oracle);
        market.resolveAttempt(hId, aId, false);

        // Outsider has no reward
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(FalsificationMarket.NothingToClaim.selector, hId, aId)
        );
        market.claimReward(hId, aId);
    }

    // ========================================================================
    // TEST 16: Expired attempts return stakes when hypothesis is falsified
    // ========================================================================

    function test_expireRemainingAttempts_onFalsification() public {
        uint256 hId = _createHypothesis(STAKE_AMOUNT);

        // Submit two falsification attempts
        uint256 aId0 = _submitFalsification(hId, MIN_STAKE);

        // Need a second falsifier
        address falsifier2 = makeAddr("falsifier2");
        vm.prank(admin);
        phiCoin.mintTo(falsifier2, TOKENS_PER_ACTOR);
        vm.prank(admin);
        phiCoin.setSpiralBurnExempt(falsifier2, true);
        vm.prank(falsifier2);
        phiCoin.approve(address(market), type(uint256).max);

        vm.prank(falsifier2);
        uint256 aId1 = market.submitFalsification(hId, METHOD_HASH, "Method2", MIN_STAKE);

        // Resolve attempt 0 as FALSIFIED => attempt 1 should be EXPIRED
        vm.prank(oracle);
        market.resolveAttempt(hId, aId0, true);

        // Attempt 1 should be EXPIRED
        FalsificationMarket.FalsificationAttempt memory a1 = market.getAttempt(hId, aId1);
        assertEq(uint8(a1.status), uint8(FalsificationMarket.AttemptStatus.EXPIRED));

        // falsifier2 should have a pending reward for their full stake
        (uint256 refund,) = market.getReward(hId, aId1, falsifier2);
        assertEq(refund, a1.stake, "expired falsifier gets full stake back");
    }
}
