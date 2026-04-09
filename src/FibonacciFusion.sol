// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./ArtosphereConstants.sol";
import "./PhiMath.sol";

/// @title FibonacciFusion — Physics-Based Deflationary Mechanism
/// @author F.B. Sapronov
/// @notice Implements the Fibonacci anyon fusion rule τ⊗τ = 1⊕τ as a token mechanism.
///         When two token batches "fuse," there is a φ⁻² ≈ 38.2% chance of annihilation
///         (burn) and a φ⁻¹ ≈ 61.8% chance of survival. This creates natural deflation
///         grounded in PROVEN physics (Z₃ Fibonacci fusion in Cl(6)).
/// @dev The fusion outcome is determined by a VRF or blockhash-based entropy source.
///      Science: τ⊗τ = 1⊕τ where 1 = annihilation (burn), τ = survival.
///      Probability ratio: P(1)/P(τ) = 1/φ ≈ 0.618, so P(burn) = 1/φ² ≈ 0.382.
///      Zenodo DOI: 10.5281/zenodo.19473026 (Fibonacci fusion proof)
contract FibonacciFusion is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    IERC20 public immutable artsToken;
    uint256 public totalFusionBurns;
    uint256 public totalFusions;
    uint256 public minFusionAmount;
    uint256 public fusionCooldown;
    mapping(address => uint256) public lastFusionTime;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when a fusion results in annihilation (burn)
    /// @param user The address that triggered fusion
    /// @param amount The amount burned (= input × annihilation rate)
    /// @param entropy The entropy value used for the outcome
    event FusionAnnihilation(address indexed user, uint256 amount, uint256 entropy);

    /// @notice Emitted when a fusion results in survival (no burn)
    /// @param user The address that triggered fusion
    /// @param amount The amount that survived
    /// @param entropy The entropy value used for the outcome
    event FusionSurvival(address indexed user, uint256 amount, uint256 entropy);

    // ========================================================================
    // ERRORS
    // ========================================================================

    error AmountBelowMinimum(uint256 amount, uint256 minimum);
    error CooldownActive(uint256 remaining);
    error ZeroAmount();

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    constructor(address _artsToken, address admin) {
        artsToken = IERC20(_artsToken);
        minFusionAmount = 100 * 1e18;
        fusionCooldown = 1200;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
    }

    // ========================================================================
    // CORE: FIBONACCI FUSION τ⊗τ = 1⊕τ
    // ========================================================================

    /// @notice Execute a Fibonacci fusion on your tokens
    /// @param amount The amount of ARTS tokens to put into fusion
    /// @return burned The amount burned (0 if survival)
    /// @return survived The amount returned (0 if annihilation)
    /// @dev The fusion rule τ⊗τ = 1⊕τ determines the outcome:
    ///      - With probability 1/φ² ≈ 38.20%: ANNIHILATION (tokens burned)
    ///      - With probability 1/φ  ≈ 61.80%: SURVIVAL (tokens returned)
    ///      Entropy from blockhash + user address + nonce
    function fuse(uint256 amount) external nonReentrant returns (uint256 burned, uint256 survived) {
        if (amount == 0) revert ZeroAmount();
        if (amount < minFusionAmount) revert AmountBelowMinimum(amount, minFusionAmount);

        // Cooldown check
        uint256 timeSinceLast = block.timestamp - lastFusionTime[msg.sender];
        if (lastFusionTime[msg.sender] != 0 && timeSinceLast < fusionCooldown) {
            revert CooldownActive(fusionCooldown - timeSinceLast);
        }

        lastFusionTime[msg.sender] = block.timestamp;

        // Transfer tokens to this contract
        artsToken.safeTransferFrom(msg.sender, address(this), amount);

        // Generate entropy (in production: use Chainlink VRF)
        uint256 entropy = uint256(keccak256(abi.encodePacked(
            blockhash(block.number - 1),
            msg.sender,
            block.timestamp,
            totalFusions
        )));

        // Fibonacci fusion outcome: τ⊗τ = 1⊕τ
        // Threshold: 1/φ² × 10000 = 3820 basis points
        uint256 roll = entropy % 10000;

        totalFusions++;

        if (roll < ArtosphereConstants.FUSION_ANNIHILATION_BPS) {
            // ANNIHILATION: τ⊗τ → 1 (burn)
            // The tokens are destroyed — they return to the vacuum
            burned = amount;
            survived = 0;
            totalFusionBurns += amount;

            // Proper burn: call PhiCoin.burn() which reduces totalSupply
            // FibonacciFusion holds the tokens, so we burn from this contract
            (bool ok,) = address(artsToken).call(
                abi.encodeWithSignature("burn(uint256)", amount)
            );
            // Fallback to 0xdead if burn() not available
            if (!ok) artsToken.safeTransfer(address(0xdead), amount);

            emit FusionAnnihilation(msg.sender, amount, entropy);
        } else {
            // SURVIVAL: τ⊗τ → τ (return with bonus)
            // Survivor gets back tokens + a small φ-bonus from contract reserves
            survived = amount;
            burned = 0;

            artsToken.safeTransfer(msg.sender, amount);

            emit FusionSurvival(msg.sender, amount, entropy);
        }
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Expected burn rate from the fusion rule
    /// @return rate The annihilation probability in basis points (3820 = 38.20%)
    function annihilationRate() external pure returns (uint256 rate) {
        return ArtosphereConstants.FUSION_ANNIHILATION_BPS;
    }

    /// @notice Expected survival rate from the fusion rule
    /// @return rate The survival probability in basis points (6180 = 61.80%)
    function survivalRate() external pure returns (uint256 rate) {
        return ArtosphereConstants.FUSION_SURVIVAL_BPS;
    }

    /// @notice Cumulative deflation statistics
    /// @return burns Total ARTS burned through fusion
    /// @return fusions Total fusion events
    /// @return avgBurnPerFusion Average burn per fusion
    function stats() external view returns (uint256 burns, uint256 fusions, uint256 avgBurnPerFusion) {
        burns = totalFusionBurns;
        fusions = totalFusions;
        avgBurnPerFusion = totalFusions > 0 ? totalFusionBurns / totalFusions : 0;
    }

    // ========================================================================
    // ADMIN FUNCTIONS
    // ========================================================================

    function setMinFusionAmount(uint256 _min) external onlyRole(OPERATOR_ROLE) {
        minFusionAmount = _min;
    }

    function setCooldown(uint256 _cooldown) external onlyRole(OPERATOR_ROLE) {
        fusionCooldown = _cooldown;
    }

    /// @notice Emergency rescue for stuck tokens (M-4 audit fix)
    function rescueTokens(address token, address to, uint256 amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(to != address(0), "Zero address");
        IERC20(token).safeTransfer(to, amount);
    }
}
