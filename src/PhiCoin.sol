// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./PhiMath.sol";

/**
 * @title PhiCoin (PHI)
 * @author IBG Technologies
 * @notice ERC-20 token with Fibonacci emission schedule governed by the golden ratio phi.
 *
 * @dev Total supply is hard-capped at phi * 10^9 tokens (1,618,033,988 * 1e18).
 *
 *      **Emission schedule:**
 *      Each epoch spans 100 blocks. The mintable amount for epoch `e` is:
 *
 *          emission(e) = F(e % 100) * phi^{-(e / 100)}
 *
 *      where F(n) is the n-th Fibonacci number and phi = (1+sqrt5)/2.
 *      This produces a Fibonacci-patterned emission that decays exponentially by
 *      the golden ratio every 100 epochs, yielding a naturally deflationary curve.
 *
 *      **Access control:**
 *        - MINTER_ROLE  : miner / staking contracts authorised to mint new tokens.
 *        - UPGRADER_ROLE: governance address authorised to upgrade the implementation.
 *        - DEFAULT_ADMIN_ROLE: manages role assignments.
 *
 *      **Upgradeability:** UUPS proxy pattern (OpenZeppelin 5.x).
 *
 *      **Burn:** Any holder may burn their own tokens (deflationary mechanism).
 */
