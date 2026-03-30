// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PhiVesting} from "../src/PhiVesting.sol";
import {PhiMath} from "../src/PhiMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ---------------------------------------------------------------------------
// Simple ERC20 mock for vesting tests
// ---------------------------------------------------------------------------
contract MockERC20 is ERC20 {
    constructor(address holder, uint256 amount) ERC20("PhiCoin", "PHI") {
        _mint(holder, amount);
    }
}

// ---------------------------------------------------------------------------
// PhiVesting Test Suite
// ---------------------------------------------------------------------------
contract PhiVestingTest is Test {
    address public admin = makeAddr("admin");
    address public beneficiary = makeAddr("beneficiary");
    address public teamMember = makeAddr("teamMember");

    uint256 public constant GRANT_AMOUNT = 2_100_000 * 1e18; // divisible by 8 for clean math
    uint256 public constant MONTH = 30 days + 10 hours + 30 minutes; // matches contract MONTH_SECONDS

    MockERC20 public token;
    PhiVesting public vesting;

    // ---------------------------------------------------------------
    // Setup
    // ---------------------------------------------------------------

    function setUp() public {
        vm.startPrank(admin);

        token = new MockERC20(admin, GRANT_AMOUNT * 10);
        vesting = new PhiVesting(IERC20(address(token)), admin);

        // Approve vesting contract to pull tokens
        token.approve(address(vesting), type(uint256).max);

        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    function _createGrant(address who, uint256 amount, bool revocable) internal {
        vm.prank(admin);
        vesting.createGrant(who, amount, 0, revocable);
    }

    function _warpMonths(uint256 months) internal {
        vm.warp(block.timestamp + months * MONTH);
    }

    // ---------------------------------------------------------------
    // Test: Fibonacci unlock schedule
    // ---------------------------------------------------------------

    function test_unlockMonths() public view {
        // F(1)=1, F(2)=1, F(3)=2, F(4)=3, F(5)=5, F(6)=8, F(7)=13, F(8)=21
        assertEq(vesting.unlockMonth(0), 1);
        assertEq(vesting.unlockMonth(1), 1);
        assertEq(vesting.unlockMonth(2), 2);
        assertEq(vesting.unlockMonth(3), 3);
        assertEq(vesting.unlockMonth(4), 5);
        assertEq(vesting.unlockMonth(5), 8);
        assertEq(vesting.unlockMonth(6), 13);
        assertEq(vesting.unlockMonth(7), 21);
    }

    function test_grantCreation() public {
        _createGrant(beneficiary, GRANT_AMOUNT, false);

        (uint256 total, uint256 start, uint256 released, uint8 milestones, bool revocable, bool revoked) =
            vesting.grants(beneficiary);

        assertEq(total, GRANT_AMOUNT);
        assertEq(start, block.timestamp);
        assertEq(released, 0);
        assertEq(milestones, 0);
        assertFalse(revocable);
        assertFalse(revoked);

        // Tokens should be in vesting contract
        assertEq(token.balanceOf(address(vesting)), GRANT_AMOUNT);
    }

    function test_duplicateGrant_reverts() public {
        _createGrant(beneficiary, GRANT_AMOUNT, false);

        vm.prank(admin);
        vm.expectRevert();
        vesting.createGrant(beneficiary, GRANT_AMOUNT, 0, false);
    }

    function test_fibonacciUnlockSchedule_progressive() public {
        _createGrant(beneficiary, GRANT_AMOUNT, false);

        uint256 perMilestone = GRANT_AMOUNT / 8;

        // At month 2 (cliff): milestones 0,1,2 unlock (months 1,1,2)
        _warpMonths(2);
        uint256 releasableNow = vesting.releasable(beneficiary);
        assertEq(releasableNow, perMilestone * 3, "3 milestones at month 2");

        vm.prank(beneficiary);
        uint256 released = vesting.release();
        assertEq(released, perMilestone * 3);
        assertEq(token.balanceOf(beneficiary), perMilestone * 3);

        // At month 3: milestone 3 unlocks (F(4)=3)
        _warpMonths(1); // now at month 3
        releasableNow = vesting.releasable(beneficiary);
        assertEq(releasableNow, perMilestone);

        vm.prank(beneficiary);
        released = vesting.release();
        assertEq(released, perMilestone);

        // At month 5: milestone 4 (F(5)=5)
        _warpMonths(2); // now at month 5
        vm.prank(beneficiary);
        released = vesting.release();
        assertEq(released, perMilestone);

        // At month 8: milestone 5 (F(6)=8)
        _warpMonths(3); // now at month 8
        vm.prank(beneficiary);
        released = vesting.release();
        assertEq(released, perMilestone);

        // At month 13: milestone 6 (F(7)=13)
        _warpMonths(5); // now at month 13
        vm.prank(beneficiary);
        released = vesting.release();
        assertEq(released, perMilestone);

        // At month 21: milestone 7 (F(8)=21) — last milestone, sweeps dust
        _warpMonths(8); // now at month 21
        vm.prank(beneficiary);
        released = vesting.release();

        // Last milestone should sweep remaining (including rounding dust)
        uint256 expectedLast = GRANT_AMOUNT - (perMilestone * 7);
        assertEq(released, expectedLast, "Last unlock sweeps dust");
        assertEq(token.balanceOf(beneficiary), GRANT_AMOUNT, "Full amount released");
    }

    function test_fullVesting_21months() public {
        _createGrant(beneficiary, GRANT_AMOUNT, false);

        // Warp to month 21 and release everything at once
        _warpMonths(21);

        vm.prank(beneficiary);
        uint256 released = vesting.release();

        assertEq(released, GRANT_AMOUNT, "All tokens should be released at month 21");
        assertEq(token.balanceOf(beneficiary), GRANT_AMOUNT);
    }

    // ---------------------------------------------------------------
    // Test: Cliff enforcement
    // ---------------------------------------------------------------

    function test_cliff_beforeCliff_reverts() public {
        _createGrant(beneficiary, GRANT_AMOUNT, false);

        // At month 0 — before cliff
        vm.prank(beneficiary);
        vm.expectRevert();
        vesting.release();
    }

    function test_cliff_atOneMonth_reverts() public {
        _createGrant(beneficiary, GRANT_AMOUNT, false);

        // Warp to month 1 — still before cliff (cliff = 2 months)
        _warpMonths(1);

        // releasable should still be 0 (cliff not reached)
        // Note: month 1 < CLIFF_MONTHS(2), so the view returns 0
        assertEq(vesting.releasable(beneficiary), 0, "Nothing releasable before cliff");

        vm.prank(beneficiary);
        vm.expectRevert();
        vesting.release();
    }

    function test_cliff_atTwoMonths_releases() public {
        _createGrant(beneficiary, GRANT_AMOUNT, false);

        // Warp to exactly month 2 (cliff boundary)
        _warpMonths(2);

        uint256 rel = vesting.releasable(beneficiary);
        assertGt(rel, 0, "Should have releasable tokens at cliff");

        vm.prank(beneficiary);
        uint256 released = vesting.release();
        assertGt(released, 0, "Should release tokens at cliff");
    }

    // ---------------------------------------------------------------
    // Test: Revocation
    // ---------------------------------------------------------------

    function test_revoke_returnsUnvested() public {
        _createGrant(beneficiary, GRANT_AMOUNT, true); // revocable

        // Release some tokens first (warp past cliff)
        _warpMonths(2);
        vm.prank(beneficiary);
        uint256 released = vesting.release();
        assertGt(released, 0);

        uint256 adminBefore = token.balanceOf(admin);

        // Revoke
        vm.prank(admin);
        vesting.revokeGrant(beneficiary);

        uint256 adminAfter = token.balanceOf(admin);
        uint256 returned = adminAfter - adminBefore;
        assertEq(returned, GRANT_AMOUNT - released, "Unvested tokens returned to admin");

        // Verify grant is revoked
        (,,,,, bool revoked) = vesting.grants(beneficiary);
        assertTrue(revoked);
    }

    function test_revoke_beforeCliff_returnsAll() public {
        _createGrant(beneficiary, GRANT_AMOUNT, true);

        uint256 adminBefore = token.balanceOf(admin);

        vm.prank(admin);
        vesting.revokeGrant(beneficiary);

        uint256 adminAfter = token.balanceOf(admin);
        assertEq(adminAfter - adminBefore, GRANT_AMOUNT, "All tokens returned before cliff");
    }

    function test_revoke_nonRevocable_reverts() public {
        _createGrant(beneficiary, GRANT_AMOUNT, false); // non-revocable

        vm.prank(admin);
        vm.expectRevert();
        vesting.revokeGrant(beneficiary);
    }

    function test_revoke_doubleRevoke_reverts() public {
        _createGrant(beneficiary, GRANT_AMOUNT, true);

        vm.prank(admin);
        vesting.revokeGrant(beneficiary);

        vm.prank(admin);
        vm.expectRevert();
        vesting.revokeGrant(beneficiary);
    }

    function test_release_afterRevoke_reverts() public {
        _createGrant(beneficiary, GRANT_AMOUNT, true);
        _warpMonths(3);

        vm.prank(admin);
        vesting.revokeGrant(beneficiary);

        vm.prank(beneficiary);
        vm.expectRevert();
        vesting.release();
    }

    function test_revoke_onlyOwner() public {
        _createGrant(beneficiary, GRANT_AMOUNT, true);

        vm.prank(beneficiary);
        vm.expectRevert();
        vesting.revokeGrant(beneficiary);
    }

    // ---------------------------------------------------------------
    // Test: Edge cases
    // ---------------------------------------------------------------

    function test_noGrant_release_reverts() public {
        vm.prank(makeAddr("nobody"));
        vm.expectRevert();
        vesting.release();
    }

    function test_nothingToRelease_reverts() public {
        _createGrant(beneficiary, GRANT_AMOUNT, false);
        _warpMonths(2);

        // Release everything available
        vm.prank(beneficiary);
        vesting.release();

        // Try again immediately — nothing new to release
        vm.prank(beneficiary);
        vm.expectRevert();
        vesting.release();
    }

    function test_releasable_viewConsistency() public {
        _createGrant(beneficiary, GRANT_AMOUNT, false);
        _warpMonths(5);

        uint256 viewAmount = vesting.releasable(beneficiary);

        vm.prank(beneficiary);
        uint256 actualReleased = vesting.release();

        assertEq(viewAmount, actualReleased, "releasable() should match actual release");
    }
}
