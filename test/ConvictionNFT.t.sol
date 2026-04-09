// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "../src/ConvictionNFT.sol";
import "../src/PhiCoin.sol";
import "../src/PhiMath.sol";
import "../src/ArtosphereConstants.sol";
import "../src/ArtosphereDiscovery.sol";
import "../src/DiscoveryStaking.sol";
import "../src/DiscoveryOracle.sol";

/// @title ConvictionNFTTest — Comprehensive Foundry tests for ConvictionNFT
///        and DiscoveryStakingV2 integration
/// @author F.B. Sapronov
/// @notice Tests: minting, burning, transfers, on-chain SVG metadata, ERC-2981 royalties,
///         claim logic, and integration with staking (via mock V2).
/// @dev Since DiscoveryStakingV2 is not yet deployed, integration tests use
///      a MockDiscoveryStakingV2 that wraps DiscoveryStaking V1 + ConvictionNFT.
///      Once V2 lands, replace the mock with the real contract.

// ============================================================================
// MOCK: Simulates DiscoveryStakingV2 behavior (V1 + ConvictionNFT minting)
// ============================================================================

/// @dev Minimal mock that wraps DiscoveryStaking V1 and mints ConvictionNFTs
///      on stake, burns them on claim. This mirrors the expected V2 interface.
contract MockDiscoveryStakingV2 {
    DiscoveryStaking public v1;
    ConvictionNFT public conviction;
    PhiCoin public artsToken;
    ArtosphereDiscovery public discoveryNFT;
    address public scientist;
    address public treasury;

    // tokenId => discoveryId
    mapping(uint256 => uint256) public tokenDiscovery;
    // discoveryId => resolved
    mapping(uint256 => bool) public resolved;
    // discoveryId => winnerSide
    mapping(uint256 => uint8) public winnerSide;
    // discoveryId => winnerRewardPool
    mapping(uint256 => uint256) public winnerRewardPool;
    // discoveryId => winnerWeightedTotal
    mapping(uint256 => uint256) public winnerWeightedTotal;
    // tokenId => claimed
    mapping(uint256 => bool) public tokenClaimed;

    error NotResolved(uint256 discoveryId);
    error AlreadyClaimed(uint256 tokenId);
    error NotTokenOwner(uint256 tokenId);

    constructor(
        DiscoveryStaking _v1,
        ConvictionNFT _conviction,
        PhiCoin _artsToken,
        ArtosphereDiscovery _discoveryNFT,
        address _treasury
    ) {
        v1 = _v1;
        conviction = _conviction;
        artsToken = _artsToken;
        discoveryNFT = _discoveryNFT;
        scientist = _discoveryNFT.scientist();
        treasury = _treasury;
    }

    /// @notice Stake and mint ConvictionNFT
    function stakeOnDiscovery(
        uint256 discoveryId,
        uint256 amount,
        uint8 side,
        uint8 tier
    ) external {
        // Transfer tokens from user to this contract
        IERC20(address(artsToken)).transferFrom(msg.sender, address(this), amount);

        // Approve V1 staking
        IERC20(address(artsToken)).approve(address(v1), amount);

        // Stake via V1 (this contract becomes the staker on V1)
        v1.stakeOnDiscovery(discoveryId, amount, side, uint256(tier));

        // Calculate net amount (after fee)
        uint256 fee = (amount * ArtosphereConstants.DS_STAKING_FEE_BPS) / 10000;
        uint256 netAmount = amount - fee;

        // Get discovery title for SVG
        (string memory title,,,,,,, ) = discoveryNFT.discoveries(discoveryId);

        // Mint ConvictionNFT to the staker
        uint256 tokenId = conviction.mint(
            msg.sender,
            discoveryId,
            side,
            netAmount,
            tier,
            title
        );

        tokenDiscovery[tokenId] = discoveryId;
    }

    /// @notice Simulate resolution (stores result for claim)
    function setResolution(
        uint256 discoveryId,
        uint8 _winnerSide,
        uint256 _rewardPool,
        uint256 _weightedTotal
    ) external {
        resolved[discoveryId] = true;
        winnerSide[discoveryId] = _winnerSide;
        winnerRewardPool[discoveryId] = _rewardPool;
        winnerWeightedTotal[discoveryId] = _weightedTotal;
    }

    /// @notice Claim by current NFT holder — burns the NFT
    function claimByNFT(uint256 tokenId) external {
        if (conviction.ownerOf(tokenId) != msg.sender) revert NotTokenOwner(tokenId);
        if (tokenClaimed[tokenId]) revert AlreadyClaimed(tokenId);

        uint256 discoveryId = tokenDiscovery[tokenId];
        if (!resolved[discoveryId]) revert NotResolved(discoveryId);

        tokenClaimed[tokenId] = true;

        ConvictionNFT.ConvictionPosition memory pos = conviction.getPosition(tokenId);

        uint256 payout = 0;
        if (pos.side == winnerSide[discoveryId]) {
            uint256 multiplier;
            if (pos.tier == 0) multiplier = PhiMath.WAD;
            else if (pos.tier == 1) multiplier = PhiMath.PHI;
            else multiplier = PhiMath.PHI_SQUARED;

            uint256 weighted = PhiMath.wadMul(pos.amount, multiplier);
            uint256 reward = 0;
            if (winnerWeightedTotal[discoveryId] > 0) {
                reward = (winnerRewardPool[discoveryId] * weighted) / winnerWeightedTotal[discoveryId];
            }
            payout = pos.amount + reward;
        }

        // Burn the NFT via markClaimed
        conviction.markClaimed(tokenId, msg.sender);

        // Transfer payout
        if (payout > 0) {
            IERC20(address(artsToken)).transfer(msg.sender, payout);
        }
    }

    /// @notice Batch claim multiple NFTs at once
    function claimBatchByNFT(uint256[] calldata tokenIds) external {
        uint256 totalPayout = 0;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            if (conviction.ownerOf(tokenId) != msg.sender) continue;
            if (tokenClaimed[tokenId]) continue;

            uint256 discoveryId = tokenDiscovery[tokenId];
            if (!resolved[discoveryId]) continue;

            tokenClaimed[tokenId] = true;

            ConvictionNFT.ConvictionPosition memory pos = conviction.getPosition(tokenId);

            if (pos.side == winnerSide[discoveryId]) {
                uint256 multiplier;
                if (pos.tier == 0) multiplier = PhiMath.WAD;
                else if (pos.tier == 1) multiplier = PhiMath.PHI;
                else multiplier = PhiMath.PHI_SQUARED;

                uint256 weighted = PhiMath.wadMul(pos.amount, multiplier);
                uint256 reward = 0;
                if (winnerWeightedTotal[discoveryId] > 0) {
                    reward = (winnerRewardPool[discoveryId] * weighted) / winnerWeightedTotal[discoveryId];
                }
                totalPayout += pos.amount + reward;
            }

            conviction.markClaimed(tokenId, msg.sender);
        }

        if (totalPayout > 0) {
            IERC20(address(artsToken)).transfer(msg.sender, totalPayout);
        }
    }
}

