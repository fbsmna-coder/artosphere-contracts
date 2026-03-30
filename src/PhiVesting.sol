// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {PhiMath} from "./PhiMath.sol";

/// @title PhiVesting — Fibonacci Vesting Schedule for PhiCoin
/// @author IBG Technologies
/// @notice Token vesting where unlocks happen at Fibonacci month boundaries:
///
///   Milestone:  0    1    2    3    4    5    6    7
///   Month F(n): F(1) F(2) F(3) F(4) F(5) F(6) F(7) F(8)
///              = 1    1    2    3    5    8    13   21
///
///   Each of the 8 unlock events releases totalAllocation / 8 tokens.
///   (Last unlock sweeps any rounding dust.)
///
///   Cliff: F(3) = 2 months — nothing released before month 2.
///   Total vesting: F(8) = 21 months.
///   Revocable by admin (for team/advisor allocations).
///
/// @dev Uses PhiMath.fibonacci() for schedule computation. Since fibonacci()
///      returns WAD-scaled values, we divide by WAD to get raw month numbers.
contract PhiVesting is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------

    /// @notice Number of unlock milestones (F(1) through F(8))
    uint256 public constant NUM_UNLOCKS = 8;

    /// @notice Cliff duration in months: F(3) = 2
    uint256 public constant CLIFF_MONTHS = 2;

    /// @notice Total vesting duration in months: F(8) = 21
    uint256 public constant TOTAL_MONTHS = 21;

    /// @notice Approximate seconds per month (~30.44 days)
    uint256 public constant MONTH_SECONDS = 30 days + 10 hours + 30 minutes;

    /// @notice Pre-computed Fibonacci unlock months for each milestone (gas savings)
    ///         F(1)=1, F(2)=1, F(3)=2, F(4)=3, F(5)=5, F(6)=8, F(7)=13, F(8)=21
    uint256 private constant _FIB_1 = 1;
    uint256 private constant _FIB_2 = 1;
    uint256 private constant _FIB_3 = 2;
    uint256 private constant _FIB_4 = 3;
    uint256 private constant _FIB_5 = 5;
    uint256 private constant _FIB_6 = 8;
    uint256 private constant _FIB_7 = 13;
    uint256 private constant _FIB_8 = 21;

    // ---------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------

    struct VestingGrant {
        uint256 totalAmount;        // total tokens allocated
        uint256 startTime;          // grant start timestamp
        uint256 releasedAmount;     // tokens already claimed
        uint8   releasedMilestones; // bitmask of claimed milestones (bits 0-7)
        bool    revocable;          // can admin revoke?
        bool    revoked;            // has been revoked?
    }

    // ---------------------------------------------------------------
    // State
    // ---------------------------------------------------------------

    IERC20 public immutable token;

    mapping(address => VestingGrant) public grants;

    // ---------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------

    event GrantCreated(address indexed beneficiary, uint256 amount, uint256 startTime, bool revocable);
    event TokensReleased(address indexed beneficiary, uint256 amount, uint256 milestone);
    event GrantRevoked(address indexed beneficiary, uint256 amountReturned);

    // ---------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error GrantAlreadyExists(address beneficiary);
    error NoGrant(address beneficiary);
    error NotRevocable();
    error AlreadyRevoked();
    error CliffNotReached(uint256 elapsedMonths, uint256 cliffMonths);
    error NothingToRelease();
    error GrantRevoked_();

    // ---------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------

    /// @param token_ The PhiCoin (or any ERC-20) token to vest
    /// @param admin_ Initial owner who can create and revoke grants
    constructor(IERC20 token_, address admin_) Ownable(admin_) {
        token = token_;
    }

    // ---------------------------------------------------------------
    // Admin: create & revoke grants
    // ---------------------------------------------------------------

    /// @notice Create a vesting grant for a beneficiary
    /// @param beneficiary Recipient of vested tokens
    /// @param amount Total tokens to vest (must be pre-approved)
    /// @param startTime Unix timestamp when vesting begins (0 = block.timestamp)
    /// @param revocable Whether admin can revoke unvested tokens
    function createGrant(
        address beneficiary,
        uint256 amount,
        uint256 startTime,
        bool revocable
    ) external onlyOwner {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (grants[beneficiary].totalAmount != 0) revert GrantAlreadyExists(beneficiary);

        uint256 start = startTime == 0 ? block.timestamp : startTime;

        grants[beneficiary] = VestingGrant({
            totalAmount: amount,
            startTime: start,
            releasedAmount: 0,
            releasedMilestones: 0,
            revocable: revocable,
            revoked: false
        });

        token.safeTransferFrom(msg.sender, address(this), amount);

        emit GrantCreated(beneficiary, amount, start, revocable);
    }

    /// @notice Revoke a grant and return unvested tokens to admin
    function revokeGrant(address beneficiary) external onlyOwner {
        VestingGrant storage g = grants[beneficiary];
        if (g.totalAmount == 0) revert NoGrant(beneficiary);
        if (!g.revocable) revert NotRevocable();
        if (g.revoked) revert AlreadyRevoked();

        g.revoked = true;

        uint256 unvested = g.totalAmount - g.releasedAmount;
        if (unvested > 0) {
            token.safeTransfer(owner(), unvested);
        }

        emit GrantRevoked(beneficiary, unvested);
    }

    // ---------------------------------------------------------------
    // Beneficiary: release vested tokens
    // ---------------------------------------------------------------

    /// @notice Release all currently vested (and unreleased) tokens
    /// @return totalReleased Amount of tokens released in this call
    function release() external nonReentrant returns (uint256 totalReleased) {
        VestingGrant storage g = grants[msg.sender];
        if (g.totalAmount == 0) revert NoGrant(msg.sender);
        if (g.revoked) revert GrantRevoked_();

        uint256 elapsed = block.timestamp > g.startTime ? block.timestamp - g.startTime : 0;
        uint256 elapsedMonths = elapsed / MONTH_SECONDS;

        if (elapsedMonths < CLIFF_MONTHS) revert CliffNotReached(elapsedMonths, CLIFF_MONTHS);

        uint256 amountPerMilestone = g.totalAmount / NUM_UNLOCKS;

        for (uint256 i = 0; i < NUM_UNLOCKS; i++) {
            // Skip already released
            if (g.releasedMilestones & uint8(1 << uint8(i)) != 0) continue;

            uint256 month = _fibUnlockMonth(i);
            if (elapsedMonths >= month) {
                g.releasedMilestones |= uint8(1 << uint8(i));

                uint256 amount;
                if (_allMilestonesReleased(g.releasedMilestones)) {
                    // Last milestone: sweep rounding dust
                    amount = g.totalAmount - g.releasedAmount;
                } else {
                    amount = amountPerMilestone;
                }

                g.releasedAmount += amount;
                totalReleased += amount;

                emit TokensReleased(msg.sender, amount, i);
            }
        }

        if (totalReleased == 0) revert NothingToRelease();
        token.safeTransfer(msg.sender, totalReleased);
    }

    // ---------------------------------------------------------------
    // View helpers
    // ---------------------------------------------------------------

    /// @notice How many tokens are currently releasable for `beneficiary`
    function releasable(address beneficiary) external view returns (uint256 amount) {
        VestingGrant storage g = grants[beneficiary];
        if (g.totalAmount == 0 || g.revoked) return 0;

        uint256 elapsed = block.timestamp > g.startTime ? block.timestamp - g.startTime : 0;
        uint256 elapsedMonths = elapsed / MONTH_SECONDS;

        if (elapsedMonths < CLIFF_MONTHS) return 0;

        uint256 amountPerMilestone = g.totalAmount / NUM_UNLOCKS;

        for (uint256 i = 0; i < NUM_UNLOCKS; i++) {
            if (g.releasedMilestones & uint8(1 << uint8(i)) != 0) continue;
            if (elapsedMonths >= _fibUnlockMonth(i)) {
                amount += amountPerMilestone;
            }
        }
    }

    /// @notice Get the Fibonacci unlock month for a given milestone index
    /// @param milestoneIndex 0-7 (maps to F(1) through F(8))
    function unlockMonth(uint256 milestoneIndex) external pure returns (uint256) {
        require(milestoneIndex < NUM_UNLOCKS, "PhiVesting: invalid milestone");
        return _fibUnlockMonth(milestoneIndex);
    }

    // ---------------------------------------------------------------
    // Internal — Fibonacci unlock schedule
    // ---------------------------------------------------------------

    /// @dev Returns month number for milestone index.
    ///      Uses pre-computed constants for gas efficiency.
    function _fibUnlockMonth(uint256 index) internal pure returns (uint256) {
        if (index == 0) return _FIB_1;  // F(1) = 1
        if (index == 1) return _FIB_2;  // F(2) = 1
        if (index == 2) return _FIB_3;  // F(3) = 2
        if (index == 3) return _FIB_4;  // F(4) = 3
        if (index == 4) return _FIB_5;  // F(5) = 5
        if (index == 5) return _FIB_6;  // F(6) = 8
        if (index == 6) return _FIB_7;  // F(7) = 13
        if (index == 7) return _FIB_8;  // F(8) = 21
        revert("PhiVesting: invalid index");
    }

    /// @dev Check if all 8 milestones have been released
    function _allMilestonesReleased(uint8 mask) internal pure returns (bool) {
        return mask == uint8((1 << NUM_UNLOCKS) - 1); // 0xFF
    }
}
