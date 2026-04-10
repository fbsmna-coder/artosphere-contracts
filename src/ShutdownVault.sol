// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ShutdownVault — ERC-20 approval proxy for KillSwitch.claimShutdownShare
/// @author F.B. Sapronov
/// @notice Holds the graceful-shutdown reserve (seeded from ZeckendorfTreasury's
///         Insurance Fund compartment, 8M ARTS = F(6)×10⁶) and grants allowance
///         to KillSwitch so claimShutdownShare() can pull pro-rata payouts via
///         safeTransferFrom.
/// @dev ZeckendorfTreasury has no approve() entry point, so we route the
///      Insurance Fund through this vault. balanceOf(vault) becomes the
///      shutdown pool that KillSwitch snapshots on activation.
///
///      The primary token (ARTS) cannot be rescued — once funded, the pool is
///      locked until either shutdown activates or the admin explicitly revokes
///      the KillSwitch allowance (which is a public, visible action).
contract ShutdownVault is AccessControl {
    using SafeERC20 for IERC20;

    // --- Roles ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // --- Immutables ---
    IERC20 public immutable token;
    address public immutable killSwitch;

    // --- Events ---
    event SpenderApproved(address indexed spender, uint256 amount);
    event SpenderRevoked(address indexed spender);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    // --- Errors ---
    error ZeroAddress();
    error CannotRescuePrimaryToken();

    constructor(address _token, address _killSwitch, address admin) {
        if (_token == address(0) || _killSwitch == address(0) || admin == address(0)) {
            revert ZeroAddress();
        }
        token = IERC20(_token);
        killSwitch = _killSwitch;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
    }

    /// @notice Approve a spender (typically KillSwitch) to pull ARTS from this vault.
    /// @dev Use type(uint256).max for a one-time setup. Use forceApprove to handle
    ///      both legacy approvals and new ones safely.
    function approveSpender(address spender, uint256 amount) external onlyRole(ADMIN_ROLE) {
        if (spender == address(0)) revert ZeroAddress();
        token.forceApprove(spender, amount);
        emit SpenderApproved(spender, amount);
    }

    /// @notice Revoke a spender's allowance (emergency stop before shutdown activates).
    function revokeSpender(address spender) external onlyRole(ADMIN_ROLE) {
        if (spender == address(0)) revert ZeroAddress();
        token.forceApprove(spender, 0);
        emit SpenderRevoked(spender);
    }

    /// @notice Rescue non-primary tokens accidentally sent to this vault.
    /// @dev Cannot rescue the primary ARTS token — the shutdown reserve is locked.
    function rescueTokens(address _token, address to, uint256 amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (to == address(0)) revert ZeroAddress();
        if (_token == address(token)) revert CannotRescuePrimaryToken();
        IERC20(_token).safeTransfer(to, amount);
        emit TokensRescued(_token, to, amount);
    }

    /// @notice Current shutdown reserve balance.
    function shutdownReserve() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /// @notice Current allowance granted to KillSwitch.
    function killSwitchAllowance() external view returns (uint256) {
        return token.allowance(address(this), killSwitch);
    }
}
