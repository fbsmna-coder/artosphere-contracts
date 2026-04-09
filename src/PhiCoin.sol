// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./PhiMath.sol";

/**
 * @title Artosphere (ARTS)
 * @author F.B. Sapronov
 * @notice ERC-20 token with Fibonacci emission, Proof-of-Patience, Spiral Burn, Anti-Whale limiter,
 *         ERC20Votes, and ERC20Permit for governance.
 */
contract PhiCoin is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    ERC20VotesUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    /// @notice Total supply = F(16) × 10⁶ = 987,000,000 ARTS
    /// @dev F(16) = 987 = 719 + 268: the Fibonacci unification number
    ///      linking gravity-gauge hierarchy (719/9) with vacuum energy (268).
    ///      See: Zenodo DOI 10.5281/zenodo.19471249
    uint256 public constant MAX_SUPPLY = 987_000_000 * 1e18;
    uint256 public constant EPOCH_DURATION = 1200;

    uint256 public genesisTimestamp;
    uint256 public totalMinted;
    uint256 public lastMintedEpoch;
    bool public hasEverMinted;

    // Proof-of-Patience: temporal mass tracking
    mapping(address => uint256) public lastTransferTimestamp;

    // Anti-Whale: governance-settable median balance
    uint256 public medianBalance;

    // Spiral Burn floor: F(34) = 9,227,465
    uint256 public constant BURN_FLOOR = 9_227_465 * 1e18;

    // Spiral Burn whitelist: exempt addresses (e.g. staking contracts)
    mapping(address => bool) public spiralBurnExempt;

    uint256[42] private __gap; // reduced by 1 for spiralBurnExempt

    event EmissionMinted(address indexed minter, uint256 indexed toEpoch, uint256 amount);
    event MintedTo(address indexed to, uint256 amount);
    event TokensBurned(address indexed burner, uint256 amount);
    event SpiralBurn(address indexed from, uint256 burnAmount, uint256 transferAmount);
    event SpiralBurnExemptSet(address indexed account, bool exempt);

    error ExceedsMaxSupply(uint256 requested, uint256 remaining);
    error NoEmissionAvailable();
    error InsufficientBalance(uint256 requested, uint256 available);
    error WhaleTransferLimitExceeded(uint256 amount, uint256 maxAllowed);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address admin) external initializer {
        __ERC20_init("Artosphere", "ARTS");
        __ERC20Permit_init("Artosphere");
        __ERC20Votes_init();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        genesisTimestamp = block.timestamp;
    }

    function currentEpoch() public view returns (uint256 epoch) {
        epoch = (block.timestamp - genesisTimestamp) / EPOCH_DURATION;
    }

    function emissionForEpoch(uint256 epoch) public pure returns (uint256 amount) {
        amount = PhiMath.fibEmission(epoch);
    }

    function mint(uint256 maxEpochs) external onlyRole(MINTER_ROLE) {
        uint256 epoch = currentEpoch();
        if (hasEverMinted && epoch <= lastMintedEpoch) revert NoEmissionAvailable();

        uint256 startEpoch = hasEverMinted ? lastMintedEpoch + 1 : 0;
        uint256 endEpoch = startEpoch + maxEpochs;
        if (endEpoch > epoch) endEpoch = epoch;

        uint256 totalEmission;
        for (uint256 e = startEpoch; e <= endEpoch; e++) {
            totalEmission += emissionForEpoch(e);
        }
        if (totalEmission == 0) revert NoEmissionAvailable();

        uint256 remaining = MAX_SUPPLY - totalSupply();
        if (totalEmission > remaining) totalEmission = remaining;
        if (totalEmission == 0) revert ExceedsMaxSupply(0, 0);

        lastMintedEpoch = endEpoch;
        hasEverMinted = true;
        totalMinted += totalEmission;
        _mint(msg.sender, totalEmission);
        emit EmissionMinted(msg.sender, endEpoch, totalEmission);
    }

    function mintTo(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        uint256 remaining = MAX_SUPPLY - totalSupply();
        if (amount > remaining) revert ExceedsMaxSupply(amount, remaining);
        totalMinted += amount;
        _mint(to, amount);
        emit MintedTo(to, amount);
    }

    function burn(uint256 amount) external {
        if (balanceOf(msg.sender) < amount) revert InsufficientBalance(amount, balanceOf(msg.sender));
        _burn(msg.sender, amount);
        emit TokensBurned(msg.sender, amount);
    }

    // =========================================================================
    // Proof-of-Patience: Temporal Mass
    // =========================================================================

    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    /// @notice Returns the temporal mass of an account in WAD (1e18 = 1.0x)
    /// @dev Mass increases the longer tokens are held without transferring.
    ///      New accounts start at 1.0. Capped at ~7.5x for 377+ days.
    function temporalMass(address account) public view returns (uint256) {
        uint256 lastTx = lastTransferTimestamp[account];
        if (lastTx == 0) lastTx = block.timestamp; // new account = mass 1.0
        uint256 holdingSeconds = block.timestamp - lastTx;
        if (holdingSeconds == 0) return PhiMath.WAD; // 1.0 in WAD
        uint256 holdingDays = holdingSeconds / 86400;
        if (holdingDays == 0) return PhiMath.WAD;
        if (holdingDays > 377) holdingDays = 377; // cap at F(14)
        // Simple φ-log approximation: mass ≈ 1 + sqrt(holdingDays) / 3
        uint256 bonus = (_sqrt(holdingDays * 1e18) * 1e9) / 3e18;
        return PhiMath.WAD + bonus;
    }

    // =========================================================================
    // Spiral Burn Engine
    // =========================================================================

    /// @notice Returns the current burn rate in WAD (decays as supply approaches BURN_FLOOR)
    function spiralBurnRate() public view returns (uint256) {
        uint256 currentSupply = totalSupply();
        if (currentSupply <= BURN_FLOOR) return 0;
        uint256 burnableRange = MAX_SUPPLY - BURN_FLOOR;
        uint256 currentBurnable = currentSupply - BURN_FLOOR;
        // 0.618% * (remaining/total) — decays linearly toward 0
        return PhiMath.wadMul(618033988749894848, PhiMath.wadDiv(currentBurnable, burnableRange));
    }

    // =========================================================================
    // Anti-Whale Golden Spiral Limiter
    // =========================================================================

    /// @notice Set median balance for whale detection (governance only)
    function setMedianBalance(uint256 _median) external onlyRole(DEFAULT_ADMIN_ROLE) {
        medianBalance = _median;
    }

    /// @notice Exempt an address from spiral burn (e.g. staking contracts)
    function setSpiralBurnExempt(address account, bool exempt) external onlyRole(DEFAULT_ADMIN_ROLE) {
        spiralBurnExempt[account] = exempt;
        emit SpiralBurnExemptSet(account, exempt);
    }

    /// @dev Checks if a transfer exceeds the whale limit
    function _antiWhaleCheck(address from, uint256 amount) internal view {
        if (medianBalance == 0) return; // not activated yet
        uint256 senderBalance = balanceOf(from);
        if (senderBalance <= medianBalance) return; // not a whale
        // maxTransfer = totalSupply * median / (balance * φ)
        uint256 maxTransfer = PhiMath.wadDiv(
            totalSupply() * medianBalance,
            PhiMath.wadMul(senderBalance, PhiMath.PHI)
        ) / 1e18;
        if (maxTransfer < 1e18) maxTransfer = 1e18; // minimum 1 ARTS
        if (amount > maxTransfer) revert WhaleTransferLimitExceeded(amount, maxTransfer);
    }

    // =========================================================================
    // Transfer overrides (burn-on-transfer + anti-whale + timestamp tracking)
    // =========================================================================

    // Required overrides for ERC20 + ERC20Votes + ERC20Permit
    // Spiral burn and anti-whale are applied here inside _update() so that
    // allowance is always consumed for the full original amount (fixes C1)
    // and spiral burn exemptions work for staking contracts (fixes C4).
    function _update(address from, address to, uint256 value)
        internal override(ERC20Upgradeable, ERC20VotesUpgradeable)
    {
        // Anti-whale check (skip mints and burns)
        if (from != address(0) && to != address(0)) {
            _antiWhaleCheck(from, value);
        }

        // Spiral burn on regular transfers (not mint/burn, not exempt addresses)
        uint256 burnAmount = 0;
        if (from != address(0) && to != address(0) && value > 0
            && !spiralBurnExempt[from] && !spiralBurnExempt[to])
        {
            uint256 burnRate = spiralBurnRate();
            if (burnRate > 0) {
                burnAmount = PhiMath.wadMul(value, burnRate) / 1e18;
                if (burnAmount > 0 && totalSupply() - burnAmount >= BURN_FLOOR) {
                    // Burn from sender, then transfer the remainder
                    super._update(from, address(0), burnAmount);
                    emit SpiralBurn(from, burnAmount, value - burnAmount);
                    value -= burnAmount;
                } else {
                    burnAmount = 0;
                }
            }
        }

        super._update(from, to, value);

        // Proof-of-Patience: track last transfer timestamps
        if (from != address(0)) {
            lastTransferTimestamp[from] = block.timestamp;
        }
        if (to != address(0) && lastTransferTimestamp[to] == 0) {
            lastTransferTimestamp[to] = block.timestamp;
        }
    }

    function nonces(address owner)
        public view override(ERC20PermitUpgradeable, NoncesUpgradeable)
        returns (uint256)
    { return super.nonces(owner); }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    function remainingSupply() external view returns (uint256) {
        return MAX_SUPPLY - totalSupply();
    }
}
