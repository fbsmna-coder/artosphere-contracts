// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/PhiCoin.sol";
import "../src/ArtosphereQuests.sol";

contract ArtosphereQuestsTest is Test {
    PhiCoin public phiCoinImpl;
    PhiCoin public phiCoin;
    ERC1967Proxy public coinProxy;

    ArtosphereQuests public quests;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    // Total Fibonacci rewards: 1+1+2+3+5+8+13+21 = 54 ARTS
    uint256 public constant TOTAL_REWARDS = 54e18;
    uint256 public constant MAX_REWARDS = 1000e18;

    function setUp() public {
        // Deploy PhiCoin via proxy
        phiCoinImpl = new PhiCoin();
        bytes memory coinInit = abi.encodeWithSelector(PhiCoin.initialize.selector, admin);
        coinProxy = new ERC1967Proxy(address(phiCoinImpl), coinInit);
        phiCoin = PhiCoin(address(coinProxy));

        // Deploy quests contract
        quests = new ArtosphereQuests(address(phiCoin), MAX_REWARDS);

        // Mint tokens to quest contract for rewards
        vm.startPrank(admin);
        phiCoin.grantRole(phiCoin.MINTER_ROLE(), admin);
        phiCoin.mintTo(address(quests), MAX_REWARDS);
        vm.stopPrank();
    }

    function test_startQuest() public {
        vm.prank(alice);
        quests.startQuest(0);

        (uint8 currentQuest, uint256 questStartTime, uint8 completedQuests, uint256 totalEarned,) =
            quests.getUserProgress(alice);

        assertEq(currentQuest, 0);
        assertGt(questStartTime, 0);
        assertEq(completedQuests, 0);
        assertEq(totalEarned, 0);
    }

    function test_completeQuest() public {
        vm.prank(alice);
        quests.startQuest(0);

        // Warp past quest 0 duration (1 day)
        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        quests.completeQuest();

        (, , uint8 completedQuests, uint256 totalEarned,) = quests.getUserProgress(alice);
        assertEq(completedQuests, 1); // bit 0 set
        assertEq(totalEarned, 1e18); // 1 ARTS reward
        assertEq(phiCoin.balanceOf(alice), 1e18);
    }

    function test_completeQuestTooEarly_reverts() public {
        vm.prank(alice);
        quests.startQuest(0);

        // Don't warp — try to complete immediately
        vm.prank(alice);
        vm.expectRevert("Quest duration not met");
        quests.completeQuest();
    }

    function test_questOrder() public {
        // Cannot start quest 1 without completing quest 0
        vm.prank(alice);
        vm.expectRevert("Complete previous quest first");
        quests.startQuest(1);

        // Complete quest 0 first
        vm.prank(alice);
        quests.startQuest(0);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        quests.completeQuest();

        // Now quest 1 should work
        vm.prank(alice);
        quests.startQuest(1);

        (uint8 currentQuest,,,, ) = quests.getUserProgress(alice);
        assertEq(currentQuest, 1);
    }

    function test_allQuestsComplete() public {
        // Fibonacci durations: 1,1,2,3,5,8,13,21 days
        uint256[8] memory durations = [uint256(1 days), 1 days, 2 days, 3 days, 5 days, 8 days, 13 days, 21 days];

        for (uint256 i = 0; i < 8; i++) {
            vm.prank(alice);
            quests.startQuest(i);

            vm.warp(block.timestamp + durations[i]);

            vm.prank(alice);
            quests.completeQuest();
        }

        (, , uint8 completedQuests, uint256 totalEarned,) = quests.getUserProgress(alice);
        assertEq(completedQuests, 0xFF); // all 8 bits set
        assertEq(totalEarned, TOTAL_REWARDS); // 54 ARTS
        assertEq(phiCoin.balanceOf(alice), TOTAL_REWARDS);
        assertEq(quests.totalRewardsDistributed(), TOTAL_REWARDS);
    }

    function test_doubleComplete_reverts() public {
        vm.prank(alice);
        quests.startQuest(0);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        quests.completeQuest();

        // Try to complete quest 0 again — questStartTime is now 0
        vm.prank(alice);
        vm.expectRevert("No active quest");
        quests.completeQuest();

        // Try to start quest 0 again — already completed
        vm.prank(alice);
        vm.expectRevert("Quest already completed");
        quests.startQuest(0);
    }

    function test_rewardPool_exhausted() public {
        // Deploy a quest contract with very low max rewards (less than quest 0 reward)
        ArtosphereQuests smallQuests = new ArtosphereQuests(address(phiCoin), 0);

        // Fund it with tokens
        vm.prank(admin);
        phiCoin.mintTo(address(smallQuests), 100e18);

        vm.prank(alice);
        smallQuests.startQuest(0);
        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        vm.expectRevert("Reward pool exhausted");
        smallQuests.completeQuest();
    }
}
