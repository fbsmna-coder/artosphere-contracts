// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./PhiMath.sol";

/// @title ArtosphereQuests — Fibonacci Quest System
/// @notice Users complete 8 quests following Fibonacci durations to learn φ-math and earn ARTS
/// @dev Quest milestones: 1,1,2,3,5,8,13,21 days; rewards mirror Fibonacci sequence in ARTS
contract ArtosphereQuests is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    /// @notice Total number of quests (Fibonacci sequence length)
    uint256 public constant NUM_QUESTS = 8;

    /// @notice Quest durations following Fibonacci: 1,1,2,3,5,8,13,21 days
    uint256[8] public QUEST_DURATIONS;

    /// @notice Quest rewards following Fibonacci: 1,1,2,3,5,8,13,21 ARTS (in WAD)
    uint256[8] public QUEST_REWARDS;

    struct UserProgress {
        uint8 currentQuest;     // 0-7, which quest they're on
        uint256 questStartTime; // when current quest was started
        uint8 completedQuests;  // bitmask of completed quests
        uint256 totalEarned;    // total ARTS earned from quests
    }

    mapping(address => UserProgress) public progress;

    IERC20 public artsToken;
    uint256 public totalRewardsDistributed;
    uint256 public maxTotalRewards; // cap on total quest rewards

    event QuestStarted(address indexed user, uint256 questIndex);
    event QuestCompleted(address indexed user, uint256 questIndex, uint256 reward);
    event AllQuestsCompleted(address indexed user, uint256 totalEarned);

    constructor(address _artsToken, uint256 _maxRewards) Ownable(msg.sender) {
        artsToken = IERC20(_artsToken);
        maxTotalRewards = _maxRewards;

        // Fibonacci durations: 1,1,2,3,5,8,13,21 days
        QUEST_DURATIONS[0] = 1 days;
        QUEST_DURATIONS[1] = 1 days;
        QUEST_DURATIONS[2] = 2 days;
        QUEST_DURATIONS[3] = 3 days;
        QUEST_DURATIONS[4] = 5 days;
        QUEST_DURATIONS[5] = 8 days;
        QUEST_DURATIONS[6] = 13 days;
        QUEST_DURATIONS[7] = 21 days;

        // Fibonacci rewards: 1,1,2,3,5,8,13,21 ARTS
        QUEST_REWARDS[0] = 1e18;
        QUEST_REWARDS[1] = 1e18;
        QUEST_REWARDS[2] = 2e18;
        QUEST_REWARDS[3] = 3e18;
        QUEST_REWARDS[4] = 5e18;
        QUEST_REWARDS[5] = 8e18;
        QUEST_REWARDS[6] = 13e18;
        QUEST_REWARDS[7] = 21e18;
    }

    /// @notice Start a quest by index (must be done in order)
    /// @param questIndex The quest to start (0-7)
    function startQuest(uint256 questIndex) external {
        require(questIndex < NUM_QUESTS, "Invalid quest");
        UserProgress storage p = progress[msg.sender];

        // Must complete previous quest first (except quest 0)
        if (questIndex > 0) {
            require(
                p.completedQuests & uint8(1 << (questIndex - 1)) != 0,
                "Complete previous quest first"
            );
        }
        require(
            p.completedQuests & uint8(1 << questIndex) == 0,
            "Quest already completed"
        );

        p.currentQuest = uint8(questIndex);
        p.questStartTime = block.timestamp;

        emit QuestStarted(msg.sender, questIndex);
    }

    /// @notice Complete the currently active quest and claim reward
    function completeQuest() external nonReentrant {
        UserProgress storage p = progress[msg.sender];
        uint256 qi = p.currentQuest;

        require(p.questStartTime > 0, "No active quest");
        require(
            p.completedQuests & uint8(1 << qi) == 0,
            "Already completed"
        );
        require(
            block.timestamp >= p.questStartTime + QUEST_DURATIONS[qi],
            "Quest duration not met"
        );
        require(
            totalRewardsDistributed + QUEST_REWARDS[qi] <= maxTotalRewards,
            "Reward pool exhausted"
        );

        // Mark completed
        p.completedQuests |= uint8(1 << qi);
        p.questStartTime = 0;

        // Send reward
        uint256 reward = QUEST_REWARDS[qi];
        p.totalEarned += reward;
        totalRewardsDistributed += reward;

        artsToken.safeTransfer(msg.sender, reward);

        emit QuestCompleted(msg.sender, qi, reward);

        // Check if all 8 quests done (0xFF = 8 bits set)
        if (p.completedQuests == 0xFF) {
            emit AllQuestsCompleted(msg.sender, p.totalEarned);
        }
    }

    /// @notice Get a user's quest progress
    function getUserProgress(address user)
        external
        view
        returns (
            uint8 currentQuest,
            uint256 questStartTime,
            uint8 completedQuests,
            uint256 totalEarned,
            uint256 timeRemaining
        )
    {
        UserProgress storage p = progress[user];
        currentQuest = p.currentQuest;
        questStartTime = p.questStartTime;
        completedQuests = p.completedQuests;
        totalEarned = p.totalEarned;
        if (p.questStartTime > 0) {
            uint256 endTime = p.questStartTime + QUEST_DURATIONS[p.currentQuest];
            timeRemaining = block.timestamp >= endTime ? 0 : endTime - block.timestamp;
        }
    }

    /// @notice Fund the contract with ARTS tokens (owner only)
    function fundRewards(uint256 amount) external onlyOwner {
        artsToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Withdraw unused reward tokens (owner only)
    /// @dev Only withdraws balance minus unclaimed rewards (maxTotalRewards - totalRewardsDistributed)
    function withdrawUnused() external onlyOwner {
        uint256 balance = artsToken.balanceOf(address(this));
        uint256 unclaimed = maxTotalRewards > totalRewardsDistributed
            ? maxTotalRewards - totalRewardsDistributed
            : 0;
        require(balance > unclaimed, "No unused tokens to withdraw");
        uint256 withdrawable = balance - unclaimed;
        artsToken.safeTransfer(owner(), withdrawable);
    }
}
