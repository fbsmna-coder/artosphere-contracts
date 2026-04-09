// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./PhiMath.sol";

/// @title MatryoshkaStaking — 5-layer nested staking where one deposit earns across ALL tiers simultaneously
/// @author F.B. Sapronov / Artosphere Phase 2
/// @notice Depositing into tier N automatically enrolls you in tiers 0..N.
///         Reward multiplier per layer: φ^(layer), so layers give 1x, φx, φ²x, φ³x, φ⁴x.
///         Total reward for tier 4 = sum of all layers = (φ⁵-1)/(φ-1) ≈ 11.09x base.
contract MatryoshkaStaking is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable artsToken;

    uint256 public constant NUM_LAYERS = 5;
    uint256[5] public LOCK_DAYS = [5, 21, 55, 144, 377];
    uint256 public constant SECONDS_PER_DAY = 86400;
    /// @notice Base APY = 5% expressed in WAD (0.05 * 1e18)
    uint256 public constant BASE_APY_WAD = 50000000000000000; // 0.05e18
    /// @notice Seconds in a year (365.25 days)
    uint256 public constant SECONDS_PER_YEAR = 31557600;

    struct Stake {
        uint256 amount;
        uint256 layer; // 0-4 (which matryoshka layer)
        uint256 startTimestamp;
        uint256 lockEnd;
        bool active;
    }

    mapping(address => Stake) public stakes;
    uint256 public totalStaked;

    event Staked(address indexed user, uint256 amount, uint256 layer, uint256 lockEnd);
    event Unstaked(address indexed user, uint256 amount, uint256 reward);
    event EmergencyWithdraw(address indexed user, uint256 returned, uint256 penalized);
    event RewardFundDepleted(uint256 shortfall);

    error InsufficientRewardFunds(uint256 available, uint256 required);

    constructor(address _token) Ownable(msg.sender) {
        artsToken = IERC20(_token);
    }

    function stake(uint256 amount, uint256 layer) external nonReentrant {
        require(layer < NUM_LAYERS, "Invalid layer");
        require(amount > 0, "Zero amount");
        require(!stakes[msg.sender].active, "Already staking");

        uint256 lockDuration = LOCK_DAYS[layer] * SECONDS_PER_DAY;

        stakes[msg.sender] = Stake({
            amount: amount,
            layer: layer,
            startTimestamp: block.timestamp,
            lockEnd: block.timestamp + lockDuration,
            active: true
        });

        totalStaked += amount;
        artsToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount, layer, block.timestamp + lockDuration);
    }

    /// @notice Calculate matryoshka reward — sum of all layers up to user's layer
    /// @dev For each layer i in [0..layer]:
    ///      layerReward = amount * BASE_APY * φ^i * (elapsed / SECONDS_PER_YEAR)
    ///      All arithmetic uses PhiMath WAD fixed-point.
    function calculateReward(address user) public view returns (uint256) {
        Stake storage s = stakes[user];
        if (!s.active || s.amount == 0) return 0;

        uint256 elapsed = block.timestamp - s.startTimestamp;
        uint256 totalReward = 0;

        // Sum rewards across all layers 0..s.layer
        for (uint256 i = 0; i <= s.layer; i++) {
            // φ^i multiplier (φ^0 = WAD)
            uint256 layerMultiplier = i == 0 ? PhiMath.WAD : PhiMath.phiPow(i);
            // Effective APY for this layer = BASE_APY * φ^i
            uint256 layerAPY = PhiMath.wadMul(BASE_APY_WAD, layerMultiplier);
            // Time fraction = elapsed / SECONDS_PER_YEAR (in WAD)
            uint256 timeRatioWad = (elapsed * PhiMath.WAD) / SECONDS_PER_YEAR;
            // layerReward = amount * layerAPY * timeRatio (amount is token-scaled, result is token-scaled)
            uint256 layerReward = PhiMath.wadMul(PhiMath.wadMul(s.amount, layerAPY), timeRatioWad);
            totalReward += layerReward;
        }

        return totalReward;
    }

    /// @notice Total multiplier for a given layer (sum of φ^0 + φ^1 + ... + φ^layer) in WAD
    function totalMultiplier(uint256 layer) public pure returns (uint256) {
        uint256 sum = 0;
        for (uint256 i = 0; i <= layer; i++) {
            sum += i == 0 ? PhiMath.WAD : PhiMath.phiPow(i);
        }
        return sum;
    }

    /// @notice Returns the reward fund balance (contract balance minus staked principal)
    function rewardFundBalance() external view returns (uint256) {
        uint256 balance = artsToken.balanceOf(address(this));
        return balance > totalStaked ? balance - totalStaked : 0;
    }

    function unstake() external nonReentrant {
        Stake storage s = stakes[msg.sender];
        require(s.active, "No active stake");
        require(block.timestamp >= s.lockEnd, "Still locked");

        uint256 reward = calculateReward(msg.sender);
        uint256 principal = s.amount;

        totalStaked -= principal;
        delete stakes[msg.sender];

        artsToken.safeTransfer(msg.sender, principal);
        if (reward > 0) {
            uint256 available = artsToken.balanceOf(address(this));
            if (available < reward) {
                uint256 shortfall = reward - available;
                emit RewardFundDepleted(shortfall);
                revert InsufficientRewardFunds(available, reward);
            }
            artsToken.safeTransfer(msg.sender, reward);
        }

        emit Unstaked(msg.sender, principal, reward);
    }

    function emergencyWithdraw() external nonReentrant {
        Stake storage s = stakes[msg.sender];
        require(s.active, "No active stake");

        uint256 principal = s.amount;
        // Penalty = 38.2% (1 - 1/φ = 1 - PHI_INV/WAD)
        uint256 penaltyRate = PhiMath.WAD - PhiMath.PHI_INV; // ~0.382 in WAD
        uint256 penalty = PhiMath.wadMul(principal, penaltyRate);
        if (penalty > principal) penalty = principal;
        uint256 returned = principal - penalty;

        totalStaked -= principal;
        delete stakes[msg.sender];

        artsToken.safeTransfer(msg.sender, returned);
        // Penalty stays in contract as extra rewards for other stakers

        emit EmergencyWithdraw(msg.sender, returned, penalty);
    }

    /// @notice Fund the contract with ARTS for rewards
    function fundRewards(uint256 amount) external onlyOwner {
        artsToken.safeTransferFrom(msg.sender, address(this), amount);
    }
}
