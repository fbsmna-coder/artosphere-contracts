// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./PhiMath.sol";

/// @title gARTS — Golden Mirror Synthetic Token
/// @notice Minted at phi x rate when staking ARTS. Liquid and tradeable.
contract GoldenMirror is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable artsToken;

    struct MirrorStake {
        uint256 artsDeposited;
        uint256 gArtsMinted;
        uint256 startTimestamp;
        bool active;
    }

    mapping(address => MirrorStake) public mirrorStakes;
    uint256 public totalArtsLocked;

    event MirrorStaked(address indexed user, uint256 artsIn, uint256 gArtsOut);
    event MirrorUnstaked(address indexed user, uint256 artsReturned, uint256 gArtsBurned);

    constructor(address _artsToken) ERC20("Golden Artosphere", "gARTS") {
        artsToken = IERC20(_artsToken);
    }

    /// @notice Stake ARTS, receive phi x amount in gARTS
    function mirrorStake(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        require(!mirrorStakes[msg.sender].active, "Already staked");

        // Mint phi x amount gARTS
        // wadMul(amount, PHI) = (amount * PHI) / WAD
        // Since amount is in token units (18 decimals) and PHI is WAD-scaled,
        // the result is correctly in token units: amount * 1.618...
        uint256 gArtsAmount = PhiMath.wadMul(amount, PhiMath.PHI);
        require(gArtsAmount > 0, "Amount too small");

        artsToken.safeTransferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, gArtsAmount);

        mirrorStakes[msg.sender] = MirrorStake({
            artsDeposited: amount,
            gArtsMinted: gArtsAmount,
            startTimestamp: block.timestamp,
            active: true
        });

        totalArtsLocked += amount;

        emit MirrorStaked(msg.sender, amount, gArtsAmount);
    }

    /// @notice Unstake: return gARTS (must have enough), get ARTS back
    function mirrorUnstake() external nonReentrant {
        MirrorStake storage s = mirrorStakes[msg.sender];
        require(s.active, "No active stake");
        require(balanceOf(msg.sender) >= s.gArtsMinted, "Insufficient gARTS balance");

        uint256 artsToReturn = s.artsDeposited;
        uint256 gArtsToBurn = s.gArtsMinted;

        totalArtsLocked -= artsToReturn;
        delete mirrorStakes[msg.sender];

        _burn(msg.sender, gArtsToBurn);
        artsToken.safeTransfer(msg.sender, artsToReturn);

        emit MirrorUnstaked(msg.sender, artsToReturn, gArtsToBurn);
    }

    /// @notice Current value of gARTS relative to ARTS in WAD
    /// @dev Value changes over time: starts at 1/phi, converges, then grows via fibonacci bonus
    function gArtsValue(address user) external view returns (uint256) {
        MirrorStake storage s = mirrorStakes[user];
        if (!s.active) return PhiMath.WAD; // 1:1 if no stake

        uint256 elapsed = block.timestamp - s.startTimestamp;
        uint256 elapsedDays = elapsed / 86400;
        if (elapsedDays == 0) elapsedDays = 1;

        // Value = artsDeposited / gArtsMinted * (1 + fibonacci_bonus)
        // fibonacci_bonus grows with time: rawFib(min(elapsedDays/7, 20)) / 100
        uint256 weeksPassed = elapsedDays / 7;
        if (weeksPassed > 20) weeksPassed = 20;

        // Use raw fibonacci value (not WAD-scaled) for bonus percentage
        // fibonacci() returns WAD-scaled, so divide by WAD to get raw number
        uint256 fibBonusRaw = weeksPassed > 0 ? PhiMath.fibonacci(weeksPassed) / PhiMath.WAD : 0;

        // Base value = deposit/minted in WAD = 1/phi ~ 0.618 WAD
        uint256 baseValue = PhiMath.wadDiv(s.artsDeposited, s.gArtsMinted);

        // With bonus: value = baseValue * (1 + fibBonusRaw/100)
        uint256 bonusMultiplier = PhiMath.WAD + (fibBonusRaw * PhiMath.WAD / 100);
        return PhiMath.wadMul(baseValue, bonusMultiplier);
    }
}