contract PhiCoin is Initializable, ERC20Upgradeable, AccessControlUpgradeable, UUPSUpgradeable {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Role identifier for addresses permitted to mint tokens.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Role identifier for addresses permitted to upgrade the proxy.
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Hard cap on total supply: phi * 10^9 tokens (18 decimals).
    /// @dev 1_618_033_988 * 1e18 = 1.618033988 * 10^27
    uint256 public constant MAX_SUPPLY = 1_618_033_988 * 1e18;

    /// @notice Number of blocks in a single emission epoch.
    uint256 public constant BLOCKS_PER_EPOCH = 100;

    // -------------------------------------------------------------------------
    // Storage (UUPS-safe — append-only, with gap)
    // -------------------------------------------------------------------------

    /// @notice Block number at which the contract was initialised (epoch reference).
    uint256 public genesisBlock;

    /// @notice Cumulative tokens minted through the emission schedule.
    uint256 public totalMinted;

    /// @notice Tracks the last epoch for which emission was already claimed.
    uint256 public lastMintedEpoch;

    /// @notice Whether any emission has ever been minted (disambiguates epoch 0).
    bool public hasEverMinted;

    /// @dev Reserved storage gap for future upgrades (50 slots minus used slots).
    uint256[46] private __gap;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when new tokens are minted through the emission schedule.
    /// @param minter  Address that triggered the mint.
    /// @param toEpoch The last epoch included in this batch mint.
    /// @param amount  Number of tokens minted (18-decimal WAD).
    event EmissionMinted(address indexed minter, uint256 indexed toEpoch, uint256 amount);

    /// @notice Emitted when a holder burns their own tokens.
    /// @param burner Address that burned tokens.
    /// @param amount Number of tokens burned (18-decimal WAD).
    event TokensBurned(address indexed burner, uint256 amount);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Minting would exceed the hard supply cap.
    /// @param requested Amount attempted.
    /// @param remaining Amount still available under the cap.
    error ExceedsMaxSupply(uint256 requested, uint256 remaining);

    /// @notice No new emission is available for the current epoch.
    error NoEmissionAvailable();

    /// @notice Burn amount exceeds caller's balance.
    /// @param requested Amount the caller tried to burn.
    /// @param available Caller's current balance.
    error InsufficientBalance(uint256 requested, uint256 available);

    // -------------------------------------------------------------------------
    // Initializer (replaces constructor for UUPS proxy)
    // -------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialises the PhiCoin token behind a UUPS proxy.
     * @dev Sets token metadata, grants admin/upgrader roles, and records genesis block.
     * @param admin Address that receives DEFAULT_ADMIN_ROLE and UPGRADER_ROLE.
     */
    function initialize(address admin) external initializer {
        __ERC20_init("PhiCoin", "PHI");
        __AccessControl_init();
        // UUPSUpgradeable in OZ 5.x has no __init function

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);

        genesisBlock = block.number;
    }

    // -------------------------------------------------------------------------
    // Emission logic
    // -------------------------------------------------------------------------

    /**
     * @notice Returns the current epoch number relative to genesis.
     * @return epoch The zero-indexed epoch number.
     */
    function currentEpoch() public view returns (uint256 epoch) {
        epoch = (block.number - genesisBlock) / BLOCKS_PER_EPOCH;
    }

    /**
     * @notice Computes the emission amount for a given epoch.
     * @dev Delegates to PhiMath.fibEmission which calculates:
     *      emission = F(epoch % 100) * phi^{-(epoch / 100)}
     *      All arithmetic is 18-decimal WAD fixed-point.
     * @param epoch The epoch number.
     * @return amount The emission amount in WAD (18-decimal tokens).
     */
    function emissionForEpoch(uint256 epoch) public pure returns (uint256 amount) {
        amount = PhiMath.fibEmission(epoch);
    }

    /**
     * @notice Mints the emission for all unclaimed epochs up to the current one.
     * @dev Only callable by addresses holding `MINTER_ROLE`.
     *      Reverts with `NoEmissionAvailable` if no new epochs have elapsed
     *      since the last mint. Automatically caps the total mint so that
     *      totalSupply never exceeds MAX_SUPPLY.
     */
    function mint() external onlyRole(MINTER_ROLE) {
        uint256 epoch = currentEpoch();

        // Revert if we have already minted for this epoch
        if (hasEverMinted && epoch <= lastMintedEpoch) {
            revert NoEmissionAvailable();
        }

        uint256 startEpoch = hasEverMinted ? lastMintedEpoch + 1 : 0;
        uint256 totalEmission;

        for (uint256 e = startEpoch; e <= epoch; e++) {
            totalEmission += emissionForEpoch(e);
        }

        if (totalEmission == 0) {
            revert NoEmissionAvailable();
        }

        // Enforce hard cap — silently reduce if needed
        uint256 remaining = MAX_SUPPLY - totalSupply();
        if (totalEmission > remaining) {
            totalEmission = remaining;
        }

        if (totalEmission == 0) {
            revert ExceedsMaxSupply(0, 0);
        }

        lastMintedEpoch = epoch;
        hasEverMinted = true;
        totalMinted += totalEmission;

        _mint(msg.sender, totalEmission);

        emit EmissionMinted(msg.sender, epoch, totalEmission);
    }

    /**
     * @notice Mints a specific amount of tokens to a recipient (e.g. staking rewards).
     * @dev Only callable by MINTER_ROLE. Respects the hard cap.
     * @param to     Recipient address.
     * @param amount Amount of tokens to mint (18-decimal WAD).
     */
    function mintTo(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        uint256 remaining = MAX_SUPPLY - totalSupply();
        if (amount > remaining) {
            revert ExceedsMaxSupply(amount, remaining);
        }
        totalMinted += amount;
        _mint(to, amount);
    }

    // -------------------------------------------------------------------------
    // Burn
    // -------------------------------------------------------------------------

    /**
     * @notice Burns tokens from the caller's balance (deflationary).
     * @dev Anyone can burn their own tokens. The tokens are permanently destroyed.
     * @param amount Number of tokens to burn (18-decimal WAD).
     */
    function burn(uint256 amount) external {
        if (balanceOf(msg.sender) < amount) {
            revert InsufficientBalance(amount, balanceOf(msg.sender));
        }
        _burn(msg.sender, amount);
        emit TokensBurned(msg.sender, amount);
    }

    // -------------------------------------------------------------------------
    // UUPS authorization
    // -------------------------------------------------------------------------

    /**
     * @dev Only UPGRADER_ROLE may authorise an implementation upgrade.
     * @param newImplementation Address of the new implementation contract.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    // -------------------------------------------------------------------------
    // View helpers
    // -------------------------------------------------------------------------

    /**
     * @notice Returns the number of tokens still mintable before hitting the hard cap.
     * @return The remaining mintable supply in WAD (18-decimal tokens).
     */
    function remainingSupply() external view returns (uint256) {
        return MAX_SUPPLY - totalSupply();
    }
}