// ============================================================================
// TEST CONTRACT
// ============================================================================

contract ConvictionNFTTest is Test {
    ConvictionNFT public conviction;

    PhiCoin public phiCoinImpl;
    PhiCoin public phiCoin;
    ERC1967Proxy public coinProxy;

    DiscoveryStaking public stakingImpl;
    DiscoveryStaking public staking;
    ERC1967Proxy public stakingProxy;

    ArtosphereDiscovery public discovery;
    DiscoveryOracle public oracle;

    MockDiscoveryStakingV2 public stakingV2;

    address public admin = makeAddr("admin");
    address public scientist = makeAddr("scientist");
    address public treasury = makeAddr("treasury");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public dave = makeAddr("dave");
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

        // Deploy DiscoveryStaking V1 (UUPS proxy)
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

        // Deploy ConvictionNFT (non-upgradeable)
        conviction = new ConvictionNFT(scientist, admin);

        // Deploy Mock DiscoveryStakingV2
        stakingV2 = new MockDiscoveryStakingV2(
            staking, conviction, phiCoin, discovery, treasury
        );

        // Setup roles
        vm.startPrank(admin);
        staking.grantRole(staking.ORACLE_ROLE(), address(oracle));
        phiCoin.grantRole(phiCoin.MINTER_ROLE(), admin);
        conviction.grantRole(conviction.MINTER_ROLE(), address(stakingV2));
        conviction.grantRole(conviction.MINTER_ROLE(), admin);
        conviction.grantRole(conviction.CLAIMER_ROLE(), address(stakingV2));
        conviction.grantRole(conviction.CLAIMER_ROLE(), admin);
        vm.stopPrank();

        // Oracle setup
        vm.startPrank(admin);
        oracle.setStakingContract(address(staking));
        oracle.addValidator(validator1);
        oracle.addValidator(validator2);
        oracle.addValidator(validator3);
        oracle.addValidator(validator4);
        vm.stopPrank();

        // Grant ORACLE_ROLE on ArtosphereDiscovery + register discoveries
        vm.startPrank(scientist);
        discovery.grantRole(discovery.ORACLE_ROLE(), address(oracle));
        discovery.registerDiscovery(
            "Strong Coupling from Phi",
            "alpha_s = 1/(2*phi^3)",
            "10.5281/zenodo.19464050",
            "D", "PREDICTED",
            keccak256("test content"), 2
        );
        discovery.registerDiscovery(
            "Higgs Mass from Phi",
            "M_H = v * sqrt(2 * lambda_H)",
            "10.5281/zenodo.19480973",
            "D", "PREDICTED",
            keccak256("higgs content"), 1
        );
        vm.stopPrank();

        // Fund test accounts
        vm.startPrank(admin);
        phiCoin.mintTo(alice, LARGE_STAKE * 10);
        phiCoin.mintTo(bob, LARGE_STAKE * 10);
        phiCoin.mintTo(charlie, LARGE_STAKE * 10);
        phiCoin.mintTo(dave, LARGE_STAKE * 10);
        vm.stopPrank();

        // Approve V1 staking
        vm.prank(alice);
        phiCoin.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        phiCoin.approve(address(staking), type(uint256).max);
        vm.prank(charlie);
        phiCoin.approve(address(staking), type(uint256).max);

        // Approve MockV2
        vm.prank(alice);
        phiCoin.approve(address(stakingV2), type(uint256).max);
        vm.prank(bob);
        phiCoin.approve(address(stakingV2), type(uint256).max);
        vm.prank(charlie);
        phiCoin.approve(address(stakingV2), type(uint256).max);
        vm.prank(dave);
        phiCoin.approve(address(stakingV2), type(uint256).max);
    }

    // ========================================================================
    // 1. test_MintByMinter — only MINTER_ROLE can mint
    // ========================================================================

    function test_MintByMinter() public {
        vm.prank(admin);
        uint256 tokenId = conviction.mint(
            alice, 0, 0, STAKE_AMOUNT, 0, "Strong Coupling from Phi"
        );

        assertEq(conviction.ownerOf(tokenId), alice);
        assertEq(tokenId, 0);
        assertEq(conviction.nextTokenId(), 1);
    }

    // ========================================================================
    // 2. test_UnauthorizedMint_Reverts — non-minter can't mint
    // ========================================================================

    function test_UnauthorizedMint_Reverts() public {
        vm.expectRevert();
        vm.prank(alice);
        conviction.mint(alice, 0, 0, STAKE_AMOUNT, 0, "Test");
    }

    // ========================================================================
    // 3. test_PositionDataStored — discoveryId, side, amount, tier stored
    // ========================================================================

    function test_PositionDataStored() public {
        vm.prank(admin);
        uint256 tokenId = conviction.mint(alice, 0, 1, STAKE_AMOUNT, 2, "Strong Coupling");

        ConvictionNFT.ConvictionPosition memory pos = conviction.getPosition(tokenId);

        assertEq(pos.discoveryId, 0, "discoveryId mismatch");
        assertEq(pos.amount, STAKE_AMOUNT, "amount mismatch");
        assertEq(pos.side, 1, "side should be REFUTE");
        assertEq(pos.tier, 2, "tier mismatch");
        assertEq(pos.stakedAt, block.timestamp, "stakedAt mismatch");
        assertFalse(pos.claimed, "claimed should be false");
    }

    // ========================================================================
    // 4. test_Transferable — NFT can be transferred (NOT soulbound)
    // ========================================================================

    function test_Transferable() public {
        vm.prank(admin);
        uint256 tokenId = conviction.mint(alice, 0, 0, STAKE_AMOUNT, 0, "Test");

        vm.prank(alice);
        conviction.transferFrom(alice, bob, tokenId);

        assertEq(conviction.ownerOf(tokenId), bob);
        assertEq(conviction.balanceOf(alice), 0);
        assertEq(conviction.balanceOf(bob), 1);
    }

    // ========================================================================
    // 5. test_BurnOnClaim — NFT burns after claim via markClaimed
    // ========================================================================

    function test_BurnOnClaim() public {
        vm.prank(admin);
        uint256 tokenId = conviction.mint(alice, 0, 0, STAKE_AMOUNT, 0, "Test");

        assertTrue(conviction.exists(tokenId));

        vm.prank(admin);
        conviction.markClaimed(tokenId, alice);

        assertFalse(conviction.exists(tokenId));
        assertEq(conviction.balanceOf(alice), 0);

        vm.expectRevert(abi.encodeWithSelector(ConvictionNFT.TokenDoesNotExist.selector, tokenId));
        conviction.getPosition(tokenId);
    }

    // ========================================================================
    // 6. test_OnChainMetadata — tokenURI returns valid base64 JSON with SVG
    // ========================================================================

    function test_OnChainMetadata() public {
        vm.prank(admin);
        uint256 tokenId = conviction.mint(alice, 0, 0, STAKE_AMOUNT, 1, "Strong Coupling from Phi");

        string memory uri = conviction.tokenURI(tokenId);
        bytes memory uriBytes = bytes(uri);

        // Must start with data:application/json;base64,
        bytes memory prefix = bytes("data:application/json;base64,");
        assertGt(uriBytes.length, prefix.length, "URI too short");
        for (uint256 i = 0; i < prefix.length; i++) {
            assertEq(uint8(uriBytes[i]), uint8(prefix[i]), "URI prefix mismatch");
        }

        assertEq(conviction.name(), "Artosphere Conviction");
        assertEq(conviction.symbol(), "ARTC");
        assertEq(conviction.getDiscoveryTitle(tokenId), "Strong Coupling from Phi");
    }

    // ========================================================================
    // 7. test_ERC2981Royalty — 2.13% royalty to scientist address
    // ========================================================================

    function test_ERC2981Royalty() public {
        vm.prank(admin);
        uint256 tokenId = conviction.mint(alice, 0, 0, STAKE_AMOUNT, 0, "Test");

        uint256 salePrice = 1000 * 1e18;
        (address receiver, uint256 royaltyAmount) = conviction.royaltyInfo(tokenId, salePrice);

        assertEq(receiver, scientist, "Royalty receiver should be scientist");
        uint256 expectedRoyalty = (salePrice * ArtosphereConstants.BURN_RATE_BPS) / 10000;
        assertEq(royaltyAmount, expectedRoyalty, "Royalty should be 2.13%");
        assertEq(ArtosphereConstants.BURN_RATE_BPS, 213, "Burn rate = 213 bps");
    }

    // ========================================================================
    // 8. test_ClaimByNewOwner — transfer NFT, new owner can claim
    // ========================================================================

    function test_ClaimByNewOwner() public {
        vm.prank(alice);
        stakingV2.stakeOnDiscovery(0, STAKE_AMOUNT, 0, 0);

        uint256 tokenId = 0;

        vm.prank(alice);
        conviction.transferFrom(alice, dave, tokenId);

        uint256 fee = (STAKE_AMOUNT * ArtosphereConstants.DS_STAKING_FEE_BPS) / 10000;
        uint256 netAmount = STAKE_AMOUNT - fee;
        stakingV2.setResolution(0, 0, netAmount / 2, netAmount);

        vm.prank(admin);
        phiCoin.mintTo(address(stakingV2), LARGE_STAKE);

        uint256 daveBefore = phiCoin.balanceOf(dave);
        vm.prank(dave);
        stakingV2.claimByNFT(tokenId);

        assertTrue(phiCoin.balanceOf(dave) > daveBefore, "New owner should receive payout");
        assertFalse(conviction.exists(tokenId), "NFT burned after claim");
    }

    // ========================================================================
    // 9. test_DoubleClaimReverts — can't claim twice (burned after first)
    // ========================================================================

    function test_DoubleClaimReverts() public {
        vm.prank(alice);
        stakingV2.stakeOnDiscovery(0, STAKE_AMOUNT, 0, 0);

        uint256 fee = (STAKE_AMOUNT * ArtosphereConstants.DS_STAKING_FEE_BPS) / 10000;
        uint256 netAmount = STAKE_AMOUNT - fee;
        stakingV2.setResolution(0, 0, netAmount / 2, netAmount);

        vm.prank(admin);
        phiCoin.mintTo(address(stakingV2), LARGE_STAKE);

        vm.prank(alice);
        stakingV2.claimByNFT(0);

        vm.expectRevert(); // token burned
        vm.prank(alice);
        stakingV2.claimByNFT(0);
    }

    // ========================================================================
    // 10. test_ClaimUnresolvedReverts — can't claim before resolution
    // ========================================================================

    function test_ClaimUnresolvedReverts() public {
        vm.prank(alice);
        stakingV2.stakeOnDiscovery(0, STAKE_AMOUNT, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(MockDiscoveryStakingV2.NotResolved.selector, 0));
        vm.prank(alice);
        stakingV2.claimByNFT(0);
    }

    // ========================================================================
    // 11. test_StakeMitsNFT — staking automatically mints ConvictionNFT
    // ========================================================================

    function test_StakeMitsNFT() public {
        assertEq(conviction.balanceOf(alice), 0);

        vm.prank(alice);
        stakingV2.stakeOnDiscovery(0, STAKE_AMOUNT, 0, 1);

        assertEq(conviction.balanceOf(alice), 1);
        assertEq(conviction.ownerOf(0), alice);

        ConvictionNFT.ConvictionPosition memory pos = conviction.getPosition(0);
        assertEq(pos.discoveryId, 0);
        assertEq(pos.side, 0);
        assertEq(pos.tier, 1);

        uint256 fee = (STAKE_AMOUNT * ArtosphereConstants.DS_STAKING_FEE_BPS) / 10000;
        assertEq(pos.amount, STAKE_AMOUNT - fee, "Amount should be net of fee");
        assertEq(conviction.getDiscoveryTitle(0), "Strong Coupling from Phi");
    }

    // ========================================================================
    // 12. test_NFTHolderClaims — buy NFT on secondary, claim rewards
    // ========================================================================

    function test_NFTHolderClaims() public {
        vm.prank(alice);
        stakingV2.stakeOnDiscovery(0, LARGE_STAKE, 0, 2);

        vm.prank(alice);
        conviction.transferFrom(alice, charlie, 0);

        uint256 fee = (LARGE_STAKE * ArtosphereConstants.DS_STAKING_FEE_BPS) / 10000;
        uint256 netAmount = LARGE_STAKE - fee;
        uint256 weighted = PhiMath.wadMul(netAmount, PhiMath.PHI_SQUARED);
        uint256 rewardPool = PhiMath.wadMul(netAmount / 2, ArtosphereConstants.DS_WINNER_WAD);

        stakingV2.setResolution(0, 0, rewardPool, weighted);

        vm.prank(admin);
        phiCoin.mintTo(address(stakingV2), LARGE_STAKE * 2);

        uint256 charlieBefore = phiCoin.balanceOf(charlie);
        vm.prank(charlie);
        stakingV2.claimByNFT(0);

        assertTrue(phiCoin.balanceOf(charlie) > charlieBefore, "Secondary buyer should get payout");
        assertFalse(conviction.exists(0));
    }

    // ========================================================================
    // 13. test_OriginalStakerTransferred — original staker can't claim
    // ========================================================================

    function test_OriginalStakerTransferred() public {
        vm.prank(alice);
        stakingV2.stakeOnDiscovery(0, STAKE_AMOUNT, 0, 0);

        vm.prank(alice);
        conviction.transferFrom(alice, bob, 0);

        uint256 fee = (STAKE_AMOUNT * ArtosphereConstants.DS_STAKING_FEE_BPS) / 10000;
        uint256 netAmount = STAKE_AMOUNT - fee;
        stakingV2.setResolution(0, 0, netAmount / 2, netAmount);

        vm.prank(admin);
        phiCoin.mintTo(address(stakingV2), LARGE_STAKE);

        vm.expectRevert(abi.encodeWithSelector(MockDiscoveryStakingV2.NotTokenOwner.selector, 0));
        vm.prank(alice);
        stakingV2.claimByNFT(0);

        uint256 bobBefore = phiCoin.balanceOf(bob);
        vm.prank(bob);
        stakingV2.claimByNFT(0);
        assertTrue(phiCoin.balanceOf(bob) > bobBefore);
    }

    // ========================================================================
    // 14. test_BatchClaim — claim multiple NFTs at once
    // ========================================================================

    function test_BatchClaim() public {
        vm.prank(alice);
        stakingV2.stakeOnDiscovery(0, STAKE_AMOUNT, 0, 0);
        vm.prank(alice);
        stakingV2.stakeOnDiscovery(1, STAKE_AMOUNT, 0, 1);

        assertEq(conviction.balanceOf(alice), 2);

        uint256 fee = (STAKE_AMOUNT * ArtosphereConstants.DS_STAKING_FEE_BPS) / 10000;
        uint256 netAmount = STAKE_AMOUNT - fee;
        stakingV2.setResolution(0, 0, netAmount / 3, netAmount);
        stakingV2.setResolution(1, 0, netAmount / 3, netAmount);

        vm.prank(admin);
        phiCoin.mintTo(address(stakingV2), LARGE_STAKE * 2);

        uint256 aliceBefore = phiCoin.balanceOf(alice);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 1;

        vm.prank(alice);
        stakingV2.claimBatchByNFT(ids);

        assertTrue(phiCoin.balanceOf(alice) > aliceBefore);
        assertEq(conviction.balanceOf(alice), 0);
        assertFalse(conviction.exists(0));
        assertFalse(conviction.exists(1));
    }

    // ========================================================================
    // 15. test_AntiSybilStillWorks — can't stake both CONFIRM and REFUTE
    // ========================================================================

    function test_AntiSybilStillWorks() public {
        vm.prank(alice);
        stakingV2.stakeOnDiscovery(0, STAKE_AMOUNT, 0, 0);

        vm.expectRevert();
        vm.prank(alice);
        stakingV2.stakeOnDiscovery(0, STAKE_AMOUNT, 1, 0);

        assertEq(conviction.balanceOf(alice), 1);
    }

    // ========================================================================
    // ADDITIONAL EDGE CASE TESTS
    // ========================================================================

    function test_EnumerableTracking() public {
        vm.startPrank(admin);
        conviction.mint(alice, 0, 0, STAKE_AMOUNT, 0, "T1");
        conviction.mint(bob, 0, 1, STAKE_AMOUNT, 1, "T2");
        conviction.mint(charlie, 1, 0, STAKE_AMOUNT, 2, "T3");
        vm.stopPrank();

        assertEq(conviction.totalSupply(), 3);
        assertEq(conviction.tokenOfOwnerByIndex(alice, 0), 0);
        assertEq(conviction.tokenOfOwnerByIndex(bob, 0), 1);
        assertEq(conviction.tokenOfOwnerByIndex(charlie, 0), 2);

        vm.prank(admin);
        conviction.burn(1);

        assertEq(conviction.totalSupply(), 2);
        assertEq(conviction.balanceOf(bob), 0);
    }

    function test_UnauthorizedBurn_Reverts() public {
        vm.prank(admin);
        conviction.mint(alice, 0, 0, STAKE_AMOUNT, 0, "Test");

        vm.expectRevert();
        vm.prank(alice);
        conviction.burn(0);
    }

    function test_UnauthorizedMarkClaimed_Reverts() public {
        vm.prank(admin);
        conviction.mint(alice, 0, 0, STAKE_AMOUNT, 0, "Test");

        vm.expectRevert();
        vm.prank(alice);
        conviction.markClaimed(0, alice);
    }

    function test_MarkClaimedNotHolder_Reverts() public {
        vm.prank(admin);
        conviction.mint(alice, 0, 0, STAKE_AMOUNT, 0, "Test");

        vm.expectRevert(abi.encodeWithSelector(ConvictionNFT.NotTokenHolder.selector, 0));
        vm.prank(admin);
        conviction.markClaimed(0, bob);
    }

    function test_MultipleStakersGetSeparateNFTs() public {
        // Use direct minting (not MockV2) since V1 tracks MockV2 as single staker
        vm.startPrank(admin);
        conviction.mint(alice, 0, 0, STAKE_AMOUNT, 0, "Test"); // token 0, CONFIRM
        conviction.mint(bob, 0, 1, STAKE_AMOUNT, 1, "Test");   // token 1, REFUTE
        vm.stopPrank();

        assertEq(conviction.ownerOf(0), alice);
        assertEq(conviction.ownerOf(1), bob);

        ConvictionNFT.ConvictionPosition memory posA = conviction.getPosition(0);
        ConvictionNFT.ConvictionPosition memory posB = conviction.getPosition(1);
        assertEq(posA.side, 0, "Alice side = CONFIRM");
        assertEq(posB.side, 1, "Bob side = REFUTE");
        assertEq(posA.discoveryId, posB.discoveryId, "Same discovery");
    }

    function test_TokenIdAutoIncrement() public {
        vm.startPrank(admin);
        uint256 id0 = conviction.mint(alice, 0, 0, STAKE_AMOUNT, 0, "T1");
        uint256 id1 = conviction.mint(bob, 0, 1, STAKE_AMOUNT, 1, "T2");
        uint256 id2 = conviction.mint(charlie, 1, 0, STAKE_AMOUNT, 2, "T3");
        vm.stopPrank();

        assertEq(id0, 0);
        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(conviction.nextTokenId(), 3);
    }

    function test_PositionDataSurvivesTransfer() public {
        vm.prank(admin);
        uint256 tokenId = conviction.mint(alice, 0, 1, STAKE_AMOUNT, 2, "Test");

        ConvictionNFT.ConvictionPosition memory posBefore = conviction.getPosition(tokenId);

        vm.prank(alice);
        conviction.transferFrom(alice, bob, tokenId);

        ConvictionNFT.ConvictionPosition memory posAfter = conviction.getPosition(tokenId);

        assertEq(posAfter.discoveryId, posBefore.discoveryId);
        assertEq(posAfter.amount, posBefore.amount);
        assertEq(posAfter.side, posBefore.side);
        assertEq(posAfter.tier, posBefore.tier);
        assertEq(posAfter.stakedAt, posBefore.stakedAt);
        assertFalse(posAfter.claimed);
    }

    function test_SupportsInterface() public view {
        assertTrue(conviction.supportsInterface(0x80ac58cd), "ERC721");
        assertTrue(conviction.supportsInterface(0x780e9d63), "ERC721Enumerable");
        assertTrue(conviction.supportsInterface(0x2a55205a), "ERC2981");
        assertTrue(conviction.supportsInterface(0x7965db0b), "AccessControl");
        assertTrue(conviction.supportsInterface(0x01ffc9a7), "ERC165");
    }

    function test_LosingNFTHolderGetsNothing() public {
        vm.prank(bob);
        stakingV2.stakeOnDiscovery(0, STAKE_AMOUNT, 1, 0);

        uint256 fee = (STAKE_AMOUNT * ArtosphereConstants.DS_STAKING_FEE_BPS) / 10000;
        uint256 netAmount = STAKE_AMOUNT - fee;
        stakingV2.setResolution(0, 0, netAmount / 2, netAmount);

        vm.prank(admin);
        phiCoin.mintTo(address(stakingV2), LARGE_STAKE);

        uint256 bobBefore = phiCoin.balanceOf(bob);
        vm.prank(bob);
        stakingV2.claimByNFT(0);

        assertEq(phiCoin.balanceOf(bob), bobBefore, "Loser gets zero");
        assertFalse(conviction.exists(0));
    }

    function test_MintInvalidSide_Reverts() public {
        vm.expectRevert(ConvictionNFT.InvalidSide.selector);
        vm.prank(admin);
        conviction.mint(alice, 0, 2, STAKE_AMOUNT, 0, "Test");
    }

    function test_MintInvalidTier_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ConvictionNFT.InvalidTier.selector, 3));
        vm.prank(admin);
        conviction.mint(alice, 0, 0, STAKE_AMOUNT, 3, "Test");
    }

    function test_MintZeroAmount_Reverts() public {
        vm.expectRevert(ConvictionNFT.ZeroAmount.selector);
        vm.prank(admin);
        conviction.mint(alice, 0, 0, 0, 0, "Test");
    }

    function test_TokensOfOwner() public {
        vm.startPrank(admin);
        conviction.mint(alice, 0, 0, STAKE_AMOUNT, 0, "T1");
        conviction.mint(bob, 0, 1, STAKE_AMOUNT, 1, "T2");
        conviction.mint(alice, 1, 0, STAKE_AMOUNT, 2, "T3");
        vm.stopPrank();

        uint256[] memory aliceTokens = conviction.tokensOfOwner(alice);
        assertEq(aliceTokens.length, 2);
        assertEq(aliceTokens[0], 0);
        assertEq(aliceTokens[1], 2);

        uint256[] memory bobTokens = conviction.tokensOfOwner(bob);
        assertEq(bobTokens.length, 1);
        assertEq(bobTokens[0], 1);
    }

    function test_MarkClaimedTwice_Reverts() public {
        vm.prank(admin);
        conviction.mint(alice, 0, 0, STAKE_AMOUNT, 0, "Test");

        vm.prank(admin);
        conviction.markClaimed(0, alice);

        vm.expectRevert();
        vm.prank(admin);
        conviction.markClaimed(0, alice);
    }
}
