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
 * @title PhiCoin (PHI)
 * @author IBG Technologies
 * @notice ERC-20 token with Fibonacci emission, ERC20Votes, and ERC20Permit for governance.
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
    uint256 public constant MAX_SUPPLY = 1_618_033_988 * 1e18;
    uint256 public constant EPOCH_DURATION = 1200;

    uint256 public genesisTimestamp;
    uint256 public totalMinted;
    uint256 public lastMintedEpoch;
    bool public hasEverMinted;
    uint256[46] private __gap;

    event EmissionMinted(address indexed minter, uint256 indexed toEpoch, uint256 amount);
    event MintedTo(address indexed to, uint256 amount);
    event TokensBurned(address indexed burner, uint256 amount);

    error ExceedsMaxSupply(uint256 requested, uint256 remaining);
    error NoEmissionAvailable();
    error InsufficientBalance(uint256 requested, uint256 available);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address admin) external initializer {
        __ERC20_init("PhiCoin", "PHI");
        __ERC20Permit_init("PhiCoin");
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

    // Required overrides for ERC20 + ERC20Votes + ERC20Permit
    function _update(address from, address to, uint256 value)
        internal override(ERC20Upgradeable, ERC20VotesUpgradeable)
    { super._update(from, to, value); }

    function nonces(address owner)
        public view override(ERC20PermitUpgradeable, NoncesUpgradeable)
        returns (uint256)
    { return super.nonces(owner); }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    function remainingSupply() external view returns (uint256) {
        return MAX_SUPPLY - totalSupply();
    }
}
