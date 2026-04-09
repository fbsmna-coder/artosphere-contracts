// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "chainlink-brownie-contracts/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import "chainlink-brownie-contracts/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import "./ArtosphereConstants.sol";
import "./PhiMath.sol";

/// @title FibonacciFusionV2 — Physics-Based Deflationary Mechanism with Chainlink VRF v2.5
/// @author F.B. Sapronov
/// @notice Upgraded from V1: uses Chainlink VRF v2.5 for tamper-proof randomness on Base L2.
///         Implements the Fibonacci anyon fusion rule τ⊗τ = 1⊕τ as a token mechanism.
///         When two token batches "fuse," there is a φ⁻² ≈ 38.2% chance of annihilation
///         (burn) and a φ⁻¹ ≈ 61.8% chance of survival. This creates natural deflation
///         grounded in PROVEN physics (Z₃ Fibonacci fusion in Cl(6)).
/// @dev VRF flow: fuse() requests randomness → fulfillRandomWords() resolves outcome.
///      Fallback mode: if VRF is not configured (subscriptionId == 0), uses blockhash.
///      Science: τ⊗τ = 1⊕τ where 1 = annihilation (burn), τ = survival.
///      Probability ratio: P(1)/P(τ) = 1/φ ≈ 0.618, so P(burn) = 1/φ² ≈ 0.382.
///      Zenodo DOI: 10.5281/zenodo.19473026 (Fibonacci fusion proof)
contract FibonacciFusionV2 is AccessControl, ReentrancyGuard, VRFConsumerBaseV2Plus {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    IERC20 public immutable artsToken;
    uint256 public totalFusionBurns;
    uint256 public totalFusions;
    uint256 public minFusionAmount;
    uint256 public fusionCooldown;
    mapping(address => uint256) public lastFusionTime;

    // ========================================================================
    // VRF v2.5 CONFIGURATION (Base Mainnet defaults)
    // ========================================================================

    /// @notice Chainlink VRF subscription ID (0 = fallback to blockhash)
    uint256 public vrfSubscriptionId;

    /// @notice Key hash for VRF gas lane
    /// @dev Base mainnet 200 gwei: 0x9e1344a1247c8a1785d0a4681a27152bffdb43666ae5bf7d14d24a5efd44bf71
    bytes32 public vrfKeyHash;

    /// @notice Gas limit for VRF callback
    uint32 public vrfCallbackGasLimit = 200_000;

    /// @notice Number of confirmations for VRF request
    uint16 public constant VRF_REQUEST_CONFIRMATIONS = 3;

    /// @notice Number of random words per request
    uint32 public constant VRF_NUM_WORDS = 1;

    // ========================================================================
    // PENDING FUSIONS (VRF async flow)
    // ========================================================================

    struct PendingFusion {
        address user;
        uint256 amount;
    }

    /// @notice Maps VRF requestId to the pending fusion data
    mapping(uint256 => PendingFusion) public pendingFusions;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when a fusion results in annihilation (burn)
    event FusionAnnihilation(address indexed user, uint256 amount, uint256 entropy);

    /// @notice Emitted when a fusion results in survival (no burn)
    event FusionSurvival(address indexed user, uint256 amount, uint256 entropy);

    /// @notice Emitted when a VRF request is made (fusion pending)
    event FusionRequested(uint256 indexed requestId, address indexed user, uint256 amount);

    /// @notice Emitted when VRF configuration is updated
    event VRFConfigUpdated(uint256 subscriptionId, bytes32 keyHash, uint32 callbackGasLimit);

    // ========================================================================
    // ERRORS
    // ========================================================================

    error AmountBelowMinimum(uint256 amount, uint256 minimum);
    error CooldownActive(uint256 remaining);
    error ZeroAmount();
    error InvalidPendingFusion(uint256 requestId);

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    /// @param _artsToken The ARTS ERC-20 token address
    /// @param admin Admin and operator address
    /// @param _vrfCoordinator Chainlink VRF Coordinator address
    ///        Base mainnet: 0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634
    constructor(
        address _artsToken,
        address admin,
        address _vrfCoordinator
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
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
    /// @dev If VRF is configured (subscriptionId != 0): requests randomness async.
    ///      If VRF is NOT configured (subscriptionId == 0): resolves immediately with blockhash.
    ///      In VRF mode, returns (0, 0) — actual outcome arrives via fulfillRandomWords().
    /// @return burned The amount burned (0 if VRF pending or survival)
    /// @return survived The amount returned (0 if VRF pending or annihilation)
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

        if (vrfSubscriptionId != 0) {
            // ---- VRF MODE: request randomness, resolve in callback ----
            uint256 requestId = s_vrfCoordinator.requestRandomWords(
                VRFV2PlusClient.RandomWordsRequest({
                    keyHash: vrfKeyHash,
                    subId: vrfSubscriptionId,
                    requestConfirmations: VRF_REQUEST_CONFIRMATIONS,
                    callbackGasLimit: vrfCallbackGasLimit,
                    numWords: VRF_NUM_WORDS,
                    extraArgs: VRFV2PlusClient._argsToBytes(
                        VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                    )
                })
            );

            pendingFusions[requestId] = PendingFusion({
                user: msg.sender,
                amount: amount
            });

            emit FusionRequested(requestId, msg.sender, amount);

            // Returns (0, 0) — outcome will be emitted in fulfillRandomWords
            return (0, 0);
        } else {
            // ---- FALLBACK MODE: blockhash entropy (for testing / pre-VRF) ----
            uint256 entropy = uint256(keccak256(abi.encodePacked(
                blockhash(block.number - 1),
                msg.sender,
                block.timestamp,
                totalFusions
            )));

            return _resolveFusion(msg.sender, amount, entropy);
        }
    }

    // ========================================================================
    // VRF CALLBACK
    // ========================================================================

    /// @notice Chainlink VRF callback — resolves the pending fusion
    /// @dev Called by VRF Coordinator. Cannot revert or the request is lost.
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        PendingFusion memory fusion = pendingFusions[requestId];
        if (fusion.user == address(0)) revert InvalidPendingFusion(requestId);

        // Clean up pending state
        delete pendingFusions[requestId];

        // Resolve with VRF entropy
        _resolveFusion(fusion.user, fusion.amount, randomWords[0]);
    }

    // ========================================================================
    // INTERNAL: FUSION RESOLUTION
    // ========================================================================

    /// @notice Resolves a fusion outcome given entropy
    /// @param user The address that triggered fusion
    /// @param amount The token amount in fusion
    /// @param entropy The random value (from VRF or blockhash)
    function _resolveFusion(
        address user,
        uint256 amount,
        uint256 entropy
    ) internal returns (uint256 burned, uint256 survived) {
        // Fibonacci fusion outcome: τ⊗τ = 1⊕τ
        // Threshold: 1/φ² × 10000 = 3820 basis points
        uint256 roll = entropy % 10000;

        totalFusions++;

        if (roll < ArtosphereConstants.FUSION_ANNIHILATION_BPS) {
            // ANNIHILATION: τ⊗τ → 1 (burn)
            burned = amount;
            survived = 0;
            totalFusionBurns += amount;

            // Proper burn: call PhiCoin.burn() which reduces totalSupply
            (bool ok,) = address(artsToken).call(
                abi.encodeWithSignature("burn(uint256)", amount)
            );
            // Fallback to 0xdead if burn() not available
            if (!ok) artsToken.safeTransfer(address(0xdead), amount);

            emit FusionAnnihilation(user, amount, entropy);
        } else {
            // SURVIVAL: τ⊗τ → τ (return tokens)
            survived = amount;
            burned = 0;

            artsToken.safeTransfer(user, amount);

            emit FusionSurvival(user, amount, entropy);
        }
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /// @notice Expected burn rate from the fusion rule
    function annihilationRate() external pure returns (uint256 rate) {
        return ArtosphereConstants.FUSION_ANNIHILATION_BPS;
    }

    /// @notice Expected survival rate from the fusion rule
    function survivalRate() external pure returns (uint256 rate) {
        return ArtosphereConstants.FUSION_SURVIVAL_BPS;
    }

    /// @notice Cumulative deflation statistics
    function stats() external view returns (uint256 burns, uint256 fusions, uint256 avgBurnPerFusion) {
        burns = totalFusionBurns;
        fusions = totalFusions;
        avgBurnPerFusion = totalFusions > 0 ? totalFusionBurns / totalFusions : 0;
    }

    /// @notice Whether VRF is configured (true) or using blockhash fallback (false)
    function isVRFEnabled() external view returns (bool) {
        return vrfSubscriptionId != 0;
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

    /// @notice Configure Chainlink VRF v2.5 parameters
    /// @param _subscriptionId VRF subscription ID (set to 0 to disable VRF and use blockhash)
    /// @param _keyHash Gas lane key hash
    /// @param _callbackGasLimit Max gas for fulfillRandomWords callback
    function setVRFConfig(
        uint256 _subscriptionId,
        bytes32 _keyHash,
        uint32 _callbackGasLimit
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        vrfSubscriptionId = _subscriptionId;
        vrfKeyHash = _keyHash;
        vrfCallbackGasLimit = _callbackGasLimit;

        emit VRFConfigUpdated(_subscriptionId, _keyHash, _callbackGasLimit);
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
